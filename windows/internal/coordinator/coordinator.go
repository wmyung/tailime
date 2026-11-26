package coordinator

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wmyung/tailime/windows/internal/core"
	"github.com/wmyung/tailime/windows/internal/netudp"
	"github.com/wmyung/tailime/windows/internal/storage"
	"github.com/wmyung/tailime/windows/internal/tailscale"
	"github.com/wmyung/tailime/windows/internal/winhook"
	"github.com/wmyung/tailime/windows/internal/winime"
	"github.com/wmyung/tailime/windows/internal/winsock"
)

type PingResult struct {
	Host  string
	RTTMs float64
	Lang  core.InputLanguage
}

type pendingSetReq struct {
	seq            uint64
	nonce          uint64
	targetDeviceID string
	targetIP       string
	targetHost     string
	targetLang     core.InputLanguage
	sentAt         time.Time
	retryTimer     *time.Timer
	expireTimer    *time.Timer
}

type pendingPingReq struct {
	seq            uint64
	nonce          uint64
	targetDeviceID string
	targetIP       string
	sentAt         time.Time
	ch             chan pingReply
}

type pingReply struct {
	res PingResult
	err error
}

type incomingSetTask struct {
	gen     uint64
	msg     core.WireMessage
	srcIP   string
	srcPort uint16
	peerKey []byte
	nonce   uint64
	selfID  string
	bootID  string
}

// Coordinator runs the full bidirectional TailIME remote engine on Windows:
// - Incoming TIV1 UDP commands (from macOS or Windows) -> deterministic Windows IME switch + ACK
// - Outgoing triggers (when Windows focuses RustDesk / RDP / VNC / Parsec) -> deterministic TIV1 UDP set(ko/en)
// - Auto-English lock on remote focus (and optional restore on blur)
// - Mutual simultaneous 6-digit SAS pairing + TKP1 token exchange
type Coordinator struct {
	mu                 sync.RWMutex
	identity           *core.CryptoIdentity
	identityPersistent bool
	identityErr        error
	bootSessionID      string
	store              *storage.Store
	ime                *winime.Engine
	hook               *winhook.Controller
	udp                *netudp.Endpoint

	seqCounter         atomic.Uint64
	paused             atomic.Bool
	snapshot           *core.TailscaleStatusSnapshot
	peerStates         map[string]core.RemotePeerRuntimeState
	lastKnownLangByIP  map[string]core.InputLanguage
	pendingSets        map[uint64]*pendingSetReq
	pendingPings       map[uint64]*pendingPingReq
	activePairPrompts  map[string]bool
	currentRemoteCtx   core.ActiveRemoteContext
	lastRemoteFocused  bool
	savedLocalLang     core.InputLanguage
	hasSavedLocalLang  bool
	lastForegroundHWND uintptr

	keepaliveStop chan struct{}

	// Serialized latest-wins incoming set executor (prevents concurrent SwitchTo races across IPv4/IPv6 sockets)
	setQueueMu         sync.Mutex
	queuedSet          *incomingSetTask
	lastEnqueuedSetSeq map[string]uint64
	setEnqueueGen      atomic.Uint64
	setWakeCh          chan struct{}
	workerStopCh       chan struct{}
	workerOnce         sync.Once
	stopOnce           sync.Once

	// UI callbacks (wire before calling Start)
	OnStateUpdated func()
	OnPairPrompt   func(peerName, srcIP, sas string) bool
	OnStatusNotice func(msg string)
}

func New(
	store *storage.Store,
	ime *winime.Engine,
	hook *winhook.Controller,
	udp *netudp.Endpoint,
) *Coordinator {
	boot := make([]byte, 6)
	_, _ = rand.Read(boot)
	ephem, _ := core.GenerateEphemeralIdentity()

	c := &Coordinator{
		identity:          ephem,
		bootSessionID:     hex.EncodeToString(boot),
		store:             store,
		ime:               ime,
		hook:              hook,
		udp:               udp,
		peerStates:        make(map[string]core.RemotePeerRuntimeState),
		lastKnownLangByIP: make(map[string]core.InputLanguage),
		pendingSets:       make(map[uint64]*pendingSetReq),
		pendingPings:      make(map[uint64]*pendingPingReq),
		activePairPrompts:  make(map[string]bool),
		lastEnqueuedSetSeq: make(map[string]uint64),
		setWakeCh:          make(chan struct{}, 1),
		workerStopCh:       make(chan struct{}),
	}

	udp.OnPacketReceived = c.handleIncomingPacket
	hook.OnRemoteTrigger = c.handleRemoteTrigger
	hook.OnForegroundChanged = c.RefreshForegroundContext
	store.OnSettingsChanged = func(s core.AppSettings) {
		udp.UpdatePort(s.UDPPort)
		c.syncHookSnapshot()
		c.notifyUI()
	}
	store.OnTrustedPeersChanged = func([]core.TrustedPeerRecord) {
		c.SyncKeysToEndpoint()
		c.notifyUI()
	}

	c.syncHookSnapshot()
	return c
}

// Start launches the serialized incoming-set worker and loads the DPAPI identity.
// Call AFTER wiring OnStateUpdated/OnPairPrompt/OnStatusNotice and starting the UDP endpoint.
func (c *Coordinator) Start() {
	c.startSetWorker()
	c.ReloadIdentity()
}

// Stop shuts down background keepalive and incoming-set worker goroutines cleanly.
func (c *Coordinator) Stop() {
	c.stopRemoteKeepalive()
	c.stopOnce.Do(func() {
		close(c.workerStopCh)
	})
}

func (c *Coordinator) startSetWorker() {
	c.workerOnce.Do(func() {
		go c.incomingSetWorker()
	})
}

func (c *Coordinator) enqueueIncomingSet(task incomingSetTask) {
	c.startSetWorker()
	sessionKey := task.msg.SenderDeviceID + "#" + task.msg.BootSessionID

	c.setQueueMu.Lock()
	// Enforce strict per-(sender, boot) monotonic seq ordering under lock so parallel IPv4/IPv6 readLoops
	// can never overwrite a newer command with an older one!
	if prevSeq, ok := c.lastEnqueuedSetSeq[sessionKey]; ok && task.msg.Seq <= prevSeq {
		c.setQueueMu.Unlock()
		return
	}
	if len(c.lastEnqueuedSetSeq) > 64 {
		c.lastEnqueuedSetSeq = map[string]uint64{}
	}
	c.lastEnqueuedSetSeq[sessionKey] = task.msg.Seq
	gen := c.setEnqueueGen.Add(1)
	task.gen = gen
	c.queuedSet = &task
	c.ime.Preempt()
	c.setQueueMu.Unlock()

	select {
	case c.setWakeCh <- struct{}{}:
	default:
	}
}

func (c *Coordinator) incomingSetWorker() {
	for {
		select {
		case <-c.workerStopCh:
			return
		case <-c.setWakeCh:
		}
		for {
			c.setQueueMu.Lock()
			task := c.queuedSet
			c.queuedSet = nil
			c.setQueueMu.Unlock()
			if task == nil {
				break
			}
			select {
			case <-c.workerStopCh:
				return
			default:
			}
			c.executeIncomingSet(*task)
		}
	}
}

func (c *Coordinator) executeIncomingSet(task incomingSetTask) {
	st := c.ime.SwitchTo(task.msg.TargetLanguage)
	// If a newer set request superseded this one mid-flight, let the newer one send the authoritative ACK.
	if c.setEnqueueGen.Load() != task.gen {
		return
	}
	okVal := st.Reliable && !st.ElevationBlocked && !st.SecureDesktop && st.Language == task.msg.TargetLanguage
	replySeq := task.msg.Seq
	ack := core.WireMessage{
		Cmd:             core.CmdAck,
		SenderDeviceID:  task.selfID,
		SenderName:      c.HostDisplayName(),
		SenderOS:        "windows",
		BootSessionID:   task.bootID,
		Seq:             c.nextSeq(),
		ReplyToSeq:      &replySeq,
		CurrentLanguage: st.Language,
		SourceID:        st.SourceID,
		OK:              &okVal,
		Via:             "udp",
		Version:         core.Version,
	}
	c.udp.CacheIdempotentReply(ack, task.msg.SenderDeviceID, task.msg.BootSessionID, task.msg.Seq)
	_ = c.udp.Send(ack, task.srcIP, task.srcPort, task.peerKey, task.nonce)
	c.notifyUI()
}

func (c *Coordinator) ReloadIdentity() bool {
	res := c.store.LoadOrCreateIdentity()
	c.mu.Lock()
	if res.IsPersistent() && res.Identity != nil {
		c.identity = res.Identity
		c.identityPersistent = true
		c.identityErr = nil
	} else {
		c.identityPersistent = false
		c.identityErr = res.Err
	}
	persistent := c.identityPersistent
	c.mu.Unlock()

	c.SyncKeysToEndpoint()
	if persistent {
		c.ProbeAllPairedPeers()
	}
	c.notifyUI()
	return persistent
}

func (c *Coordinator) ResetIdentityExplicit() error {
	fresh, err := c.store.ResetIdentity()
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.identity = fresh
	c.identityPersistent = true
	c.identityErr = nil
	c.mu.Unlock()
	c.SyncKeysToEndpoint()
	c.notifyUI()
	return nil
}

func (c *Coordinator) IdentityStatus() (persistent bool, deviceID string, err error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.identityPersistent, c.identity.DeviceID, c.identityErr
}

func (c *Coordinator) HostDisplayName() string {
	c.mu.RLock()
	snap := c.snapshot
	c.mu.RUnlock()
	if snap != nil && snap.SelfNode != nil && snap.SelfNode.HostName != "" {
		return snap.SelfNode.HostName
	}
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "Windows-PC"
}

func (c *Coordinator) SetPaused(p bool) {
	c.paused.Store(p)
	c.syncHookSnapshot()
	c.notifyUI()
}

func (c *Coordinator) IsPaused() bool {
	return c.paused.Load()
}

func (c *Coordinator) CurrentSnapshot() *core.TailscaleStatusSnapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.snapshot
}

func (c *Coordinator) CurrentRemoteContext() core.ActiveRemoteContext {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.currentRemoteCtx
}

func (c *Coordinator) PeerStates() map[string]core.RemotePeerRuntimeState {
	c.mu.RLock()
	defer c.mu.RUnlock()
	cp := make(map[string]core.RemotePeerRuntimeState, len(c.peerStates))
	for k, v := range c.peerStates {
		cp[k] = v
	}
	return cp
}

func (c *Coordinator) UpdateTailscaleSnapshot(snap *core.TailscaleStatusSnapshot) {
	if snap == nil {
		return
	}
	c.mu.Lock()
	c.snapshot = snap
	c.mu.Unlock()

	c.udp.UpdateTailscaleSnapshot(snap)

	// Keep saved peer IPs in sync for both macOS and Windows peers
	for _, peer := range snap.Peers {
		if !peer.IsTailIMESupportedOS() {
			continue
		}
		ip := peer.PreferredIP()
		if ip == "" {
			continue
		}
		for _, trusted := range c.store.TrustedPeers() {
			if strings.EqualFold(trusted.Name, peer.HostName) || strings.EqualFold(trusted.Name, peer.ShortDNSName()) {
				_ = c.store.UpdateTrustedPeerInfo(trusted.DeviceID, ip, peer.OS)
			}
		}
	}
	c.RefreshForegroundContext()
	c.notifyUI()
}

func (c *Coordinator) SyncKeysToEndpoint() {
	c.mu.RLock()
	id := c.identity
	persistent := c.identityPersistent
	c.mu.RUnlock()

	keys := make(map[string][]byte)
	if persistent && id != nil {
		for _, rec := range c.store.TrustedPeers() {
			if k, err := id.DerivePeerHMACKey(rec.PublicKeyBase64); err == nil {
				keys[rec.DeviceID] = k
			}
		}
	}
	c.udp.UpdatePeerKeys(keys)
	c.syncHookSnapshot()
}

func (c *Coordinator) syncHookSnapshot() {
	s := c.store.Settings()
	c.mu.RLock()
	ctx := c.currentRemoteCtx
	persistent := c.identityPersistent
	c.mu.RUnlock()

	ready := false
	if s.Enabled && !c.paused.Load() && s.RemoteSyncEnabled && ctx.HasActiveRemoteSession() {
		if persistent && ctx.ResolvedPeer != nil && c.trustedRecordForPeer(ctx.ResolvedPeer) != nil {
			ready = true
		} else if persistent && ctx.IsAmbiguousMultiSession {
			ready = true
		}
	}

	c.hook.UpdateSnapshot(winhook.Snapshot{
		Enabled:            s.Enabled,
		Paused:             c.paused.Load(),
		RemoteSessionReady: ready,
		TriggerHangulKey:   s.TriggerHangulKey,
		TriggerRightAltTap: s.TriggerRightAltTap,
		TriggerCtrlSpace:   s.TriggerCtrlSpace,
		TriggerShiftSpace:  s.TriggerShiftSpace,
		TriggerF18F19:      s.TriggerF18F19,
	})
}

// RefreshForegroundContext inspects the active foreground window & client Tailscale sockets,
// enforces Auto-English on remote focus, reinstalls WH_KEYBOARD_LL above viewer hooks, and updates UI.
func (c *Coordinator) RefreshForegroundContext() {
	fg := winsock.GetForegroundInfo()
	settings := c.store.Settings()

	c.mu.RLock()
	snap := c.snapshot
	prevHWND := c.lastForegroundHWND
	c.mu.RUnlock()

	var selfIPs []string
	if snap != nil && snap.SelfNode != nil {
		if snap.SelfNode.IPv4 != "" {
			selfIPs = append(selfIPs, snap.SelfNode.IPv4)
		}
		if snap.SelfNode.IPv6 != "" {
			selfIPs = append(selfIPs, snap.SelfNode.IPv6)
		}
	}

	var clientIPs []string
	if core.IsRemoteViewerProcess(fg.ProcessName, settings.AllRemoteProcessNames()) {
		clientIPs = winsock.ActiveTailscaleClientIPsForViewer(fg.PID, fg.ProcessName, selfIPs)
	}

	ctx := core.ResolveRemoteTarget(fg.ProcessName, fg.PID, fg.WindowTitle, clientIPs, snap, settings)
	isFocused := ctx.HasActiveRemoteSession()

	c.mu.Lock()
	prevFocused := c.lastRemoteFocused
	prevCtx := c.currentRemoteCtx
	c.currentRemoteCtx = ctx
	c.lastRemoteFocused = isFocused
	c.lastForegroundHWND = fg.HWND
	c.mu.Unlock()

	if isFocused && !prevFocused {
		// Reinstall WH_KEYBOARD_LL so TailIME sits ahead of mstsc/msrdc/rustdesk hooks!
		c.hook.RequestHookReinstall()
		if settings.AutoEnglishOnRemoteFocus {
			cur := c.ime.CurrentStatus()
			if cur.Reliable && cur.Language != core.LangEnglish {
				c.mu.Lock()
				c.savedLocalLang = cur.Language
				c.hasSavedLocalLang = true
				c.mu.Unlock()
				c.ime.SwitchTo(core.LangEnglish)
			}
		}
		if ctx.ResolvedPeer != nil {
			c.startRemoteKeepalive(ctx.ResolvedPeer.PreferredIP())
		}
	} else if !isFocused && prevFocused {
		c.stopRemoteKeepalive()
		c.mu.Lock()
		restore := settings.RestoreLocalOnRemoteBlur && c.hasSavedLocalLang
		saved := c.savedLocalLang
		c.hasSavedLocalLang = false
		c.mu.Unlock()
		if restore {
			c.ime.SwitchTo(saved)
		}
	} else if isFocused && fg.HWND != prevHWND {
		c.hook.RequestHookReinstall()
	}

	c.syncHookSnapshot()
	if prevCtx.HasActiveRemoteSession() != ctx.HasActiveRemoteSession() ||
		prevCtx.ProcessName != ctx.ProcessName ||
		(prevCtx.ResolvedPeer == nil) != (ctx.ResolvedPeer == nil) ||
		(prevCtx.ResolvedPeer != nil && ctx.ResolvedPeer != nil && prevCtx.ResolvedPeer.ID() != ctx.ResolvedPeer.ID()) {
		c.notifyUI()
	}
}

func (c *Coordinator) startRemoteKeepalive(peerIP string) {
	c.stopRemoteKeepalive()
	if peerIP == "" {
		return
	}
	c.RequestStatus(peerIP)
	stopCh := make(chan struct{})
	c.mu.Lock()
	c.keepaliveStop = stopCh
	c.mu.Unlock()

	go func() {
		t := time.NewTicker(20 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-stopCh:
				return
			case <-t.C:
				c.RequestStatus(peerIP)
			}
		}
	}()
}

func (c *Coordinator) stopRemoteKeepalive() {
	c.mu.Lock()
	ch := c.keepaliveStop
	c.keepaliveStop = nil
	c.mu.Unlock()
	if ch != nil {
		close(ch)
	}
}

func (c *Coordinator) handleRemoteTrigger(_ winhook.TriggerEvent) {
	settings := c.store.Settings()
	if !settings.Enabled || c.paused.Load() || !settings.RemoteSyncEnabled {
		return
	}
	c.mu.RLock()
	ctx := c.currentRemoteCtx
	snap := c.snapshot
	persistent := c.identityPersistent
	id := c.identity
	c.mu.RUnlock()

	if !persistent || id == nil {
		if c.OnStatusNotice != nil {
			c.OnStatusNotice("기기 키 잠금 상태 — 설정에서 키를 복구/초기화하세요")
		}
		return
	}

	peer := ctx.ResolvedPeer
	if peer == nil && ctx.IsAmbiguousMultiSession && snap != nil {
		var paired []*core.TailscalePeer
		for _, ip := range ctx.CandidatePeerIPs {
			if cand := snap.PeerMatchingIP(ip); cand != nil && c.trustedRecordForPeer(cand) != nil {
				paired = append(paired, cand)
			}
		}
		if len(paired) == 1 {
			peer = paired[0]
		} else {
			if c.OnStatusNotice != nil {
				c.OnStatusNotice("원격 대상이 여러 개입니다. 트레이 메뉴에서 대상을 고정(Pin)해 주세요.")
			}
			return
		}
	}
	if peer == nil {
		return
	}
	ip := peer.PreferredIP()
	trusted := c.trustedRecordForPeer(peer)
	if ip == "" || trusted == nil {
		return
	}
	hmacKey, err := id.DerivePeerHMACKey(trusted.PublicKeyBase64)
	if err != nil {
		return
	}

	c.mu.Lock()
	curLang := core.LangEnglish
	if st, ok := c.peerStates[ip]; ok {
		curLang = st.CurrentLanguage
	} else if last, ok := c.lastKnownLangByIP[ip]; ok {
		curLang = last
	}
	targetLang := curLang.Toggled()
	c.lastKnownLangByIP[ip] = targetLang
	if st, ok := c.peerStates[ip]; ok {
		st.CurrentLanguage = targetLang
		c.peerStates[ip] = st
	}
	c.mu.Unlock()

	c.sendDirectSet(targetLang, trusted.DeviceID, ip, peer.HostName, hmacKey)
	c.notifyUI()
}

func (c *Coordinator) nextSeq() uint64 {
	return c.seqCounter.Add(1)
}

func (c *Coordinator) sendDirectSet(targetLang core.InputLanguage, targetDeviceID, ip, hostName string, key []byte) {
	c.mu.RLock()
	id := c.identity
	boot := c.bootSessionID
	c.mu.RUnlock()

	seq := c.nextSeq()
	nonce := core.RandomNonce()
	msg := core.WireMessage{
		Cmd:            core.CmdSet,
		SenderDeviceID: id.DeviceID,
		SenderName:     c.HostDisplayName(),
		SenderOS:       "windows",
		BootSessionID:  boot,
		Seq:            seq,
		TargetLanguage: targetLang,
		Version:        core.Version,
	}

	req := &pendingSetReq{
		seq:            seq,
		nonce:          nonce,
		targetDeviceID: targetDeviceID,
		targetIP:       ip,
		targetHost:     hostName,
		targetLang:     targetLang,
		sentAt:         time.Now(),
	}
	c.mu.Lock()
	req.retryTimer = time.AfterFunc(35*time.Millisecond, func() {
		c.mu.RLock()
		_, stillPending := c.pendingSets[seq]
		c.mu.RUnlock()
		if stillPending {
			_ = c.udp.Send(msg, ip, 0, key, nonce)
		}
	})
	req.expireTimer = time.AfterFunc(1500*time.Millisecond, func() {
		c.mu.Lock()
		if p, ok := c.pendingSets[seq]; ok {
			p.retryTimer.Stop()
			delete(c.pendingSets, seq)
		}
		c.mu.Unlock()
	})
	c.pendingSets[seq] = req
	c.mu.Unlock()

	if err := c.udp.Send(msg, ip, 0, key, nonce); err != nil {
		c.mu.Lock()
		if p, ok := c.pendingSets[seq]; ok {
			p.retryTimer.Stop()
			p.expireTimer.Stop()
			delete(c.pendingSets, seq)
		}
		c.mu.Unlock()
	}
}

func (c *Coordinator) SendManualRemoteSet(targetQuery string, targetLang core.InputLanguage) (peerName, ip string, err error) {
	c.mu.RLock()
	persistent := c.identityPersistent
	id := c.identity
	snap := c.snapshot
	c.mu.RUnlock()
	if !persistent || id == nil {
		return "", "", errors.New("device identity is locked")
	}

	var trusted *core.TrustedPeerRecord
	if rec := c.store.TrustedPeerMatchingIP(targetQuery); rec != nil {
		trusted = rec
	} else if snap != nil {
		if p := snap.PeerMatchingIP(targetQuery); p != nil {
			trusted = c.trustedRecordForPeer(p)
		}
	}
	if trusted == nil {
		for _, rec := range c.store.TrustedPeers() {
			if strings.EqualFold(rec.Name, targetQuery) {
				cp := rec
				trusted = &cp
				break
			}
		}
	}
	if trusted == nil {
		return "", "", errors.New("peer not paired")
	}
	liveIP := c.resolveLiveIP(trusted)
	if liveIP == "" && (core.IsTailscaleIP(targetQuery) || core.IsLoopback(targetQuery)) {
		liveIP = core.NormalizeIP(targetQuery)
	}
	if liveIP == "" {
		return "", "", errors.New("peer IP unknown")
	}
	key, err := id.DerivePeerHMACKey(trusted.PublicKeyBase64)
	if err != nil {
		return "", "", err
	}

	c.mu.Lock()
	c.lastKnownLangByIP[liveIP] = targetLang
	if st, ok := c.peerStates[liveIP]; ok {
		st.CurrentLanguage = targetLang
		c.peerStates[liveIP] = st
	}
	c.mu.Unlock()

	c.sendDirectSet(targetLang, trusted.DeviceID, liveIP, trusted.Name, key)
	return trusted.Name, liveIP, nil
}

func (c *Coordinator) RequestStatus(peerIP string) {
	c.mu.RLock()
	persistent := c.identityPersistent
	id := c.identity
	boot := c.bootSessionID
	c.mu.RUnlock()
	if !persistent || id == nil {
		return
	}
	trusted := c.trustedRecordForIP(peerIP)
	if trusted == nil {
		return
	}
	key, err := id.DerivePeerHMACKey(trusted.PublicKeyBase64)
	if err != nil {
		return
	}
	msg := core.WireMessage{
		Cmd:            core.CmdStatus,
		SenderDeviceID: id.DeviceID,
		SenderName:     c.HostDisplayName(),
		SenderOS:       "windows",
		BootSessionID:  boot,
		Seq:            c.nextSeq(),
		Version:        core.Version,
	}
	_ = c.udp.Send(msg, peerIP, 0, key, 0)
}

func (c *Coordinator) PingPeer(ip string) (PingResult, error) {
	c.mu.RLock()
	persistent := c.identityPersistent
	id := c.identity
	boot := c.bootSessionID
	c.mu.RUnlock()
	if !persistent || id == nil {
		return PingResult{}, errors.New("기기 키가 잠겨 있습니다. 설정에서 키를 복구/초기화하세요")
	}
	trusted := c.trustedRecordForIP(ip)
	if trusted == nil {
		return PingResult{}, errors.New("먼저 이 기기와 페어링해야 합니다")
	}
	key, err := id.DerivePeerHMACKey(trusted.PublicKeyBase64)
	if err != nil {
		return PingResult{}, err
	}
	seq := c.nextSeq()
	nonce := core.RandomNonce()
	ch := make(chan pingReply, 1)
	c.mu.Lock()
	c.pendingPings[seq] = &pendingPingReq{
		seq:            seq,
		nonce:          nonce,
		targetDeviceID: trusted.DeviceID,
		targetIP:       core.NormalizeIP(ip),
		sentAt:         time.Now(),
		ch:             ch,
	}
	c.mu.Unlock()

	msg := core.WireMessage{
		Cmd:            core.CmdPing,
		SenderDeviceID: id.DeviceID,
		SenderName:     c.HostDisplayName(),
		SenderOS:       "windows",
		BootSessionID:  boot,
		Seq:            seq,
		Version:        core.Version,
	}
	if err := c.udp.Send(msg, ip, 0, key, nonce); err != nil {
		c.mu.Lock()
		delete(c.pendingPings, seq)
		c.mu.Unlock()
		return PingResult{}, err
	}

	retryTimer := time.AfterFunc(350*time.Millisecond, func() {
		c.mu.RLock()
		_, stillWaiting := c.pendingPings[seq]
		c.mu.RUnlock()
		if stillWaiting {
			_ = c.udp.Send(msg, ip, 0, key, nonce)
		}
	})
	defer retryTimer.Stop()

	select {
	case rep := <-ch:
		return rep.res, rep.err
	case <-time.After(2500 * time.Millisecond):
		c.mu.Lock()
		delete(c.pendingPings, seq)
		c.mu.Unlock()
		return PingResult{}, errors.New("응답 시간 초과 (상대 기기 TailIME 실행 및 방화벽·Tailscale 연결 확인)")
	}
}

func (c *Coordinator) ProbeAllPairedPeers() {
	c.mu.RLock()
	persistent := c.identityPersistent
	c.mu.RUnlock()
	if !persistent {
		return
	}
	for _, rec := range c.store.TrustedPeers() {
		if ip := c.resolveLiveIP(&rec); ip != "" {
			go func(targetIP string) {
				_, _ = c.PingPeer(targetIP)
			}(ip)
		}
	}
}

func (c *Coordinator) ExportPairingToken() (string, error) {
	c.mu.RLock()
	persistent := c.identityPersistent
	id := c.identity
	snap := c.snapshot
	c.mu.RUnlock()
	if !persistent || id == nil {
		return "", errors.New("기기 키가 잠겨 있어 페어링 토큰을 생성할 수 없습니다")
	}
	var selfIP string
	if snap != nil && snap.SelfNode != nil {
		selfIP = snap.SelfNode.PreferredIP()
	}
	if selfIP == "" {
		v4, v6 := tailscale.DiscoverLocalTailscaleIPs()
		if v4 != "" {
			selfIP = v4
		} else {
			selfIP = v6
		}
	}
	return id.ExportPairingToken(c.HostDisplayName(), selfIP, c.store.Settings().UDPPort)
}

func (c *Coordinator) ImportPairingToken(token string) (*core.TrustedPeerRecord, error) {
	c.mu.RLock()
	id := c.identity
	persistent := c.identityPersistent
	c.mu.RUnlock()
	if !persistent || id == nil {
		return nil, errors.New("기기 키가 잠겨 있습니다")
	}
	payload, err := core.DecodePairingToken(token)
	if err != nil {
		return nil, err
	}
	if payload.DeviceID == id.DeviceID {
		return nil, errors.New("자기 자신의 토큰은 등록할 수 없습니다")
	}
	rec := core.TrustedPeerRecord{
		DeviceID:        payload.DeviceID,
		Name:            payload.Name,
		PublicKeyBase64: payload.PublicKeyBase64,
		LastKnownIP:     payload.TailscaleIP,
		OS:              payload.OS,
		PairedAt:        time.Now(),
	}
	if err := c.store.SaveTrustedPeer(rec); err != nil {
		return nil, err
	}
	enriched := tailscale.EnrichSnapshot(c.CurrentSnapshot(), c.store.TrustedPeers())
	c.mu.Lock()
	c.snapshot = enriched
	c.mu.Unlock()
	c.udp.UpdateTailscaleSnapshot(enriched)
	c.SyncKeysToEndpoint()
	if rec.LastKnownIP != "" {
		go func(ip string) { _, _ = c.PingPeer(ip) }(rec.LastKnownIP)
	}
	c.notifyUI()
	return &rec, nil
}

func (c *Coordinator) InitiatePairing(peerIP string, isReply bool) error {
	trimmed := strings.TrimSpace(peerIP)
	if !core.IsTailscaleIP(trimmed) && !core.IsLoopback(trimmed) {
		return errors.New("올바른 Tailscale IP(100.x.y.z)를 입력해 주세요")
	}
	c.mu.RLock()
	persistent := c.identityPersistent
	id := c.identity
	boot := c.bootSessionID
	c.mu.RUnlock()
	if !persistent || id == nil {
		return errors.New("기기 키가 잠겨 있어 페어링을 시작할 수 없습니다")
	}
	sendHello := func() error {
		replyFlag := isReply
		msg := core.WireMessage{
			Cmd:             core.CmdPairHello,
			SenderDeviceID:  id.DeviceID,
			SenderName:      c.HostDisplayName(),
			SenderOS:        "windows",
			BootSessionID:   boot,
			Seq:             c.nextSeq(),
			PublicKeyBase64: id.PublicKeyBase64,
			PairReply:       &replyFlag,
			Version:         core.Version,
		}
		return c.udp.Send(msg, trimmed, 0, nil, 0)
	}
	if err := sendHello(); err != nil {
		return err
	}
	if !isReply {
		for _, delay := range []time.Duration{450 * time.Millisecond, 1100 * time.Millisecond} {
			time.AfterFunc(delay, func() {
				if c.store.TrustedPeerMatchingIP(trimmed) == nil {
					_ = sendHello()
				}
			})
		}
	}
	return nil
}

// MARK: - Incoming Packet Handler

func (c *Coordinator) handleIncomingPacket(in netudp.IncomingPacket) {
	msg := in.Packet.Message
	srcIP := in.SourceIP
	srcPort := in.SourcePort

	c.mu.RLock()
	id := c.identity
	persistent := c.identityPersistent
	boot := c.bootSessionID
	c.mu.RUnlock()
	if !persistent || id == nil {
		return
	}

	var peerKey []byte
	if trusted := c.store.TrustedPeerByDeviceID(msg.SenderDeviceID); trusted != nil {
		peerKey, _ = id.DerivePeerHMACKey(trusted.PublicKeyBase64)
	}

	// Only update saved peer IP/OS & reachable state after constant-time HMAC verification succeeds!
	if in.Packet.Authenticated {
		ipToUpdate := ""
		if core.IsTailscaleIP(srcIP) {
			ipToUpdate = srcIP
		}
		if ipToUpdate != "" || msg.SenderOS != "" {
			_ = c.store.UpdateTrustedPeerInfo(msg.SenderDeviceID, ipToUpdate, msg.SenderOS)
		}
		c.mu.Lock()
		st := c.peerStates[srcIP]
		if st.HostName == "" {
			if msg.SenderName != "" {
				st.HostName = msg.SenderName
			} else {
				st.HostName = srcIP
			}
		}
		st.PeerID = msg.SenderDeviceID
		st.IP = srcIP
		st.DaemonReachable = true
		st.LastSeenAt = time.Now()
		if msg.CurrentLanguage != "" {
			st.CurrentLanguage = msg.CurrentLanguage
			c.lastKnownLangByIP[srcIP] = msg.CurrentLanguage
		}
		c.peerStates[srcIP] = st
		c.mu.Unlock()
		c.notifyUI()
	}

	switch msg.Cmd {
	case core.CmdPairHello:
		go c.handleIncomingPairHello(msg, srcIP, srcPort)

	case core.CmdPairAck:
		if !in.Packet.Authenticated {
			return
		}
		go func() { _, _ = c.PingPeer(srcIP) }()

	case core.CmdPing:
		if !in.Packet.Authenticated || len(peerKey) == 0 {
			return
		}
		cur := c.ime.CurrentStatus()
		okTrue := true
		replySeq := msg.Seq
		pong := core.WireMessage{
			Cmd:             core.CmdPong,
			SenderDeviceID:  id.DeviceID,
			SenderName:      c.HostDisplayName(),
			SenderOS:        "windows",
			BootSessionID:   boot,
			Seq:             c.nextSeq(),
			ReplyToSeq:      &replySeq,
			CurrentLanguage: cur.Language,
			SourceID:        cur.SourceID,
			OK:              &okTrue,
			Version:         core.Version,
		}
		c.udp.CacheIdempotentReply(pong, msg.SenderDeviceID, msg.BootSessionID, msg.Seq)
		_ = c.udp.Send(pong, srcIP, srcPort, peerKey, in.Packet.Nonce)

	case core.CmdPong:
		if !in.Packet.Authenticated || msg.ReplyToSeq == nil {
			return
		}
		c.mu.Lock()
		pending := c.pendingPings[*msg.ReplyToSeq]
		if pending == nil || pending.targetDeviceID != msg.SenderDeviceID || pending.targetIP != srcIP || pending.nonce != in.Packet.Nonce {
			c.mu.Unlock()
			return
		}
		delete(c.pendingPings, *msg.ReplyToSeq)
		rtt := float64(time.Since(pending.sentAt).Microseconds()) / 1000.0
		if rtt < 0.1 {
			rtt = 0.1
		}
		lang := msg.CurrentLanguage
		if lang == "" {
			lang = core.LangEnglish
		}
		host := msg.SenderName
		if host == "" {
			host = srcIP
		}
		c.lastKnownLangByIP[srcIP] = lang
		c.peerStates[srcIP] = core.RemotePeerRuntimeState{
			PeerID:          msg.SenderDeviceID,
			HostName:        host,
			IP:              srcIP,
			DaemonReachable: true,
			LastRTTMs:       rtt,
			HasRTT:          true,
			CurrentLanguage: lang,
			CurrentSourceID: msg.SourceID,
			LastSeenAt:      time.Now(),
		}
		c.mu.Unlock()

		pending.ch <- pingReply{res: PingResult{Host: host, RTTMs: rtt, Lang: lang}}
		c.notifyUI()

	case core.CmdStatus:
		if !in.Packet.Authenticated || len(peerKey) == 0 {
			return
		}
		cur := c.ime.CurrentStatus()
		okTrue := true
		replySeq := msg.Seq
		stMsg := core.WireMessage{
			Cmd:             core.CmdState,
			SenderDeviceID:  id.DeviceID,
			SenderName:      c.HostDisplayName(),
			SenderOS:        "windows",
			BootSessionID:   boot,
			Seq:             c.nextSeq(),
			ReplyToSeq:      &replySeq,
			CurrentLanguage: cur.Language,
			SourceID:        cur.SourceID,
			OK:              &okTrue,
			Version:         core.Version,
		}
		_ = c.udp.Send(stMsg, srcIP, srcPort, peerKey, in.Packet.Nonce)

	case core.CmdState:
		if !in.Packet.Authenticated || msg.CurrentLanguage == "" {
			return
		}
		host := msg.SenderName
		if host == "" {
			host = srcIP
		}
		c.mu.Lock()
		c.lastKnownLangByIP[srcIP] = msg.CurrentLanguage
		st := c.peerStates[srcIP]
		st.PeerID = msg.SenderDeviceID
		st.HostName = host
		st.IP = srcIP
		st.DaemonReachable = true
		st.CurrentLanguage = msg.CurrentLanguage
		st.CurrentSourceID = msg.SourceID
		st.LastSeenAt = time.Now()
		c.peerStates[srcIP] = st
		c.mu.Unlock()
		c.notifyUI()

	case core.CmdSet, core.CmdExpectSet:
		if !in.Packet.Authenticated || len(peerKey) == 0 || msg.TargetLanguage == "" {
			return
		}
		// Queue onto single serialized latest-wins worker so UDP readLoop never blocks and concurrent sets cannot race!
		c.enqueueIncomingSet(incomingSetTask{
			msg:     msg,
			srcIP:   srcIP,
			srcPort: srcPort,
			peerKey: peerKey,
			nonce:   in.Packet.Nonce,
			selfID:  id.DeviceID,
			bootID:  boot,
		})

	case core.CmdAck:
		if !in.Packet.Authenticated || msg.ReplyToSeq == nil {
			return
		}
		c.mu.Lock()
		req := c.pendingSets[*msg.ReplyToSeq]
		if req == nil || req.targetDeviceID != msg.SenderDeviceID || req.targetIP != srcIP || req.nonce != in.Packet.Nonce {
			c.mu.Unlock()
			return
		}
		delete(c.pendingSets, *msg.ReplyToSeq)
		req.retryTimer.Stop()
		req.expireTimer.Stop()

		ackOK := msg.OK == nil || *msg.OK
		rtt := float64(time.Since(req.sentAt).Microseconds()) / 1000.0
		if rtt < 0.1 {
			rtt = 0.1
		}
		resLang := msg.CurrentLanguage
		if resLang == "" {
			if ackOK {
				resLang = req.targetLang
			} else if prev, ok := c.peerStates[srcIP]; ok && prev.CurrentLanguage != "" {
				resLang = prev.CurrentLanguage
			} else {
				resLang = core.LangEnglish
			}
		}
		host := msg.SenderName
		if host == "" {
			host = req.targetHost
		}
		c.lastKnownLangByIP[srcIP] = resLang
		c.peerStates[srcIP] = core.RemotePeerRuntimeState{
			PeerID:          msg.SenderDeviceID,
			HostName:        host,
			IP:              srcIP,
			DaemonReachable: true,
			LastRTTMs:       rtt,
			HasRTT:          true,
			CurrentLanguage: resLang,
			CurrentSourceID: msg.SourceID,
			LastSeenAt:      time.Now(),
		}
		noticeFn := c.OnStatusNotice
		c.mu.Unlock()
		if !ackOK && noticeFn != nil {
			noticeFn(fmt.Sprintf("⚠ %s 한영 전환 실패 (상대 기기 권한/잠금 화면 확인)", host))
		}
		c.notifyUI()

	case core.CmdProbeQuery:
		// Windows never uses macOS in-band F16/F17/F20 carriers; reply cleanly with probeObserved=false.
		if !in.Packet.Authenticated || len(peerKey) == 0 {
			return
		}
		okTrue := true
		obsFalse := false
		replySeq := msg.Seq
		res := core.WireMessage{
			Cmd:            core.CmdProbeResult,
			SenderDeviceID: id.DeviceID,
			SenderName:     c.HostDisplayName(),
			SenderOS:       "windows",
			BootSessionID:  boot,
			Seq:            c.nextSeq(),
			ReplyToSeq:     &replySeq,
			OK:             &okTrue,
			Via:            "windows-udp-only",
			ProbeToken:     msg.ProbeToken,
			ProbeObserved:  &obsFalse,
			Version:        core.Version,
		}
		_ = c.udp.Send(res, srcIP, srcPort, peerKey, in.Packet.Nonce)
	}
}

func (c *Coordinator) handleIncomingPairHello(msg core.WireMessage, srcIP string, srcPort uint16) {
	c.mu.RLock()
	id := c.identity
	persistent := c.identityPersistent
	boot := c.bootSessionID
	promptFn := c.OnPairPrompt
	c.mu.RUnlock()
	if !persistent || id == nil || msg.SenderDeviceID == id.DeviceID {
		return
	}
	derivedID, ok := core.DeviceIDForPublicKeyBase64(msg.PublicKeyBase64)
	if !ok || derivedID != msg.SenderDeviceID {
		return
	}

	// Already trusted with exact same public key -> send authenticated pairAck immediately.
	if existing := c.store.TrustedPeerByDeviceID(msg.SenderDeviceID); existing != nil && existing.PublicKeyBase64 == msg.PublicKeyBase64 {
		if key, err := id.DerivePeerHMACKey(msg.PublicKeyBase64); err == nil {
			okTrue := true
			replySeq := msg.Seq
			ack := core.WireMessage{
				Cmd:            core.CmdPairAck,
				SenderDeviceID: id.DeviceID,
				SenderName:     c.HostDisplayName(),
				SenderOS:       "windows",
				BootSessionID:  boot,
				Seq:            c.nextSeq(),
				ReplyToSeq:     &replySeq,
				OK:             &okTrue,
				Version:        core.Version,
			}
			_ = c.udp.Send(ack, srcIP, srcPort, key, 0)
		}
		return
	}

	// Step 1 of mutual simultaneous SAS handshake: echo our publicKey BEFORE showing prompt!
	if msg.PairReply == nil || !*msg.PairReply {
		_ = c.InitiatePairing(srcIP, true)
	}

	sas, err := id.ConfirmationCode(msg.PublicKeyBase64)
	if err != nil {
		return
	}

	c.mu.Lock()
	if c.activePairPrompts[msg.SenderDeviceID] {
		c.mu.Unlock()
		return
	}
	c.activePairPrompts[msg.SenderDeviceID] = true
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.activePairPrompts, msg.SenderDeviceID)
		c.mu.Unlock()
	}()

	peerName := msg.SenderName
	if peerName == "" {
		peerName = srcIP
	}
	if promptFn == nil || !promptFn(peerName, srcIP, sas) {
		return
	}

	rec := core.TrustedPeerRecord{
		DeviceID:        msg.SenderDeviceID,
		Name:            peerName,
		PublicKeyBase64: msg.PublicKeyBase64,
		LastKnownIP:     srcIP,
		OS:              msg.SenderOS,
		PairedAt:        time.Now(),
	}
	_ = c.store.SaveTrustedPeer(rec)
	enriched := tailscale.EnrichSnapshot(c.CurrentSnapshot(), c.store.TrustedPeers())
	c.mu.Lock()
	c.snapshot = enriched
	c.mu.Unlock()
	c.udp.UpdateTailscaleSnapshot(enriched)
	c.SyncKeysToEndpoint()

	if key, err := id.DerivePeerHMACKey(msg.PublicKeyBase64); err == nil {
		okTrue := true
		replySeq := msg.Seq
		ack := core.WireMessage{
			Cmd:            core.CmdPairAck,
			SenderDeviceID: id.DeviceID,
			SenderName:     c.HostDisplayName(),
			SenderOS:       "windows",
			BootSessionID:  boot,
			Seq:            c.nextSeq(),
			ReplyToSeq:     &replySeq,
			OK:             &okTrue,
			Version:        core.Version,
		}
		_ = c.udp.Send(ack, srcIP, srcPort, key, 0)
	}
	c.notifyUI()
}

// Helpers

func (c *Coordinator) trustedRecordForPeer(p *core.TailscalePeer) *core.TrustedPeerRecord {
	if p == nil {
		return nil
	}
	if p.IPv4 != "" {
		if r := c.store.TrustedPeerMatchingIP(p.IPv4); r != nil {
			return r
		}
	}
	if p.IPv6 != "" {
		if r := c.store.TrustedPeerMatchingIP(p.IPv6); r != nil {
			return r
		}
	}
	for _, rec := range c.store.TrustedPeers() {
		if strings.EqualFold(rec.Name, p.HostName) || strings.EqualFold(rec.Name, p.ShortDNSName()) {
			cp := rec
			return &cp
		}
	}
	return nil
}

func (c *Coordinator) trustedRecordForIP(ip string) *core.TrustedPeerRecord {
	if r := c.store.TrustedPeerMatchingIP(ip); r != nil {
		return r
	}
	c.mu.RLock()
	snap := c.snapshot
	c.mu.RUnlock()
	if snap != nil {
		if p := snap.PeerMatchingIP(ip); p != nil {
			return c.trustedRecordForPeer(p)
		}
	}
	return nil
}

func (c *Coordinator) resolveLiveIP(rec *core.TrustedPeerRecord) string {
	c.mu.RLock()
	snap := c.snapshot
	c.mu.RUnlock()
	if snap != nil {
		for i := range snap.Peers {
			p := &snap.Peers[i]
			if strings.EqualFold(p.HostName, rec.Name) || strings.EqualFold(p.ShortDNSName(), rec.Name) {
				if ip := p.PreferredIP(); ip != "" {
					return ip
				}
			}
		}
	}
	return rec.LastKnownIP
}

func (c *Coordinator) notifyUI() {
	if c.OnStateUpdated != nil {
		c.OnStateUpdated()
	}
}

func FormatDiagnosticsSummary(c *Coordinator) string {
	persistent, devID, kcErr := c.IdentityStatus()
	st := c.ime.CurrentStatus()
	ctx := c.CurrentRemoteContext()
	bound := c.udp.BoundAddresses()
	keyDesc := "정상 (DPAPI 영구 키)"
	if !persistent {
		keyDesc = fmt.Sprintf("⚠ 잠금/복호화 오류 (%v)", kcErr)
	}
	elevDesc := "정상"
	if c.ime.LastElevationBlocked() {
		elevDesc = "⚠ 관리자 권한 창(UIPI) 감지 — 관리자 권한 실행 필요"
	} else if c.ime.SelfElevated() {
		elevDesc = "관리자 권한으로 실행 중"
	}
	remoteDesc := "로컬 앱 포커스"
	if ctx.HasActiveRemoteSession() {
		host := "미확정"
		if ctx.ResolvedPeer != nil {
			host = ctx.ResolvedPeer.HostName
		}
		remoteDesc = fmt.Sprintf("%s → %s (%s)", ctx.ProcessName, host, ctx.ResolutionSource)
	}
	devShort := devID
	if len(devShort) > 8 {
		devShort = devShort[:8] + "…"
	}
	return fmt.Sprintf(
		"TailIME Windows v%s\r\n"+
			"• 기기 키(DPAPI): %s (ID %s)\r\n"+
			"• 현재 로컬 IME: %s (%s)\r\n"+
			"• 키보드 훅: %v  |  권한(UIPI): %s\r\n"+
			"• UDP 바인딩: %s\r\n"+
			"• 원격 컨텍스트: %s\r\n"+
			"• 신뢰 기기 수: %d",
		core.Version,
		keyDesc, devShort,
		st.Language.DisplayName(), st.SourceID,
		c.hook.IsActive(), elevDesc,
		strings.Join(bound, ", "),
		remoteDesc,
		len(c.store.TrustedPeers()),
	)
}

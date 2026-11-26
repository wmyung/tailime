package netudp

import (
	"fmt"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/wmyung/tailime/windows/internal/core"
	"github.com/wmyung/tailime/windows/internal/tailscale"
)

type IncomingPacket struct {
	Packet     *core.DecodedWirePacket
	SourceIP   string
	SourcePort uint16
	ReceivedAt time.Time
}

// Endpoint binds UDP exclusively to local Tailscale IPv4/IPv6 + 127.0.0.1 (NEVER 0.0.0.0),
// disables Windows WSAECONNRESET, verifies peers against Tailscale, and enforces replay protection.
type Endpoint struct {
	mu           sync.RWMutex
	port         uint16
	running      bool
	conns        map[string]*net.UDPConn // keyed by bindIP
	boundAddrs   []string
	peerKeys     map[string][]byte // deviceID -> 32-byte HMAC key
	snapshot     *core.TailscaleStatusSnapshot
	replayGuard  *core.SlidingWindowReplayGuard
	pairLimiter  map[string][]time.Time
	whoisCache   map[string]whoisCacheEntry
	stopCh       chan struct{}
	wg           sync.WaitGroup

	OnPacketReceived    func(IncomingPacket)
	OnBindStatusChanged func([]string)
}

type whoisCacheEntry struct {
	valid     bool
	checkedAt time.Time
}

func NewEndpoint(port uint16) *Endpoint {
	if port == 0 {
		port = core.DefaultUDPPort
	}
	return &Endpoint{
		port:        port,
		conns:       make(map[string]*net.UDPConn),
		peerKeys:    make(map[string][]byte),
		replayGuard: core.NewSlidingWindowReplayGuard(),
		pairLimiter: make(map[string][]time.Time),
		whoisCache:  make(map[string]whoisCacheEntry),
	}
}

func (e *Endpoint) Start() {
	e.mu.Lock()
	if e.running {
		e.mu.Unlock()
		return
	}
	e.running = true
	e.stopCh = make(chan struct{})
	stopCh := e.stopCh
	e.mu.Unlock()

	e.RebindNow()

	// Periodically re-check local Tailscale interfaces (handles logon before Tailscale connects or IP change).
	e.wg.Add(1)
	go func() {
		defer e.wg.Done()
		t := time.NewTicker(10 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-stopCh:
				return
			case <-t.C:
				e.RebindNow()
			}
		}
	}()
}

func (e *Endpoint) Stop() {
	e.mu.Lock()
	if !e.running {
		e.mu.Unlock()
		return
	}
	e.running = false
	close(e.stopCh)
	for ip, c := range e.conns {
		_ = c.Close()
		delete(e.conns, ip)
	}
	e.boundAddrs = nil
	e.mu.Unlock()
	e.wg.Wait()
}

func (e *Endpoint) UpdatePort(port uint16) {
	if port == 0 {
		port = core.DefaultUDPPort
	}
	e.mu.Lock()
	if e.port == port {
		e.mu.Unlock()
		return
	}
	e.port = port
	for ip, c := range e.conns {
		_ = c.Close()
		delete(e.conns, ip)
	}
	running := e.running
	e.mu.Unlock()
	if running {
		e.RebindNow()
	}
}

func (e *Endpoint) UpdatePeerKeys(keys map[string][]byte) {
	e.mu.Lock()
	cp := make(map[string][]byte, len(keys))
	for k, v := range keys {
		cp[k] = append([]byte(nil), v...)
	}
	e.peerKeys = cp
	e.mu.Unlock()
}

func (e *Endpoint) UpdateTailscaleSnapshot(snap *core.TailscaleStatusSnapshot) {
	e.mu.Lock()
	e.snapshot = snap
	e.mu.Unlock()
	e.RebindNow()
}

func (e *Endpoint) BoundAddresses() []string {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return append([]string(nil), e.boundAddrs...)
}

func (e *Endpoint) CacheIdempotentReply(reply core.WireMessage, senderDeviceID, bootSessionID string, seq uint64) {
	e.mu.Lock()
	e.replayGuard.CacheReply(reply, senderDeviceID, bootSessionID, seq)
	e.mu.Unlock()
}

// DiscoverLocalBindIPs returns strictly local Tailscale IPv4, Tailscale IPv6, and 127.0.0.1 (NEVER 0.0.0.0).
func DiscoverLocalBindIPs(snap *core.TailscaleStatusSnapshot) []string {
	seen := map[string]bool{"127.0.0.1": true}
	if snap != nil && snap.SelfNode != nil {
		if core.IsTailscaleIPv4(snap.SelfNode.IPv4) {
			seen[core.NormalizeIP(snap.SelfNode.IPv4)] = true
		}
		if core.IsTailscaleIPv6(snap.SelfNode.IPv6) {
			seen[core.NormalizeIP(snap.SelfNode.IPv6)] = true
		}
	}
	if ifaces, err := net.Interfaces(); err == nil {
		for _, iface := range ifaces {
			// Strictly restrict to Tailscale/Wintun/WireGuard/utun interfaces (never carrier-NAT physical NICs!)
			if iface.Flags&net.FlagUp == 0 || !tailscale.IsTailscaleInterfaceName(iface.Name) {
				continue
			}
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}
			for _, a := range addrs {
				var ip net.IP
				switch v := a.(type) {
				case *net.IPNet:
					ip = v.IP
				case *net.IPAddr:
					ip = v.IP
				}
				if ip == nil {
					continue
				}
				s := core.NormalizeIP(ip.String())
				if core.IsTailscaleIP(s) {
					seen[s] = true
				}
			}
		}
	}
	out := make([]string, 0, len(seen))
	for ip := range seen {
		out = append(out, ip)
	}
	sort.Strings(out)
	return out
}

func (e *Endpoint) RebindNow() {
	e.mu.Lock()
	if !e.running {
		e.mu.Unlock()
		return
	}
	snap := e.snapshot
	port := e.port
	e.mu.Unlock()

	desired := DiscoverLocalBindIPs(snap)
	desiredSet := make(map[string]bool, len(desired))
	for _, ip := range desired {
		desiredSet[ip] = true
	}

	e.mu.Lock()
	if !e.running {
		e.mu.Unlock()
		return
	}
	changed := false
	// Close removed IPs
	for ip, c := range e.conns {
		if !desiredSet[ip] {
			_ = c.Close()
			delete(e.conns, ip)
			changed = true
		}
	}
	// Open newly discovered IPs
	for _, ip := range desired {
		if _, ok := e.conns[ip]; ok {
			continue
		}
		netType := "udp4"
		if strings.Contains(ip, ":") {
			netType = "udp6"
		}
		addr := &net.UDPAddr{IP: net.ParseIP(ip), Port: int(port)}
		conn, err := net.ListenUDP(netType, addr)
		if err != nil {
			continue
		}
		disableUDPConnReset(conn)
		e.conns[ip] = conn
		changed = true
		e.wg.Add(1)
		go e.readLoop(ip, conn)
	}

	bound := make([]string, 0, len(e.conns))
	for ip, c := range e.conns {
		if la, ok := c.LocalAddr().(*net.UDPAddr); ok {
			if strings.Contains(ip, ":") {
				bound = append(bound, fmt.Sprintf("[%s]:%d", ip, la.Port))
			} else {
				bound = append(bound, fmt.Sprintf("%s:%d", ip, la.Port))
			}
		}
	}
	sort.Strings(bound)
	if len(bound) != len(e.boundAddrs) {
		changed = true
	} else {
		for i := range bound {
			if bound[i] != e.boundAddrs[i] {
				changed = true
				break
			}
		}
	}
	e.boundAddrs = bound
	cb := e.OnBindStatusChanged
	e.mu.Unlock()

	if changed && cb != nil {
		cb(append([]string(nil), bound...))
	}
}

func (e *Endpoint) Send(msg core.WireMessage, toIP string, toPort uint16, key []byte, nonce uint64) error {
	norm := core.NormalizeIP(toIP)
	if !core.IsTailscaleIP(norm) && !core.IsLoopback(norm) {
		return fmt.Errorf("refusing to send outside Tailscale/loopback: %s", toIP)
	}
	e.mu.RLock()
	port := toPort
	if port == 0 {
		port = e.port
	}
	conn := e.pickSendConnLocked(norm)
	e.mu.RUnlock()

	pkt, err := core.EncodeWirePacket(msg, key, uint64(time.Now().UnixMilli()), nonce)
	if err != nil {
		return err
	}
	dst := &net.UDPAddr{IP: net.ParseIP(norm), Port: int(port)}
	if conn != nil {
		_, err = conn.WriteToUDP(pkt, dst)
		return err
	}
	// Fallback ephemeral socket bound to matching Tailscale/loopback source
	netType := "udp4"
	if strings.Contains(norm, ":") {
		netType = "udp6"
	}
	c, err := net.DialUDP(netType, nil, dst)
	if err != nil {
		return err
	}
	defer c.Close()
	_, err = c.Write(pkt)
	return err
}

func (e *Endpoint) pickSendConnLocked(destIP string) *net.UDPConn {
	isV6 := strings.Contains(destIP, ":")
	if core.IsLoopback(destIP) {
		if c, ok := e.conns["127.0.0.1"]; ok && !isV6 {
			return c
		}
	}
	for ip, c := range e.conns {
		if ip == "127.0.0.1" {
			continue
		}
		if strings.Contains(ip, ":") == isV6 {
			return c
		}
	}
	return nil
}

func (e *Endpoint) readLoop(bindIP string, conn *net.UDPConn) {
	defer e.wg.Done()
	buf := make([]byte, 2048)
	for {
		n, srcAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			if isTransientUDPError(err) {
				continue
			}
			// Check if stopped/closed
			e.mu.RLock()
			stillActive := e.running && e.conns[bindIP] == conn
			e.mu.RUnlock()
			if !stillActive {
				return
			}
			time.Sleep(10 * time.Millisecond)
			continue
		}
		if n < core.WireHeaderLength || srcAddr == nil {
			continue
		}
		raw := make([]byte, n)
		copy(raw, buf[:n])
		srcIP := core.NormalizeIP(srcAddr.IP.String())
		srcPort := uint16(srcAddr.Port)
		e.handleDatagram(raw, srcIP, srcPort)
	}
}

func (e *Endpoint) handleDatagram(raw []byte, srcIP string, srcPort uint16) {
	if !core.IsTailscaleIP(srcIP) && !core.IsLoopback(srcIP) {
		return
	}

	e.mu.RLock()
	keys := e.peerKeys
	snap := e.snapshot
	e.mu.RUnlock()

	decoded, err := core.DecodeWirePacket(raw, uint64(time.Now().UnixMilli()), func(senderDeviceID string) []byte {
		return keys[senderDeviceID]
	})
	if err != nil {
		return
	}

	// Unauthenticated pairHello: rate-limit + verify Tailscale peer membership asynchronously when CLI works;
	// if tailscale.exe is absent or failed (FromCLI == false), accept Tailscale-adapter pairHello (still gated by 6-digit SAS).
	if !decoded.Authenticated {
		if decoded.Message.Cmd != core.CmdPairHello {
			return
		}
		if !e.allowPairHello(srcIP) {
			return
		}
		incoming := IncomingPacket{
			Packet:     decoded,
			SourceIP:   srcIP,
			SourcePort: srcPort,
			ReceivedAt: time.Now(),
		}
		if core.IsLoopback(srcIP) || (snap != nil && snap.IsKnownPeerIP(srcIP)) {
			e.deliverPacket(incoming)
			return
		}
		if valid, fresh := e.lookupWhoisCache(srcIP); fresh {
			if valid {
				e.deliverPacket(incoming)
			}
			return
		}
		if tailscale.FindBinary() != "" {
			// Run whois off the read loop so slow CLI calls never stall authenticated UDP packets!
			go e.verifyWhoisAndDeliver(srcIP, incoming)
			return
		}
		// CLI binary absent: socket is strictly bound to Tailscale/Wintun adapter + 6-digit SAS required
		e.deliverPacket(incoming)
		return
	} else {
		// Authenticated packet: check sliding-window replay guard & idempotent cached reply
		now := time.Now()
		e.mu.Lock()
		verdict, cached := e.replayGuard.CheckAndRecord(
			decoded.Message.SenderDeviceID,
			decoded.Message.BootSessionID,
			decoded.Message.Seq,
			now,
			decoded.Message.Cmd.IsStateMutating(),
		)
		peerKey := e.peerKeys[decoded.Message.SenderDeviceID]
		e.mu.Unlock()

		switch verdict {
		case core.ReplayAccept:
			// proceed
		case core.ReplayDuplicate:
			if cached != nil && len(peerKey) > 0 {
				_ = e.Send(*cached, srcIP, srcPort, peerKey, decoded.Nonce)
			}
			return
		case core.ReplayRejectStaleOrder, core.ReplayRejectTooOld:
			return
		}
	}

	e.deliverPacket(IncomingPacket{
		Packet:     decoded,
		SourceIP:   srcIP,
		SourcePort: srcPort,
		ReceivedAt: time.Now(),
	})
}

func (e *Endpoint) deliverPacket(in IncomingPacket) {
	e.mu.RLock()
	cb := e.OnPacketReceived
	e.mu.RUnlock()
	if cb != nil {
		cb(in)
	}
}

func (e *Endpoint) allowPairHello(srcIP string) bool {
	now := time.Now()
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.pairLimiter) > 64 {
		for ip, stamps := range e.pairLimiter {
			kept := stamps[:0]
			for _, ts := range stamps {
				if now.Sub(ts) < 30*time.Second {
					kept = append(kept, ts)
				}
			}
			if len(kept) == 0 {
				delete(e.pairLimiter, ip)
			} else {
				e.pairLimiter[ip] = kept
			}
		}
	}
	prev := e.pairLimiter[srcIP]
	kept := prev[:0]
	for _, ts := range prev {
		if now.Sub(ts) < 30*time.Second {
			kept = append(kept, ts)
		}
	}
	if len(kept) >= 6 {
		e.pairLimiter[srcIP] = kept
		return false
	}
	e.pairLimiter[srcIP] = append(kept, now)
	return true
}

func (e *Endpoint) lookupWhoisCache(srcIP string) (valid bool, fresh bool) {
	now := time.Now()
	e.mu.RLock()
	entry, ok := e.whoisCache[srcIP]
	e.mu.RUnlock()
	if !ok {
		return false, false
	}
	ttl := 10 * time.Second
	if entry.valid {
		ttl = 5 * time.Minute
	}
	if now.Sub(entry.checkedAt) < ttl {
		return entry.valid, true
	}
	return false, false
}

func (e *Endpoint) verifyWhoisAndDeliver(srcIP string, incoming IncomingPacket) {
	_, ok := tailscale.VerifyPeerWhois(srcIP, 3*time.Second)
	now := time.Now()
	e.mu.Lock()
	if len(e.whoisCache) > 64 {
		for ip, ent := range e.whoisCache {
			if now.Sub(ent.checkedAt) > 5*time.Minute {
				delete(e.whoisCache, ip)
			}
		}
	}
	fromCLI := e.snapshot != nil && e.snapshot.FromCLI
	if ok || fromCLI {
		e.whoisCache[srcIP] = whoisCacheEntry{valid: ok, checkedAt: now}
	}
	e.mu.Unlock()

	if ok || !fromCLI {
		e.deliverPacket(incoming)
	}
}

package core

import (
	"bytes"
	"encoding/hex"
	"errors"
	"testing"
	"time"
)

func makeDeterministicKey(start byte) []byte {
	raw := make([]byte, 32)
	for i := range raw {
		raw[i] = start + byte(i)
	}
	return raw
}

func TestCryptoECDH_SAS_Token_AndGoldenInteroperability(t *testing.T) {
	macA, err := IdentityFromRawPrivateKey(makeDeterministicKey(0x01))
	if err != nil {
		t.Fatal(err)
	}
	winB, err := IdentityFromRawPrivateKey(makeDeterministicKey(0x21))
	if err != nil {
		t.Fatal(err)
	}
	macC, err := GenerateEphemeralIdentity()
	if err != nil {
		t.Fatal(err)
	}

	keyAB, err := macA.DerivePeerHMACKey(winB.PublicKeyBase64)
	if err != nil {
		t.Fatal(err)
	}
	keyBA, err := winB.DerivePeerHMACKey(macA.PublicKeyBase64)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(keyAB, keyBA) {
		t.Fatalf("HMAC key mismatch: %x != %x", keyAB, keyBA)
	}

	keyAC, err := macA.DerivePeerHMACKey(macC.PublicKeyBase64)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(keyAB, keyAC) {
		t.Fatal("distinct peer derived same HMAC key")
	}

	sasAB, err := macA.ConfirmationCode(winB.PublicKeyBase64)
	if err != nil {
		t.Fatal(err)
	}
	sasBA, err := winB.ConfirmationCode(macA.PublicKeyBase64)
	if err != nil {
		t.Fatal(err)
	}
	if sasAB != sasBA || len(sasAB) != 7 {
		t.Fatalf("SAS mismatch or bad format: %q vs %q", sasAB, sasBA)
	}

	token, err := winB.ExportPairingToken("win-laptop", "100.64.0.30", DefaultUDPPort)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodePairingToken(token)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.DeviceID != winB.DeviceID || decoded.Name != "win-laptop" || decoded.TailscaleIP != "100.64.0.30" || decoded.Port != DefaultUDPPort {
		t.Fatalf("unexpected decoded token: %+v", decoded)
	}
	if _, err := DecodePairingToken(token + "x"); err == nil {
		t.Fatal("tampered token accepted")
	}

	// Verify exact byte-for-byte cross-OS golden vectors verified identically by Swift CryptoKit in TailIMETestRunner!
	if macA.DeviceID != "aaa8fff703b50b2297f4f6e13508f724" {
		t.Fatalf("unexpected golden A ID: %s", macA.DeviceID)
	}
	if winB.DeviceID != "4457134794559182226754e9dd2f1083" {
		t.Fatalf("unexpected golden B ID: %s", winB.DeviceID)
	}
	if sasAB != "847-839" {
		t.Fatalf("unexpected golden SAS: %s", sasAB)
	}
	if hex.EncodeToString(keyAB) != "6f351c0e9ccf5b46d5103e9a2cb40eba54edadfc128222dfc946c0fda59ec617" {
		t.Fatalf("unexpected golden HMAC key: %s", hex.EncodeToString(keyAB))
	}
}

func TestNonDestructiveIdentityLoader(t *testing.T) {
	orig, err := GenerateEphemeralIdentity()
	if err != nil {
		t.Fatal(err)
	}

	// 1. Existing valid key -> loaded, no create/update
	creates, updates := 0, 0
	res := LoadOrCreateWithStore(
		func() KeyReadOutcome { return KeyReadOutcome{Status: KeyReadFound, Data: orig.RawPrivateKey()} },
		func([]byte) error { creates++; return nil },
		func([]byte) error { updates++; return nil },
	)
	if res.Status != IdentityLoaded || res.Identity == nil || res.Identity.DeviceID != orig.DeviceID || creates != 0 || updates != 0 {
		t.Fatalf("unexpected loaded result: %+v creates=%d updates=%d", res, creates, updates)
	}

	// 2. Locked / DPAPI error -> NEVER creates or updates!
	creates, updates = 0, 0
	lockedErr := errors.New("dpapi decrypt failed")
	res = LoadOrCreateWithStore(
		func() KeyReadOutcome { return KeyReadOutcome{Status: KeyReadLocked, Err: lockedErr} },
		func([]byte) error { creates++; return nil },
		func([]byte) error { updates++; return nil },
	)
	if res.Status != IdentityLocked || res.IsPersistent() || creates != 0 || updates != 0 {
		t.Fatalf("locked key must never overwrite: %+v creates=%d updates=%d", res, creates, updates)
	}

	// 3. Not found -> calls create once, never update
	var saved []byte
	updates = 0
	res = LoadOrCreateWithStore(
		func() KeyReadOutcome { return KeyReadOutcome{Status: KeyReadNotFound} },
		func(b []byte) error { saved = append([]byte(nil), b...); return nil },
		func([]byte) error { updates++; return nil },
	)
	if res.Status != IdentityCreated || !res.IsPersistent() || len(saved) != 32 || updates != 0 {
		t.Fatalf("unexpected create result: %+v len=%d updates=%d", res, len(saved), updates)
	}

	// 4. Corrupt payload -> calls update once, never create
	creates = 0
	var repaired []byte
	res = LoadOrCreateWithStore(
		func() KeyReadOutcome { return KeyReadOutcome{Status: KeyReadFound, Data: []byte{1, 2, 3}} },
		func([]byte) error { creates++; return nil },
		func(b []byte) error { repaired = append([]byte(nil), b...); return nil },
	)
	if res.Status != IdentityCreated || creates != 0 || len(repaired) != 32 {
		t.Fatalf("unexpected repair result: %+v creates=%d len=%d", res, creates, len(repaired))
	}
}

func TestWirePacketCodecAndReplayGuard(t *testing.T) {
	macA, _ := GenerateEphemeralIdentity()
	winB, _ := GenerateEphemeralIdentity()
	key, err := macA.DerivePeerHMACKey(winB.PublicKeyBase64)
	if err != nil {
		t.Fatal(err)
	}
	nowMs := uint64(1_760_000_000_000)

	msg := WireMessage{
		Cmd:            CmdSet,
		SenderDeviceID: macA.DeviceID,
		SenderName:     "mac-pro",
		BootSessionID:  "boot-1",
		Seq:            42,
		TargetLanguage: LangKorean,
		Version:        Version,
	}

	pkt, err := EncodeWirePacket(msg, key, nowMs, 999)
	if err != nil {
		t.Fatal(err)
	}

	dec, err := DecodeWirePacket(pkt, nowMs+100, func(sender string) []byte {
		if sender == macA.DeviceID {
			return key
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !dec.Authenticated || dec.Nonce != 999 || dec.Message.Cmd != CmdSet || dec.Message.TargetLanguage != LangKorean {
		t.Fatalf("unexpected decoded packet: %+v", dec)
	}

	// Tamper MAC
	badMAC := append([]byte(nil), pkt...)
	badMAC[len(badMAC)-1] ^= 0x01
	if _, err := DecodeWirePacket(badMAC, nowMs, func(string) []byte { return key }); !errors.Is(err, ErrInvalidHMAC) {
		t.Fatalf("expected ErrInvalidHMAC, got %v", err)
	}

	// Timestamp out of window
	if _, err := DecodeWirePacket(pkt, nowMs+400_000, func(string) []byte { return key }); !errors.Is(err, ErrTimestampOutOfWindow) {
		t.Fatalf("expected ErrTimestampOutOfWindow, got %v", err)
	}

	// Unauthenticated pairHello allowed only if deviceID matches pubkey
	hello := WireMessage{
		Cmd:             CmdPairHello,
		SenderDeviceID:  winB.DeviceID,
		SenderName:      "win-pc",
		BootSessionID:   "boot-w",
		Seq:             1,
		PublicKeyBase64: winB.PublicKeyBase64,
	}
	helloPkt, err := EncodeWirePacket(hello, nil, nowMs, 11)
	if err != nil {
		t.Fatal(err)
	}
	decHello, err := DecodeWirePacket(helloPkt, nowMs, nil)
	if err != nil || decHello.Authenticated {
		t.Fatalf("expected valid unauth pairHello, got %+v err=%v", decHello, err)
	}

	// Sliding window replay guard
	guard := NewSlidingWindowReplayGuard()
	now := time.Now()
	if v, _ := guard.CheckAndRecord("devA", "b1", 10, now, true); v != ReplayAccept {
		t.Fatalf("expected accept, got %v", v)
	}
	ack := WireMessage{Cmd: CmdAck, SenderDeviceID: "devB", BootSessionID: "b2", Seq: 1}
	guard.CacheReply(ack, "devA", "b1", 10)
	if v, cached := guard.CheckAndRecord("devA", "b1", 10, now, true); v != ReplayDuplicate || cached == nil {
		t.Fatalf("expected cached duplicate, got %v %v", v, cached)
	}
	if v, _ := guard.CheckAndRecord("devA", "b1", 9, now, true); v != ReplayRejectStaleOrder {
		t.Fatalf("expected stale order reject, got %v", v)
	}
	if v, _ := guard.CheckAndRecord("devA", "b1", 9, now, false); v != ReplayRejectStaleOrder && v != ReplayDuplicate {
		// seq 9 was already recorded in bitmap on the previous call
		t.Fatalf("expected duplicate for recorded seq 9, got %v", v)
	}
	if v, _ := guard.CheckAndRecord("devA", "b1", 8, now, false); v != ReplayAccept {
		t.Fatalf("non-mutating older packet in window should accept, got %v", v)
	}
}

func TestIPValidationAndRemoteResolver(t *testing.T) {
	if !IsTailscaleIPv4("100.64.0.10") || !IsTailscaleIPv4("::ffff:100.127.255.254") || !IsTailscaleIPv4("::100.68.162.56") {
		t.Fatal("failed valid Tailscale IPv4 checks")
	}
	if IsTailscaleIPv4("192.168.1.10") || IsTailscaleIPv4("100.63.255.255") || IsTailscaleIPv4("100.128.0.1") {
		t.Fatal("accepted non-Tailscale IPv4")
	}
	if !IsTailscaleIPv6("fd7a:115c:a1e0::10") || IsTailscaleIPv6("fe80::1") {
		t.Fatal("failed Tailscale IPv6 checks")
	}

	snap := &TailscaleStatusSnapshot{
		Peers: []TailscalePeer{
			{HostName: "mac-pro-1", DNSName: "mac-pro-1.example.ts.net.", OS: "macOS", IPv4: "100.64.0.10", Online: true, DirectAddr: "192.0.2.10:41641"},
			{HostName: "WIN-DESK", DNSName: "win-desk.example.ts.net.", OS: "windows", IPv4: "100.64.0.30", Online: true},
		},
	}
	settings := DefaultSettings()

	lobby := ResolveRemoteTarget(`C:\Program Files\RustDesk\rustdesk.exe`, 123, "RustDesk", nil, snap, settings)
	if !lobby.IsLobbyWindow || lobby.HasActiveRemoteSession() {
		t.Fatalf("expected lobby, got %+v", lobby)
	}

	sock := ResolveRemoteTarget("rustdesk.exe", 123, "123456789", []string{"100.64.0.10"}, snap, settings)
	if !sock.HasActiveRemoteSession() || sock.ResolvedPeer == nil || sock.ResolvedPeer.HostName != "mac-pro-1" || sock.ResolutionSource != "socket" {
		t.Fatalf("expected socket resolution to mac-pro-1, got %+v", sock)
	}

	rdp := ResolveRemoteTarget("mstsc.exe", 456, "WIN-DESK - Remote Desktop Connection", nil, snap, settings)
	if !rdp.HasActiveRemoteSession() || rdp.ResolvedPeer == nil || rdp.ResolvedPeer.HostName != "WIN-DESK" || rdp.ResolutionSource != "window-title" {
		t.Fatalf("expected title resolution to WIN-DESK, got %+v", rdp)
	}
}

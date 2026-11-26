package tailscale

import (
	"testing"
	"time"

	"github.com/wmyung/tailime/windows/internal/core"
)

func TestIsTailscaleInterfaceName(t *testing.T) {
	accepted := []string{"Tailscale", "Tailscale Tunnel", "Wintun Userspace Tunnel", "WireGuard Tunnel", "utun4", "UTUN12"}
	for _, name := range accepted {
		if !IsTailscaleInterfaceName(name) {
			t.Fatalf("expected %q to be accepted as Tailscale interface", name)
		}
	}
	rejected := []string{"", "Wi-Fi", "Ethernet", "Ethernet 2", "Cellular", "en0", "lo0", "vEthernet (Default Switch)"}
	for _, name := range rejected {
		if IsTailscaleInterfaceName(name) {
			t.Fatalf("expected %q to be rejected as non-Tailscale interface", name)
		}
	}
}

func TestParseStatusAndZeroCLIEnrichSnapshot(t *testing.T) {
	raw := []byte(`{
		"Self": {"HostName":"win-host","OS":"windows","TailscaleIPs":["100.64.0.30"],"Online":true},
		"Peer": {
			"n1": {"HostName":"mac-desk","OS":"macOS","TailscaleIPs":["100.64.0.10"],"Online":true,"CurAddr":"192.0.2.1:41641"}
		}
	}`)
	snap, err := ParseStatusJSON(raw, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if !snap.FromCLI {
		t.Fatal("ParseStatusJSON must set FromCLI=true")
	}

	trusted := []core.TrustedPeerRecord{
		{DeviceID: "d1", Name: "unknown-os-peer", PublicKeyBase64: "pk1", LastKnownIP: "100.64.0.51"},
		{DeviceID: "d2", Name: "win-peer", PublicKeyBase64: "pk2", LastKnownIP: "100.64.0.52", OS: "windows"},
		{DeviceID: "d3", Name: "mac-peer", PublicKeyBase64: "pk3", LastKnownIP: "100.64.0.53", OS: "macOS"},
	}
	enriched := EnrichSnapshot(nil, trusted)
	if enriched.FromCLI {
		t.Fatal("EnrichSnapshot(nil, ...) must keep FromCLI=false")
	}
	p1 := enriched.PeerMatchingIP("100.64.0.51")
	if p1 == nil || p1.OS != "unknown" || p1.IsMacOS() || p1.OSShortLabel() != "TailIME" || !p1.IsTailIMESupportedOS() {
		t.Fatalf("unexpected unknown-os enriched peer: %+v", p1)
	}
	p2 := enriched.PeerMatchingIP("100.64.0.52")
	if p2 == nil || !p2.IsWindows() || p2.IsMacOS() {
		t.Fatalf("unexpected windows enriched peer: %+v", p2)
	}
	p3 := enriched.PeerMatchingIP("100.64.0.53")
	if p3 == nil || !p3.IsMacOS() || p3.IsWindows() {
		t.Fatalf("unexpected macOS enriched peer: %+v", p3)
	}
}

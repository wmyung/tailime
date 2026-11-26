package tailscale

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/wmyung/tailime/windows/internal/core"
)

// IsTailscaleInterfaceName returns true ONLY for Tailscale / WireGuard / Wintun / utun virtual adapters,
// preventing TailIME from binding a carrier-NAT Wi-Fi/LTE NIC that happens to receive a 100.64.0.0/10 address.
func IsTailscaleInterfaceName(name string) bool {
	lower := strings.ToLower(strings.TrimSpace(name))
	if lower == "" {
		return false
	}
	return strings.Contains(lower, "tailscale") ||
		strings.Contains(lower, "wintun") ||
		strings.Contains(lower, "wireguard") ||
		strings.HasPrefix(lower, "utun")
}

// DiscoverLocalTailscaleIPs scans local Tailscale/Wintun/utun network interfaces directly for Tailscale CGNAT IPv4
// (100.64.0.0/10) and ULA IPv6 (fd7a:115c:a1e0::/48) so TailIME works even without tailscale.exe CLI.
func DiscoverLocalTailscaleIPs() (ipv4, ipv6 string) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return "", ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || !IsTailscaleInterfaceName(iface.Name) {
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
			if ipv4 == "" && core.IsTailscaleIPv4(s) {
				ipv4 = s
			} else if ipv6 == "" && core.IsTailscaleIPv6(s) {
				ipv6 = s
			}
		}
	}
	return ipv4, ipv6
}

// EnrichSnapshot merges CLI status with local interface Tailscale IPs and stored trusted peers
// so pairing, token export, pinging, and remote target resolution work even when tailscale.exe is absent.
func EnrichSnapshot(cliSnap *core.TailscaleStatusSnapshot, trustedPeers []core.TrustedPeerRecord) *core.TailscaleStatusSnapshot {
	v4, v6 := DiscoverLocalTailscaleIPs()
	host, _ := os.Hostname()
	if host == "" {
		host = "Windows-PC"
	}

	var selfNode *core.TailscalePeer
	if cliSnap != nil && cliSnap.SelfNode != nil {
		cp := *cliSnap.SelfNode
		if cp.IPv4 == "" {
			cp.IPv4 = v4
		}
		if cp.IPv6 == "" {
			cp.IPv6 = v6
		}
		if cp.IPv4 != "" || cp.IPv6 != "" {
			cp.Online = true
		}
		selfNode = &cp
	} else if v4 != "" || v6 != "" {
		selfNode = &core.TailscalePeer{
			HostName: host,
			OS:       "windows",
			IPv4:     v4,
			IPv6:     v6,
			Online:   true,
			Active:   true,
		}
	}

	var peers []core.TailscalePeer
	if cliSnap != nil {
		peers = append(peers, cliSnap.Peers...)
	}
	for _, rec := range trustedPeers {
		ip := core.NormalizeIP(rec.LastKnownIP)
		if !core.IsTailscaleIP(ip) {
			continue
		}
		exists := false
		for _, p := range peers {
			if strings.EqualFold(p.IPv4, ip) || strings.EqualFold(p.IPv6, ip) {
				exists = true
				break
			}
		}
		if !exists {
			peerOS := strings.TrimSpace(rec.OS)
			if peerOS == "" {
				peerOS = "unknown"
			}
			tp := core.TailscalePeer{
				HostName: rec.Name,
				OS:       peerOS,
				Online:   true,
			}
			if strings.Contains(ip, ":") {
				tp.IPv6 = ip
			} else {
				tp.IPv4 = ip
			}
			peers = append(peers, tp)
		}
	}
	core.SortPeers(peers)

	fetched := time.Now()
	fromCLI := false
	if cliSnap != nil {
		if !cliSnap.FetchedAt.IsZero() {
			fetched = cliSnap.FetchedAt
		}
		fromCLI = cliSnap.FromCLI
	}
	return &core.TailscaleStatusSnapshot{
		SelfNode:  selfNode,
		Peers:     peers,
		FetchedAt: fetched,
		FromCLI:   fromCLI,
	}
}

func FindBinary() string {
	if p, err := exec.LookPath("tailscale"); err == nil {
		return p
	}
	var candidates []string
	if runtime.GOOS == "windows" {
		for _, env := range []string{"ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"} {
			if base := os.Getenv(env); base != "" {
				candidates = append(candidates, filepath.Join(base, "Tailscale", "tailscale.exe"))
			}
		}
		candidates = append(candidates, `C:\Program Files\Tailscale\tailscale.exe`)
	} else {
		candidates = []string{
			"/opt/homebrew/bin/tailscale",
			"/usr/local/bin/tailscale",
			"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
		}
	}
	for _, c := range candidates {
		if info, err := os.Stat(c); err == nil && !info.IsDir() {
			return c
		}
	}
	return ""
}

type rawStatus struct {
	Self *rawNode            `json:"Self"`
	Peer map[string]*rawNode `json:"Peer"`
}

type rawNode struct {
	HostName     string   `json:"HostName"`
	DNSName      string   `json:"DNSName"`
	OS           string   `json:"OS"`
	TailscaleIPs []string `json:"TailscaleIPs"`
	Online       bool     `json:"Online"`
	Active       bool     `json:"Active"`
	CurAddr      string   `json:"CurAddr"`
	Relay        string   `json:"Relay"`
}

func ParseStatusJSON(data []byte, fetchedAt time.Time) (*core.TailscaleStatusSnapshot, error) {
	var root rawStatus
	if err := json.Unmarshal(data, &root); err != nil {
		return nil, err
	}
	snap := &core.TailscaleStatusSnapshot{FetchedAt: fetchedAt, FromCLI: true}
	if root.Self != nil {
		if p := parseNode(root.Self); p != nil {
			snap.SelfNode = p
		}
	}
	for _, rn := range root.Peer {
		if p := parseNode(rn); p != nil {
			snap.Peers = append(snap.Peers, *p)
		}
	}
	core.SortPeers(snap.Peers)
	return snap, nil
}

func parseNode(rn *rawNode) *core.TailscalePeer {
	if rn == nil {
		return nil
	}
	var ipv4, ipv6 string
	for _, ip := range rn.TailscaleIPs {
		norm := core.NormalizeIP(ip)
		if strings.Contains(norm, ":") {
			if ipv6 == "" {
				ipv6 = norm
			}
		} else if norm != "" {
			if ipv4 == "" {
				ipv4 = norm
			}
		}
	}
	if ipv4 == "" && ipv6 == "" {
		return nil
	}
	label := strings.TrimSpace(rn.HostName)
	if label == "" {
		dns := strings.TrimSuffix(strings.TrimSpace(rn.DNSName), ".")
		if idx := strings.IndexByte(dns, '.'); idx > 0 {
			label = dns[:idx]
		} else if dns != "" {
			label = dns
		} else if ipv4 != "" {
			label = ipv4
		} else {
			label = ipv6
		}
	}
	return &core.TailscalePeer{
		HostName:   label,
		DNSName:    rn.DNSName,
		OS:         rn.OS,
		IPv4:       ipv4,
		IPv6:       ipv6,
		Online:     rn.Online,
		Active:     rn.Active,
		DirectAddr: rn.CurAddr,
		Relay:      rn.Relay,
	}
}

func FetchStatus(timeout time.Duration) *core.TailscaleStatusSnapshot {
	bin := FindBinary()
	if bin == "" {
		return nil
	}
	if timeout <= 0 {
		timeout = 4 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "status", "--json")
	configureHiddenCommand(cmd)
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	snap, err := ParseStatusJSON(out, time.Now())
	if err != nil {
		return nil
	}
	return snap
}

func VerifyPeerWhois(ip string, timeout time.Duration) (string, bool) {
	if core.IsLoopback(ip) {
		return "localhost", true
	}
	if !core.IsTailscaleIP(ip) {
		return "", false
	}
	bin := FindBinary()
	if bin == "" {
		return "", false
	}
	if timeout <= 0 {
		timeout = 3 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "whois", "--json", ip)
	configureHiddenCommand(cmd)
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	var root struct {
		Node struct {
			ComputedName string `json:"ComputedName"`
			Name         string `json:"Name"`
		} `json:"Node"`
	}
	if json.Unmarshal(out, &root) != nil {
		return "", false
	}
	name := strings.TrimSuffix(strings.TrimSpace(root.Node.ComputedName), ".")
	if name == "" {
		name = strings.TrimSuffix(strings.TrimSpace(root.Node.Name), ".")
	}
	if name == "" {
		name = ip
	}
	return name, true
}

package core

import (
	"net/netip"
	"path/filepath"
	"strings"
)

// NormalizeIP unwraps IPv4-mapped IPv6 addresses (::ffff:100.x.x.x or ::100.x.x.x).
func NormalizeIP(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	lower := strings.ToLower(trimmed)
	if strings.HasPrefix(lower, "::ffff:") {
		v4 := trimmed[7:]
		if addr, err := netip.ParseAddr(v4); err == nil && addr.Is4() {
			return addr.String()
		}
	}
	if strings.HasPrefix(trimmed, "::") && strings.Contains(trimmed, ".") {
		v4 := trimmed[2:]
		if addr, err := netip.ParseAddr(v4); err == nil && addr.Is4() {
			return addr.String()
		}
	}
	if addr, err := netip.ParseAddr(trimmed); err == nil {
		if addr.Is4In6() {
			return addr.Unmap().String()
		}
		return addr.String()
	}
	return trimmed
}

// IsTailscaleIPv4 checks CGNAT 100.64.0.0/10 (100.64.0.0 – 100.127.255.255).
func IsTailscaleIPv4(ip string) bool {
	addr, err := netip.ParseAddr(NormalizeIP(ip))
	if err != nil || !addr.Is4() {
		return false
	}
	b := addr.As4()
	return b[0] == 100 && b[1] >= 64 && b[1] <= 127
}

// IsTailscaleIPv6 checks Tailscale ULA prefix fd7a:115c:a1e0::/48.
func IsTailscaleIPv6(ip string) bool {
	addr, err := netip.ParseAddr(NormalizeIP(ip))
	if err != nil || !addr.Is6() {
		return false
	}
	b := addr.As16()
	return b[0] == 0xFD && b[1] == 0x7A && b[2] == 0x11 && b[3] == 0x5C && b[4] == 0xA1 && b[5] == 0xE0
}

func IsTailscaleIP(ip string) bool {
	return IsTailscaleIPv4(ip) || IsTailscaleIPv6(ip)
}

func IsLoopback(ip string) bool {
	n := NormalizeIP(ip)
	return n == "127.0.0.1" || n == "::1"
}

var windowsLobbyTitles = map[string]bool{
	"rustdesk":                 true,
	"settings":                 true,
	"preferences":              true,
	"about":                    true,
	"remote desktop connection": true,
	"원격 데스크톱 연결":              true,
	"windows app":              true,
	"parsec":                   true,
	"anydesk":                  true,
	"teamviewer":               true,
	"tigervnc viewer":          true,
	"realvnc viewer":           true,
	"moonlight":                true,
	"connections":              true,
}

func IsRemoteViewerProcess(procPathOrName string, allowed []string) bool {
	base := strings.ToLower(filepath.Base(strings.ReplaceAll(procPathOrName, "\\", "/")))
	if base == "" {
		return false
	}
	for _, a := range allowed {
		if base == strings.ToLower(strings.TrimSpace(a)) {
			return true
		}
	}
	return false
}

func IsLikelyLobbyTitle(title string) bool {
	trimmed := strings.ToLower(strings.TrimSpace(title))
	if trimmed == "" {
		return false
	}
	return windowsLobbyTitles[trimmed]
}

// ResolveRemoteTarget runs the exact 4-tier resolver mirroring macOS RemoteTargetResolver.
func ResolveRemoteTarget(
	processName string,
	foregroundPID uint32,
	windowTitle string,
	activeClientSocketIPs []string,
	snapshot *TailscaleStatusSnapshot,
	settings AppSettings,
) ActiveRemoteContext {
	if !IsRemoteViewerProcess(processName, settings.AllRemoteProcessNames()) {
		return ActiveRemoteContext{
			IsRemoteAppFocused: false,
			ProcessName:        processName,
			ForegroundPID:      foregroundPID,
		}
	}

	trimmedTitle := strings.TrimSpace(windowTitle)
	if IsLikelyLobbyTitle(trimmedTitle) && len(activeClientSocketIPs) == 0 {
		return ActiveRemoteContext{
			IsRemoteAppFocused: true,
			IsLobbyWindow:      true,
			ProcessName:        processName,
			ForegroundPID:      foregroundPID,
			WindowTitle:        trimmedTitle,
			ResolutionSource:   "lobby",
		}
	}

	// Tier 0: Explicit manual pin
	if settings.PinnedPeerID != "" && snapshot != nil {
		for i := range snapshot.Peers {
			p := &snapshot.Peers[i]
			if p.ID() == settings.PinnedPeerID || p.IPv4 == settings.PinnedPeerID || strings.EqualFold(p.HostName, settings.PinnedPeerID) {
				cp := *p
				return ActiveRemoteContext{
					IsRemoteAppFocused: true,
					ProcessName:        processName,
					ForegroundPID:      foregroundPID,
					WindowTitle:        trimmedTitle,
					ResolvedPeer:       &cp,
					ResolutionSource:   "pinned",
					CandidatePeerIPs:   activeClientSocketIPs,
				}
			}
		}
	}

	// Tier 1A: Learned window title table
	if trimmedTitle != "" && snapshot != nil {
		if learnedIP, ok := settings.LearnedWindowTitles[trimmedTitle]; ok {
			if p := snapshot.PeerMatchingIP(learnedIP); p != nil {
				cp := *p
				return ActiveRemoteContext{
					IsRemoteAppFocused: true,
					ProcessName:        processName,
					ForegroundPID:      foregroundPID,
					WindowTitle:        trimmedTitle,
					ResolvedPeer:       &cp,
					ResolutionSource:   "learned-title",
					CandidatePeerIPs:   activeClientSocketIPs,
				}
			}
		}
	}

	// Tier 1B: User-defined aliases
	if trimmedTitle != "" && snapshot != nil {
		lowerTitle := strings.ToLower(trimmedTitle)
		for alias, targetIP := range settings.PeerAliases {
			if alias != "" && strings.Contains(lowerTitle, strings.ToLower(alias)) {
				if p := snapshot.PeerMatchingIP(targetIP); p != nil {
					cp := *p
					return ActiveRemoteContext{
						IsRemoteAppFocused: true,
						ProcessName:        processName,
						ForegroundPID:      foregroundPID,
						WindowTitle:        trimmedTitle,
						ResolvedPeer:       &cp,
						ResolutionSource:   "alias",
						CandidatePeerIPs:   activeClientSocketIPs,
					}
				}
			}
		}
	}

	// Tier 2: Direct window title match against IPv4, IPv6, HostName, or short DNSName
	if trimmedTitle != "" && snapshot != nil {
		if p := MatchPeerByWindowTitle(trimmedTitle, snapshot.Peers); p != nil {
			cp := *p
			return ActiveRemoteContext{
				IsRemoteAppFocused: true,
				ProcessName:        processName,
				ForegroundPID:      foregroundPID,
				WindowTitle:        trimmedTitle,
				ResolvedPeer:       &cp,
				ResolutionSource:   "window-title",
				CandidatePeerIPs:   activeClientSocketIPs,
			}
		}
	}

	// Tier 3: Active client Tailscale sockets
	if snapshot != nil && len(activeClientSocketIPs) > 0 {
		var matched []TailscalePeer
		seen := map[string]bool{}
		for _, ip := range activeClientSocketIPs {
			if p := snapshot.PeerMatchingIP(ip); p != nil {
				if !seen[p.ID()] {
					seen[p.ID()] = true
					matched = append(matched, *p)
				}
			}
		}
		if len(matched) == 1 {
			cp := matched[0]
			return ActiveRemoteContext{
				IsRemoteAppFocused: true,
				ProcessName:        processName,
				ForegroundPID:      foregroundPID,
				WindowTitle:        trimmedTitle,
				ResolvedPeer:       &cp,
				ResolutionSource:   "socket",
				CandidatePeerIPs:   activeClientSocketIPs,
			}
		}
		if len(matched) > 1 {
			cand := make([]string, 0, len(matched))
			for _, p := range matched {
				if ip := p.PreferredIP(); ip != "" {
					cand = append(cand, ip)
				}
			}
			return ActiveRemoteContext{
				IsRemoteAppFocused:      true,
				ProcessName:             processName,
				ForegroundPID:           foregroundPID,
				WindowTitle:             trimmedTitle,
				ResolutionSource:        "ambiguous-multi-session",
				IsAmbiguousMultiSession: true,
				CandidatePeerIPs:        cand,
			}
		}
	}

	return ActiveRemoteContext{
		IsRemoteAppFocused: true,
		IsLobbyWindow:      IsLikelyLobbyTitle(trimmedTitle),
		ProcessName:        processName,
		ForegroundPID:      foregroundPID,
		WindowTitle:        trimmedTitle,
		ResolutionSource:   "none",
	}
}

func MatchPeerByWindowTitle(title string, peers []TailscalePeer) *TailscalePeer {
	lower := strings.ToLower(title)
	for i := range peers {
		p := &peers[i]
		if p.IPv4 != "" && strings.Contains(lower, strings.ToLower(p.IPv4)) {
			return p
		}
		if p.IPv6 != "" && strings.Contains(lower, strings.ToLower(p.IPv6)) {
			return p
		}
	}
	for i := range peers {
		p := &peers[i]
		host := strings.ToLower(p.HostName)
		if len(host) >= 3 && strings.Contains(lower, host) {
			return p
		}
		dns := strings.ToLower(p.ShortDNSName())
		if len(dns) >= 3 && strings.Contains(lower, dns) {
			return p
		}
	}
	return nil
}

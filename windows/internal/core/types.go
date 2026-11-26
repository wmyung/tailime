package core

import (
	"sort"
	"strings"
	"time"
)

const (
	Version        = "1.1.0"
	DefaultUDPPort = 39418
)

// InputLanguage matches macOS TailIMECore's InputLanguage wire enum ("ko", "en", "other").
type InputLanguage string

const (
	LangKorean  InputLanguage = "ko"
	LangEnglish InputLanguage = "en"
	LangOther   InputLanguage = "other"
)

func (l InputLanguage) Toggled() InputLanguage {
	if l == LangKorean {
		return LangEnglish
	}
	return LangKorean
}

func (l InputLanguage) ShortBadge() string {
	switch l {
	case LangKorean:
		return "한"
	case LangEnglish:
		return "EN"
	default:
		return "??"
	}
}

func (l InputLanguage) DisplayName() string {
	switch l {
	case LangKorean:
		return "한국어"
	case LangEnglish:
		return "영어 (ABC)"
	default:
		return "기타"
	}
}

func ParseInputLanguage(s string) (InputLanguage, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "ko":
		return LangKorean, true
	case "en":
		return LangEnglish, true
	default:
		return "", false
	}
}

type TailscalePeer struct {
	HostName   string `json:"hostName"`
	DNSName    string `json:"dnsName"`
	OS         string `json:"os"`
	IPv4       string `json:"ipv4,omitempty"`
	IPv6       string `json:"ipv6,omitempty"`
	Online     bool   `json:"online"`
	Active     bool   `json:"active"`
	DirectAddr string `json:"directAddr,omitempty"`
	Relay      string `json:"relay,omitempty"`
}

func (p TailscalePeer) ID() string {
	if p.IPv4 != "" {
		return p.IPv4
	}
	if p.IPv6 != "" {
		return p.IPv6
	}
	return p.HostName
}

func (p TailscalePeer) PreferredIP() string {
	if p.IPv4 != "" {
		return p.IPv4
	}
	return p.IPv6
}

func (p TailscalePeer) IsMacOS() bool {
	o := strings.ToLower(strings.TrimSpace(p.OS))
	return o == "macos" || o == "darwin"
}

func (p TailscalePeer) IsWindows() bool {
	return strings.ToLower(strings.TrimSpace(p.OS)) == "windows"
}

func (p TailscalePeer) IsTailIMESupportedOS() bool {
	return p.IsMacOS() || p.IsWindows() || strings.EqualFold(strings.TrimSpace(p.OS), "unknown")
}

func (p TailscalePeer) OSShortLabel() string {
	if p.IsMacOS() {
		return "macOS"
	}
	if p.IsWindows() {
		return "Windows"
	}
	if p.OS == "" || strings.EqualFold(strings.TrimSpace(p.OS), "unknown") {
		return "TailIME"
	}
	return p.OS
}

func (p TailscalePeer) IsDirectPath() bool {
	return p.DirectAddr != ""
}

func (p TailscalePeer) ShortDNSName() string {
	trimmed := strings.TrimSpace(p.DNSName)
	trimmed = strings.TrimSuffix(trimmed, ".")
	if idx := strings.IndexByte(trimmed, '.'); idx > 0 {
		return trimmed[:idx]
	}
	if trimmed != "" {
		return trimmed
	}
	return p.HostName
}

type TailscaleStatusSnapshot struct {
	SelfNode  *TailscalePeer
	Peers     []TailscalePeer
	FetchedAt time.Time
	FromCLI   bool
}

func (s *TailscaleStatusSnapshot) DesktopPeers() []TailscalePeer {
	if s == nil {
		return nil
	}
	out := make([]TailscalePeer, 0, len(s.Peers))
	for _, p := range s.Peers {
		if p.IsTailIMESupportedOS() {
			out = append(out, p)
		}
	}
	return out
}

func (s *TailscaleStatusSnapshot) PeerMatchingIP(ip string) *TailscalePeer {
	if s == nil || ip == "" {
		return nil
	}
	lower := strings.ToLower(strings.TrimSpace(ip))
	for i := range s.Peers {
		p := &s.Peers[i]
		if (p.IPv4 != "" && strings.ToLower(p.IPv4) == lower) ||
			(p.IPv6 != "" && strings.ToLower(p.IPv6) == lower) {
			return p
		}
	}
	return nil
}

func (s *TailscaleStatusSnapshot) IsKnownPeerIP(ip string) bool {
	if IsLoopback(ip) {
		return true
	}
	return s.PeerMatchingIP(ip) != nil
}

func SortPeers(peers []TailscalePeer) {
	sort.Slice(peers, func(i, j int) bool {
		a, b := peers[i], peers[j]
		if a.IsTailIMESupportedOS() != b.IsTailIMESupportedOS() {
			return a.IsTailIMESupportedOS()
		}
		if a.Online != b.Online {
			return a.Online
		}
		if a.IsMacOS() != b.IsMacOS() {
			return a.IsMacOS()
		}
		return strings.ToLower(a.HostName) < strings.ToLower(b.HostName)
	})
}

type TrustedPeerRecord struct {
	DeviceID        string    `json:"deviceID"`
	Name            string    `json:"name"`
	PublicKeyBase64 string    `json:"publicKeyBase64"`
	LastKnownIP     string    `json:"lastKnownIP,omitempty"`
	OS              string    `json:"os,omitempty"`
	PairedAt        time.Time `json:"pairedAt"`
}

type RemotePeerRuntimeState struct {
	PeerID          string
	HostName        string
	IP              string
	DaemonReachable bool
	LastRTTMs       float64
	HasRTT          bool
	CurrentLanguage InputLanguage
	CurrentSourceID string
	LastSeenAt      time.Time
}

type ActiveRemoteContext struct {
	IsRemoteAppFocused      bool
	IsLobbyWindow           bool
	ProcessName             string
	ForegroundPID           uint32
	WindowTitle             string
	ResolvedPeer            *TailscalePeer
	ResolutionSource        string
	IsAmbiguousMultiSession bool
	CandidatePeerIPs        []string
}

func (c ActiveRemoteContext) HasActiveRemoteSession() bool {
	return c.IsRemoteAppFocused && !c.IsLobbyWindow && (c.ResolvedPeer != nil || c.IsAmbiguousMultiSession)
}

// AppSettings stores persistent Windows TailIME user preferences.
type AppSettings struct {
	Enabled                   bool              `json:"enabled"`
	RemoteSyncEnabled         bool              `json:"remoteSyncEnabled"`
	UDPPort                   uint16            `json:"udpPort"`
	AutoEnglishOnRemoteFocus  bool              `json:"autoEnglishOnRemoteFocus"`
	RestoreLocalOnRemoteBlur  bool              `json:"restoreLocalOnRemoteBlur"`
	TriggerHangulKey          bool              `json:"triggerHangulKey"`          // VK_HANGUL (0x15) — Korean 103/106 default
	TriggerRightAltTap        bool              `json:"triggerRightAltTap"`        // VK_RMENU (0xA5) — 101-key US keyboard standalone tap
	TriggerCtrlSpace          bool              `json:"triggerCtrlSpace"`          // Ctrl+Space
	TriggerShiftSpace         bool              `json:"triggerShiftSpace"`         // Shift+Space (opt-in)
	TriggerF18F19             bool              `json:"triggerF18F19"`             // F18 / F19 (PowerToys / AutoHotkey / QMK)
	PinnedPeerID              string            `json:"pinnedPeerID,omitempty"`
	CustomRemoteProcessNames  []string          `json:"customRemoteProcessNames,omitempty"`
	PeerAliases               map[string]string `json:"peerAliases,omitempty"`
	LearnedWindowTitles       map[string]string `json:"learnedWindowTitles,omitempty"`
}

func DefaultSettings() AppSettings {
	return AppSettings{
		Enabled:                  true,
		RemoteSyncEnabled:        true,
		UDPPort:                  DefaultUDPPort,
		AutoEnglishOnRemoteFocus: true,
		RestoreLocalOnRemoteBlur: false,
		TriggerHangulKey:         true,
		TriggerRightAltTap:       true,
		TriggerCtrlSpace:         false,
		TriggerShiftSpace:        false,
		TriggerF18F19:            true,
		PeerAliases:              map[string]string{},
		LearnedWindowTitles:      map[string]string{},
	}
}

var DefaultRemoteViewerProcesses = []string{
	"rustdesk.exe",
	"mstsc.exe",
	"msrdc.exe",
	"windows365.exe",
	"vncviewer.exe",
	"tvnviewer.exe",
	"vncviewer-x64.exe",
	"parsecd.exe",
	"moonlight.exe",
	"anydesk.exe",
	"teamviewer.exe",
	"nxplayer.exe",
	"jumpdesktop.exe",
	"splashtop.exe",
	"strwinclt.exe",
}

func (s AppSettings) AllRemoteProcessNames() []string {
	out := make([]string, 0, len(DefaultRemoteViewerProcesses)+len(s.CustomRemoteProcessNames))
	out = append(out, DefaultRemoteViewerProcesses...)
	out = append(out, s.CustomRemoteProcessNames...)
	return out
}

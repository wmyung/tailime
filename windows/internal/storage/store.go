package storage

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"github.com/wmyung/tailime/windows/internal/core"
)

type Store struct {
	mu           sync.RWMutex
	baseDir      string
	settings     core.AppSettings
	trustedPeers []core.TrustedPeerRecord

	OnSettingsChanged     func(core.AppSettings)
	OnTrustedPeersChanged func([]core.TrustedPeerRecord)
}

func DefaultDataDir() string {
	if localAppData := os.Getenv("LOCALAPPDATA"); localAppData != "" {
		return filepath.Join(localAppData, "TailIME")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".tailime"
	}
	return filepath.Join(home, ".tailime")
}

func NewStore(baseDir string) *Store {
	if baseDir == "" {
		baseDir = DefaultDataDir()
	}
	_ = os.MkdirAll(baseDir, 0700)
	s := &Store{
		baseDir:  baseDir,
		settings: core.DefaultSettings(),
	}
	s.loadAll()
	return s
}

func (s *Store) BaseDir() string {
	return s.baseDir
}

func (s *Store) SettingsPath() string {
	return filepath.Join(s.baseDir, "settings.json")
}

func (s *Store) TrustedPeersPath() string {
	return filepath.Join(s.baseDir, "trusted_peers.json")
}

func (s *Store) IdentityPath() string {
	return filepath.Join(s.baseDir, "identity.dpapi")
}

func (s *Store) loadAll() {
	if raw, err := os.ReadFile(s.SettingsPath()); err == nil {
		loaded := core.DefaultSettings()
		if json.Unmarshal(raw, &loaded) == nil {
			if loaded.UDPPort == 0 {
				loaded.UDPPort = core.DefaultUDPPort
			}
			if loaded.PeerAliases == nil {
				loaded.PeerAliases = map[string]string{}
			}
			if loaded.LearnedWindowTitles == nil {
				loaded.LearnedWindowTitles = map[string]string{}
			}
			s.settings = loaded
		}
	}
	if raw, err := os.ReadFile(s.TrustedPeersPath()); err == nil {
		var peers []core.TrustedPeerRecord
		if json.Unmarshal(raw, &peers) == nil {
			s.trustedPeers = peers
		} else {
			// Preserve corrupt file aside instead of silently wiping on next save
			_ = os.Rename(s.TrustedPeersPath(), s.TrustedPeersPath()+".corrupt")
		}
	}
}

func (s *Store) Settings() core.AppSettings {
	s.mu.RLock()
	defer s.mu.RUnlock()
	cp := s.settings
	cp.PeerAliases = copyMap(s.settings.PeerAliases)
	cp.LearnedWindowTitles = copyMap(s.settings.LearnedWindowTitles)
	cp.CustomRemoteProcessNames = append([]string(nil), s.settings.CustomRemoteProcessNames...)
	return cp
}

func (s *Store) UpdateSettings(mutate func(*core.AppSettings)) error {
	s.mu.Lock()
	mutate(&s.settings)
	if s.settings.UDPPort == 0 {
		s.settings.UDPPort = core.DefaultUDPPort
	}
	if s.settings.PeerAliases == nil {
		s.settings.PeerAliases = map[string]string{}
	}
	if s.settings.LearnedWindowTitles == nil {
		s.settings.LearnedWindowTitles = map[string]string{}
	}
	snapshot := s.settings
	snapshot.PeerAliases = copyMap(s.settings.PeerAliases)
	snapshot.LearnedWindowTitles = copyMap(s.settings.LearnedWindowTitles)
	snapshot.CustomRemoteProcessNames = append([]string(nil), s.settings.CustomRemoteProcessNames...)
	data, err := json.MarshalIndent(snapshot, "", "  ")
	cb := s.OnSettingsChanged
	s.mu.Unlock()

	if err != nil {
		return err
	}
	if err := atomicWriteFile(s.SettingsPath(), data); err != nil {
		return err
	}
	if cb != nil {
		cb(snapshot)
	}
	return nil
}

func (s *Store) TrustedPeers() []core.TrustedPeerRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]core.TrustedPeerRecord, len(s.trustedPeers))
	copy(out, s.trustedPeers)
	return out
}

func (s *Store) TrustedPeerByDeviceID(deviceID string) *core.TrustedPeerRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for i := range s.trustedPeers {
		if s.trustedPeers[i].DeviceID == deviceID {
			cp := s.trustedPeers[i]
			return &cp
		}
	}
	return nil
}

func (s *Store) TrustedPeerMatchingIP(ip string) *core.TrustedPeerRecord {
	if ip == "" {
		return nil
	}
	norm := core.NormalizeIP(ip)
	s.mu.RLock()
	defer s.mu.RUnlock()
	for i := range s.trustedPeers {
		if core.NormalizeIP(s.trustedPeers[i].LastKnownIP) == norm {
			cp := s.trustedPeers[i]
			return &cp
		}
	}
	return nil
}

func (s *Store) SaveTrustedPeer(rec core.TrustedPeerRecord) error {
	s.mu.Lock()
	replaced := false
	for i := range s.trustedPeers {
		if s.trustedPeers[i].DeviceID == rec.DeviceID {
			s.trustedPeers[i] = rec
			replaced = true
			break
		}
	}
	if !replaced {
		s.trustedPeers = append(s.trustedPeers, rec)
	}
	err := s.persistTrustedPeersLocked()
	peersCopy := append([]core.TrustedPeerRecord(nil), s.trustedPeers...)
	cb := s.OnTrustedPeersChanged
	s.mu.Unlock()

	if err == nil && cb != nil {
		cb(peersCopy)
	}
	return err
}

func (s *Store) UpdateTrustedPeerIP(deviceID, ip string) error {
	return s.UpdateTrustedPeerInfo(deviceID, ip, "")
}

func (s *Store) UpdateTrustedPeerInfo(deviceID, ip, osName string) error {
	s.mu.Lock()
	changed := false
	for i := range s.trustedPeers {
		if s.trustedPeers[i].DeviceID == deviceID {
			if ip != "" && s.trustedPeers[i].LastKnownIP != ip {
				s.trustedPeers[i].LastKnownIP = ip
				changed = true
			}
			if osName != "" && osName != "unknown" && s.trustedPeers[i].OS != osName {
				s.trustedPeers[i].OS = osName
				changed = true
			}
			break
		}
	}
	var err error
	var peersCopy []core.TrustedPeerRecord
	var cb func([]core.TrustedPeerRecord)
	if changed {
		err = s.persistTrustedPeersLocked()
		peersCopy = append([]core.TrustedPeerRecord(nil), s.trustedPeers...)
		cb = s.OnTrustedPeersChanged
	}
	s.mu.Unlock()

	if changed && err == nil && cb != nil {
		cb(peersCopy)
	}
	return err
}

func (s *Store) ClearTrustedPeers() error {
	s.mu.Lock()
	s.trustedPeers = nil
	err := s.persistTrustedPeersLocked()
	cb := s.OnTrustedPeersChanged
	s.mu.Unlock()

	if err == nil && cb != nil {
		cb(nil)
	}
	return err
}

func (s *Store) persistTrustedPeersLocked() error {
	data, err := json.MarshalIndent(s.trustedPeers, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteFile(s.TrustedPeersPath(), data)
}

// LoadOrCreateIdentity loads or creates the DPAPI-protected Curve25519 identity non-destructively.
// If identity.dpapi exists but cannot be read or decrypted (e.g. profile migration / DPAPI error),
// it returns IdentityLocked and NEVER overwrites the existing blob.
func (s *Store) LoadOrCreateIdentity() core.IdentityLoadResult {
	path := s.IdentityPath()
	return core.LoadOrCreateWithStore(
		func() core.KeyReadOutcome {
			blob, err := os.ReadFile(path)
			if err != nil {
				if errors.Is(err, os.ErrNotExist) {
					return core.KeyReadOutcome{Status: core.KeyReadNotFound}
				}
				return core.KeyReadOutcome{Status: core.KeyReadLocked, Err: err}
			}
			plain, err := dpapiUnprotect(blob)
			if err != nil {
				return core.KeyReadOutcome{Status: core.KeyReadLocked, Err: err}
			}
			return core.KeyReadOutcome{Status: core.KeyReadFound, Data: plain}
		},
		func(raw []byte) error {
			enc, err := dpapiProtect(raw)
			if err != nil {
				return err
			}
			return atomicWriteFile(path, enc)
		},
		func(raw []byte) error {
			enc, err := dpapiProtect(raw)
			if err != nil {
				return err
			}
			return atomicWriteFile(path, enc)
		},
	)
}

// ResetIdentity explicitly rotates the device's DPAPI identity (only on explicit user action, e.g. after profile/password reset).
func (s *Store) ResetIdentity() (*core.CryptoIdentity, error) {
	fresh, err := core.GenerateEphemeralIdentity()
	if err != nil {
		return nil, err
	}
	raw := fresh.RawPrivateKey()
	defer clear(raw)
	enc, err := dpapiProtect(raw)
	if err != nil {
		return nil, err
	}
	if err := atomicWriteFile(s.IdentityPath(), enc); err != nil {
		return nil, err
	}
	return fresh, nil
}

func copyMap(m map[string]string) map[string]string {
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

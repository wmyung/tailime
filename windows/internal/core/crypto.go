package core

import (
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
)

const (
	hmacHKDFSalt = "TailIME-HMAC-v1"
	sasHKDFSalt  = "TailIME-SAS-v1"
)

type CryptoIdentity struct {
	privateKey      *ecdh.PrivateKey
	PublicKeyData   []byte
	PublicKeyBase64 string
	DeviceID        string
}

func NewCryptoIdentity(priv *ecdh.PrivateKey) *CryptoIdentity {
	pub := priv.PublicKey().Bytes()
	pubCopy := append([]byte(nil), pub...)
	return &CryptoIdentity{
		privateKey:      priv,
		PublicKeyData:   pubCopy,
		PublicKeyBase64: base64.StdEncoding.EncodeToString(pubCopy),
		DeviceID:        ComputeDeviceID(pubCopy),
	}
}

func GenerateEphemeralIdentity() (*CryptoIdentity, error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return NewCryptoIdentity(priv), nil
}

func IdentityFromRawPrivateKey(raw []byte) (*CryptoIdentity, error) {
	if len(raw) != 32 {
		return nil, errors.New("invalid X25519 private key length")
	}
	priv, err := ecdh.X25519().NewPrivateKey(raw)
	if err != nil {
		return nil, err
	}
	return NewCryptoIdentity(priv), nil
}

func (id *CryptoIdentity) RawPrivateKey() []byte {
	return append([]byte(nil), id.privateKey.Bytes()...)
}

func ComputeDeviceID(pubKeyData []byte) string {
	sum := sha256.Sum256(pubKeyData)
	return hex.EncodeToString(sum[:16])
}

func DeviceIDForPublicKeyBase64(b64 string) (string, bool) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(raw) != 32 {
		return "", false
	}
	return ComputeDeviceID(raw), true
}

func (id *CryptoIdentity) sharedSecretAndInfo(peerPubKeyBase64 string) ([]byte, string, error) {
	peerPubRaw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(peerPubKeyBase64))
	if err != nil || len(peerPubRaw) != 32 {
		return nil, "", errors.New("invalid peer public key")
	}
	peerPub, err := ecdh.X25519().NewPublicKey(peerPubRaw)
	if err != nil {
		return nil, "", err
	}
	shared, err := id.privateKey.ECDH(peerPub)
	if err != nil {
		return nil, "", err
	}
	peerID := ComputeDeviceID(peerPubRaw)
	pair := []string{id.DeviceID, peerID}
	sort.Strings(pair)
	return shared, strings.Join(pair, "|"), nil
}

// DerivePeerHMACKey derives a 256-bit HMAC-SHA256 key byte-for-byte identical to macOS CryptoIdentity.derivePeerHMACKey.
func (id *CryptoIdentity) DerivePeerHMACKey(peerPubKeyBase64 string) ([]byte, error) {
	shared, info, err := id.sharedSecretAndInfo(peerPubKeyBase64)
	if err != nil {
		return nil, err
	}
	return hkdf.Key(sha256.New, shared, []byte(hmacHKDFSalt), info, 32)
}

// ConfirmationCode derives the 6-digit SAS ("123-456") byte-for-byte identical to macOS CryptoIdentity.confirmationCode.
func (id *CryptoIdentity) ConfirmationCode(peerPubKeyBase64 string) (string, error) {
	shared, info, err := id.sharedSecretAndInfo(peerPubKeyBase64)
	if err != nil {
		return "", err
	}
	key4, err := hkdf.Key(sha256.New, shared, []byte(sasHKDFSalt), info, 4)
	if err != nil {
		return "", err
	}
	rawVal := binary.BigEndian.Uint32(key4)
	code := rawVal % 1_000_000
	return fmt.Sprintf("%03d-%03d", code/1000, code%1000), nil
}

// PairingTokenPayload matches Swift CryptoIdentity.PairingTokenPayload JSON fields verbatim.
type PairingTokenPayload struct {
	V               int    `json:"v"`
	DeviceID        string `json:"deviceID"`
	Name            string `json:"name"`
	PublicKeyBase64 string `json:"publicKeyBase64"`
	TailscaleIP     string `json:"tailscaleIP,omitempty"`
	Port            uint16 `json:"port"`
	OS              string `json:"os,omitempty"`
}

func (id *CryptoIdentity) ExportPairingToken(hostName, tailscaleIP string, port uint16) (string, error) {
	payload := PairingTokenPayload{
		V:               1,
		DeviceID:        id.DeviceID,
		Name:            hostName,
		PublicKeyBase64: id.PublicKeyBase64,
		TailscaleIP:     tailscaleIP,
		Port:            port,
		OS:              "windows",
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return "TKP1:" + base64.RawURLEncoding.EncodeToString(data), nil
}

func DecodePairingToken(token string) (*PairingTokenPayload, error) {
	trimmed := strings.TrimSpace(token)
	if !strings.HasPrefix(trimmed, "TKP1:") {
		return nil, errors.New("missing TKP1 prefix")
	}
	b64 := strings.TrimPrefix(trimmed, "TKP1:")
	data, err := base64.RawURLEncoding.DecodeString(b64)
	if err != nil {
		// Accept padded standard/URL base64 too for resilience
		data, err = base64.URLEncoding.DecodeString(b64)
		if err != nil {
			return nil, errors.New("invalid base64url token")
		}
	}
	var payload PairingTokenPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, errors.New("invalid token JSON")
	}
	if payload.V != 1 {
		return nil, errors.New("unsupported token version")
	}
	derivedID, ok := DeviceIDForPublicKeyBase64(payload.PublicKeyBase64)
	if !ok || derivedID != payload.DeviceID {
		return nil, errors.New("token deviceID mismatch")
	}
	return &payload, nil
}

// Non-destructive persistent identity loader state machine (mirrors macOS v1.0.2 CryptoIdentity.loadOrCreateWithStore).

type KeyReadStatus int

const (
	KeyReadFound KeyReadStatus = iota
	KeyReadNotFound
	KeyReadLocked
)

type KeyReadOutcome struct {
	Status KeyReadStatus
	Data   []byte
	Err    error
}

type IdentityLoadStatus int

const (
	IdentityLoaded IdentityLoadStatus = iota
	IdentityCreated
	IdentityLocked
	IdentitySaveFailed
)

type IdentityLoadResult struct {
	Status   IdentityLoadStatus
	Identity *CryptoIdentity
	Err      error
}

func (r IdentityLoadResult) IsPersistent() bool {
	return r.Status == IdentityLoaded || r.Status == IdentityCreated
}

// LoadOrCreateWithStore NEVER overwrites an existing protected key blob on KeyReadLocked.
// Only creates a new key when KeyReadNotFound is explicitly returned (or repairs corrupted bytes on KeyReadFound).
func LoadOrCreateWithStore(
	read func() KeyReadOutcome,
	create func([]byte) error,
	update func([]byte) error,
) IdentityLoadResult {
	outcome := read()
	switch outcome.Status {
	case KeyReadFound:
		if id, err := IdentityFromRawPrivateKey(outcome.Data); err == nil {
			return IdentityLoadResult{Status: IdentityLoaded, Identity: id}
		}
		fresh, err := GenerateEphemeralIdentity()
		if err != nil {
			return IdentityLoadResult{Status: IdentitySaveFailed, Err: err}
		}
		if err := update(fresh.RawPrivateKey()); err != nil {
			return IdentityLoadResult{Status: IdentitySaveFailed, Err: err}
		}
		return IdentityLoadResult{Status: IdentityCreated, Identity: fresh}

	case KeyReadNotFound:
		fresh, err := GenerateEphemeralIdentity()
		if err != nil {
			return IdentityLoadResult{Status: IdentitySaveFailed, Err: err}
		}
		if err := create(fresh.RawPrivateKey()); err != nil {
			return IdentityLoadResult{Status: IdentitySaveFailed, Err: err}
		}
		return IdentityLoadResult{Status: IdentityCreated, Identity: fresh}

	default: // KeyReadLocked
		return IdentityLoadResult{Status: IdentityLocked, Err: outcome.Err}
	}
}

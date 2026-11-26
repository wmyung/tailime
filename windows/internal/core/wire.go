package core

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"time"
)

type WireCommand string

const (
	CmdPing        WireCommand = "ping"
	CmdPong        WireCommand = "pong"
	CmdSet         WireCommand = "set"
	CmdExpectSet   WireCommand = "expectSet"
	CmdAck         WireCommand = "ack"
	CmdState       WireCommand = "state"
	CmdStatus      WireCommand = "status"
	CmdProbeQuery  WireCommand = "probeQuery"
	CmdProbeResult WireCommand = "probeResult"
	CmdPairHello   WireCommand = "pairHello"
	CmdPairAck     WireCommand = "pairAck"
)

func (c WireCommand) IsStateMutating() bool {
	return c == CmdSet || c == CmdExpectSet || c == CmdState
}

// WireMessage matches Swift TailIMECore.WireMessage JSON schema verbatim.
type WireMessage struct {
	Cmd               WireCommand   `json:"cmd"`
	SenderDeviceID    string        `json:"senderDeviceID"`
	SenderName        string        `json:"senderName,omitempty"`
	BootSessionID     string        `json:"bootSessionID"`
	Seq               uint64        `json:"seq"`
	ReplyToSeq        *uint64       `json:"replyToSeq,omitempty"`
	TargetLanguage    InputLanguage `json:"targetLanguage,omitempty"`
	CurrentLanguage   InputLanguage `json:"currentLanguage,omitempty"`
	SourceID          string        `json:"sourceID,omitempty"`
	OK                *bool         `json:"ok,omitempty"`
	Via               string        `json:"via,omitempty"`
	CarrierDeadlineMs *int          `json:"carrierDeadlineMs,omitempty"`
	ProbeToken        *uint64       `json:"probeToken,omitempty"`
	ProbeObserved     *bool         `json:"probeObserved,omitempty"`
	PublicKeyBase64   string        `json:"publicKeyBase64,omitempty"`
	PairReply         *bool         `json:"pairReply,omitempty"`
	SenderOS          string        `json:"senderOS,omitempty"`
	Version           string        `json:"version,omitempty"`
}

var (
	ErrInvalidMagic               = errors.New("invalid TIV1 magic")
	ErrTruncated                  = errors.New("truncated packet")
	ErrPayloadTooLarge            = errors.New("payload too large")
	ErrTimestampOutOfWindow       = errors.New("timestamp out of window")
	ErrMissingKeyForAuthenticated = errors.New("missing key for authenticated packet")
	ErrInvalidHMAC                = errors.New("invalid HMAC")
	ErrUnauthenticatedNotAllowed  = errors.New("unauthenticated command not allowed")
	ErrMalformedPayload           = errors.New("malformed JSON payload")
)

const (
	WireHeaderLength    = 4 + 1 + 8 + 8 + 2 // 23 bytes
	WireMACLength       = 32
	WireMaxPayloadBytes = 1024
	WireFlagAuth        = byte(0x01)
	WireMaxClockSkewMs  = uint64(5 * 60 * 1000)
)

var wireMagic = [4]byte{'T', 'I', 'V', '1'}

type DecodedWirePacket struct {
	Authenticated bool
	TimestampMs   uint64
	Nonce         uint64
	Message       WireMessage
}

func RandomNonce() uint64 {
	var b [8]byte
	_, _ = rand.Read(b[:])
	v := binary.BigEndian.Uint64(b[:])
	if v == 0 {
		return 1
	}
	return v
}

func EncodeWirePacket(msg WireMessage, key []byte, timestampMs uint64, nonce uint64) ([]byte, error) {
	if timestampMs == 0 {
		timestampMs = uint64(time.Now().UnixMilli())
	}
	if nonce == 0 {
		nonce = RandomNonce()
	}
	payload, err := json.Marshal(msg)
	if err != nil {
		return nil, err
	}
	if len(payload) > WireMaxPayloadBytes {
		return nil, ErrPayloadTooLarge
	}
	isAuth := len(key) > 0
	if !isAuth && msg.Cmd != CmdPairHello {
		return nil, ErrUnauthenticatedNotAllowed
	}

	totalLen := WireHeaderLength + len(payload)
	if isAuth {
		totalLen += WireMACLength
	}
	pkt := make([]byte, totalLen)
	copy(pkt[0:4], wireMagic[:])
	if isAuth {
		pkt[4] = WireFlagAuth
	}
	binary.BigEndian.PutUint64(pkt[5:13], timestampMs)
	binary.BigEndian.PutUint64(pkt[13:21], nonce)
	binary.BigEndian.PutUint16(pkt[21:23], uint16(len(payload)))
	copy(pkt[23:23+len(payload)], payload)

	if isAuth {
		mac := hmac.New(sha256.New, key)
		mac.Write(pkt[:WireHeaderLength+len(payload)])
		sum := mac.Sum(nil)
		copy(pkt[WireHeaderLength+len(payload):], sum)
	}
	return pkt, nil
}

func DecodeWirePacket(data []byte, nowMs uint64, keyLookup func(senderDeviceID string) []byte) (*DecodedWirePacket, error) {
	if nowMs == 0 {
		nowMs = uint64(time.Now().UnixMilli())
	}
	if len(data) < WireHeaderLength {
		return nil, ErrTruncated
	}
	if data[0] != wireMagic[0] || data[1] != wireMagic[1] || data[2] != wireMagic[2] || data[3] != wireMagic[3] {
		return nil, ErrInvalidMagic
	}
	isAuth := (data[4] & WireFlagAuth) != 0
	tsMs := binary.BigEndian.Uint64(data[5:13])
	nonce := binary.BigEndian.Uint64(data[13:21])
	payloadLen := int(binary.BigEndian.Uint16(data[21:23]))
	if payloadLen > WireMaxPayloadBytes {
		return nil, ErrPayloadTooLarge
	}
	expectedLen := WireHeaderLength + payloadLen
	if isAuth {
		expectedLen += WireMACLength
	}
	if len(data) != expectedLen {
		return nil, ErrTruncated
	}

	var diff uint64
	if nowMs >= tsMs {
		diff = nowMs - tsMs
	} else {
		diff = tsMs - nowMs
	}
	if diff > WireMaxClockSkewMs {
		return nil, ErrTimestampOutOfWindow
	}

	var msg WireMessage
	if err := json.Unmarshal(data[WireHeaderLength:WireHeaderLength+payloadLen], &msg); err != nil {
		return nil, ErrMalformedPayload
	}
	if msg.SenderDeviceID == "" || msg.BootSessionID == "" {
		return nil, ErrMalformedPayload
	}

	if isAuth {
		if keyLookup == nil {
			return nil, ErrMissingKeyForAuthenticated
		}
		key := keyLookup(msg.SenderDeviceID)
		if len(key) == 0 {
			return nil, ErrMissingKeyForAuthenticated
		}
		mac := hmac.New(sha256.New, key)
		mac.Write(data[:WireHeaderLength+payloadLen])
		expectedMAC := mac.Sum(nil)
		receivedMAC := data[WireHeaderLength+payloadLen : expectedLen]
		if !hmac.Equal(receivedMAC, expectedMAC) {
			return nil, ErrInvalidHMAC
		}
	} else {
		derivedID, ok := DeviceIDForPublicKeyBase64(msg.PublicKeyBase64)
		if msg.Cmd != CmdPairHello || !ok || derivedID != msg.SenderDeviceID {
			return nil, ErrUnauthenticatedNotAllowed
		}
	}

	return &DecodedWirePacket{
		Authenticated: isAuth,
		TimestampMs:   tsMs,
		Nonce:         nonce,
		Message:       msg,
	}, nil
}

// SlidingWindowReplayGuard matches macOS SlidingWindowReplayGuard invariants verbatim.

type ReplayVerdict int

const (
	ReplayAccept ReplayVerdict = iota
	ReplayDuplicate
	ReplayRejectStaleOrder
	ReplayRejectTooOld
)

type sessionWindow struct {
	highestSeq         uint64
	highestMutatingSeq uint64
	bitmap             uint64
	lastSeenAt         time.Time
	cachedReplies      map[uint64]WireMessage
}

type SlidingWindowReplayGuard struct {
	sessions    map[string]*sessionWindow
	maxSessions int
}

func NewSlidingWindowReplayGuard() *SlidingWindowReplayGuard {
	return &SlidingWindowReplayGuard{
		sessions:    make(map[string]*sessionWindow),
		maxSessions: 64,
	}
}

func (g *SlidingWindowReplayGuard) CheckAndRecord(
	senderDeviceID, bootSessionID string,
	seq uint64,
	now time.Time,
	isStateMutating bool,
) (ReplayVerdict, *WireMessage) {
	if seq == 0 {
		return ReplayRejectTooOld, nil
	}
	key := senderDeviceID + "#" + bootSessionID

	if len(g.sessions) > g.maxSessions {
		for k, w := range g.sessions {
			if now.Sub(w.lastSeenAt) > time.Hour {
				delete(g.sessions, k)
			}
		}
	}

	w, exists := g.sessions[key]
	if !exists {
		w = &sessionWindow{cachedReplies: make(map[uint64]WireMessage)}
		g.sessions[key] = w
	}
	w.lastSeenAt = now

	if w.highestSeq == 0 {
		w.highestSeq = seq
		if isStateMutating {
			w.highestMutatingSeq = seq
		}
		w.bitmap = 1
		return ReplayAccept, nil
	}

	if seq > w.highestSeq {
		shift := seq - w.highestSeq
		if shift >= 64 {
			w.bitmap = 1
		} else {
			w.bitmap = (w.bitmap << shift) | 1
		}
		w.highestSeq = seq
		if isStateMutating && seq > w.highestMutatingSeq {
			w.highestMutatingSeq = seq
		}
		if len(w.cachedReplies) > 32 {
			var minKept uint64
			if w.highestSeq > 64 {
				minKept = w.highestSeq - 64
			}
			for k := range w.cachedReplies {
				if k < minKept {
					delete(w.cachedReplies, k)
				}
			}
		}
		return ReplayAccept, nil
	}

	delta := w.highestSeq - seq
	if delta >= 64 {
		return ReplayRejectTooOld, nil
	}

	bit := uint64(1) << delta
	if (w.bitmap & bit) != 0 {
		if cached, ok := w.cachedReplies[seq]; ok {
			copyReply := cached
			return ReplayDuplicate, &copyReply
		}
		return ReplayDuplicate, nil
	}

	w.bitmap |= bit
	if isStateMutating && seq < w.highestMutatingSeq {
		return ReplayRejectStaleOrder, nil
	}
	if isStateMutating && seq > w.highestMutatingSeq {
		w.highestMutatingSeq = seq
	}
	return ReplayAccept, nil
}

func (g *SlidingWindowReplayGuard) CacheReply(reply WireMessage, senderDeviceID, bootSessionID string, seq uint64) {
	key := senderDeviceID + "#" + bootSessionID
	if w, ok := g.sessions[key]; ok {
		w.cachedReplies[seq] = reply
	}
}

package coordinator

import (
	"net"
	"testing"
	"time"

	"github.com/wmyung/tailime/windows/internal/core"
	"github.com/wmyung/tailime/windows/internal/netudp"
	"github.com/wmyung/tailime/windows/internal/storage"
	"github.com/wmyung/tailime/windows/internal/winhook"
	"github.com/wmyung/tailime/windows/internal/winime"
)

func TestCoordinatorLoopbackPairingPingAndSet(t *testing.T) {
	dirA := t.TempDir()
	dirB := t.TempDir()
	storeA := storage.NewStore(dirA)
	storeB := storage.NewStore(dirB)

	_ = storeA.UpdateSettings(func(s *core.AppSettings) { s.UDPPort = 49418 })
	_ = storeB.UpdateSettings(func(s *core.AppSettings) { s.UDPPort = 49419 })

	imeA := winime.NewEngine(101)
	imeB := winime.NewEngine(202)
	hookA := winhook.NewController(101)
	hookB := winhook.NewController(202)
	udpA := netudp.NewEndpoint(49418)
	udpB := netudp.NewEndpoint(49419)
	udpA.Start()
	udpB.Start()
	defer udpA.Stop()
	defer udpB.Stop()

	coordA := New(storeA, imeA, hookA, udpA)
	coordB := New(storeB, imeB, hookB, udpB)
	coordA.Start()
	coordB.Start()
	defer coordA.Stop()
	defer coordB.Stop()

	tokA, err := coordA.ExportPairingToken()
	if err != nil {
		t.Fatal(err)
	}
	tokB, err := coordB.ExportPairingToken()
	if err != nil {
		t.Fatal(err)
	}

	// Register each other via TKP1 tokens (using loopback IP for test)
	recB, err := coordA.ImportPairingToken(tokB)
	if err != nil {
		t.Fatal(err)
	}
	if recB.OS != "windows" {
		t.Fatalf("expected peer OS 'windows' from token, got %q", recB.OS)
	}
	recA, err := coordB.ImportPairingToken(tokA)
	if err != nil {
		t.Fatal(err)
	}
	_ = storeA.UpdateTrustedPeerIP(recB.DeviceID, "127.0.0.1")
	_ = storeB.UpdateTrustedPeerIP(recA.DeviceID, "127.0.0.1")

	// Send direct set(ko) from A to B's port using Endpoint.Send and verify B switches IME & replies with ACK!
	_, devAID, _ := coordA.IdentityStatus()
	_, devBID, _ := coordB.IdentityStatus()
	keyAB, err := coordA.identity.DerivePeerHMACKey(recB.PublicKeyBase64)
	if err != nil {
		t.Fatal(err)
	}

	ackReceived := make(chan core.WireMessage, 8)
	pongReceived := make(chan core.WireMessage, 8)
	origHandler := udpA.OnPacketReceived
	udpA.OnPacketReceived = func(in netudp.IncomingPacket) {
		if in.Packet.Message.SenderDeviceID == devBID {
			if in.Packet.Message.Cmd == core.CmdAck {
				select {
				case ackReceived <- in.Packet.Message:
				default:
				}
			} else if in.Packet.Message.Cmd == core.CmdPong {
				select {
				case pongReceived <- in.Packet.Message:
				default:
				}
			}
		}
		if origHandler != nil {
			origHandler(in)
		}
	}

	msg := core.WireMessage{
		Cmd:            core.CmdSet,
		SenderDeviceID: devAID,
		SenderName:     "mac-sim",
		SenderOS:       "macOS",
		BootSessionID:  "boot-test",
		Seq:            1,
		TargetLanguage: core.LangKorean,
		Version:        core.Version,
	}
	if err := udpA.Send(msg, "127.0.0.1", 49419, keyAB, 777); err != nil {
		t.Fatal(err)
	}

	select {
	case ack := <-ackReceived:
		if ack.CurrentLanguage != core.LangKorean || ack.OK == nil || !*ack.OK || ack.SenderOS != "windows" {
			t.Fatalf("unexpected ACK: %+v", ack)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for authenticated ACK from coordinator B")
	}
	if got := imeB.CurrentStatus().Language; got != core.LangKorean {
		t.Fatalf("expected imeB to be Korean, got %s", got)
	}

	// Verify rapid consecutive sets settle cleanly on the latest target (ko -> en -> ko -> en)
	for i, lang := range []core.InputLanguage{core.LangKorean, core.LangEnglish, core.LangKorean, core.LangEnglish} {
		seq := uint64(2 + i)
		rapid := core.WireMessage{
			Cmd:            core.CmdSet,
			SenderDeviceID: devAID,
			SenderName:     "mac-sim",
			SenderOS:       "macOS",
			BootSessionID:  "boot-test",
			Seq:            seq,
			TargetLanguage: lang,
			Version:        core.Version,
		}
		if err := udpA.Send(rapid, "127.0.0.1", 49419, keyAB, 800+seq); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.After(2 * time.Second)
	for {
		select {
		case ack := <-ackReceived:
			if ack.ReplyToSeq != nil && *ack.ReplyToSeq == 5 {
				if ack.CurrentLanguage != core.LangEnglish {
					t.Fatalf("expected final rapid ACK en, got %s", ack.CurrentLanguage)
				}
				goto rapidDone
			}
		case <-deadline:
			t.Fatal("timed out waiting for final rapid set ACK (seq 5)")
		}
	}
rapidDone:
	if got := imeB.CurrentStatus().Language; got != core.LangEnglish {
		t.Fatalf("expected imeB to settle on English after rapid sets, got %s", got)
	}

	// Verify idempotent pong caching: simulate first pong lost by sending initial ping from an ephemeral socket,
	// then retrying the exact same (bootSessionID, seq) ping from udpA — B MUST reply with its cached pong!
	pingMsg := core.WireMessage{
		Cmd:            core.CmdPing,
		SenderDeviceID: devAID,
		SenderName:     "mac-sim",
		SenderOS:       "macOS",
		BootSessionID:  "boot-test",
		Seq:            6,
		Version:        core.Version,
	}
	pkt, err := core.EncodeWirePacket(pingMsg, keyAB, uint64(time.Now().UnixMilli()), 906)
	if err != nil {
		t.Fatal(err)
	}
	dropConn, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 49419})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := dropConn.Write(pkt); err != nil {
		dropConn.Close()
		t.Fatal(err)
	}
	// Wait for B's first pong on the throwaway socket so we know B has processed seq 6 and cached its pong
	_ = dropConn.SetReadDeadline(time.Now().Add(2 * time.Second))
	tmpBuf := make([]byte, 2048)
	if _, err := dropConn.Read(tmpBuf); err != nil {
		dropConn.Close()
		t.Fatalf("expected B to reply to first ping: %v", err)
	}
	dropConn.Close()

	// Now retry exact same ping (seq=6, nonce=906) from udpA (which never saw the first pong) — B MUST resend cached pong!
	if err := udpA.Send(pingMsg, "127.0.0.1", 49419, keyAB, 906); err != nil {
		t.Fatal(err)
	}
	select {
	case pong := <-pongReceived:
		if pong.ReplyToSeq == nil || *pong.ReplyToSeq != 6 || pong.SenderOS != "windows" {
			t.Fatalf("unexpected cached retry pong: %+v", pong)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for cached duplicate ping retry pong")
	}

	// Verify enqueueIncomingSet rejects stale lower seq even if delivered out-of-order by parallel readLoops
	coordB.enqueueIncomingSet(incomingSetTask{
		msg:     core.WireMessage{Cmd: core.CmdSet, SenderDeviceID: devAID, BootSessionID: "boot-test", Seq: 3, TargetLanguage: core.LangKorean},
		srcIP:   "127.0.0.1",
		srcPort: 49418,
		peerKey: keyAB,
		nonce:   999,
		selfID:  devBID,
		bootID:  "b",
	})
	time.Sleep(40 * time.Millisecond)
	if got := imeB.CurrentStatus().Language; got != core.LangEnglish {
		t.Fatalf("stale lower seq=3 overwrote seq=5! got %s", got)
	}
}

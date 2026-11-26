package ctl

import (
	"testing"
)

func TestCtlServerRoundTripAndAuth(t *testing.T) {
	dir := t.TempDir()
	srv := NewServer(dir, func(cmd string, args map[string]string) map[string]any {
		return map[string]any{"ok": true, "cmd": cmd, "lang": args["lang"]}
	})
	if err := srv.Start(); err != nil {
		t.Fatal(err)
	}
	defer srv.Stop()

	resp, err := SendCommand(dir, "set", map[string]string{"lang": "ko"})
	if err != nil {
		t.Fatal(err)
	}
	if resp["ok"] != true || resp["cmd"] != "set" || resp["lang"] != "ko" {
		t.Fatalf("unexpected resp: %+v", resp)
	}
}

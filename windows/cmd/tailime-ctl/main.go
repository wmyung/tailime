package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/wmyung/tailime/windows/internal/ctl"
	"github.com/wmyung/tailime/windows/internal/storage"
)

func printUsage() {
	fmt.Println(`TailIME Windows CLI (tailime-ctl)

사용법:
  tailime-ctl status                        로컬·원격 상태, DPAPI 기기 키, UDP 바인딩 확인
  tailime-ctl toggle                        로컬 한영 즉시 전환
  tailime-ctl set <ko|en>                   로컬 입력기를 한국어(ko) 또는 영어(en)로 절대 전환
  tailime-ctl peers                         Tailscale 피어(macOS·Windows) 및 TailIME 연결 상태 조회
  tailime-ctl remote-set <ip|host> <ko|en>  페어링된 원격 기기 입력기를 절대 전환
  tailime-ctl pair-export                   내 페어링 토큰(TKP1:...) 출력
  tailime-ctl pair-import                   표준입력(stdin)으로 상대 기기 페어링 토큰 등록
  tailime-ctl pause | resume                TailIME 일시정지 / 재개
  tailime-ctl reset-identity                DPAPI 기기 키 수동 재발급 (기존 페어링 재등록 필요)
  tailime-ctl quit                          실행 중인 TailIME 종료`)
}

func printJSON(m map[string]any) {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		fmt.Println(m)
		return
	}
	fmt.Println(string(b))
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		printUsage()
		os.Exit(0)
	}

	dataDir := storage.DefaultDataDir()
	cmd := args[0]
	var reqArgs map[string]string

	switch cmd {
	case "status", "toggle", "peers", "pause", "resume", "quit", "pair-export", "reset-identity":
		// no extra args
	case "set":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "사용법: tailime-ctl set <ko|en>")
			os.Exit(2)
		}
		reqArgs = map[string]string{"lang": args[1]}
	case "remote-set":
		if len(args) < 3 {
			fmt.Fprintln(os.Stderr, "사용법: tailime-ctl remote-set <ip|host> <ko|en>")
			os.Exit(2)
		}
		reqArgs = map[string]string{"ip": args[1], "lang": args[2]}
	case "pair-import":
		raw, err := io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintf(os.Stderr, "오류: stdin 읽기 실패: %v\n", err)
			os.Exit(2)
		}
		tok := strings.TrimSpace(string(raw))
		if tok == "" {
			fmt.Fprintln(os.Stderr, "사용법: echo TKP1:... | tailime-ctl pair-import")
			os.Exit(2)
		}
		reqArgs = map[string]string{"token": tok}
	default:
		fmt.Fprintf(os.Stderr, "알 수 없는 명령: %s\n", cmd)
		printUsage()
		os.Exit(2)
	}

	resp, err := ctl.SendCommand(dataDir, cmd, reqArgs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "오류: %v\n", err)
		os.Exit(1)
	}

	if cmd == "pair-export" {
		if tok, ok := resp["token"].(string); ok && tok != "" {
			fmt.Println(tok)
			os.Exit(0)
		}
	}
	printJSON(resp)
	if ok, _ := resp["ok"].(bool); !ok {
		os.Exit(1)
	}
}

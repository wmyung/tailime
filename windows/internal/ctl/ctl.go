package ctl

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type EndpointInfo struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
	PID   int    `json:"pid"`
}

type Request struct {
	Token string            `json:"token"`
	Cmd   string            `json:"cmd"`
	Args  map[string]string `json:"args,omitempty"`
}

type Handler func(cmd string, args map[string]string) map[string]any

// Server listens strictly on 127.0.0.1:0 with a per-session 256-bit random bearer token
// written to <dataDir>/ctl.json (mode 0600), verified in constant time via hmac.Equal.
type Server struct {
	mu       sync.Mutex
	dataDir  string
	token    string
	listener net.Listener
	handler  Handler
	stopOnce sync.Once
}

func InfoPath(dataDir string) string {
	return filepath.Join(dataDir, "ctl.json")
}

func NewServer(dataDir string, handler Handler) *Server {
	return &Server{dataDir: dataDir, handler: handler}
}

func (s *Server) Start() error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	rawTok := make([]byte, 32)
	if _, err := rand.Read(rawTok); err != nil {
		_ = ln.Close()
		return err
	}
	token := hex.EncodeToString(rawTok)
	port := ln.Addr().(*net.TCPAddr).Port

	if err := os.MkdirAll(s.dataDir, 0700); err != nil {
		_ = ln.Close()
		return err
	}
	infoBytes, _ := json.Marshal(EndpointInfo{Port: port, Token: token, PID: os.Getpid()})
	tmpPath := InfoPath(s.dataDir) + ".tmp"
	if err := os.WriteFile(tmpPath, infoBytes, 0600); err != nil {
		_ = ln.Close()
		return err
	}
	if err := os.Rename(tmpPath, InfoPath(s.dataDir)); err != nil {
		_ = os.Remove(tmpPath)
		_ = ln.Close()
		return err
	}

	s.mu.Lock()
	s.listener = ln
	s.token = token
	s.mu.Unlock()

	go s.acceptLoop(ln, token)
	return nil
}

func (s *Server) Stop() {
	s.stopOnce.Do(func() {
		s.mu.Lock()
		ln := s.listener
		s.listener = nil
		s.mu.Unlock()
		if ln != nil {
			_ = ln.Close()
		}
		_ = os.Remove(InfoPath(s.dataDir))
	})
}

func (s *Server) acceptLoop(ln net.Listener, expectedToken string) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go s.handleConn(conn, expectedToken)
	}
}

func (s *Server) handleConn(conn net.Conn, expectedToken string) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(4 * time.Second))
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	if !scanner.Scan() {
		return
	}
	var req Request
	if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
		writeResp(conn, map[string]any{"ok": false, "error": "invalid request"})
		return
	}
	if !hmac.Equal([]byte(req.Token), []byte(expectedToken)) {
		writeResp(conn, map[string]any{"ok": false, "error": "unauthorized"})
		return
	}
	resp := s.handler(req.Cmd, req.Args)
	writeResp(conn, resp)
}

func writeResp(conn net.Conn, resp map[string]any) {
	data, err := json.Marshal(resp)
	if err != nil {
		return
	}
	_, _ = conn.Write(append(data, '\n'))
}

func SendCommand(dataDir, cmd string, args map[string]string) (map[string]any, error) {
	raw, err := os.ReadFile(InfoPath(dataDir))
	if err != nil {
		return nil, errors.New("TailIME 앱이 실행 중이 아닙니다. 먼저 TailIME.exe를 실행해 주세요")
	}
	var info EndpointInfo
	if err := json.Unmarshal(raw, &info); err != nil || info.Port <= 0 || info.Token == "" {
		return nil, errors.New("TailIME 제어 정보가 손상되었습니다")
	}
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", info.Port), 2*time.Second)
	if err != nil {
		return nil, errors.New("TailIME 앱과 통신하지 못했습니다 (실행 중인지 확인하세요)")
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))

	reqBytes, err := json.Marshal(Request{Token: info.Token, Cmd: cmd, Args: args})
	if err != nil {
		return nil, err
	}
	if _, err := conn.Write(append(reqBytes, '\n')); err != nil {
		return nil, err
	}
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	if !scanner.Scan() {
		return nil, errors.New("응답을 받지 못했습니다")
	}
	var resp map[string]any
	if err := json.Unmarshal(scanner.Bytes(), &resp); err != nil {
		return nil, err
	}
	return resp, nil
}

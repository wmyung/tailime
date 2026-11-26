//go:build windows

package winsock

import (
	"encoding/binary"
	"net/netip"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/wmyung/tailime/windows/internal/core"
)

const (
	afInet                  = 2
	afInet6                 = 23
	tcpTableOwnerPIDAll     = 5
	mibTCPStateEstab        = 5
	processQueryLimitedInfo = 0x1000
	th32csSnapProcess       = 0x00000002
	errorInsufficientBuffer = 122
	procPathCacheTTL        = 10 * time.Second
)

var (
	modIPHlpAPI               = syscall.NewLazyDLL("iphlpapi.dll")
	procGetExtendedTCPTable   = modIPHlpAPI.NewProc("GetExtendedTcpTable")
	modKernel32Sock           = syscall.NewLazyDLL("kernel32.dll")
	procOpenProcessSock       = modKernel32Sock.NewProc("OpenProcess")
	procCloseHandleSock       = modKernel32Sock.NewProc("CloseHandle")
	procQueryFullProcImageW   = modKernel32Sock.NewProc("QueryFullProcessImageNameW")
	procCreateToolhelp32Snap  = modKernel32Sock.NewProc("CreateToolhelp32Snapshot")
	procProcess32FirstW       = modKernel32Sock.NewProc("Process32FirstW")
	procProcess32NextW        = modKernel32Sock.NewProc("Process32NextW")
	modUser32Sock             = syscall.NewLazyDLL("user32.dll")
	procGetForegroundWndSock  = modUser32Sock.NewProc("GetForegroundWindow")
	procGetWindowTextW        = modUser32Sock.NewProc("GetWindowTextW")
	procGetWindowThreadPIDSock = modUser32Sock.NewProc("GetWindowThreadProcessId")
)

type mibTCPRowOwnerPID struct {
	State      uint32
	LocalAddr  uint32
	LocalPort  uint32
	RemoteAddr uint32
	RemotePort uint32
	OwningPID  uint32
}

type mibTCP6RowOwnerPID struct {
	LocalAddr     [16]byte
	LocalScopeID  uint32
	LocalPort     uint32
	RemoteAddr    [16]byte
	RemoteScopeID uint32
	RemotePort    uint32
	State         uint32
	OwningPID     uint32
}

type processEntry32W struct {
	Size            uint32
	CntUsage        uint32
	ProcessID       uint32
	DefaultHeapID   uintptr
	ModuleID        uint32
	CntThreads      uint32
	ParentProcessID uint32
	PriClassBase    int32
	Flags           uint32
	ExeFile         [260]uint16
}

type ForegroundInfo struct {
	HWND        uintptr
	PID         uint32
	ProcessPath string
	ProcessName string
	WindowTitle string
}

type procPathCacheEntry struct {
	path     string
	cachedAt time.Time
}

var (
	procPathCacheMu sync.RWMutex
	procPathCache   = map[uint32]procPathCacheEntry{}
)

func GetForegroundInfo() ForegroundInfo {
	hwnd, _, _ := procGetForegroundWndSock.Call()
	if hwnd == 0 {
		return ForegroundInfo{}
	}
	var pid uint32
	procGetWindowThreadPIDSock.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
	titleBuf := make([]uint16, 256)
	n, _, _ := procGetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(&titleBuf[0])), uintptr(len(titleBuf)))
	title := ""
	if n > 0 {
		title = syscall.UTF16ToString(titleBuf[:n])
	}
	fullPath := QueryProcessPath(pid)
	name := strings.ToLower(filepath.Base(strings.ReplaceAll(fullPath, "\\", "/")))
	return ForegroundInfo{
		HWND:        hwnd,
		PID:         pid,
		ProcessPath: fullPath,
		ProcessName: name,
		WindowTitle: title,
	}
}

func QueryProcessPath(pid uint32) string {
	if pid == 0 {
		return ""
	}
	now := time.Now()
	procPathCacheMu.RLock()
	if cached, ok := procPathCache[pid]; ok && now.Sub(cached.cachedAt) < procPathCacheTTL {
		procPathCacheMu.RUnlock()
		return cached.path
	}
	procPathCacheMu.RUnlock()

	h, _, _ := procOpenProcessSock.Call(processQueryLimitedInfo, 0, uintptr(pid))
	if h == 0 {
		return ""
	}
	defer procCloseHandleSock.Call(h)

	buf := make([]uint16, 512)
	size := uint32(len(buf))
	r1, _, _ := procQueryFullProcImageW.Call(h, 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)))
	if r1 == 0 {
		return ""
	}
	p := syscall.UTF16ToString(buf[:size])

	procPathCacheMu.Lock()
	if len(procPathCache) > 256 {
		for k, v := range procPathCache {
			if now.Sub(v.cachedAt) >= procPathCacheTTL {
				delete(procPathCache, k)
			}
		}
		if len(procPathCache) > 256 {
			procPathCache = map[uint32]procPathCacheEntry{}
		}
	}
	procPathCache[pid] = procPathCacheEntry{path: p, cachedAt: now}
	procPathCacheMu.Unlock()
	return p
}

// ActiveTailscaleClientIPsForViewer inspects ESTABLISHED IPv4/IPv6 TCP connections owned by
// the foreground viewer PID and sibling PIDs with the same executable name, excluding local self IPs.
func ActiveTailscaleClientIPsForViewer(viewerPID uint32, viewerExeName string, selfIPs []string) []string {
	if viewerPID == 0 {
		return nil
	}
	pidSet := map[uint32]bool{viewerPID: true}
	if viewerExeName != "" {
		for _, p := range findPIDsByExeName(viewerExeName) {
			pidSet[p] = true
		}
	}
	selfSet := map[string]bool{}
	for _, s := range selfIPs {
		if n := core.NormalizeIP(s); n != "" {
			selfSet[n] = true
		}
	}

	found := map[string]bool{}
	collectTCPv4(pidSet, selfSet, found)
	collectTCPv6(pidSet, selfSet, found)

	out := make([]string, 0, len(found))
	for ip := range found {
		out = append(out, ip)
	}
	sort.Strings(out)
	return out
}

func findPIDsByExeName(exeLower string) []uint32 {
	snap, _, _ := procCreateToolhelp32Snap.Call(th32csSnapProcess, 0)
	if snap == 0 || snap == ^uintptr(0) {
		return nil
	}
	defer procCloseHandleSock.Call(snap)

	var pe processEntry32W
	pe.Size = uint32(unsafe.Sizeof(pe))
	r1, _, _ := procProcess32FirstW.Call(snap, uintptr(unsafe.Pointer(&pe)))
	if r1 == 0 {
		return nil
	}
	var out []uint32
	for {
		name := strings.ToLower(syscall.UTF16ToString(pe.ExeFile[:]))
		if name == exeLower {
			out = append(out, pe.ProcessID)
		}
		rNext, _, _ := procProcess32NextW.Call(snap, uintptr(unsafe.Pointer(&pe)))
		if rNext == 0 {
			break
		}
	}
	return out
}

func fetchExtendedTCPTable(af uintptr) []byte {
	var size uint32
	procGetExtendedTCPTable.Call(0, uintptr(unsafe.Pointer(&size)), 0, af, tcpTableOwnerPIDAll, 0)
	for attempt := 0; attempt < 3; attempt++ {
		if size < 4 || size > 16*1024*1024 {
			return nil
		}
		buf := make([]byte, size)
		rc, _, _ := procGetExtendedTCPTable.Call(
			uintptr(unsafe.Pointer(&buf[0])),
			uintptr(unsafe.Pointer(&size)),
			0,
			af,
			tcpTableOwnerPIDAll,
			0,
		)
		if rc == 0 {
			return buf
		}
		if rc != errorInsufficientBuffer {
			return nil
		}
	}
	return nil
}

func collectTCPv4(pidSet map[uint32]bool, selfSet map[string]bool, out map[string]bool) {
	buf := fetchExtendedTCPTable(afInet)
	if len(buf) < 4 {
		return
	}
	count := int(binary.LittleEndian.Uint32(buf[:4]))
	rowSize := int(unsafe.Sizeof(mibTCPRowOwnerPID{}))
	for i := 0; i < count; i++ {
		off := 4 + i*rowSize
		if off+rowSize > len(buf) {
			break
		}
		row := (*mibTCPRowOwnerPID)(unsafe.Pointer(&buf[off]))
		if row.State != mibTCPStateEstab || !pidSet[row.OwningPID] {
			continue
		}
		var b [4]byte
		binary.LittleEndian.PutUint32(b[:], row.RemoteAddr)
		ip := netip.AddrFrom4(b).String()
		if core.IsTailscaleIPv4(ip) && !selfSet[ip] {
			out[ip] = true
		}
	}
}

func collectTCPv6(pidSet map[uint32]bool, selfSet map[string]bool, out map[string]bool) {
	buf := fetchExtendedTCPTable(afInet6)
	if len(buf) < 4 {
		return
	}
	count := int(binary.LittleEndian.Uint32(buf[:4]))
	rowSize := int(unsafe.Sizeof(mibTCP6RowOwnerPID{}))
	for i := 0; i < count; i++ {
		off := 4 + i*rowSize
		if off+rowSize > len(buf) {
			break
		}
		row := (*mibTCP6RowOwnerPID)(unsafe.Pointer(&buf[off]))
		if row.State != mibTCPStateEstab || !pidSet[row.OwningPID] {
			continue
		}
		addr := netip.AddrFrom16(row.RemoteAddr)
		ip := core.NormalizeIP(addr.String())
		if core.IsTailscaleIP(ip) && !selfSet[ip] {
			out[ip] = true
		}
	}
}

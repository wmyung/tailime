//go:build windows

package netudp

import (
	"errors"
	"net"
	"syscall"
	"unsafe"
)

const (
	sioUDPConnReset = 0x9800000C
	wsaeConnReset   = syscall.Errno(10054)
)

// disableUDPConnReset suppresses Windows WSAECONNRESET (10054) errors on UDP ReadFrom
// when an earlier sendto hit a closed peer port (ICMP Port Unreachable).
func disableUDPConnReset(conn *net.UDPConn) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return
	}
	_ = raw.Control(func(fd uintptr) {
		var flag uint32 = 0
		var bytesReturned uint32
		_ = syscall.WSAIoctl(
			syscall.Handle(fd),
			sioUDPConnReset,
			(*byte)(unsafe.Pointer(&flag)),
			uint32(unsafe.Sizeof(flag)),
			nil,
			0,
			&bytesReturned,
			nil,
			0,
		)
	})
}

func isTransientUDPError(err error) bool {
	if errors.Is(err, wsaeConnReset) {
		return true
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) {
		return errors.Is(opErr.Err, wsaeConnReset)
	}
	return false
}

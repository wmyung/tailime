//go:build !windows

package netudp

import "net"

func disableUDPConnReset(conn *net.UDPConn) {}

func isTransientUDPError(err error) bool { return false }

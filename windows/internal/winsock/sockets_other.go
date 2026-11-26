//go:build !windows

package winsock

type ForegroundInfo struct {
	HWND        uintptr
	PID         uint32
	ProcessPath string
	ProcessName string
	WindowTitle string
}

func GetForegroundInfo() ForegroundInfo { return ForegroundInfo{} }

func QueryProcessPath(pid uint32) string { return "" }

func ActiveTailscaleClientIPsForViewer(viewerPID uint32, viewerExeName string, selfIPs []string) []string {
	return nil
}

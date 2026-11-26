//go:build windows

package main

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"os"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/wmyung/tailime/windows/internal/coordinator"
	"github.com/wmyung/tailime/windows/internal/core"
	"github.com/wmyung/tailime/windows/internal/ctl"
	"github.com/wmyung/tailime/windows/internal/netudp"
	"github.com/wmyung/tailime/windows/internal/storage"
	"github.com/wmyung/tailime/windows/internal/tailscale"
	"github.com/wmyung/tailime/windows/internal/winhook"
	"github.com/wmyung/tailime/windows/internal/winime"
)

const (
	wmDestroy          = 0x0002
	wmCommand          = 0x0111
	wmClose            = 0x0010
	wmUser             = 0x0400
	wmTrayCallback     = wmUser + 1
	wmAppRefreshUI     = wmUser + 2
	wmAppQuit          = wmUser + 3
	wmLButtonUp        = 0x0202
	wmLButtonDblClk    = 0x0203
	wmRButtonUp        = 0x0205
	wmContextMenu      = 0x007B
	nimAdd             = 0x00000000
	nimModify          = 0x00000001
	nimDelete          = 0x00000002
	nifMessage         = 0x00000001
	nifIcon            = 0x00000002
	nifTip             = 0x00000004
	nifInfo            = 0x00000010
	niifInfo           = 0x00000001
	tpmRightButton     = 0x0002
	tpmBottomAlign     = 0x0020
	mfString           = 0x00000000
	mfGrayed           = 0x00000001
	mfChecked          = 0x00000008
	mfPopup            = 0x00000010
	mfSeparator        = 0x00000800
	mbYesNo            = 0x00000004
	mbOK               = 0x00000000
	mbIconInformation  = 0x00000040
	mbIconWarning      = 0x00000030
	mbSetForeground    = 0x00010000
	mbTopmost          = 0x00040000
	idYes              = 6
	errorAlreadyExists = 183

	cmdToggleLocal   = 1001
	cmdTogglePause   = 1002
	cmdOpenSettings  = 1003
	cmdCopyDiag      = 1004
	cmdRefreshTS     = 1005
	cmdReloadKey     = 1006
	cmdPinAuto       = 1010
	cmdQuit          = 1099
	cmdPinPeerBase   = 2000
	cfUnicodeText    = 13
	gmemMoveable     = 0x0002
	dtCenter         = 0x0001
	dtVCenter        = 0x0004
	dtSingleLine     = 0x0020
	transparentBk    = 1
	biRGB            = 0
	dibRGBColors     = 0
	cleartypeQuality = 5
	fwBold           = 700
	fwNormal         = 400
	defaultCharset   = 1
)

var (
	modUser32               = syscall.NewLazyDLL("user32.dll")
	procRegisterClassExW    = modUser32.NewProc("RegisterClassExW")
	procCreateWindowExW     = modUser32.NewProc("CreateWindowExW")
	procDefWindowProcW      = modUser32.NewProc("DefWindowProcW")
	procDestroyWindow       = modUser32.NewProc("DestroyWindow")
	procShowWindow          = modUser32.NewProc("ShowWindow")
	procUpdateWindow        = modUser32.NewProc("UpdateWindow")
	procSetForegroundWindow = modUser32.NewProc("SetForegroundWindow")
	procGetMessageW         = modUser32.NewProc("GetMessageW")
	procTranslateMessage    = modUser32.NewProc("TranslateMessage")
	procDispatchMessageW    = modUser32.NewProc("DispatchMessageW")
	procPostMessageW        = modUser32.NewProc("PostMessageW")
	procPostQuitMessage     = modUser32.NewProc("PostQuitMessage")
	procCreatePopupMenu     = modUser32.NewProc("CreatePopupMenu")
	procAppendMenuW         = modUser32.NewProc("AppendMenuW")
	procTrackPopupMenu      = modUser32.NewProc("TrackPopupMenu")
	procDestroyMenu         = modUser32.NewProc("DestroyMenu")
	procGetCursorPos        = modUser32.NewProc("GetCursorPos")
	procMessageBoxW         = modUser32.NewProc("MessageBoxW")
	procCreateIconIndirect  = modUser32.NewProc("CreateIconIndirect")
	procDestroyIcon         = modUser32.NewProc("DestroyIcon")
	procDrawTextW           = modUser32.NewProc("DrawTextW")
	procFillRect            = modUser32.NewProc("FillRect")
	procGetDC               = modUser32.NewProc("GetDC")
	procReleaseDC           = modUser32.NewProc("ReleaseDC")
	procOpenClipboard       = modUser32.NewProc("OpenClipboard")
	procCloseClipboard      = modUser32.NewProc("CloseClipboard")
	procEmptyClipboard      = modUser32.NewProc("EmptyClipboard")
	procSetClipboardData    = modUser32.NewProc("SetClipboardData")
	procGetClipboardData    = modUser32.NewProc("GetClipboardData")
	procSetProcessDpiCtx    = modUser32.NewProc("SetProcessDpiAwarenessContext")
	procSendMessageW        = modUser32.NewProc("SendMessageW")
	procSetWindowTextW      = modUser32.NewProc("SetWindowTextW")
	procGetWindowTextW      = modUser32.NewProc("GetWindowTextW")
	procGetWindowTextLenW   = modUser32.NewProc("GetWindowTextLengthW")
	procEnableWindow        = modUser32.NewProc("EnableWindow")
	procLoadCursorW         = modUser32.NewProc("LoadCursorW")

	modShell32          = syscall.NewLazyDLL("shell32.dll")
	procShellNotifyIcon = modShell32.NewProc("Shell_NotifyIconW")

	modGdi32              = syscall.NewLazyDLL("gdi32.dll")
	procCreateCompatDC    = modGdi32.NewProc("CreateCompatibleDC")
	procDeleteDC          = modGdi32.NewProc("DeleteDC")
	procCreateDIBSection  = modGdi32.NewProc("CreateDIBSection")
	procCreateBitmap      = modGdi32.NewProc("CreateBitmap")
	procSelectObject      = modGdi32.NewProc("SelectObject")
	procDeleteObject      = modGdi32.NewProc("DeleteObject")
	procCreateSolidBrush  = modGdi32.NewProc("CreateSolidBrush")
	procSetBkMode         = modGdi32.NewProc("SetBkMode")
	procSetTextColor      = modGdi32.NewProc("SetTextColor")
	procCreateFontIndirectW = modGdi32.NewProc("CreateFontIndirectW")

	modKernel32          = syscall.NewLazyDLL("kernel32.dll")
	procGetModuleHandleW = modKernel32.NewProc("GetModuleHandleW")
	procCreateMutexW     = modKernel32.NewProc("CreateMutexW")
	procGlobalAlloc      = modKernel32.NewProc("GlobalAlloc")
	procGlobalLock       = modKernel32.NewProc("GlobalLock")
	procGlobalUnlock     = modKernel32.NewProc("GlobalUnlock")
	procGlobalSize       = modKernel32.NewProc("GlobalSize")
	procCloseHandleMain  = modKernel32.NewProc("CloseHandle")

	modAdvapi32          = syscall.NewLazyDLL("advapi32.dll")
	procRegOpenKeyExW    = modAdvapi32.NewProc("RegOpenKeyExW")
	procRegCreateKeyExW  = modAdvapi32.NewProc("RegCreateKeyExW")
	procRegSetValueExW   = modAdvapi32.NewProc("RegSetValueExW")
	procRegQueryValueExW = modAdvapi32.NewProc("RegQueryValueExW")
	procRegDeleteValueW  = modAdvapi32.NewProc("RegDeleteValueW")
	procRegCloseKey      = modAdvapi32.NewProc("RegCloseKey")
)

type wndClassExW struct {
	CbSize        uint32
	Style         uint32
	LpfnWndProc   uintptr
	CbClsExtra    int32
	CbWndExtra    int32
	HInstance     uintptr
	HIcon         uintptr
	HCursor       uintptr
	HbrBackground uintptr
	LpszMenuName  *uint16
	LpszClassName *uint16
	HIconSm       uintptr
}

type point struct{ X, Y int32 }

type rectW struct{ Left, Top, Right, Bottom int32 }

type winMsg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
}

type notifyIconDataW struct {
	CbSize           uint32
	HWnd             uintptr
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	HIcon            uintptr
	SzTip            [128]uint16
	DwState          uint32
	DwStateMask      uint32
	SzInfo           [256]uint16
	UVersion         uint32
	SzInfoTitle      [64]uint16
	DwInfoFlags      uint32
	GuidItem         [16]byte
	HBalloonIcon     uintptr
}

type iconInfo struct {
	FIcon    uint32
	XHotspot uint32
	YHotspot uint32
	HbmMask  uintptr
	HbmColor uintptr
}

type bitmapInfoHeader struct {
	BiSize          uint32
	BiWidth         int32
	BiHeight        int32
	BiPlanes        uint16
	BiBitCount      uint16
	BiCompression   uint32
	BiSizeImage     uint32
	BiXPelsPerMeter int32
	BiYPelsPerMeter int32
	BiClrUsed       uint32
	BiClrImportant  uint32
}

type logFontW struct {
	LfHeight         int32
	LfWidth          int32
	LfEscapement     int32
	LfOrientation    int32
	LfWeight         int32
	LfItalic         byte
	LfUnderline      byte
	LfStrikeOut      byte
	LfCharSet        byte
	LfOutPrecision   byte
	LfClipPrecision  byte
	LfQuality        byte
	LfPitchAndFamily byte
	LfFaceName       [32]uint16
}

type appState struct {
	store     *storage.Store
	ime       *winime.Engine
	hook      *winhook.Controller
	udp       *netudp.Endpoint
	coord     *coordinator.Coordinator
	ctlServer *ctl.Server

	hInstance  uintptr
	trayHwnd   uintptr
	trayIcon   uintptr
	lastBadge  string
	lastColor  uint32
	menuPeers  []core.TailscalePeer
	settingsUI *settingsDialog

	stopOnce sync.Once
	stopCh   chan struct{}
}

var globalApp *appState

func main() {
	runtime.LockOSThread()

	// Enable Per-Monitor V2 DPI awareness when supported (Win10 1703+) so Win32 dialogs and tray badge render crisply on 4K displays.
	const dpiContextPerMonitorAwareV2 = ^uintptr(3) // (DPI_AWARENESS_CONTEXT)-4
	if procSetProcessDpiCtx.Find() == nil {
		procSetProcessDpiCtx.Call(dpiContextPerMonitorAwareV2)
	}

	// Single-instance guard via named Win32 mutex
	mutexName, _ := syscall.UTF16PtrFromString("Local\\TailIME_SingleInstance_v1")
	hMutex, _, err := procCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(mutexName)))
	if hMutex == 0 {
		return
	}
	defer procCloseHandleMain.Call(hMutex)
	if err == syscall.Errno(errorAlreadyExists) {
		return
	}

	var markerBytes [8]byte
	_, _ = rand.Read(markerBytes[:])
	marker := uintptr(binary.LittleEndian.Uint64(markerBytes[:]) | 0x1000)

	store := storage.NewStore("")
	imeEngine := winime.NewEngine(marker)
	hookCtrl := winhook.NewController(marker)
	udpEndp := netudp.NewEndpoint(store.Settings().UDPPort)
	coord := coordinator.New(store, imeEngine, hookCtrl, udpEndp)

	hInst, _, _ := procGetModuleHandleW.Call(0)
	app := &appState{
		store:     store,
		ime:       imeEngine,
		hook:      hookCtrl,
		udp:       udpEndp,
		coord:     coord,
		hInstance: hInst,
		stopCh:    make(chan struct{}),
	}
	globalApp = app

	coord.OnStateUpdated = func() {
		if app.trayHwnd != 0 {
			procPostMessageW.Call(app.trayHwnd, wmAppRefreshUI, 0, 0)
		}
	}
	coord.OnPairPrompt = func(peerName, srcIP, sas string) bool {
		title := "TailIME 기기 페어링 확인"
		body := fmt.Sprintf(
			"'%s' (%s)와(과) 암호화 페어링을 진행합니다.\n\n"+
				"확인 코드 (SAS):  %s\n\n"+
				"양쪽 기기 화면에 표시된 6자리 코드가 서로 일치하는지 확인한 뒤 승인하세요.",
			peerName, srcIP, sas,
		)
		return showMessageBox(0, title, body, mbYesNo|mbIconInformation|mbSetForeground|mbTopmost) == idYes
	}
	coord.OnStatusNotice = func(msg string) {
		app.showBalloon("TailIME", msg)
	}

	// Start local CLI control server FIRST so tailime-ctl works immediately!
	app.ctlServer = ctl.NewServer(store.BaseDir(), app.handleCtlCommand)
	_ = app.ctlServer.Start()

	udpEndp.Start()
	coord.Start()
	hookCtrl.Start()

	if err := app.createTrayWindow(); err != nil {
		return
	}
	app.refreshTailscaleAsync(true, nil)

	// Background Tailscale discovery & foreground context pollers
	go func() {
		tsTicker := time.NewTicker(15 * time.Second)
		fgTicker := time.NewTicker(500 * time.Millisecond)
		defer tsTicker.Stop()
		defer fgTicker.Stop()
		for {
			select {
			case <-app.stopCh:
				return
			case <-tsTicker.C:
				app.refreshTailscaleAsync(false, nil)
			case <-fgTicker.C:
				app.coord.RefreshForegroundContext()
				if app.trayHwnd != 0 {
					procPostMessageW.Call(app.trayHwnd, wmAppRefreshUI, 0, 0)
				}
			}
		}
	}()

	// Standard Win32 UI message loop
	var msg winMsg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
	}

	app.shutdown()
}

func (a *appState) shutdown() {
	a.stopOnce.Do(func() {
		close(a.stopCh)
		a.removeTrayIcon()
		a.hook.Stop()
		a.coord.Stop()
		a.udp.Stop()
		if a.ctlServer != nil {
			a.ctlServer.Stop()
		}
	})
}

func (a *appState) refreshTailscaleAsync(probe bool, onDone func(string)) {
	go func() {
		cliSnap := tailscale.FetchStatus(4 * time.Second)
		enriched := tailscale.EnrichSnapshot(cliSnap, a.store.TrustedPeers())
		a.coord.UpdateTailscaleSnapshot(enriched)
		if probe {
			a.coord.ProbeAllPairedPeers()
		}
		if onDone != nil {
			peers := enriched.DesktopPeers()
			selfIP := ""
			if enriched.SelfNode != nil {
				selfIP = enriched.SelfNode.PreferredIP()
			}
			var msg string
			if !enriched.FromCLI && selfIP != "" {
				msg = fmt.Sprintf("Tailscale 인터페이스 감지됨 (%s) · CLI 없음 — 직접 IP 또는 토큰으로 연결하세요.", selfIP)
			} else if len(peers) == 0 {
				msg = "감지된 Tailscale Mac/Windows 피어 없음 — 직접 IP 또는 토큰으로 연결하세요."
			} else {
				msg = fmt.Sprintf("Tailscale 피어 %d대 확인됨.", len(peers))
			}
			onDone(msg)
		}
	}()
}

// MARK: - CLI IPC Commands

func (a *appState) handleCtlCommand(cmd string, args map[string]string) map[string]any {
	switch cmd {
	case "status":
		st := a.ime.CurrentStatus()
		ctx := a.coord.CurrentRemoteContext()
		persistent, devID, kcErr := a.coord.IdentityStatus()
		errStr := ""
		if kcErr != nil {
			errStr = kcErr.Error()
		}
		remotePeer := ""
		if ctx.ResolvedPeer != nil {
			remotePeer = ctx.ResolvedPeer.HostName
		}
		return map[string]any{
			"ok":                 true,
			"os":                 "windows",
			"version":            core.Version,
			"enabled":            a.store.Settings().Enabled,
			"paused":             a.coord.IsPaused(),
			"keyboardHookActive": a.hook.IsActive(),
			"selfElevated":       a.ime.SelfElevated(),
			"elevationBlocked":   a.ime.LastElevationBlocked(),
			"identityPersistent": persistent,
			"deviceID":           devID,
			"identityError":      errStr,
			"localLang":          string(st.Language),
			"localSource":        st.SourceID,
			"boundUDP":           a.udp.BoundAddresses(),
			"remoteFocused":      ctx.HasActiveRemoteSession(),
			"remotePeer":         remotePeer,
			"remoteProcess":      ctx.ProcessName,
			"remoteResolution":   ctx.ResolutionSource,
			"remoteIsLobby":      ctx.IsLobbyWindow,
			"trustedPeerCount":   len(a.store.TrustedPeers()),
		}
	case "toggle":
		st := a.ime.Toggle()
		return map[string]any{"ok": true, "lang": string(st.Language)}
	case "set":
		lang, ok := core.ParseInputLanguage(args["lang"])
		if !ok {
			return map[string]any{"ok": false, "error": "lang must be 'ko' or 'en'"}
		}
		st := a.ime.SwitchTo(lang)
		return map[string]any{"ok": !st.ElevationBlocked, "target": string(lang), "actual": string(st.Language), "elevationBlocked": st.ElevationBlocked}
	case "pause":
		a.coord.SetPaused(true)
		return map[string]any{"ok": true, "paused": true}
	case "resume":
		a.coord.SetPaused(false)
		return map[string]any{"ok": true, "paused": false}
	case "peers":
		snap := a.coord.CurrentSnapshot()
		states := a.coord.PeerStates()
		list := make([]map[string]any, 0)
		if snap != nil {
			for _, p := range snap.Peers {
				ip := p.PreferredIP()
				st := states[ip]
				lang := "unknown"
				if st.CurrentLanguage != "" {
					lang = string(st.CurrentLanguage)
				}
				list = append(list, map[string]any{
					"hostName":        p.HostName,
					"os":              p.OS,
					"ip":              ip,
					"online":          p.Online,
					"direct":          p.IsDirectPath(),
					"daemonReachable": st.DaemonReachable,
					"lang":            lang,
				})
			}
		}
		return map[string]any{"ok": true, "peers": list}
	case "pair-export":
		tok, err := a.coord.ExportPairingToken()
		if err != nil {
			return map[string]any{"ok": false, "error": err.Error()}
		}
		return map[string]any{"ok": true, "token": tok}
	case "pair-import":
		rec, err := a.coord.ImportPairingToken(args["token"])
		if err != nil {
			return map[string]any{"ok": false, "error": err.Error()}
		}
		return map[string]any{"ok": true, "peer": rec.Name, "deviceID": rec.DeviceID}
	case "remote-set":
		lang, ok := core.ParseInputLanguage(args["lang"])
		if !ok || args["ip"] == "" {
			return map[string]any{"ok": false, "error": "ip and lang ('ko'|'en') required"}
		}
		name, ip, err := a.coord.SendManualRemoteSet(args["ip"], lang)
		if err != nil {
			return map[string]any{"ok": false, "error": err.Error()}
		}
		return map[string]any{"ok": true, "peer": name, "ip": ip, "target": string(lang)}
	case "reset-identity":
		if err := a.coord.ResetIdentityExplicit(); err != nil {
			return map[string]any{"ok": false, "error": err.Error()}
		}
		_, devID, _ := a.coord.IdentityStatus()
		return map[string]any{"ok": true, "deviceID": devID}
	case "quit":
		if a.trayHwnd != 0 {
			procPostMessageW.Call(a.trayHwnd, wmAppQuit, 0, 0)
		}
		return map[string]any{"ok": true}
	default:
		return map[string]any{"ok": false, "error": "unknown command: " + cmd}
	}
}

// MARK: - Tray Window & Dynamic Icon

func (a *appState) createTrayWindow() error {
	className, _ := syscall.UTF16PtrFromString("TailIMETrayWindowClass")
	wc := wndClassExW{
		CbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
		LpfnWndProc:   syscall.NewCallback(trayWndProc),
		HInstance:     a.hInstance,
		LpszClassName: className,
	}
	procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

	title, _ := syscall.UTF16PtrFromString("TailIME")
	hwnd, _, err := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(title)),
		0, 0, 0, 0, 0,
		0, 0, a.hInstance, 0,
	)
	if hwnd == 0 {
		return err
	}
	a.trayHwnd = hwnd
	a.updateTrayIcon(true)
	return nil
}

func trayWndProc(hwnd uintptr, msg uint32, wParam, lParam uintptr) uintptr {
	app := globalApp
	if app == nil {
		r, _, _ := procDefWindowProcW.Call(hwnd, uintptr(msg), wParam, lParam)
		return r
	}
	switch msg {
	case wmTrayCallback:
		switch uint32(lParam) {
		case wmRButtonUp, wmContextMenu:
			app.showTrayMenu()
		case wmLButtonUp, wmLButtonDblClk:
			app.openSettingsWindow()
		}
		return 0
	case wmAppRefreshUI:
		app.updateTrayIcon(false)
		if app.settingsUI != nil {
			app.settingsUI.refresh()
		}
		return 0
	case wmAppQuit:
		procDestroyWindow.Call(hwnd)
		return 0
	case wmCommand:
		app.handleMenuCommand(int(wParam & 0xFFFF))
		return 0
	case wmDestroy:
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(hwnd, uintptr(msg), wParam, lParam)
	return r
}

func (a *appState) updateTrayIcon(initial bool) {
	settings := a.store.Settings()
	paused := a.coord.IsPaused() || !settings.Enabled
	ctx := a.coord.CurrentRemoteContext()
	st := a.ime.CurrentStatus()
	persistent, _, _ := a.coord.IdentityStatus()
	warning := !persistent || a.ime.LastElevationBlocked() || !a.hook.IsActive()

	badge := st.Language.ShortBadge()
	// COLORREF is 0x00BBGGRR
	bgColor := uint32(0x00323232) // dark slate
	if paused {
		badge = "⏸"
		bgColor = 0x00666666
	} else if warning {
		bgColor = 0x000080FF // vivid orange
	} else if ctx.HasActiveRemoteSession() {
		bgColor = 0x00E37100 // TailIME blue (#0071E3)
		if ctx.ResolvedPeer != nil {
			states := a.coord.PeerStates()
			if ps, ok := states[ctx.ResolvedPeer.PreferredIP()]; ok && ps.DaemonReachable {
				badge = ps.CurrentLanguage.ShortBadge()
			}
		}
	} else if st.Language == core.LangKorean {
		bgColor = 0x009B4B1A // deep blue-indigo for Korean
	}

	if !initial && badge == a.lastBadge && bgColor == a.lastColor {
		return
	}

	newIcon := createBadgeIcon(badge, bgColor)
	if newIcon == 0 {
		return
	}
	oldIcon := a.trayIcon
	a.trayIcon = newIcon
	a.lastBadge = badge
	a.lastColor = bgColor

	var nid notifyIconDataW
	nid.CbSize = uint32(unsafe.Sizeof(nid))
	nid.HWnd = a.trayHwnd
	nid.UID = 1
	nid.UFlags = nifMessage | nifIcon | nifTip
	nid.UCallbackMessage = wmTrayCallback
	nid.HIcon = newIcon
	tip := fmt.Sprintf("TailIME v%s — %s", core.Version, badge)
	copyUTF16(nid.SzTip[:], tip)

	action := uintptr(nimModify)
	if initial {
		action = nimAdd
	}
	procShellNotifyIcon.Call(action, uintptr(unsafe.Pointer(&nid)))
	if oldIcon != 0 {
		procDestroyIcon.Call(oldIcon)
	}
}

func (a *appState) showBalloon(title, text string) {
	if a.trayHwnd == 0 {
		return
	}
	var nid notifyIconDataW
	nid.CbSize = uint32(unsafe.Sizeof(nid))
	nid.HWnd = a.trayHwnd
	nid.UID = 1
	nid.UFlags = nifInfo
	nid.DwInfoFlags = niifInfo
	copyUTF16(nid.SzInfoTitle[:], title)
	copyUTF16(nid.SzInfo[:], text)
	procShellNotifyIcon.Call(nimModify, uintptr(unsafe.Pointer(&nid)))
}

func (a *appState) removeTrayIcon() {
	if a.trayHwnd != 0 {
		var nid notifyIconDataW
		nid.CbSize = uint32(unsafe.Sizeof(nid))
		nid.HWnd = a.trayHwnd
		nid.UID = 1
		procShellNotifyIcon.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
	}
	if a.trayIcon != 0 {
		procDestroyIcon.Call(a.trayIcon)
		a.trayIcon = 0
	}
}

func (a *appState) showTrayMenu() {
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)

	persistent, _, _ := a.coord.IdentityStatus()
	if !persistent {
		appendMenu(menu, mfString, cmdReloadKey, "⚠ 기기 키(DPAPI) 잠김 — 클릭하여 다시 읽기")
		appendMenu(menu, mfSeparator, 0, "")
	}
	if a.ime.LastElevationBlocked() {
		appendMenu(menu, mfGrayed, 0, "⚠ 관리자 권한 창 감지 — TailIME 관리자 실행 필요")
		appendMenu(menu, mfSeparator, 0, "")
	}

	st := a.ime.CurrentStatus()
	appendMenu(menu, mfString, cmdToggleLocal, fmt.Sprintf("로컬 입력기: %s (%s) — 클릭하여 전환", st.Language.DisplayName(), st.Language.ShortBadge()))

	ctx := a.coord.CurrentRemoteContext()
	if ctx.HasActiveRemoteSession() && ctx.ResolvedPeer != nil {
		ps := a.coord.PeerStates()[ctx.ResolvedPeer.PreferredIP()]
		if ps.DaemonReachable {
			appendMenu(menu, mfGrayed, 0, fmt.Sprintf("⚡ 원격 활성: %s [%s] · %.1fms", ctx.ResolvedPeer.HostName, ps.CurrentLanguage.ShortBadge(), ps.LastRTTMs))
		} else {
			appendMenu(menu, mfGrayed, 0, fmt.Sprintf("↗ 원격 창: %s (TailIME 미연결)", ctx.ResolvedPeer.HostName))
		}
	} else {
		appendMenu(menu, mfGrayed, 0, "원격 세션: 대기 중")
	}

	// Submenu: Remote Target Selector (macOS + Windows)
	sub, _, _ := procCreatePopupMenu.Call()
	if sub != 0 {
		pinned := a.store.Settings().PinnedPeerID
		autoFlags := uintptr(mfString)
		if pinned == "" {
			autoFlags |= mfChecked
		}
		appendMenu(sub, autoFlags, cmdPinAuto, "자동 감지 (포커스 창 · 소켓 기반)")
		appendMenu(sub, mfSeparator, 0, "")

		var peers []core.TailscalePeer
		if snap := a.coord.CurrentSnapshot(); snap != nil {
			peers = snap.DesktopPeers()
		}
		a.menuPeers = peers
		if len(peers) == 0 {
			appendMenu(sub, mfGrayed, 0, "감지된 Tailscale Mac/Windows 피어 없음")
		} else {
			for i, p := range peers {
				dot := "○"
				if p.Online {
					dot = "●"
				}
				flags := uintptr(mfString)
				if pinned == p.ID() {
					flags |= mfChecked
				}
				label := fmt.Sprintf("%s %s [%s] (%s)", dot, p.HostName, p.OSShortLabel(), p.PreferredIP())
				appendMenu(sub, flags, uintptr(cmdPinPeerBase+i), label)
			}
		}
		appendMenu(sub, mfSeparator, 0, "")
		appendMenu(sub, mfString, cmdRefreshTS, "Tailscale 피어 새로고침")
		appendMenu(menu, mfPopup, sub, "원격 대상 기기 선택 (Mac · Windows)")
	}

	appendMenu(menu, mfSeparator, 0, "")
	pauseTitle := "일시정지"
	if a.coord.IsPaused() {
		pauseTitle = "재개하기"
	}
	appendMenu(menu, mfString, cmdTogglePause, pauseTitle)
	appendMenu(menu, mfString, cmdOpenSettings, "설정 및 페어링...")
	appendMenu(menu, mfString, cmdCopyDiag, "진단 요약 복사")
	appendMenu(menu, mfSeparator, 0, "")
	appendMenu(menu, mfString, cmdQuit, "TailIME 종료")

	var pt point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	procSetForegroundWindow.Call(a.trayHwnd)
	procTrackPopupMenu.Call(menu, tpmRightButton|tpmBottomAlign, uintptr(pt.X), uintptr(pt.Y), 0, a.trayHwnd, 0)
	procPostMessageW.Call(a.trayHwnd, 0, 0, 0)
}

func (a *appState) handleMenuCommand(id int) {
	switch {
	case id == cmdToggleLocal:
		go a.ime.Toggle()
	case id == cmdTogglePause:
		a.coord.SetPaused(!a.coord.IsPaused())
	case id == cmdOpenSettings:
		a.openSettingsWindow()
	case id == cmdCopyDiag:
		setClipboardText(coordinator.FormatDiagnosticsSummary(a.coord))
		a.showBalloon("TailIME", "진단 요약이 클립보드에 복사되었습니다.")
	case id == cmdRefreshTS:
		a.refreshTailscaleAsync(true, nil)
	case id == cmdReloadKey:
		if a.coord.ReloadIdentity() {
			a.showBalloon("TailIME", "기기 키를 정상적으로 복구했습니다.")
		} else {
			a.showBalloon("TailIME", "기기 키 복구에 실패했습니다. 설정 창에서 수동 재발급할 수 있습니다.")
		}
	case id == cmdPinAuto:
		_ = a.store.UpdateSettings(func(s *core.AppSettings) { s.PinnedPeerID = "" })
		a.coord.RefreshForegroundContext()
	case id >= cmdPinPeerBase && id < cmdPinPeerBase+len(a.menuPeers):
		peer := a.menuPeers[id-cmdPinPeerBase]
		_ = a.store.UpdateSettings(func(s *core.AppSettings) { s.PinnedPeerID = peer.ID() })
		a.coord.RefreshForegroundContext()
	case id == cmdQuit:
		procDestroyWindow.Call(a.trayHwnd)
	}
}

func createBadgeIcon(text string, bgColor uint32) uintptr {
	const size = 32
	screenDC, _, _ := procGetDC.Call(0)
	if screenDC == 0 {
		return 0
	}
	defer procReleaseDC.Call(0, screenDC)

	memDC, _, _ := procCreateCompatDC.Call(screenDC)
	if memDC == 0 {
		return 0
	}
	defer procDeleteDC.Call(memDC)

	bmi := bitmapInfoHeader{
		BiSize:        uint32(unsafe.Sizeof(bitmapInfoHeader{})),
		BiWidth:       size,
		BiHeight:      -size, // top-down DIB
		BiPlanes:      1,
		BiBitCount:    32,
		BiCompression: biRGB,
	}
	var bits unsafe.Pointer
	hbmColor, _, _ := procCreateDIBSection.Call(memDC, uintptr(unsafe.Pointer(&bmi)), dibRGBColors, uintptr(unsafe.Pointer(&bits)), 0, 0)
	if hbmColor == 0 {
		return 0
	}
	defer procDeleteObject.Call(hbmColor)

	oldBmp, _, _ := procSelectObject.Call(memDC, hbmColor)
	defer procSelectObject.Call(memDC, oldBmp)

	brush, _, _ := procCreateSolidBrush.Call(uintptr(bgColor))
	if brush != 0 {
		r := rectW{0, 0, size, size}
		procFillRect.Call(memDC, uintptr(unsafe.Pointer(&r)), brush)
		procDeleteObject.Call(brush)
	}

	var lf logFontW
	lf.LfHeight = -20
	if len([]rune(text)) > 1 {
		lf.LfHeight = -16
	}
	lf.LfWeight = fwBold
	lf.LfCharSet = defaultCharset
	lf.LfQuality = cleartypeQuality
	copyUTF16(lf.LfFaceName[:], "Malgun Gothic")
	hFont, _, _ := procCreateFontIndirectW.Call(uintptr(unsafe.Pointer(&lf)))
	if hFont != 0 {
		oldFont, _, _ := procSelectObject.Call(memDC, hFont)
		procSetBkMode.Call(memDC, transparentBk)
		procSetTextColor.Call(memDC, 0x00FFFFFF)
		u16, _ := syscall.UTF16FromString(text)
		r := rectW{0, 0, size, size}
		procDrawTextW.Call(memDC, uintptr(unsafe.Pointer(&u16[0])), uintptr(len(u16)-1), uintptr(unsafe.Pointer(&r)), dtCenter|dtVCenter|dtSingleLine)
		procSelectObject.Call(memDC, oldFont)
		procDeleteObject.Call(hFont)
	}

	// Set full alpha (0xFF) on every pixel so Windows taskbar renders crisp opaque badge
	if bits != nil {
		px := unsafe.Slice((*uint32)(bits), size*size)
		for i := range px {
			px[i] |= 0xFF000000
		}
	}

	maskBytes := make([]byte, (size/8)*size)
	hbmMask, _, _ := procCreateBitmap.Call(size, size, 1, 1, uintptr(unsafe.Pointer(&maskBytes[0])))
	if hbmMask == 0 {
		return 0
	}
	defer procDeleteObject.Call(hbmMask)

	ii := iconInfo{FIcon: 1, HbmMask: hbmMask, HbmColor: hbmColor}
	hIcon, _, _ := procCreateIconIndirect.Call(uintptr(unsafe.Pointer(&ii)))
	return hIcon
}

// MARK: - Win32 Utility Helpers

func appendMenu(menu, flags, id uintptr, text string) {
	if text == "" {
		procAppendMenuW.Call(menu, flags, id, 0)
		return
	}
	p, _ := syscall.UTF16PtrFromString(text)
	procAppendMenuW.Call(menu, flags, id, uintptr(unsafe.Pointer(p)))
}

func showMessageBox(hwnd uintptr, title, body string, flags uint32) int {
	t, _ := syscall.UTF16PtrFromString(title)
	b, _ := syscall.UTF16PtrFromString(body)
	r, _, _ := procMessageBoxW.Call(hwnd, uintptr(unsafe.Pointer(b)), uintptr(unsafe.Pointer(t)), uintptr(flags))
	return int(r)
}

func copyUTF16(dst []uint16, src string) {
	u16, _ := syscall.UTF16FromString(src)
	n := len(u16)
	if n > len(dst) {
		n = len(dst)
	}
	copy(dst[:n], u16[:n])
	if len(dst) > 0 {
		dst[len(dst)-1] = 0
	}
}

func setClipboardText(text string) {
	u16, err := syscall.UTF16FromString(text)
	if err != nil {
		return
	}
	r, _, _ := procOpenClipboard.Call(0)
	if r == 0 {
		return
	}
	defer procCloseClipboard.Call()
	procEmptyClipboard.Call()
	byteLen := uintptr(len(u16) * 2)
	hMem, _, _ := procGlobalAlloc.Call(gmemMoveable, byteLen)
	if hMem == 0 {
		return
	}
	ptr, _, _ := procGlobalLock.Call(hMem)
	if ptr == 0 {
		return
	}
	dst := unsafe.Slice((*uint16)(uintptrToPtr(ptr)), len(u16))
	copy(dst, u16)
	procGlobalUnlock.Call(hMem)
	procSetClipboardData.Call(cfUnicodeText, hMem)
}

func getClipboardText() string {
	r, _, _ := procOpenClipboard.Call(0)
	if r == 0 {
		return ""
	}
	defer procCloseClipboard.Call()
	hMem, _, _ := procGetClipboardData.Call(cfUnicodeText)
	if hMem == 0 {
		return ""
	}
	byteSize, _, _ := procGlobalSize.Call(hMem)
	maxUnits := int(byteSize / 2)
	if maxUnits <= 0 {
		return ""
	}
	if maxUnits > 4096 {
		maxUnits = 4096
	}
	ptr, _, _ := procGlobalLock.Call(hMem)
	if ptr == 0 {
		return ""
	}
	defer procGlobalUnlock.Call(hMem)
	slice := unsafe.Slice((*uint16)(uintptrToPtr(ptr)), maxUnits)
	end := 0
	for end < len(slice) && slice[end] != 0 {
		end++
	}
	return syscall.UTF16ToString(slice[:end])
}

func uintptrToPtr(p uintptr) unsafe.Pointer {
	return *(*unsafe.Pointer)(unsafe.Pointer(&p))
}

func isStartupEnabled() bool {
	const (
		hkeyCurrentUser = 0x80000001
		keyRead         = 0x20019
	)
	subKey, _ := syscall.UTF16PtrFromString(`Software\Microsoft\Windows\CurrentVersion\Run`)
	var hKey uintptr
	rc, _, _ := procRegOpenKeyExW.Call(hkeyCurrentUser, uintptr(unsafe.Pointer(subKey)), 0, keyRead, uintptr(unsafe.Pointer(&hKey)))
	if rc != 0 {
		return false
	}
	defer procRegCloseKey.Call(hKey)
	valName, _ := syscall.UTF16PtrFromString("TailIME")
	var size uint32
	rc2, _, _ := procRegQueryValueExW.Call(hKey, uintptr(unsafe.Pointer(valName)), 0, 0, 0, uintptr(unsafe.Pointer(&size)))
	return rc2 == 0 && size > 0
}

func setStartupEnabled(enable bool) error {
	const (
		hkeyCurrentUser = 0x80000001
		keySetValue     = 0x0002
		regSZ           = 1
	)
	subKey, _ := syscall.UTF16PtrFromString(`Software\Microsoft\Windows\CurrentVersion\Run`)
	var hKey uintptr
	rc, _, _ := procRegCreateKeyExW.Call(hkeyCurrentUser, uintptr(unsafe.Pointer(subKey)), 0, 0, 0, keySetValue, 0, uintptr(unsafe.Pointer(&hKey)), 0)
	if rc != 0 {
		return syscall.Errno(rc)
	}
	defer procRegCloseKey.Call(hKey)
	valName, _ := syscall.UTF16PtrFromString("TailIME")
	if !enable {
		procRegDeleteValueW.Call(hKey, uintptr(unsafe.Pointer(valName)))
		return nil
	}
	exePath, err := os.Executable()
	if err != nil {
		return err
	}
	cmdStr := fmt.Sprintf(`"%s"`, exePath)
	u16, _ := syscall.UTF16FromString(cmdStr)
	rc2, _, _ := procRegSetValueExW.Call(
		hKey,
		uintptr(unsafe.Pointer(valName)),
		0,
		regSZ,
		uintptr(unsafe.Pointer(&u16[0])),
		uintptr(len(u16)*2),
	)
	if rc2 != 0 {
		return syscall.Errno(rc2)
	}
	return nil
}

func stringsTrim(s string) string { return strings.TrimSpace(s) }

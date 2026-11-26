//go:build windows

package main

import (
	"fmt"
	"slices"
	"strings"
	"sync"
	"syscall"
	"unsafe"

	"github.com/wmyung/tailime/windows/internal/coordinator"
	"github.com/wmyung/tailime/windows/internal/core"
)

const (
	wsOverlappedWindow = 0x00CF0000
	wsCaption          = 0x00C00000
	wsSysMenu          = 0x00080000
	wsMinimizeBox      = 0x00020000
	wsChild            = 0x40000000
	wsVisible          = 0x10000000
	wsTabStop          = 0x00010000
	wsVScroll          = 0x00200000
	wsBorder           = 0x00800000
	bsAutoCheckBox     = 0x00000003
	bsPushButton       = 0x00000000
	bsGroupBox         = 0x00000007
	cbsDropDownList    = 0x0003
	esMultiLine        = 0x0004
	esReadOnly         = 0x0800
	esAutoVScroll      = 0x0040
	wmSetFont          = 0x0030
	bmGetCheck         = 0x00F0
	bmSetCheck         = 0x00F1
	bstChecked         = 1
	bstUnchecked       = 0
	cbAddString        = 0x0143
	cbResetContent     = 0x014B
	cbGetCurSel        = 0x0147
	cbSetCurSel        = 0x014E
	swShow             = 5
	swHide             = 0
	colorBtnFace       = 15
	idcArrow           = 32512

	ctrlEnabled      = 3001
	ctrlStartup      = 3002
	ctrlAutoEnglish  = 3003
	ctrlRestoreBlur  = 3004
	ctrlTrigHangul   = 3005
	ctrlTrigRAlt     = 3006
	ctrlTrigCtrlSp   = 3007
	ctrlTrigShiftSp  = 3008
	ctrlTrigF18F19   = 3009
	ctrlPeerCombo    = 3020
	ctrlDirectIPEdit = 3019
	ctrlBtnRefresh   = 3021
	ctrlBtnPairSAS   = 3022
	ctrlBtnPing      = 3023
	ctrlBtnCopyTok   = 3024
	ctrlBtnPasteTok  = 3025
	ctrlBtnClearPeer = 3026
	ctrlBtnResetKey  = 3027
	ctrlBtnCopyDiag  = 3028
	ctrlStatusLabel  = 3030
	ctrlDiagEdit     = 3031
)

type settingsDialog struct {
	app            *appState
	hwnd           uintptr
	font           uintptr
	chkEnabled     uintptr
	chkStartup     uintptr
	chkAutoEnglish uintptr
	chkRestoreBlur uintptr
	chkTrigHangul  uintptr
	chkTrigRAlt    uintptr
	chkTrigCtrlSp  uintptr
	chkTrigShiftSp uintptr
	chkTrigF18F19  uintptr
	peerCombo      uintptr
	directIPEdit   uintptr
	statusLabel    uintptr
	diagEdit       uintptr
	displayedPeers []core.TailscalePeer
	lastComboItems []string
	lastDiagText   string

	statusMu      sync.Mutex
	pendingStatus string
	hasNewStatus  bool
}

var settingsClassRegistered bool

func (a *appState) openSettingsWindow() {
	if a.settingsUI == nil {
		d := &settingsDialog{app: a}
		if err := d.create(); err != nil {
			showMessageBox(0, "TailIME", "설정 창을 열지 못했습니다: "+err.Error(), mbOK|mbIconWarning)
			return
		}
		a.settingsUI = d
	}
	a.settingsUI.refresh()
	procShowWindow.Call(a.settingsUI.hwnd, swShow)
	procSetForegroundWindow.Call(a.settingsUI.hwnd)
}

func (d *settingsDialog) create() error {
	className, _ := syscall.UTF16PtrFromString("TailIMESettingsWindowClass")
	if !settingsClassRegistered {
		hCursor, _, _ := procLoadCursorW.Call(0, idcArrow)
		wc := wndClassExW{
			CbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
			LpfnWndProc:   syscall.NewCallback(settingsWndProc),
			HInstance:     d.app.hInstance,
			HCursor:       hCursor,
			HbrBackground: colorBtnFace + 1,
			LpszClassName: className,
		}
		procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
		settingsClassRegistered = true
	}

	title, _ := syscall.UTF16PtrFromString(fmt.Sprintf("TailIME 설정 및 페어링 (Windows v%s)", core.Version))
	style := uintptr(wsCaption | wsSysMenu | wsMinimizeBox)
	hwnd, _, err := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(title)),
		style,
		200, 120, 640, 636,
		0, 0, d.app.hInstance, 0,
	)
	if hwnd == 0 {
		return err
	}
	d.hwnd = hwnd

	var lf logFontW
	lf.LfHeight = -14
	lf.LfWeight = fwNormal
	lf.LfCharSet = defaultCharset
	lf.LfQuality = cleartypeQuality
	copyUTF16(lf.LfFaceName[:], "Malgun Gothic")
	d.font, _, _ = procCreateFontIndirectW.Call(uintptr(unsafe.Pointer(&lf)))

	// Group 1: General & Triggers
	d.createCtrl("BUTTON", "기본 동작 및 한영키 트리거", wsChild|wsVisible|bsGroupBox, 14, 10, 594, 176, 0)
	d.chkEnabled = d.createCtrl("BUTTON", "TailIME 활성화", wsChild|wsVisible|wsTabStop|bsAutoCheckBox, 28, 34, 190, 22, ctrlEnabled)
	d.chkStartup = d.createCtrl("BUTTON", "Windows 시작 시 자동 실행", wsChild|wsVisible|wsTabStop|bsAutoCheckBox, 240, 34, 240, 22, ctrlStartup)
	d.chkAutoEnglish = d.createCtrl("BUTTON", "원격 창 포커스 시 로컬 IME 자동 영문 고정 (자소 분리 방지)", wsChild|wsVisible|wsTabStop|bsAutoCheckBox, 28, 60, 520, 22, ctrlAutoEnglish)
	d.chkRestoreBlur = d.createCtrl("BUTTON", "원격 창 벗어날 때 이전 로컬 입력기 복원", wsChild|wsVisible|wsTabStop|bsAutoCheckBox, 28, 86, 420, 22, ctrlRestoreBlur)

	d.chkTrigHangul = d.createCtrl("BUTTON", "한/영 키 (VK_HANGUL)", wsChild|wsVisible|wsTabStop|bsAutoCheckBox, 28, 118, 175, 22, ctrlTrigHangul)
	d.chkTrigRAlt = d.createCtrl("BUTTON", "우측 Alt 단독 탭 (101키)", wsChild|wsVisible|wsTabStop|bsAutoCheckBox, 212, 118, 190, 22, ctrlTrigRAlt)
	d.chkTrigF18F19 = d.createCtrl("BUTTON", "F18 / F19", wsChild|wsVisible|wsTabStop|bsAutoCheckBox, 415, 118, 120, 22, ctrlTrigF18F19)
	d.chkTrigCtrlSp = d.createCtrl("BUTTON", "Ctrl + Space", wsChild|wsVisible|wsTabStop|bsAutoCheckBox, 28, 146, 150, 22, ctrlTrigCtrlSp)
	d.chkTrigShiftSp = d.createCtrl("BUTTON", "Shift + Space", wsChild|wsVisible|wsTabStop|bsAutoCheckBox, 212, 146, 150, 22, ctrlTrigShiftSp)

	// Group 2: Tailscale Peer Pairing (macOS + Windows)
	d.createCtrl("BUTTON", "Tailscale 원격 기기 (macOS · Windows) 페어링 — X25519 + 6자리 SAS", wsChild|wsVisible|bsGroupBox, 14, 196, 594, 188, 0)
	d.peerCombo = d.createCtrl("COMBOBOX", "", wsChild|wsVisible|wsTabStop|wsVScroll|cbsDropDownList, 28, 224, 462, 200, ctrlPeerCombo)
	d.createCtrl("BUTTON", "새로고침", wsChild|wsVisible|wsTabStop|bsPushButton, 500, 222, 94, 26, ctrlBtnRefresh)

	d.createCtrl("STATIC", "직접 IP (선택):", wsChild|wsVisible, 28, 260, 96, 22, 0)
	d.directIPEdit = d.createCtrl("EDIT", "", wsChild|wsVisible|wsTabStop|wsBorder, 128, 257, 466, 24, ctrlDirectIPEdit)

	d.createCtrl("BUTTON", "직접 페어링(SAS)", wsChild|wsVisible|wsTabStop|bsPushButton, 28, 292, 128, 28, ctrlBtnPairSAS)
	d.createCtrl("BUTTON", "연결 테스트", wsChild|wsVisible|wsTabStop|bsPushButton, 162, 292, 96, 28, ctrlBtnPing)
	d.createCtrl("BUTTON", "내 토큰 복사", wsChild|wsVisible|wsTabStop|bsPushButton, 264, 292, 102, 28, ctrlBtnCopyTok)
	d.createCtrl("BUTTON", "클립보드 토큰 등록", wsChild|wsVisible|wsTabStop|bsPushButton, 372, 292, 134, 28, ctrlBtnPasteTok)
	d.createCtrl("BUTTON", "기기 초기화", wsChild|wsVisible|wsTabStop|bsPushButton, 512, 292, 82, 28, ctrlBtnClearPeer)

	d.statusLabel = d.createCtrl("STATIC", "피어를 선택하거나 직접 IP(100.x.y.z)를 입력해 페어링·연결 테스트를 실행하세요.", wsChild|wsVisible, 28, 330, 566, 44, ctrlStatusLabel)

	// Group 3: Diagnostics & Trusted Peers
	d.createCtrl("BUTTON", "실시간 상태 · 신뢰 기기 · 진단", wsChild|wsVisible|bsGroupBox, 14, 392, 594, 192, 0)
	d.diagEdit = d.createCtrl("EDIT", "", wsChild|wsVisible|wsBorder|wsVScroll|esMultiLine|esReadOnly|esAutoVScroll, 28, 418, 566, 120, ctrlDiagEdit)
	d.createCtrl("BUTTON", "진단 요약 복사", wsChild|wsVisible|wsTabStop|bsPushButton, 28, 546, 120, 28, ctrlBtnCopyDiag)
	d.createCtrl("BUTTON", "기기 키 재읽기 / 재발급", wsChild|wsVisible|wsTabStop|bsPushButton, 158, 546, 165, 28, ctrlBtnResetKey)

	return nil
}

func (d *settingsDialog) createCtrl(class, text string, style uintptr, x, y, w, h int, id int) uintptr {
	cls, _ := syscall.UTF16PtrFromString(class)
	txt, _ := syscall.UTF16PtrFromString(text)
	hwnd, _, _ := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(cls)),
		uintptr(unsafe.Pointer(txt)),
		style,
		uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		d.hwnd,
		uintptr(id),
		d.app.hInstance,
		0,
	)
	if hwnd != 0 && d.font != 0 {
		procSendMessageW.Call(hwnd, wmSetFont, d.font, 1)
	}
	return hwnd
}

func settingsWndProc(hwnd uintptr, msg uint32, wParam, lParam uintptr) uintptr {
	app := globalApp
	if app == nil || app.settingsUI == nil || app.settingsUI.hwnd != hwnd {
		r, _, _ := procDefWindowProcW.Call(hwnd, uintptr(msg), wParam, lParam)
		return r
	}
	d := app.settingsUI
	switch msg {
	case wmClose:
		procShowWindow.Call(hwnd, swHide)
		return 0
	case wmCommand:
		id := int(wParam & 0xFFFF)
		d.handleCommand(id)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(hwnd, uintptr(msg), wParam, lParam)
	return r
}

func (d *settingsDialog) refresh() {
	if d.hwnd == 0 {
		return
	}
	s := d.app.store.Settings()
	setChecked(d.chkEnabled, s.Enabled)
	setChecked(d.chkStartup, isStartupEnabled())
	setChecked(d.chkAutoEnglish, s.AutoEnglishOnRemoteFocus)
	setChecked(d.chkRestoreBlur, s.RestoreLocalOnRemoteBlur)
	setChecked(d.chkTrigHangul, s.TriggerHangulKey)
	setChecked(d.chkTrigRAlt, s.TriggerRightAltTap)
	setChecked(d.chkTrigCtrlSp, s.TriggerCtrlSpace)
	setChecked(d.chkTrigShiftSp, s.TriggerShiftSpace)
	setChecked(d.chkTrigF18F19, s.TriggerF18F19)

	d.statusMu.Lock()
	if d.hasNewStatus {
		msg := d.pendingStatus
		d.hasNewStatus = false
		d.statusMu.Unlock()
		setText(d.statusLabel, msg)
	} else {
		d.statusMu.Unlock()
	}

	var peers []core.TailscalePeer
	if snap := d.app.coord.CurrentSnapshot(); snap != nil {
		peers = snap.DesktopPeers()
	}
	states := d.app.coord.PeerStates()

	var comboItems []string
	if len(peers) == 0 {
		comboItems = []string{"감지된 Tailscale Mac/Windows 피어 없음"}
	} else {
		comboItems = make([]string, 0, len(peers))
		for _, p := range peers {
			ip := p.PreferredIP()
			extra := " [오프라인]"
			if st, ok := states[ip]; ok && st.DaemonReachable {
				extra = fmt.Sprintf(" [TailIME 연결됨 · %s · %.1fms]", st.CurrentLanguage.ShortBadge(), st.LastRTTMs)
			} else if p.Online {
				extra = " [온라인]"
			}
			comboItems = append(comboItems, fmt.Sprintf("%s [%s] (%s)%s", p.HostName, p.OSShortLabel(), ip, extra))
		}
	}

	// Only rebuild combo box when items actually changed (prevents 500ms ticker from closing open dropdown!)
	if !slices.Equal(comboItems, d.lastComboItems) {
		prevComboIP := d.selectedComboPeerIP()
		procSendMessageW.Call(d.peerCombo, cbResetContent, 0, 0)
		d.displayedPeers = peers
		d.lastComboItems = comboItems
		selIdx := 0
		for i, label := range comboItems {
			addComboString(d.peerCombo, label)
			if i < len(peers) && prevComboIP != "" && peers[i].PreferredIP() == prevComboIP {
				selIdx = i
			}
		}
		procSendMessageW.Call(d.peerCombo, cbSetCurSel, uintptr(selIdx), 0)
	} else {
		d.displayedPeers = peers
	}

	// Diagnostics + Trusted Peers (only update edit box if text changed to preserve scroll/selection!)
	var sb strings.Builder
	sb.WriteString(coordinator.FormatDiagnosticsSummary(d.app.coord))
	sb.WriteString("\r\n\r\n신뢰된 원격 기기:")
	trusted := d.app.store.TrustedPeers()
	if len(trusted) == 0 {
		sb.WriteString("\r\n  (없음 — 위에서 페어링하거나 토큰을 교환하세요)")
	} else {
		for _, rec := range trusted {
			st := states[rec.LastKnownIP]
			mark := "○ 대기"
			if st.DaemonReachable {
				mark = "● 연결됨"
			}
			sb.WriteString(fmt.Sprintf("\r\n  • %s (%s)  %s", rec.Name, rec.LastKnownIP, mark))
		}
	}
	diagText := sb.String()
	if diagText != d.lastDiagText {
		d.lastDiagText = diagText
		setText(d.diagEdit, diagText)
	}
}

func (d *settingsDialog) handleCommand(id int) {
	switch id {
	case ctrlEnabled, ctrlAutoEnglish, ctrlRestoreBlur, ctrlTrigHangul, ctrlTrigRAlt, ctrlTrigCtrlSp, ctrlTrigShiftSp, ctrlTrigF18F19:
		_ = d.app.store.UpdateSettings(func(s *core.AppSettings) {
			s.Enabled = isChecked(d.chkEnabled)
			s.AutoEnglishOnRemoteFocus = isChecked(d.chkAutoEnglish)
			s.RestoreLocalOnRemoteBlur = isChecked(d.chkRestoreBlur)
			s.TriggerHangulKey = isChecked(d.chkTrigHangul)
			s.TriggerRightAltTap = isChecked(d.chkTrigRAlt)
			s.TriggerCtrlSpace = isChecked(d.chkTrigCtrlSp)
			s.TriggerShiftSpace = isChecked(d.chkTrigShiftSp)
			s.TriggerF18F19 = isChecked(d.chkTrigF18F19)
		})
	case ctrlStartup:
		if err := setStartupEnabled(isChecked(d.chkStartup)); err != nil {
			d.setStatus("자동 실행 설정 실패: " + err.Error())
		}
	case ctrlBtnRefresh:
		d.setStatus("Tailscale 피어 목록 새로고침 중...")
		d.app.refreshTailscaleAsync(true, func(summary string) {
			d.postStatus(summary)
		})
	case ctrlBtnPairSAS:
		ip := d.selectedPeerIP()
		if ip == "" {
			d.setStatus("먼저 피어를 선택하거나 직접 IP(100.x.y.z)를 입력해 주세요.")
			return
		}
		if err := d.app.coord.InitiatePairing(ip, false); err != nil {
			d.setStatus("✗ " + err.Error())
		} else {
			d.setStatus(fmt.Sprintf("%s로 페어링 요청을 보냈습니다. 양쪽 화면에서 6자리 SAS 코드를 승인하세요.", ip))
		}
	case ctrlBtnPing:
		ip := d.selectedPeerIP()
		if ip == "" {
			d.setStatus("먼저 피어를 선택하거나 직접 IP(100.x.y.z)를 입력해 주세요.")
			return
		}
		d.setStatus(ip + "에 Ping 전송 중...")
		go func(target string) {
			res, err := d.app.coord.PingPeer(target)
			if err != nil {
				d.postStatus("✗ " + err.Error())
			} else {
				d.postStatus(fmt.Sprintf("✓ %s 연결 성공 (RTT %.1fms · 현재 입력기: %s)", res.Host, res.RTTMs, res.Lang.DisplayName()))
			}
		}(ip)
	case ctrlBtnCopyTok:
		tok, err := d.app.coord.ExportPairingToken()
		if err != nil {
			d.setStatus("✗ " + err.Error())
			return
		}
		setClipboardText(tok)
		d.setStatus("✓ 내 페어링 토큰(TKP1)이 클립보드에 복사되었습니다. Mac/Windows 상대 기기에 붙여넣으세요.")
	case ctrlBtnPasteTok:
		clip := stringsTrim(getClipboardText())
		if !strings.HasPrefix(clip, "TKP1:") {
			d.setStatus("✗ 클립보드에 올바른 TKP1:... 페어링 토큰이 없습니다. 상대 기기에서 먼저 '내 토큰 복사'를 눌러 주세요.")
			return
		}
		rec, err := d.app.coord.ImportPairingToken(clip)
		if err != nil {
			d.setStatus("✗ " + err.Error())
			return
		}
		d.setStatus(fmt.Sprintf("✓ '%s' 등록 완료! 이제 양쪽 기기가 암호화 연결됩니다.", rec.Name))
		d.refresh()
	case ctrlBtnClearPeer:
		if showMessageBox(d.hwnd, "신뢰 기기 초기화", "신뢰된 원격 기기 목록 전체를 초기화할까요?\n다시 연결하려면 페어링을 새로 진행해야 합니다.", mbYesNo|mbIconWarning) == idYes {
			_ = d.app.store.ClearTrustedPeers()
			d.setStatus("신뢰 기기 목록이 초기화되었습니다.")
			d.refresh()
		}
	case ctrlBtnCopyDiag:
		setClipboardText(coordinator.FormatDiagnosticsSummary(d.app.coord))
		d.setStatus("✓ 진단 요약이 클립보드에 복사되었습니다.")
	case ctrlBtnResetKey:
		if d.app.coord.ReloadIdentity() {
			d.setStatus("✓ 기존 DPAPI 기기 키를 정상적으로 읽었습니다.")
			d.refresh()
			return
		}
		if showMessageBox(d.hwnd, "기기 키 재발급", "기존 DPAPI 기기 키를 복호화할 수 없습니다.\n새 기기 키를 발급할까요? (기존 페어링은 다시 등록해야 합니다.)", mbYesNo|mbIconWarning) == idYes {
			if err := d.app.coord.ResetIdentityExplicit(); err != nil {
				d.setStatus("✗ 키 재발급 실패: " + err.Error())
			} else {
				d.setStatus("✓ 새 DPAPI 기기 키가 발급되었습니다. 상대 기기와 다시 페어링해 주세요.")
				d.refresh()
			}
		}
	}
}

func (d *settingsDialog) selectedComboPeerIP() string {
	idx, _, _ := procSendMessageW.Call(d.peerCombo, cbGetCurSel, 0, 0)
	i := int(int32(idx))
	if i < 0 || i >= len(d.displayedPeers) {
		return ""
	}
	return d.displayedPeers[i].PreferredIP()
}

func (d *settingsDialog) selectedPeerIP() string {
	if manual := stringsTrim(getWindowText(d.directIPEdit)); manual != "" {
		return manual
	}
	return d.selectedComboPeerIP()
}

func getWindowText(hwnd uintptr) string {
	if hwnd == 0 {
		return ""
	}
	n, _, _ := procGetWindowTextLenW.Call(hwnd)
	if n == 0 || n > 512 {
		return ""
	}
	buf := make([]uint16, n+1)
	procGetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(&buf[0])), n+1)
	return syscall.UTF16ToString(buf)
}

func (d *settingsDialog) setStatus(s string) {
	setText(d.statusLabel, s)
}

func (d *settingsDialog) postStatus(s string) {
	d.statusMu.Lock()
	d.pendingStatus = s
	d.hasNewStatus = true
	d.statusMu.Unlock()
	if d.app != nil && d.app.trayHwnd != 0 {
		procPostMessageW.Call(d.app.trayHwnd, wmAppRefreshUI, 0, 0)
	}
}

func setChecked(hwnd uintptr, checked bool) {
	v := uintptr(bstUnchecked)
	if checked {
		v = bstChecked
	}
	procSendMessageW.Call(hwnd, bmSetCheck, v, 0)
}

func isChecked(hwnd uintptr) bool {
	r, _, _ := procSendMessageW.Call(hwnd, bmGetCheck, 0, 0)
	return r == bstChecked
}

func addComboString(hwnd uintptr, s string) {
	p, _ := syscall.UTF16PtrFromString(s)
	procSendMessageW.Call(hwnd, cbAddString, 0, uintptr(unsafe.Pointer(p)))
}

func setText(hwnd uintptr, s string) {
	p, _ := syscall.UTF16PtrFromString(s)
	procSetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(p)))
}

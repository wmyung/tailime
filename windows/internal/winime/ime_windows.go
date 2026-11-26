//go:build windows

package winime

import (
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/wmyung/tailime/windows/internal/core"
)

const (
	wmIMEControl            = 0x0283
	wmInputLangChangeReq    = 0x0050
	imcGetConversionMode    = 0x0001
	imcSetConversionMode    = 0x0002
	imcGetOpenStatus        = 0x0005
	imcSetOpenStatus        = 0x0006
	imeCModeNative          = 0x0001 // Hangul mode on Korean IME (0x0412)
	langKoreanID            = 0x0412
	primaryLangKorean       = 0x0012
	smtoAbortIfHung         = 0x0002
	vkHangul                = 0x15
	inputKeyboard           = 1
	keyeventfKeyUp          = 0x0002
	processQueryLimitedInfo = 0x1000
	tokenQuery              = 0x0008
	tokenElevationClass     = 20
)

var (
	modUser32IME                 = syscall.NewLazyDLL("user32.dll")
	procGetForegroundWindow      = modUser32IME.NewProc("GetForegroundWindow")
	procGetWindowThreadProcessId = modUser32IME.NewProc("GetWindowThreadProcessId")
	procGetGUIThreadInfo         = modUser32IME.NewProc("GetGUIThreadInfo")
	procGetKeyboardLayout        = modUser32IME.NewProc("GetKeyboardLayout")
	procGetKeyboardLayoutList    = modUser32IME.NewProc("GetKeyboardLayoutList")
	procSendMessageTimeoutW      = modUser32IME.NewProc("SendMessageTimeoutW")
	procPostMessageW             = modUser32IME.NewProc("PostMessageW")
	procSendInput                = modUser32IME.NewProc("SendInput")

	modImm32               = syscall.NewLazyDLL("imm32.dll")
	procImmGetDefaultIMEWnd = modImm32.NewProc("ImmGetDefaultIMEWnd")

	modKernel32IME       = syscall.NewLazyDLL("kernel32.dll")
	procOpenProcess      = modKernel32IME.NewProc("OpenProcess")
	procCloseHandle      = modKernel32IME.NewProc("CloseHandle")
	procGetCurrentProc   = modKernel32IME.NewProc("GetCurrentProcess")
	modAdvapi32IME       = syscall.NewLazyDLL("advapi32.dll")
	procOpenProcessToken = modAdvapi32IME.NewProc("OpenProcessToken")
	procGetTokenInfo     = modAdvapi32IME.NewProc("GetTokenInformation")
)

type rect struct {
	Left, Top, Right, Bottom int32
}

type guiThreadInfo struct {
	cbSize        uint32
	flags         uint32
	hwndActive    uintptr
	hwndFocus     uintptr
	hwndCapture   uintptr
	hwndMenuOwner uintptr
	hwndMoveSize  uintptr
	hwndCaret     uintptr
	rcCaret       rect
}

// keyboardInput matches Win32 INPUT struct on 64-bit Windows (40 bytes total).
type keyboardInput struct {
	Type uint32
	_    uint32
	Ki   keybdInput
	_    [8]byte // union padding to match MOUSEINPUT size on amd64/arm64
}

type keybdInput struct {
	WVk         uint16
	WScan       uint16
	DwFlags     uint32
	Time        uint32
	_           uint32
	DwExtraInfo uintptr
}

type Status struct {
	Language         core.InputLanguage
	SourceID         string
	HKL              uintptr
	Reliable         bool
	SecureDesktop    bool
	ElevationBlocked bool
}

type Engine struct {
	syntheticMarker uintptr
	selfElevated    bool
	lastElevBlocked atomic.Bool
	switchMu        sync.Mutex
	switchGen       atomic.Uint64
}

func NewEngine(syntheticMarker uintptr) *Engine {
	return &Engine{
		syntheticMarker: syntheticMarker,
		selfElevated:    isCurrentProcessElevated(),
	}
}

func (e *Engine) LastElevationBlocked() bool {
	return e.lastElevBlocked.Load()
}

func (e *Engine) SelfElevated() bool {
	return e.selfElevated
}

// Preempt invalidates any in-flight SwitchTo polling loop so a newer request wins immediately.
func (e *Engine) Preempt() {
	e.switchGen.Add(1)
}

func (e *Engine) CurrentStatus() Status {
	fg := getForegroundWindow()
	if fg == 0 {
		return Status{Language: core.LangEnglish, SourceID: "secure-desktop", SecureDesktop: true}
	}
	focusWnd, tid, pid := resolveFocusWindow(fg)
	hkl := getKeyboardLayout(tid)
	langID := uint16(hkl & 0xFFFF)

	if !isKoreanHKL(langID) {
		return Status{
			Language: core.LangEnglish,
			SourceID: hklName(langID),
			HKL:      hkl,
			Reliable: true,
		}
	}

	imeWnd := getDefaultIMEWnd(focusWnd, fg)
	if imeWnd == 0 {
		return Status{
			Language: core.LangEnglish,
			SourceID: "ko-KR:no-ime-wnd",
			HKL:      hkl,
			Reliable: false,
		}
	}

	convMode, ok := sendIMEControl(imeWnd, imcGetConversionMode, 0)
	if !ok {
		blocked := !e.selfElevated && isProcessElevated(pid)
		e.lastElevBlocked.Store(blocked)
		return Status{
			Language:         core.LangEnglish,
			SourceID:         "ko-KR:unreadable",
			HKL:              hkl,
			Reliable:         false,
			ElevationBlocked: blocked,
		}
	}
	e.lastElevBlocked.Store(false)
	if (convMode & imeCModeNative) != 0 {
		return Status{
			Language: core.LangKorean,
			SourceID: "ko-KR:hangul",
			HKL:      hkl,
			Reliable: true,
		}
	}
	return Status{
		Language: core.LangEnglish,
		SourceID: "ko-KR:alnum",
		HKL:      hkl,
		Reliable: true,
	}
}

// SwitchTo deterministically sets Windows Korean IME to targetLang ("ko" or "en").
// Serialized with switchMu + latest-generation preemption (switchGen) so rapid consecutive
// switches can never overlap or fire a stale synthetic VK_HANGUL fallback backwards.
// Follows IMM32/TSF safety rules:
// 1. Keep Korean IME open (IMC_SETOPENSTATUS=1) and mutate IME_CMODE_NATIVE (0x0001) on 0x0412.
// 2. Poll verification over 60ms before falling back to a SINGLE synthetic VK_HANGUL injection (only if readable, opposite, and still latest gen).
// 3. Detect UIPI elevation mismatch and bail cleanly instead of looping or double-toggling.
func (e *Engine) SwitchTo(target core.InputLanguage) Status {
	if target != core.LangKorean && target != core.LangEnglish {
		return e.CurrentStatus()
	}
	gen := e.switchGen.Add(1)
	e.switchMu.Lock()
	defer e.switchMu.Unlock()

	if e.switchGen.Load() != gen {
		return e.CurrentStatus()
	}

	fg := getForegroundWindow()
	if fg == 0 {
		return Status{Language: core.LangEnglish, SourceID: "secure-desktop", SecureDesktop: true}
	}
	focusWnd, tid, pid := resolveFocusWindow(fg)
	if !e.selfElevated && isProcessElevated(pid) {
		e.lastElevBlocked.Store(true)
		return Status{Language: core.LangEnglish, SourceID: "uipi-elevated", ElevationBlocked: true}
	}
	e.lastElevBlocked.Store(false)

	hkl := getKeyboardLayout(tid)
	langID := uint16(hkl & 0xFFFF)

	// If switching to Korean while an English/other layout is active, request the installed Korean HKL first.
	if target == core.LangKorean && !isKoreanHKL(langID) {
		if koHKL := findInstalledKoreanHKL(); koHKL != 0 {
			procPostMessageW.Call(focusWnd, wmInputLangChangeReq, 0, koHKL)
			time.Sleep(40 * time.Millisecond)
			if e.switchGen.Load() != gen {
				return e.CurrentStatus()
			}
			hkl = getKeyboardLayout(tid)
			langID = uint16(hkl & 0xFFFF)
		}
	}

	if !isKoreanHKL(langID) {
		// Still not on Korean layout (e.g. English-only keyboard layout active, switching to EN is already satisfied).
		return e.CurrentStatus()
	}

	imeWnd := getDefaultIMEWnd(focusWnd, fg)
	if imeWnd == 0 {
		return e.CurrentStatus()
	}

	curConv, ok := sendIMEControl(imeWnd, imcGetConversionMode, 0)
	if ok {
		curIsKo := (curConv & imeCModeNative) != 0
		if (target == core.LangKorean && curIsKo) || (target == core.LangEnglish && !curIsKo) {
			return e.CurrentStatus()
		}
	}

	// Ensure Korean IME stays open (closing IME is distinct from English mode on Korean MS IME).
	_, _ = sendIMEControl(imeWnd, imcSetOpenStatus, 1)

	var desired uintptr
	if ok {
		if target == core.LangKorean {
			desired = curConv | imeCModeNative
		} else {
			desired = curConv &^ imeCModeNative
		}
	} else if target == core.LangKorean {
		desired = imeCModeNative
	}
	_, _ = sendIMEControl(imeWnd, imcSetConversionMode, desired)

	// Poll up to 60ms (3 x 20ms) for cross-process TSF/IMM round-trip to settle; abort early if superseded.
	for i := 0; i < 3; i++ {
		if e.switchGen.Load() != gen {
			return e.CurrentStatus()
		}
		time.Sleep(20 * time.Millisecond)
		if e.switchGen.Load() != gen {
			return e.CurrentStatus()
		}
		st := e.CurrentStatus()
		if st.Reliable && st.Language == target {
			return st
		}
	}

	// Fallback for modern Windows 11 TSF/UWP apps that ignore WM_IME_CONTROL:
	// ONLY inject a SINGLE synthetic VK_HANGUL toggle if we are STILL the latest generation and reliably verified opposite!
	if e.switchGen.Load() != gen {
		return e.CurrentStatus()
	}
	st := e.CurrentStatus()
	// Re-check generation AFTER CurrentStatus() (which may block up to 50ms in SendMessageTimeoutW)
	// so a preempted switch NEVER fires a stale synthetic VK_HANGUL toggle!
	if e.switchGen.Load() != gen {
		return st
	}
	if st.Reliable && st.Language != target && isKoreanHKL(uint16(st.HKL&0xFFFF)) {
		e.injectSyntheticHangulKey()
		time.Sleep(45 * time.Millisecond)
		return e.CurrentStatus()
	}
	return st
}

func (e *Engine) Toggle() Status {
	cur := e.CurrentStatus()
	return e.SwitchTo(cur.Language.Toggled())
}

func (e *Engine) injectSyntheticHangulKey() {
	inputs := [2]keyboardInput{
		{
			Type: inputKeyboard,
			Ki: keybdInput{
				WVk:         vkHangul,
				DwExtraInfo: e.syntheticMarker,
			},
		},
		{
			Type: inputKeyboard,
			Ki: keybdInput{
				WVk:         vkHangul,
				DwFlags:     keyeventfKeyUp,
				DwExtraInfo: e.syntheticMarker,
			},
		},
	}
	procSendInput.Call(
		uintptr(len(inputs)),
		uintptr(unsafe.Pointer(&inputs[0])),
		unsafe.Sizeof(inputs[0]),
	)
}

func getForegroundWindow() uintptr {
	hwnd, _, _ := procGetForegroundWindow.Call()
	return hwnd
}

func resolveFocusWindow(fg uintptr) (focusWnd uintptr, tid uint32, pid uint32) {
	r1, _, _ := procGetWindowThreadProcessId.Call(fg, uintptr(unsafe.Pointer(&pid)))
	tid = uint32(r1)
	focusWnd = fg
	var gti guiThreadInfo
	gti.cbSize = uint32(unsafe.Sizeof(gti))
	ok, _, _ := procGetGUIThreadInfo.Call(uintptr(tid), uintptr(unsafe.Pointer(&gti)))
	if ok != 0 && gti.hwndFocus != 0 {
		focusWnd = gti.hwndFocus
	}
	return focusWnd, tid, pid
}

func getKeyboardLayout(tid uint32) uintptr {
	hkl, _, _ := procGetKeyboardLayout.Call(uintptr(tid))
	return hkl
}

func getDefaultIMEWnd(focusWnd, fg uintptr) uintptr {
	w, _, _ := procImmGetDefaultIMEWnd.Call(focusWnd)
	if w == 0 && fg != focusWnd {
		w, _, _ = procImmGetDefaultIMEWnd.Call(fg)
	}
	return w
}

func sendIMEControl(imeWnd, cmd, param uintptr) (uintptr, bool) {
	var result uintptr
	r1, _, _ := procSendMessageTimeoutW.Call(
		imeWnd,
		wmIMEControl,
		cmd,
		param,
		smtoAbortIfHung,
		50, // 50ms timeout so a hung app never stalls TailIME
		uintptr(unsafe.Pointer(&result)),
	)
	return result, r1 != 0
}

func isKoreanHKL(langID uint16) bool {
	return langID == langKoreanID || (langID&0x03FF) == primaryLangKorean
}

func findInstalledKoreanHKL() uintptr {
	n, _, _ := procGetKeyboardLayoutList.Call(0, 0)
	if n == 0 || n > 64 {
		return 0
	}
	list := make([]uintptr, n)
	got, _, _ := procGetKeyboardLayoutList.Call(n, uintptr(unsafe.Pointer(&list[0])))
	for i := uintptr(0); i < got; i++ {
		if isKoreanHKL(uint16(list[i] & 0xFFFF)) {
			return list[i]
		}
	}
	return 0
}

func hklName(langID uint16) string {
	switch langID {
	case 0x0409:
		return "en-US"
	case 0x0412:
		return "ko-KR"
	default:
		return "layout-other"
	}
}

func isCurrentProcessElevated() bool {
	hProc, _, _ := procGetCurrentProc.Call()
	return queryTokenElevated(hProc, false)
}

func isProcessElevated(pid uint32) bool {
	if pid == 0 {
		return false
	}
	hProc, _, _ := procOpenProcess.Call(processQueryLimitedInfo, 0, uintptr(pid))
	if hProc == 0 {
		// ACCESS_DENIED from non-elevated process generally indicates an elevated or protected process.
		return true
	}
	defer procCloseHandle.Call(hProc)
	return queryTokenElevated(hProc, true)
}

func queryTokenElevated(hProc uintptr, assumeElevatedOnAccessError bool) bool {
	var tok uintptr
	r1, _, _ := procOpenProcessToken.Call(hProc, tokenQuery, uintptr(unsafe.Pointer(&tok)))
	if r1 == 0 {
		return assumeElevatedOnAccessError
	}
	defer procCloseHandle.Call(tok)
	var elevated uint32
	var retLen uint32
	r2, _, _ := procGetTokenInfo.Call(
		tok,
		tokenElevationClass,
		uintptr(unsafe.Pointer(&elevated)),
		unsafe.Sizeof(elevated),
		uintptr(unsafe.Pointer(&retLen)),
	)
	if r2 == 0 {
		return assumeElevatedOnAccessError
	}
	return elevated != 0
}

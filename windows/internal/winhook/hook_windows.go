//go:build windows

package winhook

import (
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	whKeyboardLL           = 13
	wmKeyDown              = 0x0100
	wmKeyUp                = 0x0101
	wmSysKeyDown           = 0x0104
	wmSysKeyUp             = 0x0105
	wmQuit                 = 0x0012
	wmAppReinstallHook     = 0x8001
	llkhfInjected          = 0x00000010
	vkHangul               = 0x15
	vkSpace                = 0x20
	vkLShift               = 0xA0
	vkRShift               = 0xA1
	vkLControl             = 0xA2
	vkRControl             = 0xA3
	vkLMenu                = 0xA4
	vkRMenu                = 0xA5
	vkLWin                 = 0x5B
	vkRWin                 = 0x5C
	vkF18                  = 0x81
	vkF19                  = 0x82
	vkMenuSuppressDummy    = 0xE8 // Unassigned VK used by AutoHotkey to cancel Alt menu bar activation
	eventSystemForeground  = 0x0003
	wineventOutOfContext   = 0x0000
	inputKeyboard          = 1
	keyeventfKeyUp         = 0x0002
)

var (
	modUser32Hook         = syscall.NewLazyDLL("user32.dll")
	procSetWindowsHookExW = modUser32Hook.NewProc("SetWindowsHookExW")
	procUnhookWindowsHook = modUser32Hook.NewProc("UnhookWindowsHookEx")
	procCallNextHookEx    = modUser32Hook.NewProc("CallNextHookEx")
	procGetMessageW       = modUser32Hook.NewProc("GetMessageW")
	procPostThreadMsgW    = modUser32Hook.NewProc("PostThreadMessageW")
	procGetAsyncKeyState  = modUser32Hook.NewProc("GetAsyncKeyState")
	procSetWinEventHook   = modUser32Hook.NewProc("SetWinEventHook")
	procUnhookWinEvent    = modUser32Hook.NewProc("UnhookWinEvent")
	procSendInputHook     = modUser32Hook.NewProc("SendInput")
	modKernel32Hook       = syscall.NewLazyDLL("kernel32.dll")
	procGetCurrentTidHook = modKernel32Hook.NewProc("GetCurrentThreadId")
)

type kbdLLHookStruct struct {
	VkCode      uint32
	ScanCode    uint32
	Flags       uint32
	Time        uint32
	DwExtraInfo uintptr
}

type winMsg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	PtX     int32
	PtY     int32
}

type keyboardInput struct {
	Type uint32
	_    uint32
	Ki   keybdInput
	_    [8]byte
}

type keybdInput struct {
	WVk         uint16
	WScan       uint16
	DwFlags     uint32
	Time        uint32
	_           uint32
	DwExtraInfo uintptr
}

type Snapshot struct {
	Enabled            bool
	Paused             bool
	RemoteSessionReady bool
	TriggerHangulKey   bool
	TriggerRightAltTap bool
	TriggerCtrlSpace   bool
	TriggerShiftSpace  bool
	TriggerF18F19      bool
}

type TriggerEvent struct {
	VKCode uint32
	Label  string
}

// Controller manages the low-level WH_KEYBOARD_LL hook on a dedicated locked OS thread.
// Inside the hook callback ZERO blocking I/O occurs: it reads an atomic Snapshot, tracks
// swallowed key pairs (never leaving stuck keys), and sends matches to a buffered channel.
type Controller struct {
	syntheticMarker uintptr
	snap            atomic.Pointer[Snapshot]
	triggerCh       chan TriggerEvent
	fgChangedCh     chan struct{}
	active          atomic.Bool

	mu              sync.Mutex
	running         bool
	threadID        uint32
	stopCh          chan struct{}
	swallowedDown   map[uint32]bool
	rAltDownAt      time.Time
	rAltChorded     bool

	OnRemoteTrigger     func(TriggerEvent)
	OnForegroundChanged func()
}

var (
	globalHookMu   sync.Mutex
	activeInstance *Controller
)

func NewController(syntheticMarker uintptr) *Controller {
	c := &Controller{
		syntheticMarker: syntheticMarker,
		triggerCh:       make(chan TriggerEvent, 32),
		fgChangedCh:     make(chan struct{}, 16),
		swallowedDown:   make(map[uint32]bool),
	}
	s := Snapshot{
		Enabled:          true,
		TriggerHangulKey: true,
		TriggerF18F19:    true,
	}
	c.snap.Store(&s)
	return c
}

func (c *Controller) UpdateSnapshot(s Snapshot) {
	cp := s
	c.snap.Store(&cp)
}

func (c *Controller) IsActive() bool {
	return c.active.Load()
}

func (c *Controller) RequestHookReinstall() {
	c.mu.Lock()
	tid := c.threadID
	c.mu.Unlock()
	if tid != 0 {
		procPostThreadMsgW.Call(uintptr(tid), wmAppReinstallHook, 0, 0)
	}
}

func (c *Controller) Start() {
	c.mu.Lock()
	if c.running {
		c.mu.Unlock()
		return
	}
	c.running = true
	c.stopCh = make(chan struct{})
	stopCh := c.stopCh
	c.mu.Unlock()

	globalHookMu.Lock()
	activeInstance = c
	globalHookMu.Unlock()

	// Dispatch worker goroutines off the hook thread
	go func() {
		for {
			select {
			case <-stopCh:
				return
			case ev := <-c.triggerCh:
				if c.OnRemoteTrigger != nil {
					c.OnRemoteTrigger(ev)
				}
			}
		}
	}()
	go func() {
		for {
			select {
			case <-stopCh:
				return
			case <-c.fgChangedCh:
				if c.OnForegroundChanged != nil {
					c.OnForegroundChanged()
				}
			}
		}
	}()

	// Dedicated Win32 OS thread for WH_KEYBOARD_LL + EVENT_SYSTEM_FOREGROUND
	go c.hookThreadLoop(stopCh)
}

func (c *Controller) Stop() {
	c.mu.Lock()
	if !c.running {
		c.mu.Unlock()
		return
	}
	c.running = false
	tid := c.threadID
	close(c.stopCh)
	c.mu.Unlock()

	if tid != 0 {
		procPostThreadMsgW.Call(uintptr(tid), wmQuit, 0, 0)
	}
	c.active.Store(false)
}

func (c *Controller) hookThreadLoop(stopCh chan struct{}) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	tid, _, _ := procGetCurrentTidHook.Call()
	c.mu.Lock()
	c.threadID = uint32(tid)
	c.mu.Unlock()

	kbCallback := syscall.NewCallback(lowLevelKeyboardProc)
	fgCallback := syscall.NewCallback(winEventForegroundProc)

	installKB := func() uintptr {
		h, _, _ := procSetWindowsHookExW.Call(whKeyboardLL, kbCallback, 0, 0)
		c.active.Store(h != 0)
		return h
	}

	hKB := installKB()
	hFG, _, _ := procSetWinEventHook.Call(
		eventSystemForeground,
		eventSystemForeground,
		0,
		fgCallback,
		0,
		0,
		wineventOutOfContext,
	)

	// Watchdog: periodically reinstall hook so mstsc/rustdesk hooks never permanently shadow ours
	go func() {
		t := time.NewTicker(15 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-stopCh:
				return
			case <-t.C:
				c.RequestHookReinstall()
			}
		}
	}()

	var msg winMsg
	for {
		r1, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(r1) <= 0 {
			break
		}
		if msg.Message == wmAppReinstallHook {
			if hKB != 0 {
				procUnhookWindowsHook.Call(hKB)
			}
			hKB = installKB()
		}
	}

	if hKB != 0 {
		procUnhookWindowsHook.Call(hKB)
	}
	if hFG != 0 {
		procUnhookWinEvent.Call(hFG)
	}
	c.active.Store(false)
}

func winEventForegroundProc(hHook, event, hwnd, idObj, idChild, evThread, evTime uintptr) uintptr {
	globalHookMu.Lock()
	inst := activeInstance
	globalHookMu.Unlock()
	if inst != nil {
		select {
		case inst.fgChangedCh <- struct{}{}:
		default:
		}
	}
	return 0
}

func lowLevelKeyboardProc(nCode int32, wParam uintptr, lParam uintptr) uintptr {
	if nCode < 0 || lParam == 0 {
		r, _, _ := procCallNextHookEx.Call(0, uintptr(nCode), wParam, lParam)
		return r
	}
	globalHookMu.Lock()
	inst := activeInstance
	globalHookMu.Unlock()
	if inst == nil {
		r, _, _ := procCallNextHookEx.Call(0, uintptr(nCode), wParam, lParam)
		return r
	}

	info := readKBDLLHookStruct(lParam)
	if (info.Flags&llkhfInjected) != 0 || info.DwExtraInfo == inst.syntheticMarker {
		r, _, _ := procCallNextHookEx.Call(0, uintptr(nCode), wParam, lParam)
		return r
	}

	if inst.handleKeyEvent(uint32(wParam), info.VkCode) {
		return 1 // Swallow trigger cleanly!
	}
	r, _, _ := procCallNextHookEx.Call(0, uintptr(nCode), wParam, lParam)
	return r
}

func (c *Controller) handleKeyEvent(msg uint32, vk uint32) bool {
	isDown := (msg == wmKeyDown || msg == wmSysKeyDown)
	isUp := (msg == wmKeyUp || msg == wmSysKeyUp)
	if !isDown && !isUp {
		return false
	}

	// Always swallow matching keyUp for any keyDown we previously swallowed (zero stuck keys!)
	if isUp && c.swallowedDown[vk] {
		delete(c.swallowedDown, vk)
		return true
	}

	snap := c.snap.Load()
	if snap == nil || !snap.Enabled || snap.Paused || !snap.RemoteSessionReady {
		c.rAltDownAt = time.Time{}
		return false
	}

	// Track standalone Right Alt (VK_RMENU) tap cleanly (for 101-key English keyboards on Windows)
	if vk == vkRMenu && snap.TriggerRightAltTap {
		if isDown {
			if c.rAltDownAt.IsZero() {
				c.rAltDownAt = time.Now()
				c.rAltChorded = false
			}
			// Do not swallow keyDown so RightAlt+key chords still work!
			return false
		}
		if isUp {
			downAt := c.rAltDownAt
			chorded := c.rAltChorded
			c.rAltDownAt = time.Time{}
			c.rAltChorded = false
			if !downAt.IsZero() && !chorded && time.Since(downAt) <= 350*time.Millisecond {
				// Suppress Windows Alt menu-bar activation cleanly (AutoHotkey VK_E8 trick)
				c.suppressAltMenu()
				c.emitTrigger(vk, "우측 Alt (단독 탭)")
			}
			return false
		}
	} else if !c.rAltDownAt.IsZero() && isDown {
		c.rAltChorded = true
	}

	if !isDown {
		return false
	}

	ctrlDown := isVKPressed(vkLControl) || isVKPressed(vkRControl)
	shiftDown := isVKPressed(vkLShift) || isVKPressed(vkRShift)
	altDown := isVKPressed(vkLMenu) || isVKPressed(vkRMenu)
	winDown := isVKPressed(vkLWin) || isVKPressed(vkRWin)

	// 1. Hardware Hangul key (VK_HANGUL = 0x15 — standard Korean 103/106 Right Alt / Han-Eng key)
	if snap.TriggerHangulKey && vk == vkHangul && !ctrlDown && !altDown && !winDown {
		c.swallowedDown[vk] = true
		c.emitTrigger(vk, "한/영 키 (VK_HANGUL)")
		return true
	}

	// 2. F18 / F19 (PowerToys / AutoHotkey / QMK remapped users)
	if snap.TriggerF18F19 && (vk == vkF18 || vk == vkF19) && !ctrlDown && !altDown && !winDown {
		c.swallowedDown[vk] = true
		label := "F18"
		if vk == vkF19 {
			label = "F19"
		}
		c.emitTrigger(vk, label)
		return true
	}

	// 3. Ctrl+Space (optional)
	if snap.TriggerCtrlSpace && vk == vkSpace && ctrlDown && !shiftDown && !altDown && !winDown {
		c.swallowedDown[vk] = true
		c.emitTrigger(vk, "Ctrl + Space")
		return true
	}

	// 4. Shift+Space (optional)
	if snap.TriggerShiftSpace && vk == vkSpace && shiftDown && !ctrlDown && !altDown && !winDown {
		c.swallowedDown[vk] = true
		c.emitTrigger(vk, "Shift + Space")
		return true
	}

	return false
}

func (c *Controller) emitTrigger(vk uint32, label string) {
	select {
	case c.triggerCh <- TriggerEvent{VKCode: vk, Label: label}:
	default:
	}
}

func (c *Controller) suppressAltMenu() {
	inputs := [2]keyboardInput{
		{
			Type: inputKeyboard,
			Ki: keybdInput{
				WVk:         vkMenuSuppressDummy,
				DwExtraInfo: c.syntheticMarker,
			},
		},
		{
			Type: inputKeyboard,
			Ki: keybdInput{
				WVk:         vkMenuSuppressDummy,
				DwFlags:     keyeventfKeyUp,
				DwExtraInfo: c.syntheticMarker,
			},
		},
	}
	procSendInputHook.Call(
		uintptr(len(inputs)),
		uintptr(unsafe.Pointer(&inputs[0])),
		unsafe.Sizeof(inputs[0]),
	)
}

func readKBDLLHookStruct(lParam uintptr) kbdLLHookStruct {
	// Win32 WH_KEYBOARD_LL passes a non-Go OS struct pointer in lParam.
	p := *(*unsafe.Pointer)(unsafe.Pointer(&lParam))
	return *(*kbdLLHookStruct)(p)
}

func isVKPressed(vk uint32) bool {
	r, _, _ := procGetAsyncKeyState.Call(uintptr(vk))
	return (uint16(r) & 0x8000) != 0
}

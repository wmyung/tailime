//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/wmyung/tailime/windows/internal/core"
	"github.com/wmyung/tailime/windows/internal/ctl"
	"github.com/wmyung/tailime/windows/internal/storage"
)

const (
	mbOK                    = 0x00000000
	mbYesNo                 = 0x00000004
	mbIconInformation       = 0x00000040
	mbIconWarning           = 0x00000030
	mbIconError             = 0x00000010
	mbSetForeground         = 0x00010000
	idYes                   = 6
	hkeyCurrentUser         = 0x80000001
	keyRead                 = 0x20019
	keySetValue             = 0x0002
	keyAllAccess            = 0xF003F
	regSZ                   = 1
	regExpandSZ             = 2
	regDWord                = 4
	hwndBroadcast           = 0xFFFF
	wmSettingChange         = 0x001A
	smtoAbortIfHung         = 0x0002
	movefileReplaceExisting = 0x01
	movefileDelayUntilBoot  = 0x04
	swShowNormal            = 1
	createNoWindow          = 0x08000000
	seeMaskNoCloseProcess   = 0x00000040
	waitObject0             = 0x00000000
	errorFileNotFound       = 2
)

var (
	modUser32Setup          = syscall.NewLazyDLL("user32.dll")
	procMsgBoxSetup         = modUser32Setup.NewProc("MessageBoxW")
	procSendMsgTimeoutSetup = modUser32Setup.NewProc("SendMessageTimeoutW")
	procSetDpiCtxSetup      = modUser32Setup.NewProc("SetProcessDpiAwarenessContext")

	modShell32Setup     = syscall.NewLazyDLL("shell32.dll")
	procShellExecuteExW = modShell32Setup.NewProc("ShellExecuteExW")

	modKernel32Setup        = syscall.NewLazyDLL("kernel32.dll")
	procMoveFileExSetup     = modKernel32Setup.NewProc("MoveFileExW")
	procWaitForSingleObj    = modKernel32Setup.NewProc("WaitForSingleObject")
	procGetExitCodeProcess  = modKernel32Setup.NewProc("GetExitCodeProcess")
	procCloseHandleSetup    = modKernel32Setup.NewProc("CloseHandle")

	modAdvapi32Setup     = syscall.NewLazyDLL("advapi32.dll")
	procRegOpenKeySetup  = modAdvapi32Setup.NewProc("RegOpenKeyExW")
	procRegCreateSetup   = modAdvapi32Setup.NewProc("RegCreateKeyExW")
	procRegQuerySetup    = modAdvapi32Setup.NewProc("RegQueryValueExW")
	procRegSetSetup      = modAdvapi32Setup.NewProc("RegSetValueExW")
	procRegDeleteVal     = modAdvapi32Setup.NewProc("RegDeleteValueW")
	procRegDeleteTreeW   = modAdvapi32Setup.NewProc("RegDeleteTreeW")
	procRegCloseSetup    = modAdvapi32Setup.NewProc("RegCloseKey")
)

// shellExecuteInfoW matches 64-bit Win32 SHELLEXECUTEINFOW (112 bytes).
type shellExecuteInfoW struct {
	CbSize       uint32
	FMask        uint32
	Hwnd         uintptr
	LpVerb       *uint16
	LpFile       *uint16
	LpParameters *uint16
	LpDirectory  *uint16
	NShow        int32
	HInstApp     uintptr
	LpIDList     uintptr
	LpClass      *uint16
	HkeyClass    uintptr
	DwHotKey     uint32
	HMonitor     uintptr
	HProcess     uintptr
}

func main() {
	const dpiPerMonitorV2 = ^uintptr(3)
	if procSetDpiCtxSetup.Find() == nil {
		procSetDpiCtxSetup.Call(dpiPerMonitorV2)
	}

	silent := false
	uninstall := false
	uninstallStage2 := false
	purge := false
	addFirewall := false
	firewallExeArg := ""

	for i := 1; i < len(os.Args); i++ {
		arg := strings.ToLower(os.Args[i])
		switch arg {
		case "/s", "--silent", "-s":
			silent = true
		case "--uninstall", "/uninstall":
			uninstall = true
		case "--uninstall-stage2":
			uninstallStage2 = true
		case "--purge":
			purge = true
		case "--add-firewall":
			addFirewall = true
			if i+1 < len(os.Args) {
				firewallExeArg = os.Args[i+1]
				i++
			}
		}
	}

	if addFirewall {
		if firewallExeArg == "" {
			firewallExeArg = filepath.Join(storage.DefaultDataDir(), "TailIME.exe")
		}
		if err := configureFirewallRulesElevated(firewallExeArg); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}

	if uninstall || uninstallStage2 {
		runUninstall(silent, purge, uninstallStage2)
		return
	}

	runInstall(silent)
}

func runInstall(silent bool) {
	if len(embeddedAppExe) == 0 || len(embeddedCtlExe) == 0 {
		if !silent {
			msgBox("TailIME 설치 오류", "설치 패키지에 실행 파일이 포함되어 있지 않습니다.", mbOK|mbIconError)
		}
		os.Exit(1)
	}

	installDir := storage.DefaultDataDir()
	appDst := filepath.Join(installDir, "TailIME.exe")
	ctlDst := filepath.Join(installDir, "tailime-ctl.exe")
	uninstDst := filepath.Join(installDir, "TailIME-Uninstall.exe")

	addStartup := true
	configureFW := true

	if !silent {
		prompt := fmt.Sprintf(
			"TailIME v%s (Windows)를 설치합니다.\n\n"+
				"• 설치 경로: %s\n"+
				"• 구성 요소: TailIME.exe (시스템 트레이), tailime-ctl.exe (CLI)\n"+
				"• 시작 메뉴 바로가기, Windows 자동 실행, 제어판 제거 항목이 등록됩니다.\n"+
				"• Mac ↔ Windows / Windows ↔ Windows Tailscale 원격 한영 전환 지원\n\n"+
				"설치를 계속할까요?",
			core.Version, installDir,
		)
		if msgBox("TailIME 설치", prompt, mbYesNo|mbIconInformation|mbSetForeground) != idYes {
			return
		}
	}

	// 1. Gracefully stop any running TailIME.exe
	stopRunningTailIME(installDir)

	if err := os.MkdirAll(installDir, 0700); err != nil {
		if !silent {
			msgBox("TailIME 설치 실패", "설치 폴더를 생성하지 못했습니다:\n"+err.Error(), mbOK|mbIconError)
		}
		os.Exit(1)
	}

	// 2. Write embedded binaries safely (with rename-aside fallback if file handle still closing)
	if err := writeBinarySafe(appDst, embeddedAppExe); err != nil {
		if !silent {
			msgBox("TailIME 설치 실패", "TailIME.exe 설치 실패:\n"+err.Error(), mbOK|mbIconError)
		}
		os.Exit(1)
	}
	if err := writeBinarySafe(ctlDst, embeddedCtlExe); err != nil {
		if !silent {
			msgBox("TailIME 설치 실패", "tailime-ctl.exe 설치 실패:\n"+err.Error(), mbOK|mbIconError)
		}
		os.Exit(1)
	}
	if len(embeddedReadmeKO) > 0 {
		_ = os.WriteFile(filepath.Join(installDir, "README.ko.md"), embeddedReadmeKO, 0644)
	}
	if len(embeddedReadmeEN) > 0 {
		_ = os.WriteFile(filepath.Join(installDir, "README.md"), embeddedReadmeEN, 0644)
	}
	if len(embeddedLicense) > 0 {
		_ = os.WriteFile(filepath.Join(installDir, "LICENSE"), embeddedLicense, 0644)
	}

	// Copy self as uninstaller
	if selfExe, err := os.Executable(); err == nil {
		if rawSelf, err := os.ReadFile(selfExe); err == nil {
			_ = writeBinarySafe(uninstDst, rawSelf)
		}
	}

	// 3. Register Start Menu shortcut, Startup Run key, Uninstall entry, and User PATH
	createStartMenuShortcut(appDst)
	if addStartup {
		_ = regSetString(hkeyCurrentUser, `Software\Microsoft\Windows\CurrentVersion\Run`, "TailIME", fmt.Sprintf(`"%s"`, appDst))
	}
	registerUninstallEntry(installDir, appDst, uninstDst)
	addToUserPath(installDir)

	// 4. Optional scoped Windows Defender Firewall rule (Tailscale CIDR UDP 39418 only!)
	fwNote := ""
	if configureFW && !silent {
		fwPrompt := "Windows 방화벽에 Tailscale 전용 수신 규칙(UDP 39418 · 100.64.0.0/10 및 fd7a:115c:a1e0::/48 전용)을 추가할까요?\n\n" +
			"• Mac 또는 다른 Windows에서 이 PC로 한영 전환 신호를 받으려면 방화벽 허용이 필요합니다.\n" +
			"• [예]를 누르면 관리자 권한(UAC) 확인 창이 뜹니다."
		if msgBox("TailIME 방화벽 설정 (권장)", fwPrompt, mbYesNo|mbIconInformation|mbSetForeground) == idYes {
			if selfExe, err := os.Executable(); err == nil {
				if runElevatedSelf(selfExe, fmt.Sprintf(`--add-firewall "%s"`, appDst)) {
					fwNote = "\n• 방화벽: Tailscale 전용 UDP 39418 허용 규칙 등록됨"
				} else {
					fwNote = "\n• 방화벽: 관리자 승인이 취소되어 수동 허용이 필요할 수 있습니다."
				}
			}
		} else {
			fwNote = "\n• 방화벽: 건너뜀 (첫 실행 시 Windows 보안 경고에서 허용하거나 설정 가이드를 참고하세요)"
		}
	}

	// 5. Launch TailIME.exe immediately
	cmd := exec.Command(appDst)
	cmd.Dir = installDir
	_ = cmd.Start()

	if !silent {
		doneMsg := fmt.Sprintf(
			"TailIME v%s 설치가 완료되었으며 시스템 트레이에서 실행되었습니다!\n\n"+
				"• 설치 위치: %s\n"+
				"• CLI: 새 터미널에서 tailime-ctl status 사용 가능%s\n\n"+
				"이제 트레이 아이콘(한/EN)을 클릭해 Mac 또는 다른 Windows 기기와 6자리 SAS 또는 TKP1 토큰으로 페어링하세요.",
			core.Version, installDir, fwNote,
		)
		msgBox("TailIME 설치 완료", doneMsg, mbOK|mbIconInformation|mbSetForeground)
	}
}

func runUninstall(silent, purge, stage2 bool) {
	installDir := storage.DefaultDataDir()

	// If invoked from inside installDir, copy self to %TEMP% and re-launch stage2 so we can delete installDir cleanly!
	if !stage2 {
		if selfExe, err := os.Executable(); err == nil {
			cleanSelf := strings.ToLower(filepath.Clean(selfExe))
			cleanDir := strings.ToLower(filepath.Clean(installDir))
			if strings.HasPrefix(cleanSelf, cleanDir+string(filepath.Separator)) {
				tmpUninst := filepath.Join(os.TempDir(), "TailIME-Uninstall-runner.exe")
				if raw, err := os.ReadFile(selfExe); err == nil && os.WriteFile(tmpUninst, raw, 0700) == nil {
					args := []string{"--uninstall-stage2"}
					if silent {
						args = append(args, "/S")
					}
					if purge {
						args = append(args, "--purge")
					}
					c := exec.Command(tmpUninst, args...)
					_ = c.Start()
					return
				}
			}
		}
	}

	if !silent {
		if msgBox("TailIME 제거", "TailIME (Windows)를 이 PC에서 제거할까요?", mbYesNo|mbIconWarning|mbSetForeground) != idYes {
			return
		}
		if !purge {
			if msgBox("페어링 및 설정 데이터", "기존 페어링 정보와 기기 키(DPAPI)도 함께 삭제할까요?\n\n([아니오]를 선택하면 재설치 시 기존 페어링이 유지됩니다.)", mbYesNo|mbIconInformation) == idYes {
				purge = true
			}
		}
	}

	stopRunningTailIME(installDir)
	time.Sleep(300 * time.Millisecond)

	// Remove registry entries, Start Menu shortcut, and User PATH entry
	regDeleteValue(hkeyCurrentUser, `Software\Microsoft\Windows\CurrentVersion\Run`, "TailIME")
	regDeleteTree(hkeyCurrentUser, `Software\Microsoft\Windows\CurrentVersion\Uninstall\TailIME`)
	removeFromUserPath(installDir)
	removeStartMenuShortcut()

	files := []string{
		"TailIME.exe",
		"tailime-ctl.exe",
		"TailIME-Uninstall.exe",
		"README.ko.md",
		"README.md",
		"LICENSE",
		"ctl.json",
	}
	if purge {
		files = append(files, "identity.dpapi", "settings.json", "trusted_peers.json")
	}
	for _, f := range files {
		p := filepath.Join(installDir, f)
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			scheduleDeleteOnReboot(p)
		}
	}
	if purge {
		_ = os.Remove(installDir)
	}
	if stage2 {
		if selfExe, err := os.Executable(); err == nil {
			scheduleDeleteOnReboot(selfExe)
		}
	}

	if !silent {
		msgBox("TailIME 제거 완료", "TailIME가 정상적으로 제거되었습니다.", mbOK|mbIconInformation)
	}
}

func stopRunningTailIME(installDir string) {
	_, _ = ctl.SendCommand(installDir, "quit", nil)
	for i := 0; i < 20; i++ {
		if _, err := ctl.SendCommand(installDir, "status", nil); err != nil {
			break
		}
		time.Sleep(120 * time.Millisecond)
	}
	// Fallback taskkill scoped strictly to current user so multi-user sessions are untouched
	if user := strings.TrimSpace(os.Getenv("USERNAME")); user != "" {
		filter := "USERNAME eq " + user
		if domain := strings.TrimSpace(os.Getenv("USERDOMAIN")); domain != "" {
			filter = "USERNAME eq " + domain + `\` + user
		}
		cmd := exec.Command("taskkill", "/F", "/FI", filter, "/IM", "TailIME.exe")
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
		_ = cmd.Run()
		time.Sleep(200 * time.Millisecond)
	}
}

func writeBinarySafe(dst string, data []byte) error {
	tmp := dst + ".new"
	if err := os.WriteFile(tmp, data, 0755); err != nil {
		return err
	}
	srcPtr, _ := syscall.UTF16PtrFromString(tmp)
	dstPtr, _ := syscall.UTF16PtrFromString(dst)
	r1, _, err := procMoveFileExSetup.Call(uintptr(unsafe.Pointer(srcPtr)), uintptr(unsafe.Pointer(dstPtr)), movefileReplaceExisting)
	if r1 != 0 {
		return nil
	}
	// If locked, move existing exe aside and schedule reboot cleanup
	old := dst + ".old"
	_ = os.Remove(old)
	oldPtr, _ := syscall.UTF16PtrFromString(old)
	procMoveFileExSetup.Call(uintptr(unsafe.Pointer(dstPtr)), uintptr(unsafe.Pointer(oldPtr)), movefileReplaceExisting)
	scheduleDeleteOnReboot(old)

	r2, _, err2 := procMoveFileExSetup.Call(uintptr(unsafe.Pointer(srcPtr)), uintptr(unsafe.Pointer(dstPtr)), movefileReplaceExisting)
	if r2 != 0 {
		return nil
	}
	_ = os.Remove(tmp)
	if err2 != nil {
		return err2
	}
	return err
}

func scheduleDeleteOnReboot(path string) {
	p, _ := syscall.UTF16PtrFromString(path)
	procMoveFileExSetup.Call(uintptr(unsafe.Pointer(p)), 0, movefileDelayUntilBoot)
}

func configureFirewallRulesElevated(appExe string) error {
	// Remove any existing TailIME rules (including accidental Windows Cancel block rules!)
	del := exec.Command("netsh", "advfirewall", "firewall", "delete", "rule", "name=all", "program="+appExe)
	del.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	_ = del.Run()

	// Add strictly scoped Tailscale-only UDP 39418 inbound allow rule (v4 CGNAT + v6 ULA, profile=any)
	add := exec.Command(
		"netsh", "advfirewall", "firewall", "add", "rule",
		"name=TailIME (Tailscale UDP 39418)",
		"dir=in",
		"action=allow",
		"protocol=UDP",
		"localport=39418",
		"remoteip=100.64.0.0/10,fd7a:115c:a1e0::/48",
		"program="+appExe,
		"profile=any",
		"enable=yes",
	)
	add.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	return add.Run()
}

func runElevatedSelf(exe, params string) bool {
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, _ := syscall.UTF16PtrFromString(exe)
	args, _ := syscall.UTF16PtrFromString(params)
	sei := shellExecuteInfoW{
		CbSize:       uint32(unsafe.Sizeof(shellExecuteInfoW{})),
		FMask:        seeMaskNoCloseProcess,
		LpVerb:       verb,
		LpFile:       file,
		LpParameters: args,
		NShow:        swShowNormal,
	}
	r1, _, _ := procShellExecuteExW.Call(uintptr(unsafe.Pointer(&sei)))
	if r1 == 0 {
		return false
	}
	if sei.HProcess == 0 {
		return false
	}
	defer procCloseHandleSetup.Call(sei.HProcess)
	waitRes, _, _ := procWaitForSingleObj.Call(sei.HProcess, 30000)
	if waitRes != waitObject0 {
		return false
	}
	var exitCode uint32
	ok, _, _ := procGetExitCodeProcess.Call(sei.HProcess, uintptr(unsafe.Pointer(&exitCode)))
	return ok != 0 && exitCode == 0
}

func createStartMenuShortcut(targetExe string) {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return
	}
	lnk := filepath.Join(appData, "Microsoft", "Windows", "Start Menu", "Programs", "TailIME.lnk")
	esc := func(s string) string { return strings.ReplaceAll(s, "'", "''") }
	ps := fmt.Sprintf(
		`$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%s');$s.TargetPath='%s';$s.WorkingDirectory='%s';$s.Description='TailIME — Tailscale Korean/English Sync';$s.Save()`,
		esc(lnk), esc(targetExe), esc(filepath.Dir(targetExe)),
	)
	cmd := exec.Command("powershell.exe", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	_ = cmd.Run()
}

func removeStartMenuShortcut() {
	if appData := os.Getenv("APPDATA"); appData != "" {
		_ = os.Remove(filepath.Join(appData, "Microsoft", "Windows", "Start Menu", "Programs", "TailIME.lnk"))
	}
}

func registerUninstallEntry(installDir, appExe, uninstExe string) {
	key := `Software\Microsoft\Windows\CurrentVersion\Uninstall\TailIME`
	_ = regSetString(hkeyCurrentUser, key, "DisplayName", "TailIME (Tailscale 한영 전환)")
	_ = regSetString(hkeyCurrentUser, key, "DisplayVersion", core.Version)
	_ = regSetString(hkeyCurrentUser, key, "Publisher", "TailIME")
	_ = regSetString(hkeyCurrentUser, key, "InstallLocation", installDir)
	_ = regSetString(hkeyCurrentUser, key, "DisplayIcon", appExe)
	_ = regSetString(hkeyCurrentUser, key, "UninstallString", fmt.Sprintf(`"%s" --uninstall`, uninstExe))
	_ = regSetDWord(hkeyCurrentUser, key, "NoModify", 1)
	_ = regSetDWord(hkeyCurrentUser, key, "NoRepair", 1)
}

func addToUserPath(dir string) {
	cur, _, err := regGetString(hkeyCurrentUser, "Environment", "Path")
	if err != nil {
		// Never overwrite User PATH if reading the existing value failed unexpectedly
		return
	}
	parts := strings.Split(cur, ";")
	cleaned := make([]string, 0, len(parts)+1)
	for _, p := range parts {
		t := strings.TrimSpace(p)
		if t == "" {
			continue
		}
		if strings.EqualFold(filepath.Clean(t), filepath.Clean(dir)) {
			return // already present
		}
		cleaned = append(cleaned, t)
	}
	cleaned = append(cleaned, dir)
	_ = regSetExpandString(hkeyCurrentUser, "Environment", "Path", strings.Join(cleaned, ";"))
	broadcastEnvironmentChange()
}

func removeFromUserPath(dir string) {
	cur, found, err := regGetString(hkeyCurrentUser, "Environment", "Path")
	if err != nil || !found || cur == "" {
		return
	}
	parts := strings.Split(cur, ";")
	cleaned := make([]string, 0, len(parts))
	changed := false
	for _, p := range parts {
		t := strings.TrimSpace(p)
		if t == "" {
			continue
		}
		if strings.EqualFold(filepath.Clean(t), filepath.Clean(dir)) {
			changed = true
			continue
		}
		cleaned = append(cleaned, t)
	}
	if changed {
		_ = regSetExpandString(hkeyCurrentUser, "Environment", "Path", strings.Join(cleaned, ";"))
		broadcastEnvironmentChange()
	}
}

func broadcastEnvironmentChange() {
	envPtr, _ := syscall.UTF16PtrFromString("Environment")
	var res uintptr
	procSendMsgTimeoutSetup.Call(hwndBroadcast, wmSettingChange, 0, uintptr(unsafe.Pointer(envPtr)), smtoAbortIfHung, 2000, uintptr(unsafe.Pointer(&res)))
}

func msgBox(title, body string, flags uint32) int {
	t, _ := syscall.UTF16PtrFromString(title)
	b, _ := syscall.UTF16PtrFromString(body)
	r, _, _ := procMsgBoxSetup.Call(0, uintptr(unsafe.Pointer(b)), uintptr(unsafe.Pointer(t)), uintptr(flags))
	return int(r)
}

func regSetString(root uintptr, subKey, name, val string) error {
	return regSetStringType(root, subKey, name, val, regSZ)
}

func regSetExpandString(root uintptr, subKey, name, val string) error {
	return regSetStringType(root, subKey, name, val, regExpandSZ)
}

func regSetStringType(root uintptr, subKey, name, val string, typ uint32) error {
	sk, _ := syscall.UTF16PtrFromString(subKey)
	var hKey uintptr
	rc, _, _ := procRegCreateSetup.Call(root, uintptr(unsafe.Pointer(sk)), 0, 0, 0, keySetValue, 0, uintptr(unsafe.Pointer(&hKey)), 0)
	if rc != 0 {
		return syscall.Errno(rc)
	}
	defer procRegCloseSetup.Call(hKey)
	vn, _ := syscall.UTF16PtrFromString(name)
	u16, _ := syscall.UTF16FromString(val)
	rc2, _, _ := procRegSetSetup.Call(hKey, uintptr(unsafe.Pointer(vn)), 0, uintptr(typ), uintptr(unsafe.Pointer(&u16[0])), uintptr(len(u16)*2))
	if rc2 != 0 {
		return syscall.Errno(rc2)
	}
	return nil
}

func regSetDWord(root uintptr, subKey, name string, val uint32) error {
	sk, _ := syscall.UTF16PtrFromString(subKey)
	var hKey uintptr
	rc, _, _ := procRegCreateSetup.Call(root, uintptr(unsafe.Pointer(sk)), 0, 0, 0, keySetValue, 0, uintptr(unsafe.Pointer(&hKey)), 0)
	if rc != 0 {
		return syscall.Errno(rc)
	}
	defer procRegCloseSetup.Call(hKey)
	vn, _ := syscall.UTF16PtrFromString(name)
	rc2, _, _ := procRegSetSetup.Call(hKey, uintptr(unsafe.Pointer(vn)), 0, regDWord, uintptr(unsafe.Pointer(&val)), 4)
	if rc2 != 0 {
		return syscall.Errno(rc2)
	}
	return nil
}

func regGetString(root uintptr, subKey, name string) (string, bool, error) {
	sk, _ := syscall.UTF16PtrFromString(subKey)
	var hKey uintptr
	rc, _, _ := procRegOpenKeySetup.Call(root, uintptr(unsafe.Pointer(sk)), 0, keyRead, uintptr(unsafe.Pointer(&hKey)))
	if rc == errorFileNotFound {
		return "", false, nil
	}
	if rc != 0 {
		return "", false, syscall.Errno(rc)
	}
	defer procRegCloseSetup.Call(hKey)
	vn, _ := syscall.UTF16PtrFromString(name)
	var size uint32
	rc2, _, _ := procRegQuerySetup.Call(hKey, uintptr(unsafe.Pointer(vn)), 0, 0, 0, uintptr(unsafe.Pointer(&size)))
	if rc2 == errorFileNotFound {
		return "", false, nil
	}
	if rc2 != 0 {
		return "", false, syscall.Errno(rc2)
	}
	if size == 0 {
		return "", true, nil
	}
	buf := make([]uint16, size/2+1)
	rc3, _, _ := procRegQuerySetup.Call(hKey, uintptr(unsafe.Pointer(vn)), 0, 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)))
	if rc3 != 0 {
		return "", false, syscall.Errno(rc3)
	}
	return syscall.UTF16ToString(buf), true, nil
}

func regDeleteValue(root uintptr, subKey, name string) {
	sk, _ := syscall.UTF16PtrFromString(subKey)
	var hKey uintptr
	rc, _, _ := procRegOpenKeySetup.Call(root, uintptr(unsafe.Pointer(sk)), 0, keySetValue, uintptr(unsafe.Pointer(&hKey)))
	if rc != 0 {
		return
	}
	defer procRegCloseSetup.Call(hKey)
	vn, _ := syscall.UTF16PtrFromString(name)
	procRegDeleteVal.Call(hKey, uintptr(unsafe.Pointer(vn)))
}

func regDeleteTree(root uintptr, subKey string) {
	sk, _ := syscall.UTF16PtrFromString(subKey)
	procRegDeleteTreeW.Call(root, uintptr(unsafe.Pointer(sk)))
}

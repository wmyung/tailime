import AppKit
import Carbon
import CSystemBridge
import Foundation
import TailIMECore

/// Background-only warm-up manager for `com.apple.TextInputSwitcher` (fixes macOS 26+ first-press drop
/// when jetsam terminates TextInputSwitcher while idle). Never blocks the CGEventTap thread.
final class InputSwitcherWaker {
    private let queue = DispatchQueue(label: "com.tailime.inputswitcher-waker", qos: .utility)
    private let lock = NSLock()
    private var _isRunning = false
    private var lastKickstartAt: TimeInterval = 0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    var isMacOS26OrLater: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
    }

    func checkAndWarmAsync(force: Bool = false) {
        queue.async { [weak self] in
            self?.checkAndWarmSync(force: force)
        }
    }

    private func checkAndWarmSync(force: Bool) {
        let running = tailime_mach_service_exists("com.apple.inputswitcher.running")
        lock.lock()
        _isRunning = running
        let now = ProcessInfo.processInfo.systemUptime
        let shouldKick = !running && isMacOS26OrLater
            && tailime_mach_service_exists("com.apple.inputswitcher.startup")
            && (force || now - lastKickstartAt >= 10.0)
        if shouldKick {
            lastKickstartAt = now
        }
        lock.unlock()

        guard shouldKick else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "gui/\(getuid())/com.apple.TextInputSwitcher"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        // Poll briefly on background queue so status reflects warm state
        for _ in 0..<40 {
            if tailime_mach_service_exists("com.apple.inputswitcher.running") {
                lock.lock()
                _isRunning = true
                lock.unlock()
                return
            }
            usleep(10_000)
        }
    }
}

/// Runtime-resolved TSM port helper (benchmarked from `laishulu/macism`).
/// Sends message ID 7 directly to the key-focused process's `com.apple.tsm.portname`,
/// avoiding the notorious macOS Carbon TIS bug where CJK sources update the menu bar
/// without updating the focused app's input context.
enum TSMDirectBridge {
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let ipcQueue = DispatchQueue(label: "com.tailime.tsm-direct", qos: .userInteractive)

    private typealias KeyFocusFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>,
        UnsafeMutablePointer<DarwinBoolean>
    ) -> Int32
    private typealias PSNToPIDFn = @convention(c) (
        UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>
    ) -> OSStatus
    private typealias RemotePortFn = @convention(c) (
        CFAllocator?, CFString, pid_t
    ) -> Unmanaged<CFMessagePort>?
    private typealias FlattenFn = @convention(c) (
        TISInputSource, UnsafeMutablePointer<Unmanaged<AnyObject>?>
    ) -> DarwinBoolean

    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        dlsym(rtldDefault, name).map { unsafeBitCast($0, to: T.self) }
    }

    private static func candidateFocusPIDs() -> [pid_t] {
        var pids: [pid_t] = []
        if let keyFocus = sym("CPSGetKeyFocusProcess", KeyFocusFn.self),
           let psnToPID = sym("GetProcessPID", PSNToPIDFn.self) {
            var psn = ProcessSerialNumber()
            var ignored: DarwinBoolean = false
            var pid: pid_t = -1
            if keyFocus(&psn, &ignored) == 0, psnToPID(&psn, &pid) == noErr, pid > 0 {
                pids.append(pid)
            }
        }
        // Fallback / complement: if CPSGetKeyFocusProcess failed or returned a floating helper
        // (e.g. RustDesk --cm) while an Electron/AppKit app is actually frontmost, include frontmostApplication PID!
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontPID > 0,
           !pids.contains(frontPID) {
            pids.append(frontPID)
        }
        return pids
    }

    /// Returns true when `CPSGetKeyFocusProcess` and `NSWorkspace.shared.frontmostApplication`
    /// report different PIDs (e.g. a floating `RustDesk --cm` connection bar over a frontmost
    /// Electron/Chromium app), which can cause `TextInputSwitcher` to log
    /// `target app and typing focus mismatch` and skip activating `KIM_Extension`.
    static func hasFocusMismatch() -> Bool {
        candidateFocusPIDs().count > 1
    }

    private static func sendSelectRequest(_ data: CFData, toPID pid: pid_t, remotePort: RemotePortFn) -> Bool {
        guard let port = remotePort(nil, "com.apple.tsm.portname" as CFString, pid)?.takeRetainedValue() else {
            return false
        }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            port, 7, data, 0.04, 0.04, CFRunLoopMode.defaultMode.rawValue, &reply
        )
        guard status == kCFMessagePortSuccess else { return false }

        if let replyData = reply?.takeRetainedValue(),
           let dict = CFPropertyListCreateWithData(nil, replyData, 0, nil, nil)?.takeRetainedValue() as? [String: Any],
           let error = dict["tsmInputModeReplyToServerErrorKey"] as? Int,
           error != 0 {
            return false
        }
        return true
    }

    /// Asynchronously asks the currently focused app(s) to switch directly to `source` via `com.apple.tsm.portname`.
    /// All Carbon/AppKit work (`TISInputSource`, `_CreateFlattenedInputSource`, `NSWorkspace`) executes on the
    /// calling main thread, while the `CFMessagePortSendRequest` IPC runs off-main on a `.userInteractive` serial
    /// queue with a tight 40ms timeout per PID. `isCurrent` is polled before each per-PID send so superseded
    /// switches abort immediately instead of inverting a newer switch request.
    static func selectInFocusedAppAsync(
        _ source: TISInputSource,
        isCurrent: @escaping @Sendable () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard let remotePort = sym("CFMessagePortCreatePerProcessRemote", RemotePortFn.self),
              let flatten = sym("_CreateFlattenedInputSource", FlattenFn.self) else {
            completion(false)
            return
        }

        let targetPIDs = candidateFocusPIDs()
        guard !targetPIDs.isEmpty else {
            completion(false)
            return
        }

        var flatRef: Unmanaged<AnyObject>?
        guard flatten(source, &flatRef).boolValue,
              let flat = flatRef?.takeRetainedValue() else {
            completion(false)
            return
        }

        let request = ["tsmInputSourceSelectedInpSrcKey": flat] as CFDictionary
        guard let cfData = CFPropertyListCreateData(nil, request, .xmlFormat_v1_0, 0, nil)?.takeRetainedValue() else {
            completion(false)
            return
        }
        let payload = cfData as Data

        ipcQueue.async {
            let bridged = payload as CFData
            var anySucceeded = false
            for pid in targetPIDs {
                guard isCurrent() else { break }
                if sendSelectRequest(bridged, toPID: pid, remotePort: remotePort) {
                    anySucceeded = true
                }
            }
            DispatchQueue.main.async {
                completion(anySucceeded)
            }
        }
    }
}

struct InputSourceInfo: Equatable {
    let id: String
    let localizedName: String
    let language: InputLanguage
    let isKeyboardLayout: Bool
}

/// Ultra-snappy local input source engine.
/// Combines:
/// 1. Native Symbolic Hotkey 60/61 atomic `keyDown+keyUp` pulse (`CGEventSource(.privateState)`) on local apps
///    for zero-delay Hangul syllable commit & switching
/// 2. Background `TextInputSwitcher` keep-warm on macOS 26+
/// 3. Verification via `kTISNotifySelectedKeyboardInputSourceChanged` with automatic fallback to `TSMDirectBridge` / `TISSelectInputSource`
/// 4. Safe direct TIS/TSM switching (NEVER firing global hotkey pulses) when a Remote Desktop client is focused!
final class LocalSwitchEngine {
    let syntheticMarker: Int64
    let switcherWaker = InputSwitcherWaker()

    private var lastPulseAt: TimeInterval = 0
    private let minPulseInterval: TimeInterval = 0.025 // 25ms coalescing guard
    private var hotkeysSnapshot: InputSourceHotkeysSnapshot
    private var lastKoreanSourceID: String?
    private var lastEnglishSourceID: String?
    private var pendingVerificationWork: DispatchWorkItem?
    private var pendingSwitchCompletion: (gen: UInt64, targetLang: InputLanguage?, completion: ((InputSourceInfo?) -> Void)?)?
    private let generationTracker = SwitchGenerationTracker()

    var onInputSourceChanged: ((InputSourceInfo) -> Void)?

    init(syntheticMarker: Int64) {
        self.syntheticMarker = syntheticMarker
        self.hotkeysSnapshot = SymbolicHotkeysParser.readSystem()
        refreshSourceMemory()
        switcherWaker.checkAndWarmAsync(force: true)
    }

    var currentHotkeys: InputSourceHotkeysSnapshot {
        hotkeysSnapshot
    }

    func reloadSystemHotkeys() -> InputSourceHotkeysSnapshot {
        hotkeysSnapshot = SymbolicHotkeysParser.readSystem()
        return hotkeysSnapshot
    }

    func startObservingInputSourceNotifications() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemInputSourceNotification()
        }
    }

    private func handleSystemInputSourceNotification() {
        guard let info = currentInputSource() else { return }
        rememberSource(info)
        if let pending = pendingSwitchCompletion,
           generationTracker.isCurrent(pending.gen),
           (pending.targetLang == nil || info.language == pending.targetLang) {
            pendingSwitchCompletion = nil
            pendingVerificationWork?.cancel()
            pendingVerificationWork = nil
            pending.completion?(info)
        }
        onInputSourceChanged?(info)
    }

    private func rememberSource(_ info: InputSourceInfo) {
        switch info.language {
        case .korean: lastKoreanSourceID = info.id
        case .english: lastEnglishSourceID = info.id
        case .other: break
        }
    }

    func refreshSourceMemory() {
        if let cur = currentInputSource() {
            rememberSource(cur)
        }
    }

    func currentInputSource() -> InputSourceInfo? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return describe(src)
    }

    func enabledKeyboardSources() -> [InputSourceInfo] {
        selectableKeyboardTISSources().compactMap(describe)
    }

    /// Toggles between Korean and English using the fastest reliable path for local typing.
    /// Must be invoked on main thread.
    @discardableResult
    func toggleKoreanEnglish(allowHotkeyPulse: Bool = true, completion: ((InputSourceInfo?) -> Void)? = nil) -> InputLanguage {
        let current = currentInputSource()
        let targetLang: InputLanguage = (current?.language == .korean) ? .english : .korean
        switchTo(language: targetLang, allowHotkeyPulse: allowHotkeyPulse, completion: completion)
        return targetLang
    }

    /// Preserves macOS's exact native "previous input source" semantics when 3+ input sources are enabled
    /// and the user pressed their native macOS Symbolic Hotkey 60 locally — just firing on keyDown instead of keyUp!
    func pulseNativePreviousSource(completion: ((InputSourceInfo?) -> Void)? = nil) {
        let gen = generationTracker.advance()
        pendingVerificationWork?.cancel()
        pendingVerificationWork = nil
        pendingSwitchCompletion = nil

        guard let hotkey = hotkeysSnapshot.preferredPulseHotkey else {
            completion?(currentInputSource())
            return
        }
        if !switcherWaker.isRunning {
            switcherWaker.checkAndWarmAsync(force: false)
        }
        pendingSwitchCompletion = (gen, nil, completion)
        _ = postSyntheticHotkeyPulse(hotkey)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generationTracker.isCurrent(gen) else { return }
            let done = self.pendingSwitchCompletion?.completion
            self.pendingSwitchCompletion = nil
            done?(self.currentInputSource())
        }
        pendingVerificationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    /// Deterministically switches to an absolute target language (`.korean` or `.english`).
    /// Never double-toggles when already on the target language, and always cancels any stale
    /// delayed verification from an earlier switch BEFORE returning.
    func switchTo(
        language targetLang: InputLanguage,
        allowHotkeyPulse: Bool = true,
        completion: ((InputSourceInfo?) -> Void)? = nil
    ) {
        // Always invalidate any earlier in-flight verification first so rapid toggling never reverts!
        let gen = generationTracker.advance()
        pendingVerificationWork?.cancel()
        pendingVerificationWork = nil
        pendingSwitchCompletion = nil

        let current = currentInputSource()
        let hadInFlightDirect = generationTracker.hasInFlightDirectSwitch
        if let current, generationTracker.canShortCircuitAlreadyAtTarget(current.language == targetLang) {
            completion?(current)
            return
        }

        guard let targetTIS = resolveTargetTISSource(for: targetLang) else {
            completion?(current)
            return
        }

        let enabledList = selectableKeyboardTISSources()
        // When key-focus PID differs from frontmostApplication PID (e.g., floating RustDesk --cm over Electron),
        // TextInputSwitcher can hit "target app and typing focus mismatch" and fail to activate KIM_Extension.
        // Also when an earlier direct TSM IPC is still in-flight, NEVER use a relative toggle pulse — queue a
        // deterministic absolute TSM switch behind it on the same serial queue so final state matches latest request!
        let focusMismatchForKorean = (targetLang == .korean) && TSMDirectBridge.hasFocusMismatch()
        let useFastPulse = allowHotkeyPulse
            && !hadInFlightDirect
            && !focusMismatchForKorean
            && enabledList.count == 2
            && hotkeysSnapshot.preferredPulseHotkey != nil

        if useFastPulse, let hotkey = hotkeysSnapshot.preferredPulseHotkey {
            // Proactively kick TextInputSwitcher in background if it was killed by jetsam
            if !switcherWaker.isRunning {
                switcherWaker.checkAndWarmAsync(force: false)
            }
            pendingSwitchCompletion = (gen, targetLang, completion)
            if postSyntheticHotkeyPulse(hotkey) {
                // Fast path completes immediately inside handleSystemInputSourceNotification (~2-5ms).
                // Allow 150ms for TextInputSwitcher wake cycles (measured ~100ms on cold wake in macOS 26)
                // before falling back to TSMDirectBridge / TISSelectInputSource so we never collide mid-switch!
                let verify = DispatchWorkItem { [weak self] in
                    guard let self, self.generationTracker.isCurrent(gen) else { return }
                    let done = self.pendingSwitchCompletion?.completion
                    self.pendingSwitchCompletion = nil
                    let nowInfo = self.currentInputSource()
                    if nowInfo?.language == targetLang {
                        done?(nowInfo)
                        return
                    }
                    self.selectDirectly(targetTIS, expectedGeneration: gen) { [weak self] in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
                            guard let self, self.generationTracker.isCurrent(gen) else { return }
                            done?(self.currentInputSource())
                        }
                    }
                }
                pendingVerificationWork = verify
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.150, execute: verify)
                return
            }
            pendingSwitchCompletion = nil
        }

        // Direct path (used when remote viewer is focused for Auto-ABC, >2 input sources, hotkey 60/61 disabled,
        // an earlier direct TSM IPC is in-flight, or Korean activation encounters a key-focus vs frontmost-app PID mismatch)
        pendingSwitchCompletion = (gen, targetLang, completion)

        let finishDirectVerification: () -> Void = { [weak self] in
            guard let self, self.generationTracker.isCurrent(gen), self.pendingSwitchCompletion != nil else { return }
            let done = self.pendingSwitchCompletion?.completion
            self.pendingSwitchCompletion = nil
            self.pendingVerificationWork?.cancel()
            self.pendingVerificationWork = nil
            let nowInfo = self.currentInputSource()
            if nowInfo?.language != targetLang {
                _ = TISSelectInputSource(targetTIS)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
                    guard let self, self.generationTracker.isCurrent(gen) else { return }
                    done?(self.currentInputSource())
                }
                return
            }
            done?(nowInfo)
        }

        // Bounded 80ms hard-cap timer guarantees completion even if a hung helper stalls the off-main TSM IPC queue.
        let hardCap = DispatchWorkItem(block: finishDirectVerification)
        pendingVerificationWork = hardCap
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.080, execute: hardCap)

        selectDirectly(targetTIS, expectedGeneration: gen) { [weak self] in
            guard let self, self.generationTracker.isCurrent(gen), self.pendingSwitchCompletion != nil else { return }
            // Healthy TSM IPC completed quickly (<1ms) -> replace 80ms hard cap with tight 25ms verification check.
            self.pendingVerificationWork?.cancel()
            let directFallback = DispatchWorkItem(block: finishDirectVerification)
            self.pendingVerificationWork = directFallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: directFallback)
        }
    }

    /// Switches directly to a specific input source ID (used when restoring a saved local input source).
    func switchToSourceID(_ sourceID: String, allowHotkeyPulse: Bool = false) {
        let gen = generationTracker.advance()
        pendingVerificationWork?.cancel()
        pendingVerificationWork = nil
        pendingSwitchCompletion = nil

        let hadInFlightDirect = generationTracker.hasInFlightDirectSwitch
        if generationTracker.canShortCircuitAlreadyAtTarget(currentInputSource()?.id == sourceID) {
            return
        }
        let list = selectableKeyboardTISSources()
        guard let target = list.first(where: { stringProperty($0, kTISPropertyInputSourceID) == sourceID }) else { return }
        if allowHotkeyPulse, !hadInFlightDirect, list.count == 2, let hotkey = hotkeysSnapshot.preferredPulseHotkey {
            _ = postSyntheticHotkeyPulse(hotkey)
            return
        }
        selectDirectly(target, expectedGeneration: gen)
    }

    private func selectDirectly(
        _ source: TISInputSource,
        expectedGeneration gen: UInt64,
        completion: (() -> Void)? = nil
    ) {
        let isKeyboardLayout = (describe(source)?.isKeyboardLayout == true)
        let tracker = generationTracker
        tracker.beginInFlightDirectSwitch()
        // First try TSMDirectBridge off-main (macism trick — reliably activates Korean 2-Set in focused app(s))
        TSMDirectBridge.selectInFocusedAppAsync(source, isCurrent: { tracker.isCurrent(gen) }) { [weak self] succeeded in
            defer { tracker.endInFlightDirectSwitch() }
            guard self != nil, tracker.isCurrent(gen) else { return }
            if !succeeded || isKeyboardLayout {
                // Fall back to TISSelectInputSource on failure, or mirror plain keyboard layouts so menu bar stays in sync
                _ = TISSelectInputSource(source)
            }
            completion?()
        }
    }

    /// Emits an atomic `keyDown + keyUp` synthetic pulse using a clean `.privateState` event source
    /// so physically held Shift/Cmd/Opt modifiers never leak into the shortcut.
    @discardableResult
    private func postSyntheticHotkeyPulse(_ hotkey: SymbolicHotkeySpec) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPulseAt >= minPulseInterval else { return false }
        lastPulseAt = now

        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(hotkey.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(hotkey.keyCode), keyDown: false) else {
            return false
        }

        // Preserve hardware Caps Lock state while enforcing exact hotkey modifier flags on keyDown ONLY.
        // CRITICAL: On keyUp, restore ONLY live physically held modifiers from `.hidSystemState` (NEVER `.maskSecondaryFn`
        // or synthetic unheld modifiers), and post to `.cgSessionEventTap` so macOS WindowServer never latches Globe/Fn
        // or Ctrl/Cmd/Opt/Shift while still preserving real physical holds (e.g. holding Ctrl across Ctrl+Space)!
        let physicalFlags = VirtualKeyCode.currentPhysicalModifierFlags()
        var downFlags = hotkey.syntheticPulseFlags
        if physicalFlags.contains(.maskAlphaShift) {
            downFlags.insert(.maskAlphaShift)
        }

        down.flags = downFlags
        up.flags = physicalFlags
        for ev in [down, up] {
            ev.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        }

        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    private func resolveTargetTISSource(for language: InputLanguage) -> TISInputSource? {
        let sources = selectableKeyboardTISSources()
        switch language {
        case .korean:
            if let preferred = lastKoreanSourceID,
               let match = sources.first(where: { stringProperty($0, kTISPropertyInputSourceID) == preferred }) {
                return match
            }
            return sources.first { describe($0)?.language == .korean }
        case .english, .other:
            if let preferred = lastEnglishSourceID,
               let match = sources.first(where: { stringProperty($0, kTISPropertyInputSourceID) == preferred }) {
                return match
            }
            if let abc = sources.first(where: { stringProperty($0, kTISPropertyInputSourceID) == "com.apple.keylayout.ABC" }) {
                return abc
            }
            if let us = sources.first(where: { stringProperty($0, kTISPropertyInputSourceID) == "com.apple.keylayout.US" }) {
                return us
            }
            return sources.first { describe($0)?.language == .english }
        }
    }

    private func selectableKeyboardTISSources() -> [TISInputSource] {
        let filter = [
            kTISPropertyInputSourceIsEnabled as String: true,
            kTISPropertyInputSourceIsSelectCapable as String: true,
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
        ] as CFDictionary
        return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    private func describe(_ source: TISInputSource) -> InputSourceInfo? {
        guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
        let type = stringProperty(source, kTISPropertyInputSourceType) ?? ""
        let langs: [String]
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            langs = (Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]) ?? []
        } else {
            langs = []
        }
        return InputSourceInfo(
            id: id,
            localizedName: name,
            language: InputLanguage.classify(sourceID: id, languages: langs),
            isKeyboardLayout: type == (kTISTypeKeyboardLayout as String)
        )
    }

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

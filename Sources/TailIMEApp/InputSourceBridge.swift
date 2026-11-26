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

    private static func keyFocusPID() -> pid_t? {
        guard let keyFocus = sym("CPSGetKeyFocusProcess", KeyFocusFn.self),
              let psnToPID = sym("GetProcessPID", PSNToPIDFn.self) else {
            return nil
        }
        var psn = ProcessSerialNumber()
        var ignored: DarwinBoolean = false
        var pid: pid_t = -1
        guard keyFocus(&psn, &ignored) == 0,
              psnToPID(&psn, &pid) == noErr,
              pid > 0 else {
            return nil
        }
        return pid
    }

    /// Asks the currently key-focused app to switch directly to `source` via its TSM port.
    /// Returns false if private symbols are unavailable or the app does not reply cleanly.
    static func selectInFocusedApp(_ source: TISInputSource) -> Bool {
        guard let remotePort = sym("CFMessagePortCreatePerProcessRemote", RemotePortFn.self),
              let flatten = sym("_CreateFlattenedInputSource", FlattenFn.self),
              let pid = keyFocusPID() else {
            return false
        }

        var flatRef: Unmanaged<AnyObject>?
        guard flatten(source, &flatRef).boolValue,
              let flat = flatRef?.takeRetainedValue() else {
            return false
        }

        let request = ["tsmInputSourceSelectedInpSrcKey": flat] as CFDictionary
        guard let data = CFPropertyListCreateData(nil, request, .xmlFormat_v1_0, 0, nil)?.takeRetainedValue(),
              let port = remotePort(nil, "com.apple.tsm.portname" as CFString, pid)?.takeRetainedValue() else {
            return false
        }

        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            port, 7, data, 0.12, 0.12, CFRunLoopMode.defaultMode.rawValue, &reply
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
    private var switchGeneration: UInt64 = 0

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
        switchGeneration &+= 1
        let gen = switchGeneration
        pendingVerificationWork?.cancel()
        pendingVerificationWork = nil

        guard let hotkey = hotkeysSnapshot.preferredPulseHotkey else {
            completion?(currentInputSource())
            return
        }
        if !switcherWaker.isRunning {
            switcherWaker.checkAndWarmAsync(force: false)
        }
        _ = postSyntheticHotkeyPulse(hotkey)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.switchGeneration == gen else { return }
            completion?(self.currentInputSource())
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
        switchGeneration &+= 1
        let gen = switchGeneration
        pendingVerificationWork?.cancel()
        pendingVerificationWork = nil

        let current = currentInputSource()
        if let current, current.language == targetLang {
            completion?(current)
            return
        }

        guard let targetTIS = resolveTargetTISSource(for: targetLang) else {
            completion?(current)
            return
        }

        let enabledList = selectableKeyboardTISSources()
        let useFastPulse = allowHotkeyPulse
            && enabledList.count == 2
            && hotkeysSnapshot.preferredPulseHotkey != nil

        if useFastPulse, let hotkey = hotkeysSnapshot.preferredPulseHotkey {
            // Proactively kick TextInputSwitcher in background if it was killed by jetsam
            if !switcherWaker.isRunning {
                switcherWaker.checkAndWarmAsync(force: false)
            }
            if postSyntheticHotkeyPulse(hotkey) {
                // Verify arrival within 55ms; if macOS dropped the pulse (e.g., busy app or disabled symbolic hotkey),
                // fall back seamlessly to TSMDirectBridge / TISSelectInputSource!
                let verify = DispatchWorkItem { [weak self] in
                    guard let self, self.switchGeneration == gen else { return }
                    let nowInfo = self.currentInputSource()
                    if nowInfo?.language == targetLang {
                        completion?(nowInfo)
                        return
                    }
                    self.selectDirectly(targetTIS)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
                        completion?(self?.currentInputSource())
                    }
                }
                pendingVerificationWork = verify
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: verify)
                return
            }
        }

        // Direct path (used when remote viewer is focused for Auto-ABC, >2 input sources, or hotkey 60/61 disabled)
        selectDirectly(targetTIS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            completion?(self?.currentInputSource())
        }
    }

    /// Switches directly to a specific input source ID (used when restoring a saved local input source).
    func switchToSourceID(_ sourceID: String, allowHotkeyPulse: Bool = false) {
        switchGeneration &+= 1
        pendingVerificationWork?.cancel()
        pendingVerificationWork = nil

        if currentInputSource()?.id == sourceID { return }
        let list = selectableKeyboardTISSources()
        guard let target = list.first(where: { stringProperty($0, kTISPropertyInputSourceID) == sourceID }) else { return }
        if allowHotkeyPulse, list.count == 2, let hotkey = hotkeysSnapshot.preferredPulseHotkey {
            _ = postSyntheticHotkeyPulse(hotkey)
            return
        }
        selectDirectly(target)
    }

    private func selectDirectly(_ source: TISInputSource) {
        // First try TSMDirectBridge (macism trick — reliably activates Korean 2-Set in focused app)
        if !TSMDirectBridge.selectInFocusedApp(source) {
            _ = TISSelectInputSource(source)
        } else {
            // Also mirror via TISSelectInputSource for plain layouts if needed so menu bar stays in sync
            let info = describe(source)
            if info?.isKeyboardLayout == true {
                _ = TISSelectInputSource(source)
            }
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

        // Preserve hardware Caps Lock state while enforcing exact hotkey modifier flags
        let capsOn = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        var flags = hotkey.syntheticPulseFlags
        if capsOn {
            flags.insert(.maskAlphaShift)
        }

        for ev in [down, up] {
            ev.flags = flags
            ev.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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

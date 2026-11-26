import AppKit
import CoreGraphics
import CSystemBridge
import Foundation
import os
import TailIMECore

/// Immutable state snapshot read atomically by the O(µs) CGEventTap callback.
struct TapRuntimeSnapshot: Sendable {
    var enabled: Bool = true
    var paused: Bool = false
    var activeTriggers: [TriggerSpec] = []
    var carrierPair: CarrierPair = CarrierPair()
    var remoteContext: ActiveRemoteContext = ActiveRemoteContext()
    var hasActivePairedController: Bool = false // True ONLY after HMAC-authenticated session activity from a paired peer
    var localIsKorean: Bool = false
    var localHoldGateEnabled: Bool = true
    var remoteDirectHoldDuration: TimeInterval = 0 // Precomputed adaptive UDP hold cap (>0 only on Direct UDP)
    var remoteNextInBandCarrierKeyCode: Int64 = 0  // >0 when ready to inject in-band carrier synchronously in tap!
    var remoteUnpairedPassthrough: Bool = false    // True when remote peer is unpaired and fallback == .passthrough
    var swapBackquoteInKorean: Bool = false
    var escapeToEnglish: Bool = false
    var isRecordingTrigger: Bool = false
    var diagnosticsMonitorOpen: Bool = false
}

/// High-priority dedicated-thread dual CGEventTap controller:
/// - HID tap (`.cghidEventTap`): catches local physical/Karabiner keys BEFORE RustDesk/ScreenSharing session taps,
///   synchronously arms FIFO `holdGate` on trigger so zero keys slip past before switching!
/// - Session tap (`.cgSessionEventTap`): catches remote-daemon-injected in-band carrier keys (F16/F17/F20)
///   ONLY when an authenticated paired controller is active, synchronously arms `sessionHoldGate` so characters
///   arriving right after the carrier wait for the remote switch, and suppresses leaked raw triggers!
final class EventTapController {
    let syntheticMarker: Int64

    private var snapshotLock = os_unfair_lock_s()
    private var _snapshot = TapRuntimeSnapshot()

    // Owned exclusively by the dedicated tap thread's CFRunLoop (zero lock contention on hot path!)
    private var matcher = TriggerMatcher()
    private var holdGate = HoldGate<CGEvent>(maxBufferedEvents: 64)
    private var holdGateTimer: DispatchSourceTimer?
    private var sessionHoldGate = HoldGate<CGEvent>(maxBufferedEvents: 64)
    private var sessionHoldTimer: DispatchSourceTimer?
    private let holdTimerQueue = DispatchQueue(label: "com.tailime.holdgate-timer", qos: .userInteractive)
    private var pidNameCache: [Int64: String] = [:]
    private var recordingPendingMod: (keyCode: Int64, downAt: TimeInterval)?
    private var lastTriggerListSignature: [String] = []

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var hidTap: CFMachPort?
    private var sessionTap: CFMachPort?
    private var hidSource: CFRunLoopSource?
    private var sessionSource: CFRunLoopSource?

    private let actionQueue = DispatchQueue(label: "com.tailime.tap-actions", qos: .userInteractive)

    // Callbacks delivered asynchronously off the tap thread (never blocking the callback!)
    var onLocalTriggerFired: ((TriggerSpec, Bool, UInt64, Bool) -> Void)?                       // (spec, isOwned, holdGen, fromSessionTap)
    var onRemoteTriggerFired: ((TriggerSpec, Bool, ActiveRemoteContext, UInt64, Int64) -> Void)? // (spec, isOwned, ctx, holdGen, injectedCarrierKeyCode)
    var onInBandCarrierReceived: ((InputLanguage, String, UInt64) -> Void)?                // (targetLang, injector, sessionHoldGen)
    var onInBandProbeReceived: ((String, TimeInterval) -> Void)?                           // (injector, uptime)
    var onEscapeToEnglish: (() -> Void)?
    var onRecordedTrigger: ((TriggerSpec) -> Void)?
    var onDiagnosticEvent: ((String) -> Void)?
    var onTapStatusChanged: ((Bool, Bool) -> Void)?

    init(syntheticMarker: Int64) {
        self.syntheticMarker = syntheticMarker
    }

    deinit {
        stop()
    }

    func updateSnapshot(_ mutate: (inout TapRuntimeSnapshot) -> Void) {
        os_unfair_lock_lock(&snapshotLock)
        mutate(&_snapshot)
        os_unfair_lock_unlock(&snapshotLock)
    }

    func currentSnapshot() -> TapRuntimeSnapshot {
        os_unfair_lock_lock(&snapshotLock)
        let copy = _snapshot
        os_unfair_lock_unlock(&snapshotLock)
        return copy
    }

    func start() {
        guard tapThread == nil else { return }
        let thread = Thread { [weak self] in
            self?.runTapLoop()
        }
        thread.name = "com.tailime.eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    func stop() {
        flushHoldGateAsync(reason: .terminating, discard: false)
        flushSessionHoldGateAsync(reason: .terminating, discard: false)
        if let rl = tapRunLoop {
            CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                self?.teardownTapsOnTapThread()
                CFRunLoopStop(rl)
            }
            CFRunLoopWakeUp(rl)
        }
        tapThread = nil
        tapRunLoop = nil
    }

    func flushHoldGateAsync(
        reason: HoldGate<CGEvent>.FlushReason,
        expectedGeneration: UInt64? = nil,
        discard: Bool = false
    ) {
        guard let rl = tapRunLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let events: [CGEvent]
            if let expectedGeneration {
                guard let drained = self.holdGate.flushIfGeneration(expectedGeneration, reason: reason, discard: discard) else {
                    return
                }
                events = drained
            } else {
                events = self.holdGate.flush(reason: reason, discard: discard)
            }
            self.cancelHoldTimer()
            self.repostEvents(events, tap: .cghidEventTap)
        }
        CFRunLoopWakeUp(rl)
    }

    func flushSessionHoldGateAsync(
        reason: HoldGate<CGEvent>.FlushReason,
        expectedGeneration: UInt64? = nil,
        discard: Bool = false
    ) {
        guard let rl = tapRunLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let events: [CGEvent]
            if let expectedGeneration {
                guard let drained = self.sessionHoldGate.flushIfGeneration(expectedGeneration, reason: reason, discard: discard) else {
                    return
                }
                events = drained
            } else {
                events = self.sessionHoldGate.flush(reason: reason, discard: discard)
            }
            self.cancelSessionHoldTimer()
            self.repostEvents(events, tap: .cgSessionEventTap)
        }
        CFRunLoopWakeUp(rl)
    }

    /// Injects a clean in-band carrier key (e.g. F16/F17/F20) into `.cghidEventTap` so it enters
    /// the focused remote desktop client in exact FIFO order with the user's typing.
    func injectInBandCarrier(keyCode: Int64) {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return
        }
        for ev in [down, up] {
            ev.flags = [.maskSecondaryFn]
            ev.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Injects a fallback key or modifier tap for remote machines that do NOT run TailIME.
    /// If `action == .passthrough` and an owned trigger had been swallowed, re-injects `originalSpec`.
    func injectFallbackAction(_ action: FallbackResolvedAction, originalSpec: TriggerSpec? = nil) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        switch action {
        case .passthrough:
            if let spec = originalSpec, spec.kind == .ownedKey {
                injectFallbackAction(.sendKey(keyCode: spec.keyCode, modifiers: spec.modifiers), originalSpec: nil)
            }
            return
        case .sendKey(let keyCode, let modifiers):
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
                return
            }
            var flags = modifiers.cgEventFlags
            if VirtualKeyCode.functionKeys.contains(keyCode) {
                flags.insert(.maskSecondaryFn)
            }
            for ev in [down, up] {
                ev.flags = flags
                ev.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
                ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        case .sendModifierTap(let keyCode):
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
                return
            }
            down.type = .flagsChanged
            up.type = .flagsChanged
            if keyCode == VirtualKeyCode.rightOption {
                down.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
            } else if keyCode == VirtualKeyCode.rightCommand {
                down.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
            } else if keyCode == VirtualKeyCode.rightControl {
                down.flags = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
            }
            up.flags = []
            for ev in [down, up] {
                ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Dedicated Tap Thread

    private func runTapLoop() {
        let rl = CFRunLoopGetCurrent()
        tapRunLoop = rl

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)

        let info = Unmanaged.passUnretained(self).toOpaque()

        // Tap A: HID-level tap for local physical/Karabiner keys (ahead of all session taps!)
        hidTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()
                return owner.handleHIDEvent(type: type, event: event)
            },
            userInfo: info
        )

        if let hidTap {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, hidTap, 0)
            hidSource = src
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: hidTap, enable: true)
        }

        // Tap B: Session-level tap for remote-server-injected carrier keys, FIFO session hold, & leak suppression
        let sessionMask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        sessionTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: sessionMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()
                return owner.handleSessionEvent(type: type, event: event)
            },
            userInfo: info
        )

        if let sessionTap {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, sessionTap, 0)
            sessionSource = src
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: sessionTap, enable: true)
        }

        let hidOK = hidTap != nil
        let sessOK = sessionTap != nil
        DispatchQueue.main.async { [weak self] in
            self?.onTapStatusChanged?(hidOK, sessOK)
        }

        CFRunLoopRun()
        teardownTapsOnTapThread()
    }

    private func teardownTapsOnTapThread() {
        cancelHoldTimer()
        cancelSessionHoldTimer()
        repostEvents(holdGate.flush(reason: .terminating, discard: false), tap: .cghidEventTap)
        repostEvents(sessionHoldGate.flush(reason: .terminating, discard: false), tap: .cgSessionEventTap)
        matcher.resetGates()

        if let rl = tapRunLoop {
            if let src = hidSource { CFRunLoopRemoveSource(rl, src, .commonModes) }
            if let src = sessionSource { CFRunLoopRemoveSource(rl, src, .commonModes) }
        }
        if let tap = hidTap { CFMachPortInvalidate(tap) }
        if let tap = sessionTap { CFMachPortInvalidate(tap) }
        hidSource = nil
        sessionSource = nil
        hidTap = nil
        sessionTap = nil
    }

    // MARK: - HID Tap Callback (Strictly O(µs), Non-Blocking!)

    private func handleHIDEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let hidTap { CGEvent.tapEnable(tap: hidTap, enable: true) }
            matcher.resetGates()
            let drained = holdGate.flush(reason: .tapDisabled, discard: false)
            cancelHoldTimer()
            repostEvents(drained, tap: .cghidEventTap)
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let snap = currentSnapshot()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = NormalizedModifiers(cgFlags: event.flags)
        let now = ProcessInfo.processInfo.systemUptime

        if snap.diagnosticsMonitorOpen && (type == .keyDown || type == .flagsChanged) {
            let srcPID = event.getIntegerValueField(.eventSourceUnixProcessID)
            let kindStr = (type == .keyDown) ? "keyDown" : "flagsChanged"
            let label = VirtualKeyCode.displayName(for: keyCode)
            let msg = "[HID] \(kindStr) code=\(keyCode) (\(label)) mods=\(mods.displayPrefix.isEmpty ? "none" : mods.displayPrefix) srcPID=\(srcPID)"
            actionQueue.async { [weak self] in self?.onDiagnosticEvent?(msg) }
        }

        if snap.isRecordingTrigger {
            return handleRecordingEvent(type: type, keyCode: keyCode, mods: mods, rawFlags: event.flags.rawValue, now: now, event: event)
        }

        guard snap.enabled && !snap.paused else {
            if holdGate.isArmed {
                let drained = holdGate.flush(reason: .manualReset, discard: false)
                cancelHoldTimer()
                repostEvents(drained, tap: .cghidEventTap)
            }
            return Unmanaged.passUnretained(event)
        }

        let srcPID = event.getIntegerValueField(.eventSourceUnixProcessID)
        if srcPID != 0 && isRemoteHostServerPID(srcPID) {
            return Unmanaged.passUnretained(event)
        }

        let sig = snap.activeTriggers.map(\.id)
        if sig != lastTriggerListSignature {
            matcher.updateTriggers(snap.activeTriggers)
            lastTriggerListSignature = sig
        }

        // Mouse click cancels pending modifier taps and discards buffered keyDowns
        // while STILL emitting any safe release events (orphan keyUps / flagsChanged) so nothing sticks!
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            _ = matcher.process(KeyEventSample(kind: .mouseDown, keyCode: 0, timestamp: now))
            if holdGate.isArmed {
                let safeReleases = holdGate.flush(reason: .focusChanged, discard: true)
                cancelHoldTimer()
                repostEvents(safeReleases, tap: .cghidEventTap)
            }
            return Unmanaged.passUnretained(event)
        }

        let sampleKind: KeyEventSample.Kind
        switch type {
        case .keyDown: sampleKind = .keyDown
        case .keyUp: sampleKind = .keyUp
        case .flagsChanged: sampleKind = .flagsChanged
        default: return Unmanaged.passUnretained(event)
        }

        let repeated = (type == .keyDown) && (event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        let sample = KeyEventSample(
            kind: sampleKind,
            keyCode: keyCode,
            modifiers: mods,
            rawFlags: event.flags.rawValue,
            isAutoRepeat: repeated,
            timestamp: now
        )

        let decision = matcher.process(sample)

        switch decision {
        case .swallowOnly:
            return nil

        case .fireOwned(let spec):
            if snap.remoteContext.hasActiveRemoteSession {
                if snap.remoteUnpairedPassthrough {
                    matcher.releaseSwallowed(spec.keyCode)
                    return Unmanaged.passUnretained(event)
                }
                var holdGen: UInt64 = 0
                var injectedCarrier: Int64 = 0
                if snap.remoteNextInBandCarrierKeyCode != 0 {
                    // Synchronously inject in-band carrier BEFORE returning from HID tap so zero subsequent keys overtake it!
                    injectedCarrier = snap.remoteNextInBandCarrierKeyCode
                    injectInBandCarrier(keyCode: injectedCarrier)
                    // Optimistically alternate next carrier on tap thread for rapid double-taps
                    let nextKey = (injectedCarrier == snap.carrierPair.koreanKeyCode)
                        ? snap.carrierPair.englishKeyCode
                        : snap.carrierPair.koreanKeyCode
                    updateSnapshot { s in
                        if s.remoteNextInBandCarrierKeyCode == injectedCarrier {
                            s.remoteNextInBandCarrierKeyCode = nextKey
                        }
                    }
                } else if snap.remoteDirectHoldDuration > 0 {
                    holdGen = armHoldGateOnTapThread(maxDuration: snap.remoteDirectHoldDuration, now: now)
                }
                actionQueue.async { [weak self] in
                    self?.onRemoteTriggerFired?(spec, true, snap.remoteContext, holdGen, injectedCarrier)
                }
            } else {
                var holdGen: UInt64 = 0
                if snap.localHoldGateEnabled {
                    holdGen = armHoldGateOnTapThread(maxDuration: 0.028, now: now)
                }
                actionQueue.async { [weak self] in
                    self?.onLocalTriggerFired?(spec, true, holdGen, false)
                }
            }
            return nil

        case .fireObserved(let spec):
            if snap.remoteContext.hasActiveRemoteSession {
                var holdGen: UInt64 = 0
                var injectedCarrier: Int64 = 0
                if !snap.remoteUnpairedPassthrough {
                    if snap.remoteNextInBandCarrierKeyCode != 0 {
                        injectedCarrier = snap.remoteNextInBandCarrierKeyCode
                        injectInBandCarrier(keyCode: injectedCarrier)
                        let nextKey = (injectedCarrier == snap.carrierPair.koreanKeyCode)
                            ? snap.carrierPair.englishKeyCode
                            : snap.carrierPair.koreanKeyCode
                        updateSnapshot { s in
                            if s.remoteNextInBandCarrierKeyCode == injectedCarrier {
                                s.remoteNextInBandCarrierKeyCode = nextKey
                            }
                        }
                    } else if snap.remoteDirectHoldDuration > 0 {
                        holdGen = armHoldGateOnTapThread(maxDuration: snap.remoteDirectHoldDuration, now: now)
                    }
                }
                actionQueue.async { [weak self] in
                    self?.onRemoteTriggerFired?(spec, false, snap.remoteContext, holdGen, injectedCarrier)
                }
            } else if spec.kind == .modifierTap {
                var holdGen: UInt64 = 0
                if snap.localHoldGateEnabled {
                    holdGen = armHoldGateOnTapThread(maxDuration: 0.028, now: now)
                }
                actionQueue.async { [weak self] in
                    self?.onLocalTriggerFired?(spec, false, holdGen, false)
                }
            }
            return Unmanaged.passUnretained(event)

        case .passThrough:
            break
        }

        // Optional local conveniences (only when NOT controlling a remote desktop session)
        if !snap.remoteContext.hasActiveRemoteSession {
            if snap.escapeToEnglish,
               type == .keyDown,
               !repeated,
               keyCode == VirtualKeyCode.escape,
               mods.isEmpty,
               snap.localIsKorean {
                actionQueue.async { [weak self] in self?.onEscapeToEnglish?() }
            }

            if snap.swapBackquoteInKorean,
               snap.localIsKorean,
               (type == .keyDown || type == .keyUp),
               keyCode == VirtualKeyCode.grave,
               mods.isEmpty {
                var backtick: UniChar = 0x0060
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &backtick)
            }
        }

        // Strict FIFO HoldGate: while armed, buffer ALL keyDown/keyUp/repeat/flagsChanged with metadata!
        if holdGate.isArmed, let copy = event.copy() {
            let holdKind = holdGateKind(for: type, repeated: repeated)
            let (buffered, overflow) = holdGate.enqueueIfArmed(copy, kind: holdKind, keyCode: keyCode, now: now)
            if let overflow {
                cancelHoldTimer()
                repostEvents(overflow, tap: .cghidEventTap)
            }
            if buffered {
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Session Tap Callback (Remote Host Receiver: Authenticated In-Band Carriers + FIFO Hold + Anti-Leak)

    private func handleSessionEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let sessionTap { CGEvent.tapEnable(tap: sessionTap, enable: true) }
            let drained = sessionHoldGate.flush(reason: .tapDisabled, discard: false)
            cancelSessionHoldTimer()
            repostEvents(drained, tap: .cgSessionEventTap)
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let snap = currentSnapshot()
        guard snap.enabled && !snap.paused else {
            if sessionHoldGate.isArmed {
                let drained = sessionHoldGate.flush(reason: .manualReset, discard: false)
                cancelSessionHoldTimer()
                repostEvents(drained, tap: .cgSessionEventTap)
            }
            return Unmanaged.passUnretained(event)
        }

        let srcPID = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard srcPID != 0 else {
            return Unmanaged.passUnretained(event)
        }

        let injectorName = processName(for: srcPID)
        guard isRemoteHostServerName(injectorName) else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = NormalizedModifiers(cgFlags: event.flags)
        let now = ProcessInfo.processInfo.systemUptime
        let repeated = (type == .keyDown) && (event.getIntegerValueField(.keyboardEventAutorepeat) != 0)

        if snap.diagnosticsMonitorOpen && type == .keyDown {
            let msg = "[SESSION] Remote-injected keyDown code=\(keyCode) (\(VirtualKeyCode.displayName(for: keyCode))) from \(injectorName) (pid \(srcPID)) paired=\(snap.hasActivePairedController)"
            actionQueue.async { [weak self] in self?.onDiagnosticEvent?(msg) }
        }

        // Security gate: ONLY trust in-band carrier / probe F-keys when an HMAC-authenticated paired controller is active!
        if snap.hasActivePairedController {
            // 1. In-Band Probe Carrier (default F20)
            if (type == .keyDown || type == .keyUp) && keyCode == snap.carrierPair.probeKeyCode && mods.isEmpty {
                if type == .keyDown && !repeated {
                    actionQueue.async { [weak self] in
                        self?.onInBandProbeReceived?(injectorName, now)
                    }
                }
                return nil
            }

            // 2. In-Band Language Carrier (default F16 = Korean, F17 = English)
            if (type == .keyDown || type == .keyUp) && mods.isEmpty, let targetLang = snap.carrierPair.language(for: keyCode) {
                if type == .keyDown && !repeated {
                    // Synchronously arm sessionHoldGate so characters right behind the carrier wait for the switch!
                    let sessionGen = armSessionHoldGateOnTapThread(maxDuration: 0.032, now: now)
                    actionQueue.async { [weak self] in
                        self?.onInBandCarrierReceived?(targetLang, injectorName, sessionGen)
                    }
                }
                return nil
            }

            // 3. Anti-Leak Guard: suppress leaked raw triggers (e.g. F18) from the paired controller
            if type == .keyDown || type == .keyUp {
                let isOwnedTrigger = snap.activeTriggers.contains {
                    $0.kind == .ownedKey && $0.keyCode == keyCode && $0.modifiers == mods
                }
                if isOwnedTrigger {
                    return nil
                }
            }
        } else {
            // Unpaired client (e.g. Windows PC or Mac without TailIME): allow recognized Hangul/trigger keys to switch locally
            if type == .keyDown && !repeated {
                let matchesTrigger = snap.activeTriggers.first {
                    $0.kind == .ownedKey && $0.keyCode == keyCode && $0.modifiers == mods
                }
                if let spec = matchesTrigger {
                    let sessionGen = armSessionHoldGateOnTapThread(maxDuration: 0.028, now: now)
                    actionQueue.async { [weak self] in
                        self?.onLocalTriggerFired?(spec, true, sessionGen, true)
                    }
                    return nil
                }
            } else if type == .keyUp {
                let matchesTrigger = snap.activeTriggers.contains {
                    $0.kind == .ownedKey && $0.keyCode == keyCode && $0.modifiers == mods
                }
                if matchesTrigger {
                    return nil
                }
            }
        }

        // Strict FIFO sessionHoldGate: hold remote-injected keys arriving right after a carrier until switch lands!
        if sessionHoldGate.isArmed, let copy = event.copy() {
            let holdKind = holdGateKind(for: type, repeated: repeated)
            let (buffered, overflow) = sessionHoldGate.enqueueIfArmed(copy, kind: holdKind, keyCode: keyCode, now: now)
            if let overflow {
                cancelSessionHoldTimer()
                repostEvents(overflow, tap: .cgSessionEventTap)
            }
            if buffered {
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Key Recording Helper

    private func handleRecordingEvent(
        type: CGEventType,
        keyCode: Int64,
        mods: NormalizedModifiers,
        rawFlags: UInt64,
        now: TimeInterval,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            recordingPendingMod = nil
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            if keyCode == VirtualKeyCode.escape && mods.isEmpty {
                updateSnapshot { $0.isRecordingTrigger = false }
                return nil
            }
            let spec = TriggerSpec(keyCode: keyCode, modifiers: mods, kind: .ownedKey, origin: .userRecorded)
            updateSnapshot { $0.isRecordingTrigger = false }
            DispatchQueue.main.async { [weak self] in
                self?.onRecordedTrigger?(spec)
            }
            return nil
        }
        if type == .keyUp {
            return nil
        }
        if type == .flagsChanged {
            if VirtualKeyCode.rightModifierKeys.contains(keyCode) {
                let down = !mods.isEmpty
                if down {
                    recordingPendingMod = (keyCode, now)
                } else if let pending = recordingPendingMod, pending.keyCode == keyCode, now - pending.downAt < 0.5 {
                    recordingPendingMod = nil
                    let spec = TriggerSpec(keyCode: keyCode, modifiers: [], kind: .modifierTap, origin: .userRecorded)
                    updateSnapshot { $0.isRecordingTrigger = false }
                    DispatchQueue.main.async { [weak self] in
                        self?.onRecordedTrigger?(spec)
                    }
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - HoldGate Helpers (Always called on tap thread)

    private func armHoldGateOnTapThread(maxDuration: TimeInterval, now: TimeInterval) -> UInt64 {
        let gen = holdGate.arm(now: now, maxDuration: maxDuration)
        scheduleHoldTimeout(generation: gen, delay: maxDuration)
        return gen
    }

    private func armSessionHoldGateOnTapThread(maxDuration: TimeInterval, now: TimeInterval) -> UInt64 {
        let gen = sessionHoldGate.arm(now: now, maxDuration: maxDuration)
        scheduleSessionHoldTimeout(generation: gen, delay: maxDuration)
        return gen
    }

    private func scheduleHoldTimeout(generation: UInt64, delay: TimeInterval) {
        cancelHoldTimer()
        let timer = DispatchSource.makeTimerSource(queue: holdTimerQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.flushHoldGateAsync(reason: .timeout, expectedGeneration: generation, discard: false)
        }
        timer.resume()
        holdGateTimer = timer
    }

    private func cancelHoldTimer() {
        holdGateTimer?.cancel()
        holdGateTimer = nil
    }

    private func scheduleSessionHoldTimeout(generation: UInt64, delay: TimeInterval) {
        cancelSessionHoldTimer()
        let timer = DispatchSource.makeTimerSource(queue: holdTimerQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.flushSessionHoldGateAsync(reason: .timeout, expectedGeneration: generation, discard: false)
        }
        timer.resume()
        sessionHoldTimer = timer
    }

    private func cancelSessionHoldTimer() {
        sessionHoldTimer?.cancel()
        sessionHoldTimer = nil
    }

    private func holdGateKind(for type: CGEventType, repeated: Bool) -> HoldGateEventKind {
        switch type {
        case .keyDown: return repeated ? .autoRepeat : .keyDown
        case .keyUp: return .keyUp
        default: return .flagsChanged
        }
    }

    private func repostEvents(_ events: [CGEvent], tap: CGEventTapLocation) {
        guard !events.isEmpty else { return }
        for ev in events {
            ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            ev.post(tap: tap)
        }
    }

    // MARK: - Process Name Lookup (Cached)

    private func processName(for pid: Int64) -> String {
        if let cached = pidNameCache[pid] { return cached }
        var buf = [CChar](repeating: 0, count: 1024)
        let name: String
        if tailime_pid_path(pid_t(pid), &buf, Int32(buf.count)) {
            let path = String(cString: buf)
            name = (path as NSString).lastPathComponent
        } else {
            name = ""
        }
        if pidNameCache.count > 128 {
            pidNameCache.removeAll(keepingCapacity: true)
        }
        pidNameCache[pid] = name
        return name
    }

    private func isRemoteHostServerPID(_ pid: Int64) -> Bool {
        isRemoteHostServerName(processName(for: pid))
    }

    private func isRemoteHostServerName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return RemoteViewerCatalog.hostServerProcessNames.contains { lower.contains($0) }
    }
}

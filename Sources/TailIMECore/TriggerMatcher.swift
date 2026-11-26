import CoreGraphics
import Foundation

/// High-level action decided by the O(µs) event tap trigger engine.
public enum TriggerDecision: Equatable, Sendable {
    case passThrough
    case swallowOnly
    case fireOwned(TriggerSpec)      // Swallow original key and execute switch (local or remote)
    case fireObserved(TriggerSpec)   // Never swallow flagsChanged; execute observed action (remote only or sync)
}

/// Event abstraction so TriggerMatcher is 100% unit-testable without requiring real CGEvents.
public struct KeyEventSample: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyDown
        case keyUp
        case flagsChanged
        case mouseDown
    }

    public let kind: Kind
    public let keyCode: Int64
    public let modifiers: NormalizedModifiers
    public let rawFlags: UInt64
    public let isAutoRepeat: Bool
    public let timestamp: TimeInterval

    public init(
        kind: Kind,
        keyCode: Int64,
        modifiers: NormalizedModifiers = [],
        rawFlags: UInt64 = 0,
        isAutoRepeat: Bool = false,
        timestamp: TimeInterval
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.rawFlags = rawFlags
        self.isAutoRepeat = isAutoRepeat
        self.timestamp = timestamp
    }
}

/// Builds the active deduplicated list of triggers from user settings + auto-discovered sources.
public enum TriggerResolver {
    public static func resolveActiveTriggers(
        settings: AppSettings,
        systemHotkeys: InputSourceHotkeysSnapshot,
        karabiner: KarabinerDiscoveryResult
    ) -> [TriggerSpec] {
        var result: [TriggerSpec] = []
        var seen: Set<String> = []

        func append(_ spec: TriggerSpec) {
            if seen.insert(spec.id).inserted {
                result.append(spec)
            }
        }

        // 1. Explicit user-recorded or preset triggers have highest priority
        for spec in settings.userTriggers {
            append(spec)
        }

        // 2. System symbolic hotkey 60 (previous input source).
        // Keep hotkey 61 ("next input source") untouched when hotkey 60 is enabled so multi-source
        // users keep macOS's distinct 60 vs 61 semantics intact!
        if settings.autoDetectSystemHotkey {
            if let prev = systemHotkeys.previousSource, prev.enabled {
                append(prev.asTriggerSpec)
            } else if let next = systemHotkeys.nextSource, next.enabled {
                append(next.asTriggerSpec)
            }
            if systemHotkeys.capsLockSwitchesToABC {
                append(TriggerSpec(
                    keyCode: VirtualKeyCode.capsLock,
                    modifiers: [],
                    kind: .systemObserved,
                    origin: .systemHotkey
                ))
            }
            if systemHotkeys.fnKeyChangesInputSource {
                append(TriggerSpec(
                    keyCode: VirtualKeyCode.functionKey,
                    modifiers: [],
                    kind: .systemObserved,
                    origin: .systemHotkey
                ))
            }
        }

        // 3. Karabiner-Elements auto-discovered output keys (e.g., F18, F19)
        if settings.autoDetectKarabiner {
            for spec in karabiner.detectedTriggers {
                append(spec)
            }
        }

        // 4. Hardware Korean Hangul (Lang1) key
        if settings.autoDetectHardwareHangul {
            append(TriggerSpec(
                keyCode: VirtualKeyCode.lang1Hangul,
                modifiers: [],
                kind: .ownedKey,
                origin: .hardwareDefault
            ))
        }

        return result
    }

    /// Selects a conflict-free in-band carrier pair (Korean, English, Probe) avoiding all active triggers
    /// and system symbolic hotkeys.
    public static func safeCarrierPair(
        preferred: CarrierPair,
        avoidingTriggers: [TriggerSpec],
        systemHotkeys: InputSourceHotkeysSnapshot
    ) -> CarrierPair {
        var used: Set<Int64> = Set(avoidingTriggers.filter { $0.modifiers.isEmpty }.map(\.keyCode))
        if let prev = systemHotkeys.previousSource, prev.enabled, prev.modifiers.isEmpty {
            used.insert(prev.keyCode)
        }
        if let next = systemHotkeys.nextSource, next.enabled, next.modifiers.isEmpty {
            used.insert(next.keyCode)
        }

        // Candidate F-keys ordered from least commonly used by users/Karabiner
        let candidates: [Int64] = [
            VirtualKeyCode.f16, VirtualKeyCode.f17, VirtualKeyCode.f20,
            VirtualKeyCode.f13, VirtualKeyCode.f14, VirtualKeyCode.f15,
            VirtualKeyCode.f19, VirtualKeyCode.f18
        ]

        func pick(_ desired: Int64, excluding: Set<Int64>) -> Int64 {
            if !used.contains(desired) && !excluding.contains(desired) {
                return desired
            }
            return candidates.first(where: { !used.contains($0) && !excluding.contains($0) }) ?? desired
        }

        let ko = pick(preferred.koreanKeyCode, excluding: [])
        let en = pick(preferred.englishKeyCode, excluding: [ko])
        let probe = pick(preferred.probeKeyCode, excluding: [ko, en])
        return CarrierPair(koreanKeyCode: ko, englishKeyCode: en, probeKeyCode: probe)
    }
}

/// Deterministic, allocation-light state machine evaluated inside the EventTap callback.
public struct TriggerMatcher: Sendable {
    public static let modifierTapMaxDuration: TimeInterval = 0.32

    private var ownedTriggers: [TriggerSpec] = []
    private var modifierTapTriggers: [Int64: TriggerSpec] = [:]
    private var observedTriggers: [Int64: TriggerSpec] = [:]

    /// Keycodes whose keyDown we swallowed; their repeats and keyUp MUST also be swallowed
    /// even if trigger settings change before release.
    private var swallowedDown: Set<Int64> = []

    /// Tracks whether the user typed any non-Space key while Shift was held (prevents accidental Shift+Space).
    private var typedWithShift: Bool = false

    /// Tracks an in-progress standalone modifier tap (e.g. Right Cmd / Right Opt / Right Ctrl).
    private struct PendingModifierTap: Sendable {
        let keyCode: Int64
        let downAt: TimeInterval
        var cancelled: Bool
    }
    private var pendingModTap: PendingModifierTap?

    /// Last observed CapsLock/Fn flag states for edge detection.
    private var lastCapsBit: Bool = false
    private var lastFnBit: Bool = false

    public init(triggers: [TriggerSpec] = []) {
        updateTriggers(triggers)
    }

    public mutating func updateTriggers(_ triggers: [TriggerSpec]) {
        ownedTriggers = triggers.filter { $0.kind == .ownedKey }
        modifierTapTriggers = Dictionary(
            triggers.filter { $0.kind == .modifierTap }.map { ($0.keyCode, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        observedTriggers = Dictionary(
            triggers.filter { $0.kind == .systemObserved }.map { ($0.keyCode, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Must be called whenever the EventTap is disabled/re-enabled or focus/session resets.
    public mutating func resetGates() {
        swallowedDown.removeAll()
        pendingModTap = nil
        typedWithShift = false
    }

    /// Releases a keyCode from `swallowedDown` when the caller chooses to pass the original event through.
    public mutating func releaseSwallowed(_ keyCode: Int64) {
        swallowedDown.remove(keyCode)
    }

    public mutating func process(_ event: KeyEventSample) -> TriggerDecision {
        // Any mouse press cancels a pending standalone modifier tap (e.g. RightCmd + Click).
        if event.kind == .mouseDown {
            pendingModTap?.cancelled = true
            return .passThrough
        }

        // Track Shift typing state (matches gksdud SpaceComboGate guard).
        if !event.modifiers.contains(.shift) {
            typedWithShift = false
        } else if event.kind == .keyDown && event.keyCode != VirtualKeyCode.space {
            typedWithShift = true
        }

        switch event.kind {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            // Any regular keyDown cancels a pending standalone modifier tap.
            pendingModTap?.cancelled = true
            return handleKeyDown(event)
        case .keyUp:
            return handleKeyUp(event)
        case .mouseDown:
            return .passThrough
        }
    }

    private mutating func handleKeyDown(_ event: KeyEventSample) -> TriggerDecision {
        if swallowedDown.contains(event.keyCode) {
            // Swallow autorepeat or duplicate down while owned key is held.
            return .swallowOnly
        }
        guard !event.isAutoRepeat else {
            return .passThrough
        }

        for spec in ownedTriggers {
            guard spec.keyCode == event.keyCode else { continue }
            guard spec.modifiers == event.modifiers else { continue }

            // Guard Shift+Space when user was actively typing uppercase letters under the same Shift hold.
            if spec.keyCode == VirtualKeyCode.space && spec.modifiers == .shift && typedWithShift {
                continue
            }

            swallowedDown.insert(event.keyCode)
            return .fireOwned(spec)
        }
        return .passThrough
    }

    private mutating func handleKeyUp(_ event: KeyEventSample) -> TriggerDecision {
        if swallowedDown.remove(event.keyCode) != nil {
            return .swallowOnly
        }
        return .passThrough
    }

    private mutating func handleFlagsChanged(_ event: KeyEventSample) -> TriggerDecision {
        // 1. Observed system keys (Caps Lock / Fn-Globe): NEVER swallow flagsChanged!
        if let obsSpec = observedTriggers[event.keyCode] {
            if event.keyCode == VirtualKeyCode.capsLock {
                let capsNow = (event.rawFlags & CGEventFlags.maskAlphaShift.rawValue) != 0
                let changed = capsNow != lastCapsBit
                lastCapsBit = capsNow
                // Fire on Caps Lock state transition (actual press); never swallow.
                return changed ? .fireObserved(obsSpec) : .passThrough
            }
            if event.keyCode == VirtualKeyCode.functionKey || event.keyCode == VirtualKeyCode.globe {
                let fnNow = (event.rawFlags & CGEventFlags.maskSecondaryFn.rawValue) != 0
                let pressed = fnNow && !lastFnBit
                lastFnBit = fnNow
                return pressed ? .fireObserved(obsSpec) : .passThrough
            }
        }

        // 2. Standalone modifier tap triggers (Right Cmd / Right Opt / Right Ctrl)
        if let tapSpec = modifierTapTriggers[event.keyCode] {
            let isKeyDown = isModifierDown(keyCode: event.keyCode, rawFlags: event.rawFlags, modifiers: event.modifiers)
            if isKeyDown {
                // Only start a clean tap if no other modifier is currently held alongside it.
                let expectedSingleMod = expectedModifierFlag(for: event.keyCode)
                if event.modifiers == expectedSingleMod {
                    pendingModTap = PendingModifierTap(
                        keyCode: event.keyCode,
                        downAt: event.timestamp,
                        cancelled: false
                    )
                } else {
                    pendingModTap?.cancelled = true
                }
            } else if let pending = pendingModTap, pending.keyCode == event.keyCode {
                pendingModTap = nil
                let elapsed = event.timestamp - pending.downAt
                if !pending.cancelled && elapsed >= 0 && elapsed <= Self.modifierTapMaxDuration {
                    return .fireObserved(tapSpec)
                }
            }
            return .passThrough
        }

        // Pressing any OTHER modifier cancels a pending modifier tap (e.g. RightCmd + Shift).
        if pendingModTap != nil {
            pendingModTap?.cancelled = true
        }
        return .passThrough
    }

    private func expectedModifierFlag(for keyCode: Int64) -> NormalizedModifiers {
        switch keyCode {
        case VirtualKeyCode.rightCommand, VirtualKeyCode.leftCommand: return .command
        case VirtualKeyCode.rightOption, VirtualKeyCode.leftOption: return .option
        case VirtualKeyCode.rightControl, VirtualKeyCode.leftControl: return .control
        case VirtualKeyCode.rightShift, VirtualKeyCode.leftShift: return .shift
        default: return []
        }
    }

    private func isModifierDown(keyCode: Int64, rawFlags: UInt64, modifiers: NormalizedModifiers) -> Bool {
        // macOS NX device-specific modifier bitmasks (from IOLLEvent.h):
        // NX_DEVICERCMDKEYMASK = 0x10, NX_DEVICELCMDKEYMASK = 0x08
        // NX_DEVICERALTKEYMASK = 0x40, NX_DEVICELALTKEYMASK = 0x20
        // NX_DEVICERCTLKEYMASK = 0x2000, NX_DEVICELCTLKEYMASK = 0x01
        switch keyCode {
        case VirtualKeyCode.rightCommand:
            let deviceBit = (rawFlags & 0x10) != 0
            return modifiers.contains(.command) && (deviceBit || (rawFlags & 0x08) == 0)
        case VirtualKeyCode.rightOption:
            let deviceBit = (rawFlags & 0x40) != 0
            return modifiers.contains(.option) && (deviceBit || (rawFlags & 0x20) == 0)
        case VirtualKeyCode.rightControl:
            let deviceBit = (rawFlags & 0x2000) != 0
            return modifiers.contains(.control) && (deviceBit || (rawFlags & 0x01) == 0)
        default:
            return modifiers.contains(expectedModifierFlag(for: keyCode))
        }
    }
}

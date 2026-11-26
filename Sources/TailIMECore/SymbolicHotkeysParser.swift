import CoreGraphics
import Foundation

/// Read-only representation of a macOS symbolic hotkey entry (60 = previous input source, 61 = next input source).
public struct SymbolicHotkeySpec: Equatable, Sendable {
    public let id: String
    public let enabled: Bool
    public let keyCode: Int64
    public let rawModifiers: UInt64
    public let modifiers: NormalizedModifiers

    public init(id: String, enabled: Bool, keyCode: Int64, rawModifiers: UInt64) {
        self.id = id
        self.enabled = enabled
        self.keyCode = keyCode
        self.rawModifiers = rawModifiers
        self.modifiers = NormalizedModifiers(cgFlags: CGEventFlags(rawValue: rawModifiers))
    }

    public var isFunctionKey: Bool {
        VirtualKeyCode.functionKeys.contains(keyCode)
    }

    /// Flags required when synthesizing a CGEvent pulse for this symbolic hotkey.
    public var syntheticPulseFlags: CGEventFlags {
        var flags = modifiers.cgEventFlags
        if isFunctionKey {
            flags.insert(.maskSecondaryFn)
        }
        return flags
    }

    public var asTriggerSpec: TriggerSpec {
        TriggerSpec(
            keyCode: keyCode,
            modifiers: modifiers,
            kind: .ownedKey,
            origin: .systemHotkey
        )
    }
}

public struct InputSourceHotkeysSnapshot: Equatable, Sendable {
    public let previousSource: SymbolicHotkeySpec? // ID "60"
    public let nextSource: SymbolicHotkeySpec?     // ID "61"
    public let capsLockSwitchesToABC: Bool         // TISRomanSwitchState
    public let fnKeyChangesInputSource: Bool       // AppleFnUsageType == 1

    public init(
        previousSource: SymbolicHotkeySpec?,
        nextSource: SymbolicHotkeySpec?,
        capsLockSwitchesToABC: Bool,
        fnKeyChangesInputSource: Bool
    ) {
        self.previousSource = previousSource
        self.nextSource = nextSource
        self.capsLockSwitchesToABC = capsLockSwitchesToABC
        self.fnKeyChangesInputSource = fnKeyChangesInputSource
    }

    /// Best active native symbolic hotkey to synthesize for fast local switching (prefers 60, falls back to 61).
    public var preferredPulseHotkey: SymbolicHotkeySpec? {
        if let prev = previousSource, prev.enabled, prev.keyCode != VirtualKeyCode.f20 {
            return prev
        }
        if let next = nextSource, next.enabled, next.keyCode != VirtualKeyCode.f20 {
            return next
        }
        return nil
    }
}

public enum SymbolicHotkeysParser {
    /// Parses raw `AppleSymbolicHotKeys` dictionary (e.g., from `com.apple.symbolichotkeys`) without modifying anything.
    public static func parse(
        hotkeysDict: [String: Any],
        capsLockSwitchesToABC: Bool = false,
        fnKeyChangesInputSource: Bool = false
    ) -> InputSourceHotkeysSnapshot {
        let prev = parseEntry(id: "60", raw: hotkeysDict["60"])
        let next = parseEntry(id: "61", raw: hotkeysDict["61"])
        return InputSourceHotkeysSnapshot(
            previousSource: prev,
            nextSource: next,
            capsLockSwitchesToABC: capsLockSwitchesToABC,
            fnKeyChangesInputSource: fnKeyChangesInputSource
        )
    }

    public static func parseEntry(id: String, raw: Any?) -> SymbolicHotkeySpec? {
        guard let entry = raw as? [String: Any],
              let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [NSNumber],
              params.count >= 3 else {
            return nil
        }
        let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? false
        let keyCode = params[1].int64Value
        let rawMods = params[2].uint64Value
        guard keyCode >= 0, keyCode != 65535 else { return nil }
        return SymbolicHotkeySpec(
            id: id,
            enabled: enabled,
            keyCode: keyCode,
            rawModifiers: rawMods
        )
    }

    /// Reads live macOS preferences (read-only).
    public static func readSystem() -> InputSourceHotkeysSnapshot {
        let hotkeyDomain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(hotkeyDomain)
        let dict = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, hotkeyDomain) as? [String: Any] ?? [:]

        let hitoolboxDomain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(hitoolboxDomain)
        let fnUsage = (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, hitoolboxDomain) as? NSNumber)?.intValue ?? 0

        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let capsGlobalCF = CFPreferencesCopyAppValue("TISRomanSwitchState" as CFString, kCFPreferencesAnyApplication) as? NSNumber
        let capsGlobalUD = UserDefaults.standard.object(forKey: "TISRomanSwitchState") as? NSNumber
        let capsHIToolbox = CFPreferencesCopyAppValue("TISRomanSwitchState" as CFString, hitoolboxDomain) as? NSNumber
        let capsEnabled = (capsGlobalCF?.boolValue ?? false)
            || (capsGlobalUD?.boolValue ?? false)
            || (capsHIToolbox?.boolValue ?? false)

        return parse(
            hotkeysDict: dict,
            capsLockSwitchesToABC: capsEnabled,
            fnKeyChangesInputSource: fnUsage == 1
        )
    }
}

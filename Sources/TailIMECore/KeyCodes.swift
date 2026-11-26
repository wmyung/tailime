import CoreGraphics
import Foundation

/// Canonical macOS virtual key codes and HID usage IDs relevant to Korean/English switching.
public enum VirtualKeyCode {
    public static let space: Int64 = 49
    public static let escape: Int64 = 53
    public static let rightCommand: Int64 = 54
    public static let leftCommand: Int64 = 55
    public static let leftShift: Int64 = 56
    public static let capsLock: Int64 = 57
    public static let leftOption: Int64 = 58
    public static let leftControl: Int64 = 59
    public static let rightShift: Int64 = 60
    public static let rightOption: Int64 = 61
    public static let rightControl: Int64 = 62
    public static let functionKey: Int64 = 63
    public static let grave: Int64 = 50 // backquote / won key on Korean 2-Set

    // Function keys F13..F20
    public static let f13: Int64 = 105
    public static let f14: Int64 = 107
    public static let f15: Int64 = 113
    public static let f16: Int64 = 106
    public static let f17: Int64 = 64
    public static let f18: Int64 = 79
    public static let f19: Int64 = 80
    public static let f20: Int64 = 90

    // Hardware CJK / Hangul keys (JIS Kana / Eisu = HID Lang1 / Lang2)
    public static let lang1Hangul: Int64 = 104
    public static let lang2Eisu: Int64 = 102

    // Apple Silicon Globe key
    public static let globe: Int64 = 179

    public static let functionKeys: Set<Int64> = [
        f13, f14, f15, f16, f17, f18, f19, f20
    ]

    public static let rightModifierKeys: Set<Int64> = [
        rightCommand, rightOption, rightControl
    ]

    public static let allModifierKeys: Set<Int64> = [
        leftCommand, rightCommand, leftOption, rightOption,
        leftControl, rightControl, leftShift, rightShift,
        capsLock, functionKey, globe
    ]

    public static func displayName(for keyCode: Int64) -> String {
        switch keyCode {
        case f13: return "F13"
        case f14: return "F14"
        case f15: return "F15"
        case f16: return "F16"
        case f17: return "F17"
        case f18: return "F18"
        case f19: return "F19"
        case f20: return "F20"
        case space: return "Space"
        case escape: return "ESC"
        case rightCommand: return "우측 Command ⌘"
        case leftCommand: return "좌측 Command ⌘"
        case rightOption: return "우측 Option ⌥"
        case leftOption: return "좌측 Option ⌥"
        case rightControl: return "우측 Control ⌃"
        case leftControl: return "좌측 Control ⌃"
        case capsLock: return "Caps Lock ⇪"
        case functionKey, globe: return "Fn / 🌐"
        case lang1Hangul: return "한/영 (Lang1)"
        case lang2Eisu: return "영수 (Lang2)"
        default: return "Key(\(keyCode))"
        }
    }

    public static func fromKarabinerKeyName(_ name: String) -> Int64? {
        switch name.lowercased() {
        case "f13": return f13
        case "f14": return f14
        case "f15": return f15
        case "f16": return f16
        case "f17": return f17
        case "f18": return f18
        case "f19": return f19
        case "f20": return f20
        case "spacebar": return space
        case "right_command", "right_gui": return rightCommand
        case "left_command", "left_gui": return leftCommand
        case "right_option", "right_alt": return rightOption
        case "left_option", "left_alt": return leftOption
        case "right_control": return rightControl
        case "left_control": return leftControl
        case "caps_lock": return capsLock
        case "lang1", "japanese_kana", "international4": return lang1Hangul
        case "lang2", "japanese_eisuu", "international5": return lang2Eisu
        case "fn", "keyboard_fn": return functionKey
        default: return nil
        }
    }
}

/// Relevant modifier mask stripped of device-specific bits, CapsLock, and secondary Fn noise.
public struct NormalizedModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let command = NormalizedModifiers(rawValue: 1 << 0)
    public static let control = NormalizedModifiers(rawValue: 1 << 1)
    public static let option  = NormalizedModifiers(rawValue: 1 << 2)
    public static let shift   = NormalizedModifiers(rawValue: 1 << 3)

    public init(cgFlags: CGEventFlags) {
        var bits: UInt64 = 0
        if cgFlags.contains(.maskCommand) { bits |= NormalizedModifiers.command.rawValue }
        if cgFlags.contains(.maskControl) { bits |= NormalizedModifiers.control.rawValue }
        if cgFlags.contains(.maskAlternate) { bits |= NormalizedModifiers.option.rawValue }
        if cgFlags.contains(.maskShift) { bits |= NormalizedModifiers.shift.rawValue }
        self.rawValue = bits
    }

    public var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    public var displayPrefix: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

/// HID Usage IDs (page 0x07 Keyboard/Keypad) for optional physical-only HID remapping.
public enum HIDKeyUsage {
    public static let capsLock: UInt64     = 0x700000039
    public static let rightControl: UInt64 = 0x7000000E4
    public static let rightOption: UInt64  = 0x7000000E6
    public static let rightCommand: UInt64 = 0x7000000E7

    public static let f13: UInt64 = 0x700000068
    public static let f14: UInt64 = 0x700000069
    public static let f15: UInt64 = 0x70000006A
    public static let f16: UInt64 = 0x70000006B
    public static let f17: UInt64 = 0x70000006C
    public static let f18: UInt64 = 0x70000006D
    public static let f19: UInt64 = 0x70000006E
    public static let f20: UInt64 = 0x70000006F

    public static func usage(forFKeyCode keyCode: Int64) -> UInt64? {
        switch keyCode {
        case VirtualKeyCode.f13: return f13
        case VirtualKeyCode.f14: return f14
        case VirtualKeyCode.f15: return f15
        case VirtualKeyCode.f16: return f16
        case VirtualKeyCode.f17: return f17
        case VirtualKeyCode.f18: return f18
        case VirtualKeyCode.f19: return f19
        case VirtualKeyCode.f20: return f20
        default: return nil
        }
    }
}

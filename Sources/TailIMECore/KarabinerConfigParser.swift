import Foundation

/// Read-only analyzer for `~/.config/karabiner/karabiner.json` that discovers user-configured
/// Korean/English remapped output keys (e.g. Right Cmd -> F18, Right Opt -> F19, Caps Lock -> F18,
/// or complex `to_if_alone` rules) without ever editing Karabiner's files.
public struct KarabinerDiscoveryResult: Equatable, Sendable {
    public let profileName: String?
    public let detectedTriggers: [TriggerSpec]
    public let usesDirectSelectInputSource: Bool

    public init(
        profileName: String?,
        detectedTriggers: [TriggerSpec],
        usesDirectSelectInputSource: Bool = false
    ) {
        self.profileName = profileName
        self.detectedTriggers = detectedTriggers
        self.usesDirectSelectInputSource = usesDirectSelectInputSource
    }
}

public enum KarabinerConfigParser {
    public static let defaultConfigDirectory = NSString(string: "~/.config/karabiner").expandingTildeInPath
    public static let defaultConfigPath = NSString(string: "~/.config/karabiner/karabiner.json").expandingTildeInPath

    /// Source keys users commonly remap into Korean/English switch triggers in Karabiner
    /// (covers all left/right control, option, command, shift, caps lock, fn, hangul, and backquote remaps).
    private static let switchSourceNames: Set<String> = [
        "right_command", "right_gui", "left_command", "left_gui",
        "right_option", "right_alt", "left_option", "left_alt",
        "right_control", "left_control",
        "right_shift", "left_shift",
        "caps_lock",
        "lang1", "japanese_kana",
        "lang2", "japanese_eisuu",
        "fn", "keyboard_fn",
        "grave_accent_and_tilde",
    ]

    /// Target key names that strongly indicate a Korean/English switch binding.
    private static let switchTargetKeyNames: Set<String> = [
        "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
        "lang1", "japanese_kana", "lang2", "japanese_eisuu",
    ]

    public static func loadDefault() -> KarabinerDiscoveryResult {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: defaultConfigPath)) else {
            return KarabinerDiscoveryResult(profileName: nil, detectedTriggers: [])
        }
        return parse(data: data)
    }

    public static func parse(data: Data) -> KarabinerDiscoveryResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]],
              !profiles.isEmpty else {
            return KarabinerDiscoveryResult(profileName: nil, detectedTriggers: [])
        }

        let profile = profiles.first(where: { ($0["selected"] as? Bool) == true }) ?? profiles[0]
        let profileName = profile["name"] as? String

        var triggers: [TriggerSpec] = []
        var seen: Set<String> = []
        var usesSelectInputSource = false

        func addTrigger(_ spec: TriggerSpec) {
            if seen.insert(spec.id).inserted {
                triggers.append(spec)
            }
        }

        // 1. Global simple_modifications
        if let simples = profile["simple_modifications"] as? [[String: Any]] {
            for mod in simples {
                if let spec = extractSimpleModification(mod) {
                    addTrigger(spec)
                }
            }
        }

        // 2. Per-device simple_modifications
        if let devices = profile["devices"] as? [[String: Any]] {
            for device in devices {
                if (device["ignore"] as? Bool) == true { continue }
                if let simples = device["simple_modifications"] as? [[String: Any]] {
                    for mod in simples {
                        if let spec = extractSimpleModification(mod) {
                            addTrigger(spec)
                        }
                    }
                }
            }
        }

        // 3. Complex modifications (to & to_if_alone)
        if let complex = profile["complex_modifications"] as? [String: Any],
           let rules = complex["rules"] as? [[String: Any]] {
            for rule in rules {
                guard let manipulators = rule["manipulators"] as? [[String: Any]] else { continue }
                for manip in manipulators {
                    let fromKey = extractKeyName(from: manip["from"] as? [String: Any])
                    for listKey in ["to", "to_if_alone"] {
                        guard let actions = manip[listKey] as? [[String: Any]] else { continue }
                        for action in actions {
                            if action["select_input_source"] != nil {
                                usesSelectInputSource = true
                            }
                            if let spec = extractComplexAction(fromKey: fromKey, action: action) {
                                addTrigger(spec)
                            }
                        }
                    }
                }
            }
        }

        return KarabinerDiscoveryResult(
            profileName: profileName,
            detectedTriggers: triggers,
            usesDirectSelectInputSource: usesSelectInputSource
        )
    }

    private static func extractKeyName(from dict: [String: Any]?) -> String? {
        guard let dict else { return nil }
        if let k = dict["key_code"] as? String { return k.lowercased() }
        if let k = dict["apple_vendor_top_case_key_code"] as? String { return k.lowercased() }
        if let k = dict["consumer_key_code"] as? String { return k.lowercased() }
        return nil
    }

    private static func extractSimpleModification(_ mod: [String: Any]) -> TriggerSpec? {
        guard let fromName = extractKeyName(from: mod["from"] as? [String: Any]),
              switchSourceNames.contains(fromName) else {
            return nil
        }

        // Karabiner supports `to` as array of dicts or single dict in legacy configs
        let targets: [[String: Any]]
        if let arr = mod["to"] as? [[String: Any]] {
            targets = arr
        } else if let single = mod["to"] as? [String: Any] {
            targets = [single]
        } else {
            return nil
        }

        for target in targets {
            guard let toName = extractKeyName(from: target),
                  switchTargetKeyNames.contains(toName),
                  let keyCode = VirtualKeyCode.fromKarabinerKeyName(toName) else {
                continue
            }
            return TriggerSpec(
                keyCode: keyCode,
                modifiers: [],
                kind: .ownedKey,
                origin: .karabiner
            )
        }
        return nil
    }

    private static func extractComplexAction(fromKey: String?, action: [String: Any]) -> TriggerSpec? {
        guard let fromKey, switchSourceNames.contains(fromKey) else { return nil }
        guard let toName = extractKeyName(from: action),
              let keyCode = VirtualKeyCode.fromKarabinerKeyName(toName) else {
            return nil
        }

        let modNames = (action["modifiers"] as? [String])?.map { $0.lowercased() } ?? []
        var mods: NormalizedModifiers = []
        for m in modNames {
            if m.contains("command") || m.contains("gui") { mods.insert(.command) }
            else if m.contains("control") { mods.insert(.control) }
            else if m.contains("option") || m.contains("alt") { mods.insert(.option) }
            else if m.contains("shift") { mods.insert(.shift) }
        }

        // Accept unmodified F13..F20 / Lang1 / Lang2, or Space with exactly one modifier (e.g. Ctrl+Space).
        if switchTargetKeyNames.contains(toName), mods.isEmpty {
            return TriggerSpec(keyCode: keyCode, modifiers: [], kind: .ownedKey, origin: .karabiner)
        }
        if keyCode == VirtualKeyCode.space, !mods.isEmpty {
            return TriggerSpec(keyCode: keyCode, modifiers: mods, kind: .ownedKey, origin: .karabiner)
        }
        return nil
    }
}

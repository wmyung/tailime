import Foundation

/// Logical language category used for deterministic absolute switching.
public enum InputLanguage: String, Codable, Hashable, Sendable {
    case korean = "ko"
    case english = "en"
    case other = "other"

    public var toggled: InputLanguage {
        switch self {
        case .korean: return .english
        case .english, .other: return .korean
        }
    }

    public var shortBadge: String {
        switch self {
        case .korean: return "한"
        case .english: return "EN"
        case .other: return "??"
        }
    }

    public var displayName: String {
        switch self {
        case .korean: return "한국어"
        case .english: return "영어 (ABC)"
        case .other: return "기타"
        }
    }

    public static func classify(sourceID: String, languages: [String]) -> InputLanguage {
        let lowerID = sourceID.lowercased()
        if languages.contains(where: { $0.lowercased().hasPrefix("ko") })
            || lowerID.contains("korean")
            || lowerID.contains("hangul")
            || lowerID.contains("gureum")
            || lowerID.contains("sokim") {
            return .korean
        }
        if languages.contains(where: { $0.lowercased().hasPrefix("en") })
            || lowerID.contains(".abc")
            || lowerID.contains(".us")
            || lowerID.contains("roman") {
            return .english
        }
        return .other
    }
}

/// Owned triggers are swallowed on keyDown; observed triggers (CapsLock/Globe/standalone modifier taps)
/// are never swallowed so modifier flags and hardware LED states never desync.
public enum TriggerKind: String, Codable, Hashable, Sendable {
    case ownedKey       // F13..F20, Lang1/2, modifier+key combos (swallowed on keyDown)
    case modifierTap    // Standalone Right Cmd / Right Opt / Right Ctrl tap (observed on flagsChanged)
    case systemObserved // Caps Lock / Fn-Globe (observed; never swallowed locally)
}

public enum TriggerOrigin: String, Codable, Hashable, Sendable {
    case systemHotkey
    case karabiner
    case hardwareDefault
    case userRecorded
    case userPreset
}

public struct TriggerSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: String {
        "\(kind.rawValue):\(keyCode):\(modifiers.rawValue)"
    }
    public var keyCode: Int64
    public var modifiers: NormalizedModifiers
    public var kind: TriggerKind
    public var origin: TriggerOrigin
    public var label: String

    public init(
        keyCode: Int64,
        modifiers: NormalizedModifiers = [],
        kind: TriggerKind = .ownedKey,
        origin: TriggerOrigin = .userPreset,
        label: String? = nil
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.kind = kind
        self.origin = origin
        if let label {
            self.label = label
        } else {
            let prefix = modifiers.displayPrefix
            let base = VirtualKeyCode.displayName(for: keyCode)
            if kind == .modifierTap {
                self.label = "\(base) (단독 탭)"
            } else {
                self.label = prefix.isEmpty ? base : "\(prefix) + \(base)"
            }
        }
    }
}

/// Pair of unused F-keys used as in-band carriers through remote desktop clients for exact keystream ordering.
public struct CarrierPair: Codable, Equatable, Sendable {
    public var koreanKeyCode: Int64
    public var englishKeyCode: Int64
    public var probeKeyCode: Int64

    public init(
        koreanKeyCode: Int64 = VirtualKeyCode.f16,
        englishKeyCode: Int64 = VirtualKeyCode.f17,
        probeKeyCode: Int64 = VirtualKeyCode.f20
    ) {
        self.koreanKeyCode = koreanKeyCode
        self.englishKeyCode = englishKeyCode
        self.probeKeyCode = probeKeyCode
    }

    public func keyCode(for language: InputLanguage) -> Int64 {
        switch language {
        case .korean: return koreanKeyCode
        case .english, .other: return englishKeyCode
        }
    }

    public func language(for keyCode: Int64) -> InputLanguage? {
        if keyCode == koreanKeyCode { return .korean }
        if keyCode == englishKeyCode { return .english }
        return nil
    }
}

public enum RemoteTransportMode: String, Codable, CaseIterable, Sendable {
    case autoHybrid     // Auto-probe in-band carrier; if supported use carrier + UDP safety net, else UDP direct
    case udpDirectOnly  // Always send absolute set(ko/en) directly over Tailscale UDP
    case inBandOnly     // Only inject in-band carrier keys (requires remote TailIME session tap)

    public var displayName: String {
        switch self {
        case .autoHybrid: return "자동 하이브리드 (In-Band + Tailscale UDP)"
        case .udpDirectOnly: return "Tailscale UDP 직접 전송"
        case .inBandOnly: return "In-Band 키스트림 전용"
        }
    }
}

public enum FallbackKeyMode: String, Codable, CaseIterable, Sendable {
    case autoByOS       // Windows -> Right Option (Map mode), macOS -> Passthrough
    case rightOption    // Send Right Option tap (Windows Right Alt in RustDesk Map mode)
    case hangulLang1    // Send Lang1/Hangul keyCode 104
    case controlSpace   // Send Ctrl+Space
    case shiftSpace     // Send Shift+Space (explicit opt-in only)
    case passthrough    // Pass original trigger key through

    public var displayName: String {
        switch self {
        case .autoByOS: return "자동 (Windows: 우측 Option / macOS: 패스스루)"
        case .rightOption: return "우측 Option (RustDesk Map 모드 한/영)"
        case .hangulLang1: return "한/영 키 (Lang1 · KeyCode 104)"
        case .controlSpace: return "Control + Space"
        case .shiftSpace: return "Shift + Space (수동 선택)"
        case .passthrough: return "원본 키 그대로 전달"
        }
    }
}

public struct TailscalePeer: Codable, Hashable, Sendable, Identifiable {
    public var id: String { ipv4 ?? ipv6 ?? hostName }
    public var hostName: String
    public var dnsName: String
    public var os: String
    public var ipv4: String?
    public var ipv6: String?
    public var online: Bool
    public var active: Bool
    public var directAddr: String
    public var relay: String

    public init(
        hostName: String,
        dnsName: String,
        os: String,
        ipv4: String?,
        ipv6: String?,
        online: Bool,
        active: Bool,
        directAddr: String,
        relay: String
    ) {
        self.hostName = hostName
        self.dnsName = dnsName
        self.os = os
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.online = online
        self.active = active
        self.directAddr = directAddr
        self.relay = relay
    }

    public var isMacOS: Bool {
        os.lowercased() == "macos" || os.lowercased() == "darwin"
    }

    public var isWindows: Bool {
        os.lowercased() == "windows"
    }

    public var isDirectPath: Bool {
        !directAddr.isEmpty
    }

    public var shortDNSName: String {
        let trimmed = dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.split(separator: ".").first.map(String.init) ?? hostName
    }

    public var preferredIP: String? {
        ipv4 ?? ipv6
    }
}

public struct TrustedPeerRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { deviceID }
    public var deviceID: String
    public var name: String
    public var publicKeyBase64: String
    public var lastKnownIP: String?
    public var pairedAt: Date

    public init(
        deviceID: String,
        name: String,
        publicKeyBase64: String,
        lastKnownIP: String?,
        pairedAt: Date = Date()
    ) {
        self.deviceID = deviceID
        self.name = name
        self.publicKeyBase64 = publicKeyBase64
        self.lastKnownIP = lastKnownIP
        self.pairedAt = pairedAt
    }
}

public struct RemotePeerRuntimeState: Sendable, Equatable {
    public var peerID: String
    public var hostName: String
    public var ip: String
    public var daemonReachable: Bool
    public var lastRTTMs: Double?
    public var currentLanguage: InputLanguage
    public var currentSourceID: String?
    public var supportsInBandCarrier: Bool?
    public var lastSeenAt: Date

    public init(
        peerID: String,
        hostName: String,
        ip: String,
        daemonReachable: Bool = false,
        lastRTTMs: Double? = nil,
        currentLanguage: InputLanguage = .english,
        currentSourceID: String? = nil,
        supportsInBandCarrier: Bool? = nil,
        lastSeenAt: Date = Date()
    ) {
        self.peerID = peerID
        self.hostName = hostName
        self.ip = ip
        self.daemonReachable = daemonReachable
        self.lastRTTMs = lastRTTMs
        self.currentLanguage = currentLanguage
        self.currentSourceID = currentSourceID
        self.supportsInBandCarrier = supportsInBandCarrier
        self.lastSeenAt = lastSeenAt
    }
}

/// Default list of macOS remote desktop client bundle ID prefixes.
public enum RemoteViewerCatalog {
    public static let defaultBundlePrefixes: [String] = [
        "com.carriez.rustdesk",
        "com.apple.ScreenSharing",
        "com.tigervnc.tigervnc",
        "org.tigervnc.tigervnc",
        "com.realvnc.vncviewer",
        "com.p5sys.jump",
        "com.edovia.screens",
        "tv.parsec.www",
        "com.moonlight-stream.Moonlight",
        "com.nomachine",
        "com.philandro.anydesk",
        "com.microsoft.rdc",
        "com.teamviewer.TeamViewer",
        "com.splashtop",
    ]

    /// Process executable names known to inject keyboard events as a remote desktop host server.
    public static let hostServerProcessNames: [String] = [
        "rustdesk",
        "screensharingd",
        "ardagent",
        "jumpconnect",
        "parsec",
        "parsecd",
        "sunshine",
        "nxnode",
        "anydesk",
        "teamviewer",
        "vncserver",
        "tigervnc",
    ]
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var autoDetectSystemHotkey: Bool = true
    public var autoDetectKarabiner: Bool = true
    public var autoDetectHardwareHangul: Bool = true
    public var userTriggers: [TriggerSpec] = []

    // Local fast-switch options
    public var localHoldGateEnabled: Bool = true
    public var swapBackquoteInKorean: Bool = false
    public var escapeToEnglish: Bool = false
    public var optionalHIDRemapEnabled: Bool = false
    public var optionalHIDSourceUsage: UInt64 = HIDKeyUsage.rightCommand
    public var optionalHIDTargetKeyCode: Int64 = VirtualKeyCode.f19

    // Remote Tailscale options
    public var remoteSyncEnabled: Bool = true
    public var udpPort: UInt16 = 39418
    public var transportMode: RemoteTransportMode = .autoHybrid
    public var autoEnglishOnRemoteFocus: Bool = true
    public var restoreLocalSourceOnRemoteBlur: Bool = false
    public var showRemoteHUD: Bool = true
    public var showLocalHUD: Bool = false
    public var fallbackKeyMode: FallbackKeyMode = .autoByOS
    public var pinnedPeerID: String? = nil
    public var customRemoteBundlePrefixes: [String] = []
    public var peerAliases: [String: String] = [:]        // e.g. "123456789" -> "100.64.0.10"
    public var learnedWindowTitles: [String: String] = [:] // windowTitle -> peerIP
    public var carrierPair: CarrierPair = CarrierPair()

    public init() {}

    public var allRemoteBundlePrefixes: [String] {
        RemoteViewerCatalog.defaultBundlePrefixes + customRemoteBundlePrefixes
    }
}

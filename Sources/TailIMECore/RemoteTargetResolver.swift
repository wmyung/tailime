import Foundation

public struct ActiveRemoteContext: Equatable, Sendable {
    public let isRemoteAppFocused: Bool
    public let isLobbyWindow: Bool
    public let bundleID: String
    public let frontmostPID: Int32
    public let windowTitle: String
    public let resolvedPeer: TailscalePeer?
    public let resolutionSource: String // "pinned", "learned-title", "alias", "window-title", "socket", "none"
    public let isAmbiguousMultiSession: Bool
    public let candidatePeerIPs: [String]

    public init(
        isRemoteAppFocused: Bool = false,
        isLobbyWindow: Bool = false,
        bundleID: String = "",
        frontmostPID: Int32 = 0,
        windowTitle: String = "",
        resolvedPeer: TailscalePeer? = nil,
        resolutionSource: String = "none",
        isAmbiguousMultiSession: Bool = false,
        candidatePeerIPs: [String] = []
    ) {
        self.isRemoteAppFocused = isRemoteAppFocused
        self.isLobbyWindow = isLobbyWindow
        self.bundleID = bundleID
        self.frontmostPID = frontmostPID
        self.windowTitle = windowTitle
        self.resolvedPeer = resolvedPeer
        self.resolutionSource = resolutionSource
        self.isAmbiguousMultiSession = isAmbiguousMultiSession
        self.candidatePeerIPs = candidatePeerIPs
    }

    /// True when we are actively focused on a remote desktop session (not a local app or lobby screen).
    public var hasActiveRemoteSession: Bool {
        isRemoteAppFocused && !isLobbyWindow && (resolvedPeer != nil || isAmbiguousMultiSession)
    }
}

public enum FallbackResolvedAction: Equatable, Sendable {
    case sendKey(keyCode: Int64, modifiers: NormalizedModifiers)
    case sendModifierTap(keyCode: Int64)
    case passthrough
}

/// Pure, deterministic 4-tier resolver identifying which Tailscale peer a focused remote desktop window controls.
public enum RemoteTargetResolver {
    private static let lobbyTitles: Set<String> = [
        "rustdesk", "settings", "preferences", "about", "screen sharing",
        "화면 공유", "환경설정", "설정", "connections", "jump desktop", "parsec",
    ]

    public static func isRemoteViewerBundle(_ bundleID: String, allowedPrefixes: [String]) -> Bool {
        let lower = bundleID.lowercased()
        return allowedPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    public static func isLikelyLobbyTitle(_ title: String, bundleID: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            // RustDesk session tabs sometimes have an empty AX title until painted; don't force lobby if sockets exist.
            return false
        }
        return lobbyTitles.contains(trimmed)
    }

    public static func resolve(
        bundleID: String,
        frontmostPID: Int32,
        windowTitle: String,
        activeClientSocketIPs: [String],
        snapshot: TailscaleStatusSnapshot,
        settings: AppSettings
    ) -> ActiveRemoteContext {
        guard isRemoteViewerBundle(bundleID, allowedPrefixes: settings.allRemoteBundlePrefixes) else {
            return ActiveRemoteContext(isRemoteAppFocused: false, bundleID: bundleID, frontmostPID: frontmostPID)
        }

        let trimmedTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lobby = isLikelyLobbyTitle(trimmedTitle, bundleID: bundleID) && activeClientSocketIPs.isEmpty

        if lobby {
            return ActiveRemoteContext(
                isRemoteAppFocused: true,
                isLobbyWindow: true,
                bundleID: bundleID,
                frontmostPID: frontmostPID,
                windowTitle: trimmedTitle,
                resolvedPeer: nil,
                resolutionSource: "lobby"
            )
        }

        // Tier 0: Explicit manual pin
        if let pinnedID = settings.pinnedPeerID, !pinnedID.isEmpty,
           let peer = snapshot.peers.first(where: { $0.id == pinnedID || $0.ipv4 == pinnedID || $0.hostName == pinnedID }) {
            return ActiveRemoteContext(
                isRemoteAppFocused: true,
                isLobbyWindow: false,
                bundleID: bundleID,
                frontmostPID: frontmostPID,
                windowTitle: trimmedTitle,
                resolvedPeer: peer,
                resolutionSource: "pinned",
                candidatePeerIPs: activeClientSocketIPs
            )
        }

        // Tier 1A: Learned window title table (from prior in-band probe bindings)
        if !trimmedTitle.isEmpty,
           let learnedIP = settings.learnedWindowTitles[trimmedTitle],
           let peer = snapshot.peer(matchingIP: learnedIP) {
            return ActiveRemoteContext(
                isRemoteAppFocused: true,
                isLobbyWindow: false,
                bundleID: bundleID,
                frontmostPID: frontmostPID,
                windowTitle: trimmedTitle,
                resolvedPeer: peer,
                resolutionSource: "learned-title",
                candidatePeerIPs: activeClientSocketIPs
            )
        }

        // Tier 1B: User-defined aliases (e.g. RustDesk 9-digit ID "123456789" -> "100.64.0.10")
        if !trimmedTitle.isEmpty {
            let lowerTitle = trimmedTitle.lowercased()
            for (alias, targetIP) in settings.peerAliases where !alias.isEmpty {
                if lowerTitle.contains(alias.lowercased()), let peer = snapshot.peer(matchingIP: targetIP) {
                    return ActiveRemoteContext(
                        isRemoteAppFocused: true,
                        isLobbyWindow: false,
                        bundleID: bundleID,
                        frontmostPID: frontmostPID,
                        windowTitle: trimmedTitle,
                        resolvedPeer: peer,
                        resolutionSource: "alias",
                        candidatePeerIPs: activeClientSocketIPs
                    )
                }
            }
        }

        // Tier 2: Direct window title match against Tailscale peer IPv4, IPv6, HostName, or short DNSName
        if !trimmedTitle.isEmpty, let titlePeer = matchPeerByWindowTitle(trimmedTitle, peers: snapshot.peers) {
            return ActiveRemoteContext(
                isRemoteAppFocused: true,
                isLobbyWindow: false,
                bundleID: bundleID,
                frontmostPID: frontmostPID,
                windowTitle: trimmedTitle,
                resolvedPeer: titlePeer,
                resolutionSource: "window-title",
                candidatePeerIPs: activeClientSocketIPs
            )
        }

        // Tier 3: Active client Tailscale sockets (from libproc)
        let socketPeers = activeClientSocketIPs.compactMap { snapshot.peer(matchingIP: $0) }
        if socketPeers.count == 1 {
            return ActiveRemoteContext(
                isRemoteAppFocused: true,
                isLobbyWindow: false,
                bundleID: bundleID,
                frontmostPID: frontmostPID,
                windowTitle: trimmedTitle,
                resolvedPeer: socketPeers[0],
                resolutionSource: "socket",
                candidatePeerIPs: activeClientSocketIPs
            )
        }

        if socketPeers.count > 1 {
            // Multiple remote sessions active simultaneously and window title didn't disambiguate yet -> trigger probe!
            return ActiveRemoteContext(
                isRemoteAppFocused: true,
                isLobbyWindow: false,
                bundleID: bundleID,
                frontmostPID: frontmostPID,
                windowTitle: trimmedTitle,
                resolvedPeer: nil,
                resolutionSource: "ambiguous-multi-session",
                isAmbiguousMultiSession: true,
                candidatePeerIPs: socketPeers.compactMap(\.preferredIP)
            )
        }

        // Lobby check when no sockets matched and title is generic
        let fallbackLobby = isLikelyLobbyTitle(trimmedTitle, bundleID: bundleID)
        return ActiveRemoteContext(
            isRemoteAppFocused: true,
            isLobbyWindow: fallbackLobby,
            bundleID: bundleID,
            frontmostPID: frontmostPID,
            windowTitle: trimmedTitle,
            resolvedPeer: nil,
            resolutionSource: "none"
        )
    }

    public static func matchPeerByWindowTitle(_ title: String, peers: [TailscalePeer]) -> TailscalePeer? {
        let lower = title.lowercased()

        // Prefer exact IP match first (highest precision)
        for peer in peers {
            if let ip4 = peer.ipv4?.lowercased(), lower.contains(ip4) { return peer }
            if let ip6 = peer.ipv6?.lowercased(), lower.contains(ip6) { return peer }
        }

        // Match hostName or shortDNSName (require >= 3 chars to avoid spurious substring matches)
        for peer in peers {
            let host = peer.hostName.lowercased()
            if host.count >= 3 && lower.contains(host) { return peer }
            let dns = peer.shortDNSName.lowercased()
            if dns.count >= 3 && lower.contains(dns) { return peer }
        }
        return nil
    }

    /// Resolves the safest fallback key injection for remote peers that do NOT run TailIME.
    /// Never uses Shift+Space unless explicitly selected by the user.
    public static func resolveFallbackAction(
        mode: FallbackKeyMode,
        peer: TailscalePeer?
    ) -> FallbackResolvedAction {
        switch mode {
        case .autoByOS:
            if peer?.isWindows == true {
                return .sendModifierTap(keyCode: VirtualKeyCode.rightOption)
            }
            return .passthrough
        case .rightOption:
            return .sendModifierTap(keyCode: VirtualKeyCode.rightOption)
        case .hangulLang1:
            return .sendKey(keyCode: VirtualKeyCode.lang1Hangul, modifiers: [])
        case .controlSpace:
            return .sendKey(keyCode: VirtualKeyCode.space, modifiers: [.control])
        case .shiftSpace:
            return .sendKey(keyCode: VirtualKeyCode.space, modifiers: [.shift])
        case .passthrough:
            return .passthrough
        }
    }
}

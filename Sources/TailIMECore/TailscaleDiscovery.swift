import Foundation
import Darwin

public struct TailscaleStatusSnapshot: Equatable, Sendable {
    public let selfNode: TailscalePeer?
    public let peers: [TailscalePeer]
    public let fetchedAt: Date

    public init(selfNode: TailscalePeer?, peers: [TailscalePeer], fetchedAt: Date = Date()) {
        self.selfNode = selfNode
        self.peers = peers
        self.fetchedAt = fetchedAt
    }

    public var macPeers: [TailscalePeer] {
        peers.filter(\.isMacOS)
    }

    public func peer(matchingIP ip: String) -> TailscalePeer? {
        let lower = ip.lowercased()
        return peers.first {
            $0.ipv4?.lowercased() == lower || $0.ipv6?.lowercased() == lower
        }
    }

    public func isKnownPeerIP(_ ip: String) -> Bool {
        if TailscaleIPValidator.isLoopback(ip) { return true }
        return peer(matchingIP: ip) != nil
    }
}

public enum TailscaleIPValidator {
    /// Returns true if `ip` is in CGNAT `100.64.0.0/10` (100.64.0.0 – 100.127.255.255).
    public static func isTailscaleIPv4(_ ip: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return false }
        let hostOrder = UInt32(bigEndian: addr.s_addr)
        let firstOctet = (hostOrder >> 24) & 0xFF
        let secondOctet = (hostOrder >> 16) & 0xFF
        return firstOctet == 100 && (secondOctet >= 64 && secondOctet <= 127)
    }

    /// Returns true if `ip` is in Tailscale's ULA IPv6 prefix `fd7a:115c:a1e0::/48`.
    public static func isTailscaleIPv6(_ ip: String) -> Bool {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, ip, &addr) == 1 else { return false }
        return withUnsafeBytes(of: &addr) { raw -> Bool in
            raw.count >= 6
                && raw[0] == 0xFD && raw[1] == 0x7A
                && raw[2] == 0x11 && raw[3] == 0x5C
                && raw[4] == 0xA1 && raw[5] == 0xE0
        }
    }

    public static func isTailscaleIP(_ ip: String) -> Bool {
        isTailscaleIPv4(ip) || isTailscaleIPv6(ip)
    }

    public static func isLoopback(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1"
    }

    /// Validates an incoming interface name (`utun*` for Tailscale WireGuard tunnel, or `lo0` for loopback self-test).
    public static func isAllowedInterfaceName(_ ifname: String, sourceIP: String) -> Bool {
        if isLoopback(sourceIP) {
            return ifname.hasPrefix("lo")
        }
        return ifname.hasPrefix("utun")
    }
}

public enum TailscaleDiscovery {
    public static let candidateBinaries: [String] = [
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    public static func findBinary() -> String? {
        candidateBinaries.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Parses ONLY non-sensitive node/peer fields from `tailscale status --json`.
    public static func parseStatusJSON(_ data: Data, fetchedAt: Date = Date()) -> TailscaleStatusSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let selfNode = (root["Self"] as? [String: Any]).flatMap { parseNode($0) }
        var peers: [TailscalePeer] = []

        if let peerMap = root["Peer"] as? [String: [String: Any]] {
            for (_, dict) in peerMap {
                if let peer = parseNode(dict) {
                    peers.append(peer)
                }
            }
        }

        peers.sort { lhs, rhs in
            if lhs.isMacOS != rhs.isMacOS { return lhs.isMacOS }
            if lhs.online != rhs.online { return lhs.online }
            return lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName) == .orderedAscending
        }

        return TailscaleStatusSnapshot(selfNode: selfNode, peers: peers, fetchedAt: fetchedAt)
    }

    private static func parseNode(_ dict: [String: Any]) -> TailscalePeer? {
        let hostName = (dict["HostName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dnsName = (dict["DNSName"] as? String) ?? ""
        let os = (dict["OS"] as? String) ?? ""
        let ips = (dict["TailscaleIPs"] as? [String]) ?? []
        let ipv4 = ips.first(where: { !$0.contains(":") })
        let ipv6 = ips.first(where: { $0.contains(":") })
        guard ipv4 != nil || ipv6 != nil else { return nil }

        let online = (dict["Online"] as? Bool) ?? false
        let active = (dict["Active"] as? Bool) ?? false
        let directAddr = (dict["CurAddr"] as? String) ?? ""
        let relay = (dict["Relay"] as? String) ?? ""

        let label = hostName.isEmpty
            ? (dnsName.split(separator: ".").first.map(String.init) ?? ipv4 ?? ipv6 ?? "Peer")
            : hostName

        return TailscalePeer(
            hostName: label,
            dnsName: dnsName,
            os: os,
            ipv4: ipv4,
            ipv6: ipv6,
            online: online,
            active: active,
            directAddr: directAddr,
            relay: relay
        )
    }

    /// Runs `tailscale status --json` synchronously (call off the main thread / tap thread).
    public static func fetchStatusSync(timeout: TimeInterval = 4.0) -> TailscaleStatusSnapshot? {
        guard let bin = findBinary() else { return nil }
        guard let data = runCLI(bin: bin, args: ["status", "--json"], timeout: timeout) else { return nil }
        return parseStatusJSON(data)
    }

    /// Verifies that an IP address belongs to the current Tailnet via `tailscale whois --json <ip>`.
    /// Returns the verified node display name / login identity if valid, else nil.
    public static func verifyPeerWhoisSync(ip: String, timeout: TimeInterval = 3.0) -> String? {
        if TailscaleIPValidator.isLoopback(ip) { return "localhost" }
        guard TailscaleIPValidator.isTailscaleIP(ip), let bin = findBinary() else { return nil }
        guard let data = runCLI(bin: bin, args: ["whois", "--json", ip], timeout: timeout),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = root["Node"] as? [String: Any] else {
            return nil
        }
        let name = (node["ComputedName"] as? String) ?? (node["Name"] as? String) ?? ip
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func runCLI(bin: String, args: [String], timeout: TimeInterval) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return nil
        }

        let sem = DispatchSemaphore(value: 0)
        var captured = Data()
        DispatchQueue.global(qos: .utility).async {
            captured = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            sem.signal()
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        return proc.terminationStatus == 0 ? captured : nil
    }
}

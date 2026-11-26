import CSystemBridge
import Foundation

public struct ActiveSocketEntry: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let isTCP: Bool
    public let isEstablished: Bool
    public let isListen: Bool
    public let localIP: String
    public let localPort: UInt16
    public let remoteIP: String
    public let remotePort: UInt16
    public let processCommandLine: String

    public init(
        pid: Int32,
        isTCP: Bool,
        isEstablished: Bool,
        isListen: Bool,
        localIP: String,
        localPort: UInt16,
        remoteIP: String,
        remotePort: UInt16,
        processCommandLine: String = ""
    ) {
        self.pid = pid
        self.isTCP = isTCP
        self.isEstablished = isEstablished
        self.isListen = isListen
        self.localIP = localIP
        self.localPort = localPort
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.processCommandLine = processCommandLine
    }
}

public enum SocketInspector {
    /// TCP state constants from `<sys/proc_info.h>` (TSI_S_LISTEN = 1, TSI_S_ESTABLISHED = 4).
    public static let tcpStateListen: Int32 = 1
    public static let tcpStateEstablished: Int32 = 4

    /// Filters raw sockets down to outbound client connections reaching Tailscale peer IPs (v4 & v6).
    /// Excludes listening sockets, non-established TCP, unconnected UDP, local host daemons (`--server`/`--cm`),
    /// and connections targeting `selfIPs`.
    public static func filterClientTailscalePeerIPs(
        sockets: [ActiveSocketEntry],
        selfIPs: Set<String>
    ) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []

        for sock in sockets {
            // Skip remote desktop HOST/SERVER daemons so a Mac acting as a server never thinks it is a client!
            if isHostDaemonProcess(cmdLine: sock.processCommandLine) {
                continue
            }
            if sock.isTCP {
                guard sock.isEstablished && !sock.isListen else { continue }
            } else {
                guard sock.remotePort != 0 else { continue }
            }

            let remote = sock.remoteIP
            guard TailscaleIPValidator.isTailscaleIP(remote) else { continue }
            guard !selfIPs.contains(remote) else { continue }

            // Extra defense: RustDesk server listens on localPort 21118 and accepts inbound sessions there.
            if sock.localPort == 21118 && sock.remotePort != 21118 {
                continue
            }

            if seen.insert(remote).inserted {
                result.append(remote)
            }
        }
        return result
    }

    public static func isHostDaemonProcess(cmdLine: String) -> Bool {
        let lower = cmdLine.lowercased()
        let tokens = lower.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.contains("--server") || tokens.contains("--cm") || tokens.contains("--tray") {
            return true
        }
        if lower.contains("/rustdesk.app/contents/macos/service")
            || lower.contains("screensharingd")
            || lower.contains("ardagent") {
            return true
        }
        return false
    }

    /// Live libproc scan for a focused app PID and related processes sharing its `.app` bundle path.
    /// Must be called on a background queue (never inside the CGEventTap callback).
    public static func inspectClientSockets(frontmostPID: pid_t, bundlePath: String?) -> [ActiveSocketEntry] {
        var candidatePIDs: Set<pid_t> = [frontmostPID]

        if let bundlePath, !bundlePath.isEmpty {
            var pids = [pid_t](repeating: 0, count: 64)
            let count = bundlePath.withCString { cstr in
                tailime_find_pids_matching_path(cstr, &pids, Int32(pids.count))
            }
            for i in 0..<Int(count) {
                candidatePIDs.insert(pids[i])
            }
        }

        // Apple Screen Sharing may delegate network connections to a helper under ScreenSharing.app / RFB.
        if let bundlePath, bundlePath.lowercased().contains("screensharing.app") {
            var helperPIDs = [pid_t](repeating: 0, count: 32)
            let count = "ScreenSharing".withCString { cstr in
                tailime_find_pids_matching_path(cstr, &helperPIDs, Int32(helperPIDs.count))
            }
            for i in 0..<Int(count) {
                candidatePIDs.insert(helperPIDs[i])
            }
        }

        var results: [ActiveSocketEntry] = []
        var sockBuf = [TailIMESocketInfo](repeating: TailIMESocketInfo(), count: 128)
        var cmdBuf = [CChar](repeating: 0, count: 1024)

        for pid in candidatePIDs {
            let cmdLine: String
            if tailime_pid_cmdline(pid, &cmdBuf, Int32(cmdBuf.count)) {
                cmdLine = String(cString: cmdBuf)
            } else if tailime_pid_path(pid, &cmdBuf, Int32(cmdBuf.count)) {
                cmdLine = String(cString: cmdBuf)
            } else {
                cmdLine = ""
            }

            let count = tailime_list_pid_sockets(pid, &sockBuf, Int32(sockBuf.count))
            for i in 0..<Int(count) {
                let raw = sockBuf[i]
                let localIP = cString(from: raw.local_ip)
                let remoteIP = cString(from: raw.remote_ip)
                results.append(ActiveSocketEntry(
                    pid: raw.pid,
                    isTCP: raw.proto == IPPROTO_TCP,
                    isEstablished: raw.tcp_state == tcpStateEstablished,
                    isListen: raw.tcp_state == tcpStateListen,
                    localIP: localIP,
                    localPort: raw.local_port,
                    remoteIP: remoteIP,
                    remotePort: raw.remote_port,
                    processCommandLine: cmdLine
                ))
            }
        }

        return results
    }

    private static func cString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw -> String in
            let ptr = raw.bindMemory(to: CChar.self)
            return String(cString: ptr.baseAddress!)
        }
    }
}

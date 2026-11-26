import CryptoKit
import CSystemBridge
import Darwin
import Foundation
import Network
import TailIMECore

struct IncomingUDPPacket: Sendable {
    let sourceIP: String
    let sourcePort: UInt16
    let interfaceName: String
    let packet: DecodedWirePacket
}

/// Tailscale-restricted UDP socket endpoint (IPv4 Tailscale + IPv6 Tailscale + 127.0.0.1 loopback).
/// Never binds `0.0.0.0`. Verifies incoming interface (`utun*` / `lo*`) via `IP_RECVIF` / `IPV6_RECVPKTINFO`,
/// Tailnet membership via peer snapshot + cached `tailscale whois`, per-peer constant-time HMAC-SHA256,
/// and sliding-window replay protection.
final class TailscaleUDPEndpoint {
    private let queue = DispatchQueue(label: "com.tailime.udp-endpoint", qos: .userInteractive)
    private let whoisQueue = DispatchQueue(label: "com.tailime.tailscale-whois", qos: .utility)

    private var port: UInt16
    private var boundSockets: [(fd: Int32, family: Int32, bindIP: String, source: DispatchSourceRead)] = []
    private var pathMonitor: NWPathMonitor?
    private var rebindWork: DispatchWorkItem?
    private var isStarted = false
    private var consoleActive = true

    private var replayGuard = SlidingWindowReplayGuard()
    private var whoisCache: [String: (valid: Bool, checkedAt: TimeInterval)] = [:]
    private var pairRateLimiter: [String: [TimeInterval]] = [:]
    private let whoisTTL: TimeInterval = 300

    private var tailscaleSnapshot = TailscaleStatusSnapshot(selfNode: nil, peers: [])
    private var peerKeysByDeviceID: [String: SymmetricKey] = [:]

    var onPacketReceived: ((IncomingUDPPacket) -> Void)?
    var onBindStatusChanged: (([String]) -> Void)?

    init(port: UInt16 = 39418) {
        self.port = port
    }

    deinit {
        stop()
    }

    func updatePort(_ newPort: UInt16) {
        queue.async { [weak self] in
            guard let self, self.port != newPort else { return }
            self.port = newPort
            if self.isStarted {
                self.rebindSockets()
            }
        }
    }

    func updateTailscaleSnapshot(_ snapshot: TailscaleStatusSnapshot) {
        queue.async { [weak self] in
            guard let self else { return }
            let oldV4 = self.tailscaleSnapshot.selfNode?.ipv4
            let oldV6 = self.tailscaleSnapshot.selfNode?.ipv6
            self.tailscaleSnapshot = snapshot
            let newV4 = snapshot.selfNode?.ipv4
            let newV6 = snapshot.selfNode?.ipv6
            if self.isStarted && (oldV4 != newV4 || oldV6 != newV6 || self.boundSockets.isEmpty) {
                self.rebindSockets()
            }
        }
    }

    func updatePeerKeys(_ keys: [String: SymmetricKey]) {
        queue.async { [weak self] in
            self?.peerKeysByDeviceID = keys
        }
    }

    func setConsoleSessionActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, self.consoleActive != active else { return }
            self.consoleActive = active
            if !active {
                self.closeAllSockets()
            } else if self.isStarted {
                self.rebindSockets()
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            self.startPathMonitor()
            if self.consoleActive {
                self.rebindSockets()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.rebindWork?.cancel()
            self.rebindWork = nil
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.closeAllSockets()
        }
    }

    /// Caches an ACK reply for idempotent retransmission if the peer retries the same `(deviceID, bootSessionID, seq)`.
    func cacheIdempotentReply(
        _ reply: WireMessage,
        forSenderDeviceID senderID: String,
        bootSessionID: String,
        seq: UInt64
    ) {
        queue.async { [weak self] in
            self?.replayGuard.cacheReply(reply, senderDeviceID: senderID, bootSessionID: bootSessionID, seq: seq)
        }
    }

    /// Sends an encoded UDP message to `targetIP:targetPort`.
    func send(
        message: WireMessage,
        toIP targetIP: String,
        port targetPort: UInt16? = nil,
        key: SymmetricKey?,
        nonce: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let destPort = targetPort ?? self.port
            guard let data = try? WirePacketCodec.encode(message: message, key: key, nonce: nonce) else {
                return
            }
            self.sendRaw(data: data, toIP: targetIP, port: destPort)
        }
    }

    // MARK: - Socket Lifecycle

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.scheduleRebind(delay: 0.5)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func scheduleRebind(delay: TimeInterval) {
        rebindWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted, self.consoleActive else { return }
            self.rebindSockets()
        }
        rebindWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closeAllSockets() {
        for entry in boundSockets {
            entry.source.cancel()
        }
        boundSockets.removeAll()
        DispatchQueue.main.async { [weak self] in
            self?.onBindStatusChanged?([])
        }
    }

    private func rebindSockets() {
        closeAllSockets()
        guard consoleActive else { return }

        // Always discover local Tailscale utun* IPv4/IPv6 directly from kernel getifaddrs()
        // so Mac App Store / CLI-less Tailscale installs STILL bind their 100.x.y.z / fd7a:: sockets!
        let localIPs = TailscaleDiscovery.discoverLocalTailscaleIPs()
        var desiredIPs: [(String, Int32)] = [("127.0.0.1", AF_INET)]
        var seenIPs: Set<String> = ["127.0.0.1"]

        for candidateV4 in [tailscaleSnapshot.selfNode?.ipv4, localIPs.ipv4].compactMap({ $0 }) {
            if TailscaleIPValidator.isTailscaleIPv4(candidateV4), seenIPs.insert(candidateV4).inserted {
                desiredIPs.insert((candidateV4, AF_INET), at: 0)
            }
        }
        for candidateV6 in [tailscaleSnapshot.selfNode?.ipv6, localIPs.ipv6].compactMap({ $0 }) {
            if TailscaleIPValidator.isTailscaleIPv6(candidateV6), seenIPs.insert(candidateV6).inserted {
                desiredIPs.append((candidateV6, AF_INET6))
            }
        }

        var missingTailscaleBind = (desiredIPs.count == 1) // Only loopback discovered so far
        for (ip, family) in desiredIPs {
            if let bound = createAndBindSocket(ip: ip, family: family, port: port) {
                boundSockets.append(bound)
            } else if ip != "127.0.0.1" {
                missingTailscaleBind = true
            }
        }

        let boundAddrs = boundSockets.map { "\($0.bindIP):\(port)" }
        DispatchQueue.main.async { [weak self] in
            self?.onBindStatusChanged?(boundAddrs)
        }

        // If Tailscale IP wasn't ready yet after boot/wake (EADDRNOTAVAIL or utun not up), retry gracefully.
        if missingTailscaleBind {
            scheduleRebind(delay: 5.0)
        }
    }

    private func createAndBindSocket(
        ip: String,
        family: Int32,
        port: UInt16
    ) -> (fd: Int32, family: Int32, bindIP: String, source: DispatchSourceRead)? {
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))

        if family == AF_INET {
            setsockopt(fd, IPPROTO_IP, IP_RECVIF, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
                close(fd)
                return nil
            }
            let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard rc == 0 else {
                close(fd)
                return nil
            }
        } else {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = tailime_enable_ipv6_pktinfo(fd)
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, ip, &addr.sin6_addr) == 1 else {
                close(fd)
                return nil
            }
            let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard rc == 0 else {
                close(fd)
                return nil
            }
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.drainSocket(fd: fd, family: family)
        }
        readSource.setCancelHandler {
            close(fd)
        }
        readSource.resume()
        return (fd, family, ip, readSource)
    }

    // MARK: - Receive & Verify

    private func drainSocket(fd: Int32, family: Int32) {
        var payloadBuf = [UInt8](repeating: 0, count: 2048)
        var ctrlBuf = [UInt8](repeating: 0, count: 256)
        var senderStorage = sockaddr_storage()

        while true {
            var ifIndex: UInt32 = 0
            var receivedLen: Int = -1

            payloadBuf.withUnsafeMutableBytes { dataRaw in
                ctrlBuf.withUnsafeMutableBytes { ctrlRaw in
                    withUnsafeMutablePointer(to: &senderStorage) { senderPtr in
                        var iov = iovec(iov_base: dataRaw.baseAddress, iov_len: dataRaw.count)
                        withUnsafeMutablePointer(to: &iov) { iovPtr in
                            var msg = msghdr()
                            msg.msg_name = UnsafeMutableRawPointer(senderPtr)
                            msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                            msg.msg_iov = iovPtr
                            msg.msg_iovlen = 1
                            msg.msg_control = ctrlRaw.baseAddress
                            msg.msg_controllen = socklen_t(ctrlRaw.count)

                            receivedLen = recvmsg(fd, &msg, 0)
                            if receivedLen > 0 {
                                ifIndex = Self.extractInterfaceIndex(from: &msg)
                            }
                        }
                    }
                }
            }

            if receivedLen <= 0 {
                break
            }

            guard let (srcIP, srcPort) = Self.extractSenderAddress(from: &senderStorage) else {
                continue
            }

            // 1. Verify source IP is Tailscale or loopback
            guard TailscaleIPValidator.isTailscaleIP(srcIP) || TailscaleIPValidator.isLoopback(srcIP) else {
                continue
            }

            // 2. Verify incoming interface is Tailscale utun* (or lo* for loopback)
            var ifNameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 4)
            let ifName: String
            if ifIndex > 0, tailime_ifindex_to_name(ifIndex, &ifNameBuf, Int32(ifNameBuf.count)) {
                ifName = String(cString: ifNameBuf)
            } else {
                ifName = TailscaleIPValidator.isLoopback(srcIP) ? "lo0" : ""
            }
            if !ifName.isEmpty && !TailscaleIPValidator.isAllowedInterfaceName(ifName, sourceIP: srcIP) {
                continue
            }

            let data = Data(payloadBuf[0..<receivedLen])
            let decoded: DecodedWirePacket
            do {
                decoded = try WirePacketCodec.decode(data: data) { [weak self] senderID in
                    self?.peerKeysByDeviceID[senderID]
                }
            } catch {
                continue
            }

            // 3. Authenticated packets (constant-time X25519+HKDF-SHA256 HMAC from a trusted peer over utun*)
            // NEVER require the optional `tailscale` CLI binary to be accepted!
            // Unauthenticated `pairHello` packets are rate-limited and verified via snapshot/whois when CLI exists,
            // or accepted strictly over utun* Tailscale CIDR when Mac App Store Tailscale has no CLI (still gated by 6-digit SAS).
            if decoded.authenticated {
                let now = ProcessInfo.processInfo.systemUptime
                let isMutating = [.set, .expectSet, .state].contains(decoded.message.cmd)
                let verdict = replayGuard.checkAndRecord(
                    senderDeviceID: decoded.message.senderDeviceID,
                    bootSessionID: decoded.message.bootSessionID,
                    seq: decoded.message.seq,
                    now: now,
                    isStateMutating: isMutating
                )
                switch verdict {
                case .accept:
                    break
                case .rejectTooOld, .rejectStaleOrder:
                    continue
                case .duplicate(let cachedReply):
                    // Idempotent retry: re-send cached ACK without re-executing!
                    if let cachedReply, let key = peerKeysByDeviceID[decoded.message.senderDeviceID] {
                        if let replyData = try? WirePacketCodec.encode(message: cachedReply, key: key, nonce: decoded.nonce) {
                            sendRaw(data: replyData, toIP: srcIP, port: srcPort)
                        }
                    }
                    continue
                }
            } else {
                guard decoded.message.cmd == .pairHello else { continue }
                guard allowPairHello(srcIP: srcIP) else { continue }

                let incoming = IncomingUDPPacket(
                    sourceIP: srcIP,
                    sourcePort: srcPort,
                    interfaceName: ifName,
                    packet: decoded
                )
                if tailscaleSnapshot.isKnownPeerIP(srcIP) {
                    onPacketReceived?(incoming)
                    continue
                }
                let now = ProcessInfo.processInfo.systemUptime
                if let cached = whoisCache[srcIP], cached.valid, now - cached.checkedAt < whoisTTL {
                    onPacketReceived?(incoming)
                    continue
                }
                // If Tailscale CLI is not installed (e.g. sandboxed Mac App Store Tailscale), accept utun* Tailscale-CIDR pairHello
                // (still requires interactive 6-digit SAS user approval). Otherwise verify via whois and replay immediately!
                if !TailscaleDiscovery.availableBinaries().isEmpty {
                    verifyWhoisAndDeliverPairHello(ip: srcIP, incoming: incoming)
                } else if ifName.hasPrefix("utun") || TailscaleIPValidator.isLoopback(srcIP) {
                    onPacketReceived?(incoming)
                }
                continue
            }

            let incoming = IncomingUDPPacket(
                sourceIP: srcIP,
                sourcePort: srcPort,
                interfaceName: ifName,
                packet: decoded
            )
            onPacketReceived?(incoming)
        }
    }

    private func allowPairHello(srcIP: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if pairRateLimiter.count > 64 {
            pairRateLimiter = pairRateLimiter.compactMapValues { stamps in
                let kept = stamps.filter { now - $0 < 30.0 }
                return kept.isEmpty ? nil : kept
            }
        }
        let recent = (pairRateLimiter[srcIP] ?? []).filter { now - $0 < 30.0 }
        if recent.count >= 6 {
            pairRateLimiter[srcIP] = recent
            return false
        }
        pairRateLimiter[srcIP] = recent + [now]
        return true
    }

    private func verifyWhoisAndDeliverPairHello(ip: String, incoming: IncomingUDPPacket) {
        let now = ProcessInfo.processInfo.systemUptime
        if whoisCache.count > 64 {
            whoisCache = whoisCache.filter { now - $0.value.checkedAt < whoisTTL }
        }
        if let cached = whoisCache[ip], !cached.valid, now - cached.checkedAt < 10.0 {
            return
        }
        whoisCache[ip] = (false, now)
        whoisQueue.async { [weak self] in
            let valid = TailscaleDiscovery.verifyPeerWhoisSync(ip: ip) != nil
            self?.queue.async {
                guard let self else { return }
                self.whoisCache[ip] = (valid, ProcessInfo.processInfo.systemUptime)
                if valid {
                    self.onPacketReceived?(incoming)
                } else if !self.tailscaleSnapshot.fromCLI && (incoming.interfaceName.hasPrefix("utun") || TailscaleIPValidator.isLoopback(ip)) {
                    // CLI binary exists (e.g. sandboxed App Store Tailscale.app stub) but cannot query Tailnet:
                    // utun* Tailscale WireGuard tunnel + 6-digit SAS interactive approval still protects pairing!
                    // Do NOT negative-cache this CLI stub failure so subsequent retries/replies aren't dropped.
                    self.whoisCache.removeValue(forKey: ip)
                    self.onPacketReceived?(incoming)
                }
            }
        }
    }

    // MARK: - Send Raw

    private func sendRaw(data: Data, toIP ip: String, port: UInt16) {
        let isV6 = ip.contains(":")
        let family: Int32 = isV6 ? AF_INET6 : AF_INET

        // Pick matching bound socket: NEVER fall back to a 127.0.0.1 loopback socket when sending to a Tailscale IP!
        let matchingSocket: Int32?
        if TailscaleIPValidator.isLoopback(ip) {
            matchingSocket = boundSockets.first(where: { $0.family == family && $0.bindIP == "127.0.0.1" })?.fd
                ?? boundSockets.first(where: { $0.family == family })?.fd
        } else {
            matchingSocket = boundSockets.first(where: { $0.family == family && $0.bindIP != "127.0.0.1" })?.fd
            if matchingSocket == nil {
                scheduleRebind(delay: 0.25)
            }
        }

        let tempFD: Int32
        let fd: Int32
        if let sock = matchingSocket {
            fd = sock
            tempFD = -1
        } else {
            tempFD = socket(family, SOCK_DGRAM, IPPROTO_UDP)
            guard tempFD >= 0 else { return }
            fd = tempFD
        }
        defer { if tempFD >= 0 { close(tempFD) } }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            if !isV6 {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = sendto(fd, base, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            } else {
                var addr = sockaddr_in6()
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = port.bigEndian
                guard inet_pton(AF_INET6, ip, &addr.sin6_addr) == 1 else { return }
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = sendto(fd, base, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
        }
    }

    // MARK: - Cmsg & Address Parsing

    private static func extractSenderAddress(from storage: inout sockaddr_storage) -> (String, UInt16)? {
        if storage.ss_family == sa_family_t(AF_INET) {
            return withUnsafePointer(to: &storage) { ptr -> (String, UInt16)? in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    guard inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil else { return nil }
                    return (String(cString: buf), UInt16(bigEndian: sin.pointee.sin_port))
                }
            }
        } else if storage.ss_family == sa_family_t(AF_INET6) {
            return withUnsafePointer(to: &storage) { ptr -> (String, UInt16)? in
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var addr = sin6.pointee.sin6_addr
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil else { return nil }
                    return (String(cString: buf), UInt16(bigEndian: sin6.pointee.sin6_port))
                }
            }
        }
        return nil
    }

    private static func extractInterfaceIndex(from msg: inout msghdr) -> UInt32 {
        guard let controlBase = msg.msg_control, msg.msg_controllen >= MemoryLayout<cmsghdr>.size else {
            return 0
        }
        let end = controlBase.advanced(by: Int(msg.msg_controllen))
        var cursor = controlBase

        while cursor.advanced(by: MemoryLayout<cmsghdr>.size) <= end {
            let hdr = cursor.assumingMemoryBound(to: cmsghdr.self).pointee
            let cmsgLen = Int(hdr.cmsg_len)
            guard cmsgLen >= MemoryLayout<cmsghdr>.size else { break }

            let dataOffset = alignedLength(MemoryLayout<cmsghdr>.size)
            let dataPtr = cursor.advanced(by: dataOffset)
            let dataEnd = cursor.advanced(by: cmsgLen)

            if hdr.cmsg_level == IPPROTO_IP && hdr.cmsg_type == IP_RECVIF {
                if dataPtr.advanced(by: MemoryLayout<sockaddr_dl>.size) <= dataEnd {
                    let sdl = dataPtr.assumingMemoryBound(to: sockaddr_dl.self).pointee
                    return UInt32(sdl.sdl_index)
                }
            } else if hdr.cmsg_level == IPPROTO_IPV6 && hdr.cmsg_type == tailime_ipv6_pktinfo_cmsg_type() {
                if dataPtr.advanced(by: MemoryLayout<in6_pktinfo>.size) <= dataEnd {
                    let info = dataPtr.assumingMemoryBound(to: in6_pktinfo.self).pointee
                    return info.ipi6_ifindex
                }
            }

            let step = alignedLength(cmsgLen)
            if step <= 0 { break }
            cursor = cursor.advanced(by: step)
        }
        return 0
    }

    private static func alignedLength(_ len: Int) -> Int {
        let align = MemoryLayout<UInt32>.size
        return (len + align - 1) & ~(align - 1)
    }
}

import CryptoKit
import Foundation

public enum WireCommand: String, Codable, Equatable, Sendable {
    case ping
    case pong
    case set            // Direct absolute language command (idempotent: "ko" or "en")
    case expectSet      // Hybrid safety net: execute absolute set if in-band carrier did not arrive
    case ack            // Response to set / expectSet with resulting language
    case state          // Proactive state push whenever a Mac's input source changes
    case status         // Request current language/source
    case probeQuery     // Ask remote peer if it just observed the in-band probe carrier key
    case probeResult    // Remote peer replies whether it observed the probe carrier + elapsed ms
    case pairHello      // Unauthenticated pairing handshake (carries publicKey for SAS verification)
    case pairAck        // Pairing acceptance response
}

public struct WireMessage: Codable, Equatable, Sendable {
    public var cmd: WireCommand
    public var senderDeviceID: String
    public var senderName: String?
    public var bootSessionID: String
    public var seq: UInt64
    public var replyToSeq: UInt64?
    public var targetLanguage: InputLanguage?
    public var currentLanguage: InputLanguage?
    public var sourceID: String?
    public var ok: Bool?
    public var via: String?               // "carrier", "udp", "udp-fallback", "cached-ack"
    public var carrierDeadlineMs: Int?
    public var probeToken: UInt64?
    public var probeObserved: Bool?
    public var publicKeyBase64: String?
    public var pairReply: Bool?           // true when responding to initiator's pairHello so both sides show SAS simultaneously
    public var version: String?

    public init(
        cmd: WireCommand,
        senderDeviceID: String,
        senderName: String? = nil,
        bootSessionID: String,
        seq: UInt64,
        replyToSeq: UInt64? = nil,
        targetLanguage: InputLanguage? = nil,
        currentLanguage: InputLanguage? = nil,
        sourceID: String? = nil,
        ok: Bool? = nil,
        via: String? = nil,
        carrierDeadlineMs: Int? = nil,
        probeToken: UInt64? = nil,
        probeObserved: Bool? = nil,
        publicKeyBase64: String? = nil,
        pairReply: Bool? = nil,
        version: String? = nil
    ) {
        self.cmd = cmd
        self.senderDeviceID = senderDeviceID
        self.senderName = senderName
        self.bootSessionID = bootSessionID
        self.seq = seq
        self.replyToSeq = replyToSeq
        self.targetLanguage = targetLanguage
        self.currentLanguage = currentLanguage
        self.sourceID = sourceID
        self.ok = ok
        self.via = via
        self.carrierDeadlineMs = carrierDeadlineMs
        self.probeToken = probeToken
        self.probeObserved = probeObserved
        self.publicKeyBase64 = publicKeyBase64
        self.pairReply = pairReply
        self.version = version
    }
}

public enum WirePacketError: Error, Equatable, Sendable {
    case invalidMagic
    case truncated
    case payloadTooLarge
    case timestampOutOfWindow
    case missingKeyForAuthenticatedPacket
    case invalidHMAC
    case unauthenticatedCommandNotAllowed
    case malformedPayload
}

public struct DecodedWirePacket: Equatable, Sendable {
    public let authenticated: Bool
    public let timestampMs: UInt64
    public let nonce: UInt64
    public let message: WireMessage
}

/// Compact UDP wire codec for `TIV1` packets (<1200B, fits in a single Tailscale WireGuard MTU frame).
///
/// Layout:
/// - Magic: "TIV1" (4 bytes)
/// - Flags: UInt8 (bit 0 = 1 if HMAC-SHA256 authenticated; 0 only permitted for `pairHello`)
/// - TimestampMs: UInt64 big-endian (8 bytes)
/// - Nonce: UInt64 big-endian (8 bytes)
/// - PayloadLen: UInt16 big-endian (2 bytes, <= 1024)
/// - Payload: UTF-8 JSON (PayloadLen bytes)
/// - MAC: 32 bytes HMAC-SHA256 when Flags bit 0 == 1 (omitted only for unauthenticated `pairHello`)
public enum WirePacketCodec {
    public static let magic: [UInt8] = Array("TIV1".utf8)
    public static let flagAuthenticated: UInt8 = 0x01
    public static let headerLength = 4 + 1 + 8 + 8 + 2 // 23 bytes
    public static let macLength = 32
    public static let maxPayloadBytes = 1024
    /// Loose ±5 minute window as secondary check alongside monotonic sequence replay window.
    public static let maxClockSkewMs: UInt64 = 5 * 60 * 1000

    public static func encode(
        message: WireMessage,
        key: SymmetricKey?,
        timestampMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        nonce: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= maxPayloadBytes else {
            throw WirePacketError.payloadTooLarge
        }

        let isAuth = key != nil
        if !isAuth && message.cmd != .pairHello {
            throw WirePacketError.unauthenticatedCommandNotAllowed
        }

        var packet = Data(capacity: headerLength + payload.count + (isAuth ? macLength : 0))
        packet.append(contentsOf: magic)
        packet.append(isAuth ? flagAuthenticated : 0x00)
        appendBigEndian(timestampMs, to: &packet)
        appendBigEndian(nonce, to: &packet)
        appendBigEndian(UInt16(payload.count), to: &packet)
        packet.append(payload)

        if let key {
            let mac = HMAC<SHA256>.authenticationCode(for: packet, using: key)
            packet.append(contentsOf: mac)
        }
        return packet
    }

    /// Decodes and verifies a packet. `keyLookup` receives `(senderDeviceID)` parsed after structural check
    /// and returns the per-peer `SymmetricKey` for constant-time HMAC validation.
    public static func decode(
        data: Data,
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        keyLookup: (_ senderDeviceID: String) -> SymmetricKey?
    ) throws -> DecodedWirePacket {
        guard data.count >= headerLength else {
            throw WirePacketError.truncated
        }
        let bytes = [UInt8](data)
        guard bytes[0] == magic[0], bytes[1] == magic[1], bytes[2] == magic[2], bytes[3] == magic[3] else {
            throw WirePacketError.invalidMagic
        }

        let flags = bytes[4]
        let isAuth = (flags & flagAuthenticated) != 0
        let timestampMs = readBigEndianUInt64(bytes, offset: 5)
        let nonce = readBigEndianUInt64(bytes, offset: 13)
        let payloadLen = Int(readBigEndianUInt16(bytes, offset: 21))

        guard payloadLen <= maxPayloadBytes else {
            throw WirePacketError.payloadTooLarge
        }
        let expectedLen = headerLength + payloadLen + (isAuth ? macLength : 0)
        guard data.count == expectedLen else {
            throw WirePacketError.truncated
        }

        // Timestamp sanity check (±5 min)
        let diff = nowMs >= timestampMs ? (nowMs - timestampMs) : (timestampMs - nowMs)
        guard diff <= maxClockSkewMs else {
            throw WirePacketError.timestampOutOfWindow
        }

        let payloadRange = headerLength..<(headerLength + payloadLen)
        let payloadData = data.subdata(in: payloadRange)
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: payloadData),
              !message.senderDeviceID.isEmpty,
              !message.bootSessionID.isEmpty else {
            throw WirePacketError.malformedPayload
        }

        if isAuth {
            guard let key = keyLookup(message.senderDeviceID) else {
                throw WirePacketError.missingKeyForAuthenticatedPacket
            }
            let signedBody = data.subdata(in: 0..<(headerLength + payloadLen))
            let receivedMAC = data.subdata(in: (headerLength + payloadLen)..<expectedLen)
            guard HMAC<SHA256>.isValidAuthenticationCode(receivedMAC, authenticating: signedBody, using: key) else {
                throw WirePacketError.invalidHMAC
            }
        } else {
            // Only `pairHello` is ever allowed without a pre-established HMAC key.
            guard message.cmd == .pairHello,
                  let pubKey = message.publicKeyBase64,
                  CryptoIdentity.deviceID(forPublicKeyBase64: pubKey) == message.senderDeviceID else {
                throw WirePacketError.unauthenticatedCommandNotAllowed
            }
        }

        return DecodedWirePacket(
            authenticated: isAuth,
            timestampMs: timestampMs,
            nonce: nonce,
            message: message
        )
    }

    private static func appendBigEndian(_ value: UInt64, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func appendBigEndian(_ value: UInt16, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func readBigEndianUInt64(_ bytes: [UInt8], offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }

    private static func readBigEndianUInt16(_ bytes: [UInt8], offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}

/// Sliding-window replay guard per `(senderDeviceID, bootSessionID)` plus idempotent cached-ACK store
/// and strict latest-order enforcement for state-mutating commands (`.set`, `.expectSet`, `.state`).
public struct SlidingWindowReplayGuard: Sendable {
    public enum Verdict: Equatable, Sendable {
        case accept
        case duplicate(cachedReply: WireMessage?)
        case rejectStaleOrder
        case rejectTooOld
    }

    private struct SessionWindow: Sendable {
        var highestSeq: UInt64 = 0
        var highestMutatingSeq: UInt64 = 0
        var bitmap: UInt64 = 0
        var lastSeenAt: TimeInterval = 0
        var cachedReplies: [UInt64: WireMessage] = [:]
    }

    private var sessions: [String: SessionWindow] = [:]
    private let maxSessions = 64

    public init() {}

    public mutating func checkAndRecord(
        senderDeviceID: String,
        bootSessionID: String,
        seq: UInt64,
        now: TimeInterval,
        isStateMutating: Bool = false
    ) -> Verdict {
        guard seq > 0 else { return .rejectTooOld }
        let key = "\(senderDeviceID)#\(bootSessionID)"

        if sessions.count > maxSessions {
            let staleKeys = sessions.filter { now - $0.value.lastSeenAt > 3600 }.map(\.key)
            for k in staleKeys { sessions.removeValue(forKey: k) }
        }

        var window = sessions[key] ?? SessionWindow()
        window.lastSeenAt = now

        if window.highestSeq == 0 {
            window.highestSeq = seq
            if isStateMutating { window.highestMutatingSeq = seq }
            window.bitmap = 1
            sessions[key] = window
            return .accept
        }

        if seq > window.highestSeq {
            let shift = seq - window.highestSeq
            if shift >= 64 {
                window.bitmap = 1
            } else {
                window.bitmap = (window.bitmap << shift) | 1
            }
            window.highestSeq = seq
            if isStateMutating && seq > window.highestMutatingSeq {
                window.highestMutatingSeq = seq
            }
            if window.cachedReplies.count > 32 {
                let minKept = window.highestSeq > 64 ? (window.highestSeq - 64) : 0
                window.cachedReplies = window.cachedReplies.filter { $0.key >= minKept }
            }
            sessions[key] = window
            return .accept
        }

        let delta = window.highestSeq - seq
        if delta >= 64 {
            return .rejectTooOld
        }

        let bit = UInt64(1) << delta
        if (window.bitmap & bit) != 0 {
            return .duplicate(cachedReply: window.cachedReplies[seq])
        }

        // First-time seeing an out-of-order older packet:
        // Reject if it is a state-mutating command older than an already-applied newer mutating command!
        window.bitmap |= bit
        if isStateMutating && seq < window.highestMutatingSeq {
            sessions[key] = window
            return .rejectStaleOrder
        }
        if isStateMutating && seq > window.highestMutatingSeq {
            window.highestMutatingSeq = seq
        }
        sessions[key] = window
        return .accept
    }

    public mutating func cacheReply(
        _ reply: WireMessage,
        senderDeviceID: String,
        bootSessionID: String,
        seq: UInt64
    ) {
        let key = "\(senderDeviceID)#\(bootSessionID)"
        guard var window = sessions[key] else { return }
        window.cachedReplies[seq] = reply
        sessions[key] = window
    }
}

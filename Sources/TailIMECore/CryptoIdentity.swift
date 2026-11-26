import CryptoKit
import Foundation
import Security

/// Per-device persistent Curve25519 identity backed by macOS Keychain.
/// Derives unique per-peer 256-bit HMAC keys via ECDH + HKDF-SHA256 and a 6-digit SAS code.
public struct CryptoIdentity: Sendable {
    public static let defaultKeychainService = "com.tailime.app.identity"
    public static let defaultKeychainAccount = "curve25519-key-agreement-v1"

    private let privateKeyBytes: Data

    public let publicKeyData: Data
    public let publicKeyBase64: String
    public let deviceID: String

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKeyBytes = privateKey.rawRepresentation
        self.publicKeyData = privateKey.publicKey.rawRepresentation
        self.publicKeyBase64 = publicKeyData.base64EncodedString()
        self.deviceID = Self.computeDeviceID(publicKeyData: publicKeyData)
    }

    public enum KeychainReadOutcome: Equatable, Sendable {
        case found(Data)
        case notFound
        case accessDenied(OSStatus)
    }

    public enum IdentityLoadResult: Sendable {
        case loaded(CryptoIdentity)
        case created(CryptoIdentity)
        case keychainLocked(OSStatus)
        case saveFailed(OSStatus)

        public var identity: CryptoIdentity? {
            switch self {
            case .loaded(let id), .created(let id): return id
            case .keychainLocked, .saveFailed: return nil
            }
        }

        public var isPersistent: Bool {
            identity != nil
        }

        public var errorStatus: OSStatus? {
            switch self {
            case .loaded, .created: return nil
            case .keychainLocked(let st), .saveFailed(let st): return st
            }
        }
    }

    public static func generateEphemeral() -> CryptoIdentity {
        CryptoIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    /// Loads the persistent Curve25519 identity from Keychain without EVER overwriting an existing item
    /// if Keychain access was denied/cancelled (`errSecAuthFailed`, `errSecUserCanceled`, etc.).
    public static func loadOrCreateDetailed(
        service: String = defaultKeychainService,
        account: String = defaultKeychainAccount
    ) -> IdentityLoadResult {
        loadOrCreateWithStore(
            read: { readKeychainItemDetailed(service: service, account: account) },
            add: { addKeychainItem($0, service: service, account: account) },
            update: { updateKeychainItem($0, service: service, account: account) }
        )
    }

    /// Pure testable state machine backing `loadOrCreateDetailed`.
    public static func loadOrCreateWithStore(
        read: () -> KeychainReadOutcome,
        add: (Data) -> OSStatus,
        update: (Data) -> OSStatus
    ) -> IdentityLoadResult {
        switch read() {
        case .found(let raw):
            if let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
                return .loaded(CryptoIdentity(privateKey: key))
            }
            // Read succeeded with corrupted payload -> safely replace with a valid key.
            let repaired = Curve25519.KeyAgreement.PrivateKey()
            let st = update(repaired.rawRepresentation)
            return st == errSecSuccess ? .created(CryptoIdentity(privateKey: repaired)) : .saveFailed(st)

        case .notFound:
            // Only create a brand-new persistent identity when Keychain explicitly reports errSecItemNotFound.
            let fresh = Curve25519.KeyAgreement.PrivateKey()
            let st = add(fresh.rawRepresentation)
            return st == errSecSuccess ? .created(CryptoIdentity(privateKey: fresh)) : .saveFailed(st)

        case .accessDenied(let status):
            // NEVER overwrite or rotate an existing Keychain identity on ACL denial / cancel / lock!
            return .keychainLocked(status)
        }
    }

    public static func loadOrCreateFromKeychain(
        service: String = defaultKeychainService,
        account: String = defaultKeychainAccount
    ) -> CryptoIdentity? {
        loadOrCreateDetailed(service: service, account: account).identity
    }

    public static func computeDeviceID(publicKeyData: Data) -> String {
        let digest = SHA256.hash(data: publicKeyData)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func deviceID(forPublicKeyBase64 base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return computeDeviceID(publicKeyData: data)
    }

    /// Derives a deterministic, unique 256-bit HMAC SymmetricKey for a specific peer using X25519 + HKDF-SHA256.
    public func derivePeerHMACKey(peerPublicKeyBase64: String) -> SymmetricKey? {
        guard let peerPubData = Data(base64Encoded: peerPublicKeyBase64),
              peerPubData.count == 32,
              let privKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyBytes),
              let peerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubData),
              let shared = try? privKey.sharedSecretFromKeyAgreement(with: peerPub) else {
            return nil
        }
        let peerID = Self.computeDeviceID(publicKeyData: peerPubData)
        let ordered = [deviceID, peerID].sorted().joined(separator: "|")
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("TailIME-HMAC-v1".utf8),
            sharedInfo: Data(ordered.utf8),
            outputByteCount: 32
        )
    }

    /// Derives a human-verifiable 6-digit Short Authentication String (SAS) code ("123-456") identical on both Macs.
    public func confirmationCode(peerPublicKeyBase64: String) -> String? {
        guard let peerPubData = Data(base64Encoded: peerPublicKeyBase64),
              peerPubData.count == 32,
              let privKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyBytes),
              let peerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubData),
              let shared = try? privKey.sharedSecretFromKeyAgreement(with: peerPub) else {
            return nil
        }
        let peerID = Self.computeDeviceID(publicKeyData: peerPubData)
        let ordered = [deviceID, peerID].sorted().joined(separator: "|")
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("TailIME-SAS-v1".utf8),
            sharedInfo: Data(ordered.utf8),
            outputByteCount: 4
        )
        let rawVal = key.withUnsafeBytes { buf -> UInt32 in
            buf.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let code = rawVal % 1_000_000
        return String(format: "%03u-%03u", code / 1000, code % 1000)
    }

    // MARK: - Compact Pairing Token (Copy/Paste or CLI stdin)

    public struct PairingTokenPayload: Codable, Equatable, Sendable {
        public let v: Int
        public let deviceID: String
        public let name: String
        public let publicKeyBase64: String
        public let tailscaleIP: String?
        public let port: UInt16

        public init(
            deviceID: String,
            name: String,
            publicKeyBase64: String,
            tailscaleIP: String?,
            port: UInt16
        ) {
            self.v = 1
            self.deviceID = deviceID
            self.name = name
            self.publicKeyBase64 = publicKeyBase64
            self.tailscaleIP = tailscaleIP
            self.port = port
        }
    }

    public func exportPairingToken(hostName: String, tailscaleIP: String?, port: UInt16) -> String? {
        let payload = PairingTokenPayload(
            deviceID: deviceID,
            name: hostName,
            publicKeyBase64: publicKeyBase64,
            tailscaleIP: tailscaleIP,
            port: port
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "TKP1:\(b64)"
    }

    public static func decodePairingToken(_ token: String) -> PairingTokenPayload? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("TKP1:") else { return nil }
        var b64 = String(trimmed.dropFirst(5))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem != 0 {
            b64 += String(repeating: "=", count: 4 - rem)
        }
        guard let data = Data(base64Encoded: b64),
              let payload = try? JSONDecoder().decode(PairingTokenPayload.self, from: data),
              payload.v == 1,
              Self.deviceID(forPublicKeyBase64: payload.publicKeyBase64) == payload.deviceID else {
            return nil
        }
        return payload
    }

    // MARK: - Keychain Helpers

    private static func readKeychainItemDetailed(service: String, account: String) -> KeychainReadOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            if let data = result as? Data {
                return .found(data)
            }
            return .accessDenied(errSecDecode)
        }
        if status == errSecItemNotFound {
            return .notFound
        }
        return .accessDenied(status)
    }

    private static func addKeychainItem(_ data: Data, service: String, account: String) -> OSStatus {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(item as CFDictionary, nil)
    }

    private static func updateKeychainItem(_ data: Data, service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}

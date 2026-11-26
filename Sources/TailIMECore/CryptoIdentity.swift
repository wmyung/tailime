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

    public static func generateEphemeral() -> CryptoIdentity {
        CryptoIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    public static func loadOrCreateFromKeychain(
        service: String = defaultKeychainService,
        account: String = defaultKeychainAccount
    ) -> CryptoIdentity? {
        if let raw = readKeychainItem(service: service, account: account),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return CryptoIdentity(privateKey: key)
        }
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        guard saveKeychainItem(fresh.rawRepresentation, service: service, account: account) else {
            return nil
        }
        return CryptoIdentity(privateKey: fresh)
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

    private static func readKeychainItem(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func saveKeychainItem(_ data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        for (k, v) in attributes { item[k] = v }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

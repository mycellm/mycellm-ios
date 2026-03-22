import Foundation
import CryptoKit
import SwiftCBOR

/// Certificate binding a device key to an account, signed by the account master key.
///
/// Wire-compatible with Python `mycellm.identity.certs.DeviceCert`.
struct DeviceCert: Sendable {
    let accountPubkey: Data   // 32-byte raw Ed25519
    let devicePubkey: Data    // 32-byte raw Ed25519
    let deviceName: String
    var role: String = "seeder"
    let createdAt: Double
    var expiresAt: Double = 0.0
    var revoked: Bool = false
    var signature: Data = Data()

    var peerId: String {
        PeerId.from(publicKeyBytes: devicePubkey)
    }

    var isExpired: Bool {
        guard expiresAt > 0 else { return false }
        return Date().timeIntervalSince1970 > expiresAt
    }

    // MARK: - CBOR Serialization

    /// Encode the signable portion (everything except signature).
    func toCBORPayload() -> Data {
        let map: CBOR = .map([
            .utf8String("account_pubkey"): .byteString(Array(accountPubkey)),
            .utf8String("device_pubkey"): .byteString(Array(devicePubkey)),
            .utf8String("device_name"): .utf8String(deviceName),
            .utf8String("role"): .utf8String(role),
            .utf8String("created_at"): .double(createdAt),
            .utf8String("expires_at"): .double(expiresAt),
            .utf8String("revoked"): .boolean(revoked),
        ])
        return Data(map.encode())
    }

    /// Encode the full certificate including signature.
    func toCBOR() -> Data {
        let map: CBOR = .map([
            .utf8String("account_pubkey"): .byteString(Array(accountPubkey)),
            .utf8String("device_pubkey"): .byteString(Array(devicePubkey)),
            .utf8String("device_name"): .utf8String(deviceName),
            .utf8String("role"): .utf8String(role),
            .utf8String("created_at"): .double(createdAt),
            .utf8String("expires_at"): .double(expiresAt),
            .utf8String("revoked"): .boolean(revoked),
            .utf8String("signature"): .byteString(Array(signature)),
        ])
        return Data(map.encode())
    }

    /// Decode a certificate from CBOR bytes.
    static func fromCBOR(_ data: Data) throws -> DeviceCert {
        guard let cbor = try CBOR.decode(Array(data)),
              case let .map(map) = cbor else {
            throw MycellmError.invalidCBOR("Expected CBOR map for DeviceCert")
        }

        guard let accountPubkey = map[.utf8String("account_pubkey")]?.bytesValue,
              let devicePubkey = map[.utf8String("device_pubkey")]?.bytesValue,
              let deviceName = map[.utf8String("device_name")]?.stringValue else {
            throw MycellmError.invalidCBOR("Missing required DeviceCert fields")
        }

        return DeviceCert(
            accountPubkey: Data(accountPubkey),
            devicePubkey: Data(devicePubkey),
            deviceName: deviceName,
            role: map[.utf8String("role")]?.stringValue ?? "seeder",
            createdAt: map[.utf8String("created_at")]?.doubleValue ?? 0.0,
            expiresAt: map[.utf8String("expires_at")]?.doubleValue ?? 0.0,
            revoked: map[.utf8String("revoked")]?.boolValue ?? false,
            signature: Data(map[.utf8String("signature")]?.bytesValue ?? [])
        )
    }

    // MARK: - Creation & Verification

    /// Create and sign a device certificate.
    static func create(
        accountKey: AccountKey,
        deviceKey: DeviceKey,
        deviceName: String = "default",
        role: String = "seeder",
        ttlSeconds: Double? = nil
    ) throws -> DeviceCert {
        let now = Date().timeIntervalSince1970
        var cert = DeviceCert(
            accountPubkey: accountKey.publicBytes,
            devicePubkey: deviceKey.publicBytes,
            deviceName: deviceName,
            role: role,
            createdAt: now,
            expiresAt: ttlSeconds.map { now + $0 } ?? 0.0
        )
        cert.signature = try accountKey.sign(cert.toCBORPayload())
        return cert
    }

    /// Verify the certificate's signature and validity.
    func verify(accountPubkey: Data? = nil) -> Bool {
        if revoked { return false }
        if isExpired { return false }

        if let expected = accountPubkey, self.accountPubkey != expected {
            return false
        }

        do {
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: self.accountPubkey)
            return pub.isValidSignature(signature, for: toCBORPayload())
        } catch {
            return false
        }
    }
}


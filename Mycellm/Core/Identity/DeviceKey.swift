import Foundation
import CryptoKit

/// Per-device Ed25519 keypair. Signs NodeHello messages and receipts.
struct DeviceKey: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey

    var publicKey: Curve25519.Signing.PublicKey { privateKey.publicKey }

    /// Raw 32-byte public key bytes.
    var publicBytes: Data { Data(publicKey.rawRepresentation) }

    /// Hex-encoded public key.
    var publicHex: String { publicBytes.hexString }

    func sign(_ data: Data) throws -> Data {
        Data(try privateKey.signature(for: data))
    }

    /// Generate a new device keypair.
    static func generate() -> DeviceKey {
        DeviceKey(privateKey: Curve25519.Signing.PrivateKey())
    }

    init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    init(rawPrivateKey: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
    }
}

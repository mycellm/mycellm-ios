import Foundation
import Crypto

/// Master account Ed25519 keypair. Signs device certificates.
struct AccountKey: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey

    var publicKey: Curve25519.Signing.PublicKey { privateKey.publicKey }

    /// Raw 32-byte public key bytes.
    var publicBytes: Data { Data(publicKey.rawRepresentation) }

    /// Hex-encoded public key.
    var publicHex: String { publicBytes.hexString }

    func sign(_ data: Data) throws -> Data {
        Data(try privateKey.signature(for: data))
    }

    /// Generate a new account keypair.
    static func generate() -> AccountKey {
        AccountKey(privateKey: Curve25519.Signing.PrivateKey())
    }

    /// Initialize from raw 32-byte private key seed.
    init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Initialize from raw private key bytes.
    init(rawPrivateKey: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
    }
}

import Foundation
import CryptoKit

/// PeerId = SHA256(raw_32_byte_ed25519_pubkey).hexdigest()[:32]
///
/// Wire-compatible with Python: `hashlib.sha256(raw).hexdigest()[:32]`
enum PeerId {
    /// Compute peer ID from a Curve25519 signing public key.
    static func from(publicKey: Curve25519.Signing.PublicKey) -> String {
        from(publicKeyBytes: Data(publicKey.rawRepresentation))
    }

    /// Compute peer ID from raw 32-byte Ed25519 public key bytes.
    static func from(publicKeyBytes: Data) -> String {
        let digest = SHA256.hash(data: publicKeyBytes)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }
}

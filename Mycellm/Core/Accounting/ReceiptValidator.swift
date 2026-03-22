import Foundation
import CryptoKit

/// Validates receipts with replay protection and rate limiting.
/// Wire-compatible with Python `ReceiptValidator`.
actor ReceiptValidator {
    private var seenRequestIds: [String: Date] = [:]
    private var creditRate: [String: [Date]] = [:]
    private let maxRatePerMinute: Int
    private let requestIdTTL: TimeInterval = 3600 // 1 hour dedup window

    init(maxRatePerMinute: Int = 100) {
        self.maxRatePerMinute = maxRatePerMinute
    }

    /// Check if a request_id has been seen before. Returns true if NEW (not replay).
    func checkReplay(requestId: String) -> Bool {
        guard !requestId.isEmpty else { return true }

        let now = Date()
        // Prune old entries
        seenRequestIds = seenRequestIds.filter { now.timeIntervalSince($0.value) < requestIdTTL }

        if seenRequestIds[requestId] != nil { return false }
        seenRequestIds[requestId] = now
        return true
    }

    /// Check if a peer is self-crediting too fast. Returns true if OK.
    func checkCreditRate(peerId: String) -> Bool {
        let now = Date()
        let timestamps = creditRate[peerId, default: []]
        creditRate[peerId] = timestamps.filter { now.timeIntervalSince($0) < 60.0 }

        guard creditRate[peerId]!.count < maxRatePerMinute else { return false }
        creditRate[peerId]!.append(now)
        return true
    }

    /// Verify a receipt's Ed25519 signature.
    func verifySignature(receiptData: Data, signatureHex: String, seederPubkeyBytes: Data) -> Bool {
        guard let sigData = Data(hex: signatureHex) else { return false }
        do {
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: seederPubkeyBytes)
            return pub.isValidSignature(sigData, for: receiptData)
        } catch {
            return false
        }
    }
}

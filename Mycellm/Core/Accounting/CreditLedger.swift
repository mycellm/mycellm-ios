import Foundation
import CryptoKit
import SwiftCBOR

/// Local credit tracking with signed receipt generation and bootstrap submission.
actor CreditLedger {
    private(set) var balance: Double = 100.0  // Seed balance
    private(set) var totalEarned: Double = 0.0
    private(set) var totalSpent: Double = 0.0
    private var transactions: [Transaction] = []
    private var pendingReceipts: [SignedReceipt] = []
    private var bootstrapEndpoint: String = "https://api.mycellm.dev"

    struct Transaction: Sendable {
        let counterparty: String
        let amount: Double
        let direction: Direction
        let reason: String
        let timestamp: Date
        let requestId: String
        let receiptSignature: String

        enum Direction: String, Sendable {
            case earned
            case spent
        }
    }

    struct SignedReceipt: Sendable, Codable {
        let consumerId: String
        let seederId: String
        let model: String
        let tokens: Int
        let cost: Double
        let requestId: String
        let timestamp: Double
        let signature: String
    }

    func configure(bootstrapEndpoint: String) {
        self.bootstrapEndpoint = bootstrapEndpoint
    }

    // MARK: - Earn (seeder side)

    /// Record earning from serving inference. Signs a receipt and queues for submission.
    func earn(
        amount: Double,
        from consumerId: String,
        seederId: String,
        model: String,
        tokens: Int,
        requestId: String,
        deviceKey: DeviceKey
    ) throws -> SignedReceipt {
        let ts = Date().timeIntervalSince1970

        // Build canonical CBOR receipt data (wire-compatible with Python)
        let receiptData = buildReceiptData(
            consumerId: consumerId,
            seederId: seederId,
            model: model,
            tokens: tokens,
            cost: amount,
            requestId: requestId,
            timestamp: ts
        )

        // Sign with device key
        let signature = try deviceKey.sign(receiptData)
        let signatureHex = signature.hexString

        let receipt = SignedReceipt(
            consumerId: consumerId,
            seederId: seederId,
            model: model,
            tokens: tokens,
            cost: amount,
            requestId: requestId,
            timestamp: ts,
            signature: signatureHex
        )

        balance += amount
        totalEarned += amount
        transactions.append(Transaction(
            counterparty: consumerId, amount: amount,
            direction: .earned, reason: "inference: \(model)",
            timestamp: Date(), requestId: requestId,
            receiptSignature: signatureHex
        ))

        pendingReceipts.append(receipt)
        return receipt
    }

    // MARK: - Spend (consumer side)

    /// Record spending from consuming inference. Verifies the seeder's receipt signature.
    func spend(
        receipt: SignedReceipt,
        seederPubkeyBytes: Data
    ) -> Bool {
        // Verify signature
        let receiptData = buildReceiptData(
            consumerId: receipt.consumerId,
            seederId: receipt.seederId,
            model: receipt.model,
            tokens: receipt.tokens,
            cost: receipt.cost,
            requestId: receipt.requestId,
            timestamp: receipt.timestamp
        )

        guard let sigData = Data(hex: receipt.signature) else { return false }
        do {
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: seederPubkeyBytes)
            guard pub.isValidSignature(sigData, for: receiptData) else { return false }
        } catch {
            return false
        }

        balance -= receipt.cost
        totalSpent += receipt.cost
        transactions.append(Transaction(
            counterparty: receipt.seederId, amount: receipt.cost,
            direction: .spent, reason: "inference: \(receipt.model)",
            timestamp: Date(), requestId: receipt.requestId,
            receiptSignature: receipt.signature
        ))

        pendingReceipts.append(receipt)
        return true
    }

    // MARK: - Bootstrap Submission

    /// Submit pending receipts to bootstrap for auditing.
    func submitPendingReceipts() async {
        guard !pendingReceipts.isEmpty else { return }
        guard let url = URL(string: "\(bootstrapEndpoint)/v1/admin/nodes/announce") else { return }

        let receiptsToSend = pendingReceipts
        pendingReceipts.removeAll()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "receipts": receiptsToSend.map { r in
                [
                    "consumer_id": r.consumerId,
                    "seeder_id": r.seederId,
                    "model": r.model,
                    "tokens": r.tokens,
                    "cost": r.cost,
                    "request_id": r.requestId,
                    "timestamp": r.timestamp,
                    "signature": r.signature,
                ] as [String: Any]
            }
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // Re-queue on failure
                pendingReceipts.append(contentsOf: receiptsToSend)
            }
        } catch {
            // Re-queue on failure
            pendingReceipts.append(contentsOf: receiptsToSend)
        }
    }

    // MARK: - Queries

    func recentTransactions(limit: Int = 50) -> [Transaction] {
        Array(transactions.suffix(limit).reversed())
    }

    func canAfford(cost: Double) -> Bool {
        balance >= cost
    }

    var pendingReceiptCount: Int { pendingReceipts.count }
}

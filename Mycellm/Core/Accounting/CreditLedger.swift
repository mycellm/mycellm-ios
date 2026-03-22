import Foundation

/// Local credit tracking. Credits earned from serving inference, spent from consuming.
actor CreditLedger {
    private(set) var balance: Double = 0.0
    private(set) var totalEarned: Double = 0.0
    private(set) var totalSpent: Double = 0.0
    private var transactions: [Transaction] = []

    struct Transaction: Sendable {
        let counterparty: String
        let amount: Double
        let direction: Direction
        let reason: String
        let timestamp: Date

        enum Direction: String, Sendable {
            case earned
            case spent
        }
    }

    func earn(amount: Double, from peer: String, reason: String) {
        balance += amount
        totalEarned += amount
        transactions.append(Transaction(
            counterparty: peer, amount: amount,
            direction: .earned, reason: reason, timestamp: Date()
        ))
    }

    func spend(amount: Double, to peer: String, reason: String) {
        balance -= amount
        totalSpent += amount
        transactions.append(Transaction(
            counterparty: peer, amount: amount,
            direction: .spent, reason: reason, timestamp: Date()
        ))
    }

    func recentTransactions(limit: Int = 50) -> [Transaction] {
        Array(transactions.suffix(limit).reversed())
    }
}

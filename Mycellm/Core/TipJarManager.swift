import Foundation
import StoreKit

/// StoreKit 2 tip jar for supporting mycellm development.
@Observable
final class TipJarManager: @unchecked Sendable {
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchaseState: PurchaseState = .idle
    private(set) var error: String?

    enum PurchaseState: Sendable {
        case idle
        case purchasing
        case success
        case failed(String)

        var isPurchasing: Bool {
            if case .purchasing = self { return true }
            return false
        }
    }

    /// Product identifiers — configured in App Store Connect.
    static let productIds: [String] = [
        "com.mycellm.tip.small",     // $0.99
        "com.mycellm.tip.medium",    // $2.99
        "com.mycellm.tip.large",     // $4.99
        "com.mycellm.tip.generous",  // $9.99
        "com.mycellm.tip.huge",      // $24.99
    ]

    /// Tip display metadata (used when StoreKit products aren't available yet).
    static let tipTiers: [(id: String, emoji: String, label: String)] = [
        ("com.mycellm.tip.small",    "☕", "Coffee"),
        ("com.mycellm.tip.medium",   "🍵", "Matcha"),
        ("com.mycellm.tip.large",    "🍕", "Pizza"),
        ("com.mycellm.tip.generous", "🍱", "Bento"),
        ("com.mycellm.tip.huge",     "🎉", "Party"),
    ]

    /// Load products from App Store Connect.
    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let storeProducts = try await Product.products(for: Self.productIds)
            products = storeProducts.sorted { $0.price < $1.price }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Purchase a tip.
    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    purchaseState = .success
                    // Reset after a few seconds
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        purchaseState = .idle
                    }
                case .unverified:
                    purchaseState = .failed("Verification failed")
                }
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
            Task {
                try? await Task.sleep(for: .seconds(3))
                purchaseState = .idle
            }
        }
    }

    /// Emoji for a product ID.
    func emoji(for productId: String) -> String {
        Self.tipTiers.first { $0.id == productId }?.emoji ?? "💚"
    }

    /// Label for a product ID.
    func label(for productId: String) -> String {
        Self.tipTiers.first { $0.id == productId }?.label ?? "Tip"
    }
}

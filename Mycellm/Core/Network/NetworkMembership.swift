import Foundation

/// A network this node participates in.
struct NetworkMembership: Identifiable, Codable, Sendable {
    let id: String               // network_id (UUID from bootstrap)
    var name: String             // Human-readable ("Dodecki Labs", "Public")
    var bootstrapHost: String    // Bootstrap endpoint
    var bootstrapPort: Int = 8421
    var inviteToken: String?     // Join credential (nil = already joined)
    var fleetKey: String?        // Fleet admin key (opt-in remote management)
    var joinedAt: Date = Date()

    // Trust & Policy
    var trustLevel: TrustLevel = .strict
    var creditMultiplier: Double = 1.0  // How credits are valued (1.0 = standard)

    // Fleet restrictions (pushed by admin, or self-configured)
    var policy: NetworkPolicy = NetworkPolicy()

    // Connection state (not persisted)
    var isConnected: Bool = false

    enum TrustLevel: String, Codable, Sendable, CaseIterable, Identifiable {
        case strict  = "Strict"    // Verify signatures + enforce balance
        case relaxed = "Relaxed"   // Verify signatures, don't enforce balance
        case honor   = "Honor"     // Skip verification (trusted group)

        var id: String { rawValue }

        var description: String {
            switch self {
            case .strict: "Verify all receipts and enforce credit balance"
            case .relaxed: "Verify receipts but allow negative balance"
            case .honor: "Trust all peers (homelab, close group)"
            }
        }
    }

    struct NetworkPolicy: Codable, Sendable {
        var allowExternalNetworks: Bool = true    // Can this node join other networks?
        var allowFederationInbound: Bool = true   // Accept routed requests from federated nets?
        var allowFederationOutbound: Bool = true  // Route requests to federated nets?
        var modelScopeOverride: String? = nil     // Force model scope (nil = user decides)
        var maxConcurrentInference: Int = 2       // Max simultaneous inferences for this network
    }

    /// HTTP API base URL for this network's bootstrap.
    var httpEndpoint: String {
        if bootstrapHost == BootstrapClient.defaultBootstrap {
            return "https://api.mycellm.dev"
        }
        return "http://\(bootstrapHost):8420"
    }

    /// The public mycellm network (default membership).
    static let publicNetwork = NetworkMembership(
        id: "public",
        name: "Public Network",
        bootstrapHost: BootstrapClient.defaultBootstrap,
        bootstrapPort: 8421,
        trustLevel: .strict,
        creditMultiplier: 1.0
    )
}

/// Manages the list of networks this node belongs to.
@Observable
final class NetworkRegistry: @unchecked Sendable {
    private(set) var memberships: [NetworkMembership] = []
    private(set) var ledgers: [String: CreditLedger] = [:]  // network_id → ledger

    private let defaults = UserDefaults.standard
    private let storageKey = "network_memberships"

    init() {
        loadMemberships()
        // Ensure public network is always present
        if !memberships.contains(where: { $0.id == "public" }) {
            memberships.insert(.publicNetwork, at: 0)
            saveMemberships()
        }
        // Create ledgers for each network
        for m in memberships {
            if ledgers[m.id] == nil {
                ledgers[m.id] = CreditLedger()
            }
        }
    }

    /// Join a new network.
    func join(
        name: String,
        bootstrapHost: String,
        bootstrapPort: Int = 8421,
        inviteToken: String? = nil,
        fleetKey: String? = nil,
        trustLevel: NetworkMembership.TrustLevel = .strict
    ) -> NetworkMembership {
        let id = UUID().uuidString.lowercased().prefix(16).description
        let membership = NetworkMembership(
            id: id,
            name: name,
            bootstrapHost: bootstrapHost,
            bootstrapPort: bootstrapPort,
            inviteToken: inviteToken,
            fleetKey: fleetKey,
            trustLevel: trustLevel
        )
        memberships.append(membership)
        ledgers[id] = CreditLedger()
        saveMemberships()
        return membership
    }

    /// Leave a network.
    func leave(networkId: String) {
        guard networkId != "public" else { return } // Can't leave public
        memberships.removeAll { $0.id == networkId }
        ledgers.removeValue(forKey: networkId)
        saveMemberships()
    }

    /// Update a membership's settings.
    func update(_ membership: NetworkMembership) {
        if let idx = memberships.firstIndex(where: { $0.id == membership.id }) {
            memberships[idx] = membership
            saveMemberships()
        }
    }

    /// Get the ledger for a network.
    func ledger(for networkId: String) -> CreditLedger? {
        ledgers[networkId]
    }

    /// Total credit balance across all networks.
    var totalBalance: Double {
        // Can't easily sum actor values synchronously — return cached
        return 100.0 // TODO: async sum
    }

    /// Check if any fleet restricts joining external networks.
    var canJoinNewNetworks: Bool {
        !memberships.contains { $0.fleetKey != nil && !$0.policy.allowExternalNetworks }
    }

    /// Networks that allow federation inbound.
    var federationInboundNetworks: [NetworkMembership] {
        memberships.filter { $0.policy.allowFederationInbound }
    }

    /// Networks that allow federation outbound.
    var federationOutboundNetworks: [NetworkMembership] {
        memberships.filter { $0.policy.allowFederationOutbound }
    }

    /// All network_ids for NodeHello capabilities.
    var networkIds: [String] {
        memberships.map(\.id)
    }

    // MARK: - Persistence

    private func saveMemberships() {
        if let data = try? JSONEncoder().encode(memberships) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func loadMemberships() {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([NetworkMembership].self, from: data) else {
            return
        }
        memberships = saved
    }
}

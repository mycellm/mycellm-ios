import Foundation

/// A network this node participates in.
struct NetworkMembership: Identifiable, Codable, Sendable {
    let id: String               // network_id (UUID from bootstrap)
    var name: String             // Human-readable ("Dodecki Labs", "Public")
    var bootstrapHost: String    // Bootstrap endpoint
    var bootstrapPort: Int = 8421
    var inviteToken: String?     // Join credential (nil = already joined)
    var fleetKey: String?        // Fleet admin key (opt-in remote management)
    /// Shared secret for a key-protected network. Presented in
    /// NodeHello.join_keys; the host drops this network's claim without it
    /// (py 0.6.2 FederationManager.filter_claimed_network_ids).
    var joinKey: String?
    var joinedAt: Date = Date()

    // Trust & Policy
    var trustLevel: TrustLevel = .strict
    var creditMultiplier: Double = 1.0  // How credits are valued (1.0 = standard)

    // Fleet restrictions (pushed by admin, or self-configured)
    var policy: NetworkPolicy = NetworkPolicy()

    /// Whether this node participates in the network. Disabled memberships are
    /// skipped by NodeService.start() and can be toggled live (connect on, tear
    /// down on off). Persisted; missing key in older saves decodes as `true`.
    /// Public can be disabled (private-only mode) but never removed.
    var enabled: Bool = true

    // Connection state (not persisted)
    var isConnected: Bool = false

    enum TrustLevel: String, Codable, Sendable, CaseIterable, Identifiable {
        case strict = "Strict"
        case relaxed = "Relaxed"
        case honor = "Honor"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .strict: String(localized: "Strict")
            case .relaxed: String(localized: "Relaxed")
            case .honor: String(localized: "Honor")
            }
        }

        var description: String {
            switch self {
            case .strict: String(localized: "Verify all receipts and enforce credit balance")
            case .relaxed: String(localized: "Verify receipts but allow negative balance")
            case .honor: String(localized: "Trust all peers (homelab, close group)")
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
            return NetworkConfig.apiBase
        }
        return "http://\(bootstrapHost):\(NetworkConfig.httpPort)"
    }

    /// Back-compat decoder: every field is optional-with-default so memberships
    /// saved before a field existed (notably `enabled`) still decode instead of
    /// throwing keyNotFound (which would silently drop all saved networks). The
    /// memberwise initializer is preserved by keeping this in an extension.
    private enum CodingKeys: String, CodingKey {
        case id, name, bootstrapHost, bootstrapPort, inviteToken, fleetKey, joinKey
        case joinedAt, trustLevel, creditMultiplier, policy, enabled, isConnected
    }

    /// A port outside 1...65535 would trap `UInt16(_:)` when dialing — and a
    /// persisted one crash-loops the app at every launch (a mistyped port in
    /// the detail sheet did exactly that). Never store or dial one.
    static func sanitizePort(_ port: Int?) -> Int {
        guard let port, (1...65535).contains(port) else { return 8421 }
        return port
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

extension NetworkMembership {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        bootstrapHost = try c.decodeIfPresent(String.self, forKey: .bootstrapHost) ?? ""
        // sanitize: heals installs that persisted an out-of-range port before
        // input validation existed (those crash-looped on launch).
        bootstrapPort = Self.sanitizePort(try c.decodeIfPresent(Int.self, forKey: .bootstrapPort))
        inviteToken = try c.decodeIfPresent(String.self, forKey: .inviteToken)
        fleetKey = try c.decodeIfPresent(String.self, forKey: .fleetKey)
        joinKey = try c.decodeIfPresent(String.self, forKey: .joinKey)
        joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt) ?? Date()
        trustLevel = try c.decodeIfPresent(TrustLevel.self, forKey: .trustLevel) ?? .strict
        creditMultiplier = try c.decodeIfPresent(Double.self, forKey: .creditMultiplier) ?? 1.0
        policy = try c.decodeIfPresent(NetworkPolicy.self, forKey: .policy) ?? NetworkPolicy()
        // Missing in older saves → default to enabled (back-compat).
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        isConnected = try c.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
    }
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

    #if DEBUG
    /// Populate a rich multi-network membership set for App Store screenshot
    /// capture (gated by ScreenshotMode; compiled out of Release builds).
    func applyScreenshotFixture() {
        var pub = NetworkMembership.publicNetwork
        pub.isConnected = true
        let homelab = NetworkMembership(
            id: "homelab", name: "Homelab",
            bootstrapHost: "studio-m5max.local",
            trustLevel: .honor, isConnected: true
        )
        let fleet = NetworkMembership(
            id: "studio-fleet", name: "Studio Fleet",
            bootstrapHost: "fleet.mycellm.dev",
            fleetKey: "fk_9a3f2c", trustLevel: .relaxed,
            creditMultiplier: 2.0, isConnected: true
        )
        memberships = [pub, homelab, fleet]
        for m in memberships where ledgers[m.id] == nil { ledgers[m.id] = CreditLedger() }
    }
    #endif

    /// Join a new network.
    ///
    /// `networkId` should be the HOST's network id whenever it's known (parsed
    /// from an invite token, or copied from the host's `mycellm network list`).
    /// The id is what NodeHello claims and what join_keys are keyed by — a
    /// locally-invented id can never authorize against a protected network.
    /// Without one we fall back to a local UUID (fine for unprotected nets).
    func join(
        name: String,
        bootstrapHost: String,
        bootstrapPort: Int = 8421,
        networkId: String? = nil,
        inviteToken: String? = nil,
        fleetKey: String? = nil,
        joinKey: String? = nil,
        trustLevel: NetworkMembership.TrustLevel = .strict
    ) -> NetworkMembership {
        let id = networkId?.isEmpty == false
            ? networkId!
            : UUID().uuidString.lowercased().prefix(16).description
        let membership = NetworkMembership(
            id: id,
            name: name,
            bootstrapHost: bootstrapHost,
            bootstrapPort: NetworkMembership.sanitizePort(bootstrapPort),
            inviteToken: inviteToken,
            fleetKey: fleetKey,
            joinKey: joinKey,
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

    /// Cached total balance — updated via refreshTotalBalance().
    private(set) var cachedTotalBalance: Double = 100.0

    /// Total credit balance across all networks (cached, call refreshTotalBalance() to update).
    var totalBalance: Double { cachedTotalBalance }

    /// Async sum of all network ledger balances.
    func refreshTotalBalance() async {
        var sum = 0.0
        for (_, ledger) in ledgers {
            sum += await ledger.balance
        }
        cachedTotalBalance = sum
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

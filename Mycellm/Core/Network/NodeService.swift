import Foundation
import Observation

/// Main node actor — composes identity, inference, transport, and API layers.
@Observable
final class NodeService: @unchecked Sendable {
    // MARK: - Identity
    private(set) var accountKey: AccountKey?
    private(set) var deviceKey: DeviceKey?
    private(set) var deviceCert: DeviceCert?
    private(set) var peerId: String = ""
    var nodeName: String = NodeNameGenerator.generate()

    // MARK: - State
    private(set) var isRunning = false
    private(set) var networkMode: NetworkMode = .standalone

    // MARK: - Stats
    private(set) var totalInferences: Int = 0
    private(set) var connectedPeers: Int = 0
    private(set) var loadedModels: Int = 0
    private(set) var creditBalance: Double = 0.0

    // MARK: - Activity
    private(set) var recentEvents: [ActivityItem] = []

    // MARK: - Initialization

    init() {
        loadOrCreateIdentity()
    }

    private func loadOrCreateIdentity() {
        // Try loading existing keys from Keychain
        if let ak = KeychainStore.loadAccountKey(),
           let dk = KeychainStore.loadDeviceKey() {
            accountKey = ak
            deviceKey = dk
        } else {
            // Generate new identity
            let ak = AccountKey.generate()
            let dk = DeviceKey.generate()
            try? KeychainStore.saveAccountKey(ak)
            try? KeychainStore.saveDeviceKey(dk)
            accountKey = ak
            deviceKey = dk
        }

        if let dk = deviceKey {
            peerId = PeerId.from(publicKey: dk.publicKey)
        }

        // Create device certificate
        if let ak = accountKey, let dk = deviceKey {
            deviceCert = try? DeviceCert.create(
                accountKey: ak,
                deviceKey: dk,
                deviceName: nodeName,
                role: "seeder"
            )
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        addEvent(.nodeStarted)
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        addEvent(.nodeStopped)
    }

    func setNetworkMode(_ mode: NetworkMode) {
        networkMode = mode
        addEvent(.networkModeChanged(mode))
    }

    // MARK: - Events

    private func addEvent(_ kind: ActivityItem.Kind) {
        let item = ActivityItem(kind: kind)
        recentEvents.insert(item, at: 0)
        if recentEvents.count > 100 {
            recentEvents.removeLast()
        }
    }
}

// MARK: - Activity Item

struct ActivityItem: Identifiable, Sendable {
    let id = UUID()
    let timestamp = Date()
    let kind: Kind

    enum Kind: Sendable {
        case nodeStarted
        case nodeStopped
        case networkModeChanged(NetworkMode)
        case modelLoaded(String)
        case modelUnloaded(String)
        case inferenceCompleted(model: String, tokens: Int)
        case peerConnected(String)
        case peerDisconnected(String)
        case error(String)
    }

    var icon: String {
        switch kind {
        case .nodeStarted: "play.circle.fill"
        case .nodeStopped: "stop.circle.fill"
        case .networkModeChanged: "network"
        case .modelLoaded: "arrow.down.circle.fill"
        case .modelUnloaded: "arrow.up.circle.fill"
        case .inferenceCompleted: "brain"
        case .peerConnected: "person.badge.plus"
        case .peerDisconnected: "person.badge.minus"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var description: String {
        switch kind {
        case .nodeStarted: "Node started"
        case .nodeStopped: "Node stopped"
        case .networkModeChanged(let mode): "Switched to \(mode.displayName)"
        case .modelLoaded(let name): "Loaded \(name)"
        case .modelUnloaded(let name): "Unloaded \(name)"
        case .inferenceCompleted(let model, let tokens): "\(model) — \(tokens) tokens"
        case .peerConnected(let peer): "Connected: \(peer.prefix(12))…"
        case .peerDisconnected(let peer): "Disconnected: \(peer.prefix(12))…"
        case .error(let msg): msg
        }
    }
}

// MARK: - Node Name Generator

enum NodeNameGenerator {
    private static let adjectives = [
        "bold", "rare", "keen", "deep", "calm", "swift", "wild", "dark",
        "soft", "true", "free", "warm", "cool", "wise", "fair", "pure",
    ]
    private static let nouns = [
        "mycel", "grove", "spore", "root", "cap", "stem", "ring", "web",
        "node", "link", "mesh", "seed", "leaf", "bark", "moss", "fern",
    ]

    static func generate() -> String {
        let adj = adjectives.randomElement()!
        let noun = nouns.randomElement()!
        return "\(adj)-\(noun)"
    }
}

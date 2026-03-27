import Foundation
import Observation

// MARK: - Stats (high-frequency changes — only Dashboard/Peers observe)

@Observable
final class NodeStats: @unchecked Sendable {
    var totalInferences: Int = 0
    var creditBalance: Double = 0.0
    private(set) var recentEvents: [ActivityItem] = []

    func addEvent(_ kind: ActivityItem.Kind) {
        let item = ActivityItem(kind: kind)
        recentEvents.insert(item, at: 0)
        if recentEvents.count > 100 {
            recentEvents.removeLast()
        }
    }
}

// MARK: - Connection (changes on connect/disconnect — Dashboard/Peers observe)

@Observable
final class NodeConnection: @unchecked Sendable {
    var bootstrapState: BootstrapClient.ConnectionState = .disconnected
    var bootstrapTransport: BootstrapClient.Transport = .none
    var bootstrapError: String?

    var connectedPeers: Int {
        bootstrapState == .connected ? 1 : 0
    }
}

// MARK: - Main Node Service

/// Main node — composes identity, inference, transport, and API layers.
/// Split into NodeService (stable) + NodeStats (frequent) + NodeConnection (occasional)
/// so views only re-render when their specific data changes.
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
    private(set) var networkMode: NetworkMode = .public

    // MARK: - Sub-observables
    let stats = NodeStats()
    let connection = NodeConnection()

    // MARK: - Networks
    let networkRegistry = NetworkRegistry()

    // MARK: - Models
    let modelManager = ModelManager()
    let modelDownloader = ModelDownloader()
    let relayManager = RelayManager()

    // MARK: - Services
    private let httpServer = HTTPServer()
    let bootstrapClient = BootstrapClient()
    private let peerManager = PeerManager()
    let creditLedger = CreditLedger()
    let natDiscovery = NATDiscovery()
    let receiptValidator = ReceiptValidator()
    let fleetHandler = FleetHandler()

    // MARK: - Computed (delegate to sub-observables)
    var loadedModels: Int { modelManager.loadedModels.count }

    // MARK: - Initialization

    @MainActor
    init() {
        loadOrCreateIdentity()
        networkMode = Preferences.shared.networkMode
        stats.creditBalance = 100.0
        modelManager.scanLocalModels()
        Task { await fleetHandler.setNodeService(self) }
    }

    private func loadOrCreateIdentity() {
        if let ak = KeychainStore.loadAccountKey(),
           let dk = KeychainStore.loadDeviceKey() {
            accountKey = ak
            deviceKey = dk
        } else {
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
        stats.addEvent(.nodeStarted)

        let prefs = await MainActor.run { Preferences.shared }

        if prefs.httpServerEnabled || networkMode.apiServerEnabled {
            do {
                try await httpServer.start(port: prefs.apiPort, nodeService: self)
                stats.addEvent(.httpServerStarted(prefs.apiPort))
            } catch {
                stats.addEvent(.error("HTTP server failed: \(error.localizedDescription)"))
            }
        }

        await MainActor.run { modelManager.scanLocalModels() }
        relayManager.startPolling()

        Task {
            await natDiscovery.start()
            // Emit network info after first probe
            try? await Task.sleep(for: .seconds(8))
            let nat = await natDiscovery.info
            if !nat.localIP.isEmpty || !nat.publicIP.isEmpty {
                stats.addEvent(.networkInfo(
                    lan: nat.localIP.isEmpty ? "—" : nat.localIP,
                    wan: nat.publicIP.isEmpty ? "—" : nat.publicIP,
                    nat: nat.natType.rawValue
                ))
            }
        }

        if networkMode.usesBootstrap {
            await bootstrapClient.configure(
                host: prefs.bootstrapHost,
                port: UInt16(prefs.quicPort)
            )

            let weakConn = Weak(self.connection)
            let weakStats = Weak(self.stats)
            await bootstrapClient.setStateHandler { @Sendable state, transport, error in
                Task { @MainActor in
                    guard let conn = weakConn.value, let stats = weakStats.value else { return }
                    let prev = conn.bootstrapState
                    conn.bootstrapState = state
                    conn.bootstrapTransport = transport
                    conn.bootstrapError = error
                    if state != prev {
                        switch state {
                        case .connected:
                            stats.addEvent(.peerConnected("bootstrap via \(transport.rawValue)"))
                        case .failed where prev != .failed:
                            stats.addEvent(.error("Bootstrap: \(error ?? "connection failed")"))
                        case .fallbackHTTP where prev != .fallbackHTTP:
                            stats.addEvent(.error("QUIC unavailable — trying HTTP"))
                        default:
                            break
                        }
                    }
                }
            }

            let publicModels = modelManager.loadedModels.filter { $0.scope == "public" }
            let caps = Capabilities(
                models: publicModels.map { m in
                    ModelCapability(name: m.name, backend: "llama.cpp", scope: m.scope)
                },
                hardware: HardwareInfo.capabilitiesHardware(),
                role: publicModels.isEmpty ? "consumer" : "seeder",
                version: NetworkConfig.version
            )

            let weakSelf = Weak(self)
            await bootstrapClient.setInferenceHandler { @Sendable envelope in
                return await weakSelf.value?.handleRelayedInference(envelope)
            }

            stats.addEvent(.networkModeChanged(networkMode))
            await bootstrapClient.connect(peerId: peerId, capabilities: caps, deviceKey: deviceKey, deviceCert: deviceCert)
        }
    }

    func stop() async {
        guard isRunning else { return }
        await httpServer.stop()
        relayManager.stopPolling()
        await bootstrapClient.disconnect()
        connection.bootstrapState = .disconnected
        connection.bootstrapTransport = .none
        connection.bootstrapError = nil
        isRunning = false
        stats.addEvent(.nodeStopped)
    }

    // MARK: - Relayed Inference (from bootstrap)

    private func handleRelayedInference(_ envelope: MessageEnvelope) async -> MessageEnvelope? {
        guard let model = envelope.payload["model"]?.stringValue else {
            return MessageBuilders.error(from: peerId, requestId: envelope.id,
                                         code: .invalidMessage, message: "Missing model")
        }
        let messages = envelope.payload["messages"]?.arrayValue?.compactMap { item -> [String: String]? in
            guard let m = item.mapValue else { return nil }
            return ["role": m["role"]?.stringValue ?? "", "content": m["content"]?.stringValue ?? ""]
        } ?? []
        let temp = envelope.payload["temperature"]?.doubleValue ?? 0.7
        let maxTok = envelope.payload["max_tokens"]?.intValue ?? 2048

        do {
            let result = try await modelManager.engine.complete(
                messages: messages, temperature: temp, maxTokens: maxTok
            )
            stats.totalInferences += 1
            let totalTokens = result.promptTokens + result.completionTokens
            stats.addEvent(.inferenceCompleted(model: model, tokens: totalTokens))

            let cost = Double(totalTokens) * 0.001
            if let dk = deviceKey {
                let _ = try? await creditLedger.earn(
                    amount: cost, from: envelope.fromPeer,
                    seederId: peerId, model: model,
                    tokens: totalTokens, requestId: envelope.id,
                    deviceKey: dk
                )
                stats.creditBalance = await creditLedger.balance
            }

            return MessageBuilders.inferenceResponse(
                from: peerId, requestId: envelope.id,
                text: result.text, model: model,
                promptTokens: result.promptTokens,
                completionTokens: result.completionTokens
            )
        } catch {
            return MessageBuilders.error(from: peerId, requestId: envelope.id,
                                         code: .backendError, message: error.localizedDescription)
        }
    }

    /// Record an inference served via HTTP (LAN relay).
    func recordHTTPInference(model: String, tokens: Int, clientIP: String = "LAN") {
        stats.totalInferences += 1
        let cost = Double(tokens) * 0.001
        stats.creditBalance += cost
        stats.addEvent(.inferenceCompleted(model: model, tokens: tokens))
        stats.addEvent(.creditEarned(cost, clientIP))
    }

    /// Periodically submit receipts to bootstrap for auditing.
    func flushReceipts() async {
        await creditLedger.submitPendingReceipts()
    }

    func setNetworkMode(_ mode: NetworkMode) {
        networkMode = mode
        stats.addEvent(.networkModeChanged(mode))
    }

    // MARK: - Inference Facade

    func streamLocalInference(messages: [[String: String]]) async -> AsyncThrowingStream<String, Error> {
        return await modelManager.engine.stream(messages: messages)
    }

    func completeLocalInference(messages: [[String: String]], temperature: Double = 0.7, maxTokens: Int = 2048) async throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        return try await modelManager.engine.complete(messages: messages, temperature: temperature, maxTokens: maxTokens)
    }

    var hasLoadedModel: Bool { !modelManager.loadedModels.isEmpty }

    func resetInferenceContext() async {
        try? await modelManager.engine.resetContext()
    }

    /// Debit credit balance for network usage.
    func debitCredit(amount: Double, network: String = "public") {
        stats.creditBalance -= amount
        stats.totalInferences += 1
        stats.addEvent(.creditSpent(amount, network))
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
        case httpServerStarted(Int)
        case creditEarned(Double, String)
        case creditSpent(Double, String)
        case peerConnected(String)
        case peerDisconnected(String)
        case networkInfo(lan: String, wan: String, nat: String)
        case relayDiscovered(name: String, models: Int)
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
        case .httpServerStarted: "antenna.radiowaves.left.and.right"
        case .creditEarned: "plus.circle.fill"
        case .creditSpent: "minus.circle.fill"
        case .peerConnected: "person.badge.plus"
        case .peerDisconnected: "person.badge.minus"
        case .networkInfo: "wifi"
        case .relayDiscovered: "display"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var description: String {
        switch kind {
        case .nodeStarted: String(localized: "Node started")
        case .nodeStopped: String(localized: "Node stopped")
        case .networkModeChanged(let mode): String(localized: "Switched to \(mode.displayName)")
        case .modelLoaded(let name): String(localized: "Loaded \(name)")
        case .modelUnloaded(let name): String(localized: "Unloaded \(name)")
        case .inferenceCompleted(let model, let tokens): "Served \(tokens) tokens (\(model))"
        case .httpServerStarted(let port): "HTTP API on :\(port)"
        case .creditEarned(let amount, let from): String(format: "+%.3f credits from %@", amount, from)
        case .creditSpent(let amount, let to): String(format: "-%.3f credits to %@", amount, to)
        case .peerConnected(let peer): String(localized: "Connected: \(peer)")
        case .peerDisconnected(let peer): String(localized: "Disconnected: \(peer)")
        case .networkInfo(let lan, let wan, let nat): "LAN \(lan) · WAN \(wan) · \(nat)"
        case .relayDiscovered(let name, let models): String(localized: "Relay \(name): \(models) model(s)")
        case .error(let msg): msg
        }
    }

    var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince(timestamp))
        if seconds < 5 { return String(localized: "now") }
        if seconds < 60 { return "\(seconds)\(String(localized: "s ago"))" }
        if seconds < 3600 { return "\(seconds / 60)\(String(localized: "m ago"))" }
        return "\(seconds / 3600)\(String(localized: "h ago"))"
    }
}

// MARK: - Weak Reference Wrapper (for @Sendable closures)

private final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
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

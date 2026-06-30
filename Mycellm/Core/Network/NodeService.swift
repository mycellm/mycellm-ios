import Foundation
import Observation

// MARK: - Stats (high-frequency changes — only Dashboard/Peers observe)

@Observable
final class NodeStats: @unchecked Sendable {
    var totalInferences: Int = 0
    /// Authoritative aggregate balance across networks, reconciled from the
    /// tracker (source of truth) and cached locally — not the resetting
    /// in-memory ledger.
    var creditBalance: Double = 0.0
    /// Per-network authoritative balances from the tracker.
    var networkBalances: [NetworkBalance] = []
    private(set) var recentEvents: [ActivityItem] = []

    func addEvent(_ kind: ActivityItem.Kind) {
        let item = ActivityItem(kind: kind)
        recentEvents.insert(item, at: 0)
        if recentEvents.count > 100 {
            recentEvents.removeLast()
        }
    }
}

/// A node's authoritative credit balance on one network, as held by that
/// network's tracker (the public prime for the public net).
struct NetworkBalance: Identifiable, Codable, Sendable {
    var networkId: String
    var balance: Double
    var earned: Double
    var spent: Double
    var id: String { networkId }
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
        // Load the last tracker-reconciled balance so it survives restart
        // instead of resetting to the seed; reconcileTrackerCredits() refreshes
        // it from the source of truth once connected.
        stats.creditBalance = Preferences.shared.cachedCreditBalance
        stats.totalInferences = Preferences.shared.cachedServedCount
        if let data = Preferences.shared.cachedNetworkBalancesData,
           let nets = try? JSONDecoder().decode([NetworkBalance].self, from: data) {
            stats.networkBalances = nets
        }
        modelManager.scanLocalModels()
        Task { await fleetHandler.setNodeService(self) }
        // Reconcile against the tracker immediately on launch (not just on the
        // periodic flush) so the displayed balance + served count refresh from
        // the source of truth right away.
        Task { await reconcileTrackerCredits() }
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
            // Backend label: ask the engine which backend is currently active.
            // mycellm Python advertises "llama.cpp" or "mlx" — match that.
            let backendRaw = await modelManager.engine.backendName  // "MLX" | "llama.cpp" | "none"
            let activeBackendLabel = backendRaw.lowercased() == "mlx" ? "mlx" : "llama.cpp"
            let caps = Capabilities(
                models: publicModels.map { m in
                    ModelCapability(name: m.name, backend: activeBackendLabel, scope: m.scope)
                },
                hardware: HardwareInfo.capabilitiesHardware(),
                role: publicModels.isEmpty ? "consumer" : "seeder",
                version: NetworkConfig.version
            )

            let weakSelf = Weak(self)
            await bootstrapClient.setInferenceHandler { @Sendable envelope in
                return await weakSelf.value?.handleRelayedInference(envelope)
            }
            // Fleet-admin commands ride the same outbound relay pipe (F1-P1).
            // Enabled only when a fleet admin key is configured.
            await fleetHandler.setFleetKey(prefs.fleetAdminKey)
            await bootstrapClient.setFleetCommandHandler { @Sendable envelope in
                return await weakSelf.value?.handleFleetCommand(envelope)
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
        let maxTok = envelope.payload["max_tokens"]?.intValue
            ?? envelope.payload["max_completion_tokens"]?.intValue ?? 2048

        do {
            let result = try await modelManager.engine.complete(
                messages: messages, temperature: temp, maxTokens: maxTok
            )
            stats.totalInferences += 1
            let totalTokens = result.promptTokens + result.completionTokens
            stats.addEvent(.inferenceCompleted(model: model, tokens: totalTokens))

            let cost = Double(totalTokens) * 0.001
            if let dk = deviceKey,
               let receipt = try? await creditLedger.earn(
                    amount: cost, from: envelope.fromPeer,
                    seederId: peerId, model: model,
                    tokens: totalTokens, requestId: envelope.id,
                    deviceKey: dk
               ) {
                stats.creditBalance = await creditLedger.balance
                // Send the signed receipt to the consumer so it co-signs and
                // settles our earnings into the network tracker (the source of
                // truth). Without this our earnings never leave the device.
                let receiptMsg = MessageBuilders.signedCreditReceipt(
                    from: peerId,
                    consumerId: receipt.consumerId,
                    seederId: receipt.seederId,
                    model: receipt.model,
                    tokens: receipt.tokens,
                    cost: receipt.cost,
                    timestamp: receipt.timestamp,
                    signature: receipt.signature,
                    requestId: receipt.requestId
                )
                await bootstrapClient.send(receiptMsg)
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

    // MARK: - Fleet Commands (relayed from bootstrap)

    /// Handle a fleet-admin command relayed over the bootstrap pipe and return
    /// the response envelope. The FleetHandler enforces the admin-key gate; an
    /// unconfigured key yields a failure response rather than a silent drop.
    private func handleFleetCommand(_ envelope: MessageEnvelope) async -> MessageEnvelope? {
        let command = envelope.payload["command"]?.stringValue ?? ""
        let params = envelope.payload["params"]?.mapValue ?? [:]
        let adminKey = envelope.payload["fleet_admin_key"]?.stringValue ?? ""
        let (success, data, error) = await fleetHandler.handle(
            command: command, params: params, adminKey: adminKey
        )
        return MessageBuilders.fleetResponse(
            from: peerId, requestId: envelope.id,
            success: success, data: data, error: error
        )
    }

    /// Record an inference served via HTTP (LAN relay).
    func recordHTTPInference(model: String, tokens: Int, clientIP: String = "LAN") {
        stats.totalInferences += 1
        let cost = Double(tokens) * 0.001
        stats.creditBalance += cost
        stats.addEvent(.inferenceCompleted(model: model, tokens: tokens))
        stats.addEvent(.creditEarned(cost, clientIP))
    }

    /// Periodically submit receipts to bootstrap for auditing, then reconcile
    /// our displayed balance against the tracker (source of truth).
    func flushReceipts() async {
        await creditLedger.submitPendingReceipts()
        await reconcileTrackerCredits()
    }

    /// Reconcile the displayed credit balance against the tracker: fetch this
    /// node's authoritative per-network balances and cache them so they persist
    /// across restart instead of resetting to the local seed. The tracker is
    /// the source of truth; the in-memory ledger is only a transient cache.
    func reconcileTrackerCredits() async {
        guard !peerId.isEmpty else { return }
        struct TrackerBalance: Decodable {
            let balance: Double
            let total_earned: Double
            let total_spent: Double
            let tracked: Bool
            let served: Int?
        }
        var fetched: [NetworkBalance] = []
        var servedCount = 0
        var gotResponse = false
        for net in ["public", ""] {
            guard let url = URL(string: "\(NetworkConfig.apiBase)/v1/public/credits/\(peerId)?network_id=\(net)"),
                  let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let d = try? JSONDecoder().decode(TrackerBalance.self, from: data) else { continue }
            gotResponse = true
            servedCount = max(servedCount, d.served ?? 0)  // served is global, not per-net
            if d.tracked {
                fetched.append(NetworkBalance(
                    networkId: net.isEmpty ? "default" : net,
                    balance: d.balance, earned: d.total_earned, spent: d.total_spent
                ))
            }
        }
        guard gotResponse else { return }  // offline / tracker unreachable — keep cache
        let aggregate = fetched.reduce(0.0) { $0 + $1.balance }
        let encoded = try? JSONEncoder().encode(fetched)
        await MainActor.run {
            // Authoritative served count (survives restart). max() so an in-flight
            // local increment isn't briefly undone by a slightly stale server count.
            stats.totalInferences = max(stats.totalInferences, servedCount)
            Preferences.shared.cachedServedCount = servedCount
            if !fetched.isEmpty {
                stats.networkBalances = fetched
                stats.creditBalance = aggregate
                Preferences.shared.cachedCreditBalance = aggregate
                Preferences.shared.cachedNetworkBalancesData = encoded
            }
        }
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
        let result = try await modelManager.engine.complete(messages: messages, temperature: temperature, maxTokens: maxTokens)
        return (result.text, result.promptTokens, result.completionTokens)
    }

    // Multimodal (vision) variants — used when a message carries images. The
    // engine feeds them to a VLM model, or flattens to text for text models.
    func streamLocalInference(multimodal messages: [MultimodalMessage]) async -> AsyncThrowingStream<String, Error> {
        return await modelManager.engine.stream(multimodal: messages)
    }

    func completeLocalInference(multimodal messages: [MultimodalMessage], temperature: Double = 0.7, maxTokens: Int = 2048) async throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        let result = try await modelManager.engine.complete(multimodal: messages, temperature: temperature, maxTokens: maxTokens)
        return (result.text, result.promptTokens, result.completionTokens)
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

    #if DEBUG
    /// Apply a realistic, fully-populated node state for App Store screenshot
    /// capture. Launch-arg gated via `ScreenshotMode`; compiled out of Release
    /// builds, so no mock state can ship to production. The caller skips
    /// `start()` / `autoLoadLastModel()` so live networking can't overwrite it.
    @MainActor
    func applyScreenshotFixture() {
        nodeName = "bold-mycel"
        peerId = "z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuBV8xRoAnwWsdvktH"
        isRunning = true
        networkMode = .public
        connection.bootstrapState = .connected
        connection.bootstrapTransport = .quic
        stats.totalInferences = 1287
        stats.creditBalance = 342.75
        stats.networkBalances = [
            NetworkBalance(networkId: "public", balance: 342.75, earned: 409.5, spent: 66.75),
        ]
        modelManager.applyScreenshotFixture()
        networkRegistry.applyScreenshotFixture()
        stats.addEvent(.nodeStarted)
        stats.addEvent(.modelLoaded("Qwen2.5-3B-Instruct"))
        stats.addEvent(.networkInfo(lan: "192.168.1.42", wan: "73.118.4.207", nat: "Full Cone"))
        stats.addEvent(.peerConnected("calm-grove"))
        stats.addEvent(.relayDiscovered(name: "aurora", models: 3))
        stats.addEvent(.inferenceCompleted(model: "Qwen2.5-3B-Instruct", tokens: 312))
        stats.addEvent(.creditEarned(1.872, "public"))
    }
    #endif
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

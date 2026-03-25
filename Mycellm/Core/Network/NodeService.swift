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
    private(set) var networkMode: NetworkMode = .public

    // MARK: - Networks
    let networkRegistry = NetworkRegistry()

    // MARK: - Models
    let modelManager = ModelManager()
    let modelDownloader = ModelDownloader()

    // MARK: - Services
    private let httpServer = HTTPServer()
    let bootstrapClient = BootstrapClient()
    private let peerManager = PeerManager()
    let creditLedger = CreditLedger()
    let natDiscovery = NATDiscovery()
    let receiptValidator = ReceiptValidator()
    let fleetHandler = FleetHandler()

    // MARK: - Network Status
    private(set) var bootstrapState: BootstrapClient.ConnectionState = .disconnected
    private(set) var bootstrapTransport: BootstrapClient.Transport = .none
    private(set) var bootstrapError: String?

    // MARK: - Stats
    var totalInferences: Int = 0
    var connectedPeers: Int {
        bootstrapState == .connected ? 1 : 0
    }
    var loadedModels: Int { modelManager.loadedModels.count }
    var creditBalance: Double = 0.0

    // MARK: - Activity
    private(set) var recentEvents: [ActivityItem] = []

    // MARK: - Initialization

    @MainActor
    init() {
        loadOrCreateIdentity()
        networkMode = Preferences.shared.networkMode
        creditBalance = 100.0  // Seed balance for new nodes
        modelManager.scanLocalModels()
        Task { await fleetHandler.setNodeService(self) }
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

        let prefs = await MainActor.run { Preferences.shared }

        // Start HTTP server if enabled
        if prefs.httpServerEnabled || networkMode.apiServerEnabled {
            do {
                try await httpServer.start(port: prefs.apiPort, nodeService: self)
                addEvent(.nodeStarted)
            } catch {
                addEvent(.error("HTTP server failed: \(error.localizedDescription)"))
            }
        }

        modelManager.scanLocalModels()

        // Start NAT discovery (background, non-blocking)
        Task { await natDiscovery.start() }

        // Connect to bootstrap if network mode requires it
        if networkMode.usesBootstrap {
            await bootstrapClient.configure(
                host: prefs.bootstrapHost,
                port: UInt16(prefs.quicPort)
            )

            // Track state changes for UI
            let nodeRef = self
            await bootstrapClient.setStateHandler { @Sendable state, transport, error in
                Task { @MainActor in
                    let prev = nodeRef.bootstrapState
                    nodeRef.bootstrapState = state
                    nodeRef.bootstrapTransport = transport
                    nodeRef.bootstrapError = error
                    // Only log meaningful transitions (avoid spam)
                    if state != prev {
                        switch state {
                        case .connected:
                            nodeRef.addEvent(.peerConnected("bootstrap via \(transport.rawValue)"))
                        case .failed where prev != .failed:
                            nodeRef.addEvent(.error("Bootstrap: \(error ?? "connection failed")"))
                        case .fallbackHTTP where prev != .fallbackHTTP:
                            nodeRef.addEvent(.error("QUIC unavailable — trying HTTP"))
                        default:
                            break
                        }
                    }
                }
            }

            let caps = Capabilities(
                models: modelManager.loadedModels.map { m in
                    ModelCapability(name: m.name, backend: "llama.cpp", scope: m.scope)
                },
                hardware: HardwareInfo.capabilitiesHardware(),
                role: modelManager.loadedModels.isEmpty ? "consumer" : "seeder",
                version: "0.1.0"
            )

            // Handle inference requests relayed from bootstrap
            await bootstrapClient.setInferenceHandler { [weak self] envelope in
                return await self?.handleRelayedInference(envelope)
            }

            addEvent(.networkModeChanged(networkMode))
            await bootstrapClient.connect(peerId: peerId, capabilities: caps, deviceKey: deviceKey, deviceCert: deviceCert)
        }
    }

    func stop() async {
        guard isRunning else { return }
        await httpServer.stop()
        await bootstrapClient.disconnect()
        bootstrapState = .disconnected
        bootstrapTransport = .none
        bootstrapError = nil
        isRunning = false
        addEvent(.nodeStopped)
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
            totalInferences += 1
            let totalTokens = result.promptTokens + result.completionTokens
            addEvent(.inferenceCompleted(model: model, tokens: totalTokens))

            // Generate credit receipt
            let cost = Double(totalTokens) * 0.001
            if let dk = deviceKey {
                let _ = try? await creditLedger.earn(
                    amount: cost, from: envelope.fromPeer,
                    seederId: peerId, model: model,
                    tokens: totalTokens, requestId: envelope.id,
                    deviceKey: dk
                )
                creditBalance = await creditLedger.balance
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
        totalInferences += 1
        let cost = Double(tokens) * 0.001
        creditBalance += cost
        addEvent(.inferenceCompleted(model: model, tokens: tokens))
        addEvent(.creditEarned(cost, clientIP))
    }

    /// Periodically submit receipts to bootstrap for auditing.
    func flushReceipts() async {
        await creditLedger.submitPendingReceipts()
    }

    func setNetworkMode(_ mode: NetworkMode) {
        networkMode = mode
        addEvent(.networkModeChanged(mode))
    }

    // MARK: - Inference Facade

    /// Stream inference from the local model. Views should use this instead of reaching into modelManager.engine directly.
    func streamLocalInference(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        return modelManager.engine.stream(messages: messages)
    }

    /// Non-streaming inference from local model.
    func completeLocalInference(messages: [[String: String]], temperature: Double = 0.7, maxTokens: Int = 2048) async throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        return try await modelManager.engine.complete(messages: messages, temperature: temperature, maxTokens: maxTokens)
    }

    /// Whether the node has a model loaded and ready for local inference.
    var hasLoadedModel: Bool { !modelManager.loadedModels.isEmpty }

    /// Debit credit balance for network usage.
    func debitCredit(amount: Double, network: String = "public") {
        creditBalance -= amount
        totalInferences += 1
        addEvent(.creditSpent(amount, network))
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
        case httpServerStarted(Int)
        case creditEarned(Double, String)
        case creditSpent(Double, String)
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
        case .httpServerStarted: "antenna.radiowaves.left.and.right"
        case .creditEarned: "plus.circle.fill"
        case .creditSpent: "minus.circle.fill"
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
        case .inferenceCompleted(let model, let tokens): "Served \(tokens) tokens (\(model))"
        case .httpServerStarted(let port): "HTTP API on :\(port)"
        case .creditEarned(let amount, let from): String(format: "+%.3f credits from %@", amount, from)
        case .creditSpent(let amount, let to): String(format: "-%.3f credits to %@", amount, to)
        case .peerConnected(let peer): "Connected: \(peer)"
        case .peerDisconnected(let peer): "Disconnected: \(peer)"
        case .error(let msg): msg
        }
    }

    var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince(timestamp))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
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

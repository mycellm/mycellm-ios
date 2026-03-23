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
    private let quicTransport = QUICTransport()
    let bootstrapClient = BootstrapClient()
    private let peerManager = PeerManager()
    let creditLedger = CreditLedger()
    let receiptValidator = ReceiptValidator()

    // MARK: - Network Status
    private(set) var bootstrapState: BootstrapClient.ConnectionState = .disconnected
    private(set) var bootstrapTransport: BootstrapClient.Transport = .none
    private(set) var bootstrapError: String?

    // MARK: - Stats
    private(set) var totalInferences: Int = 0
    private(set) var connectedPeers: Int = 0
    var loadedModels: Int { modelManager.loadedModels.count }
    private(set) var creditBalance: Double = 0.0

    // MARK: - Activity
    private(set) var recentEvents: [ActivityItem] = []

    // MARK: - Initialization

    @MainActor
    init() {
        loadOrCreateIdentity()
        networkMode = Preferences.shared.networkMode
        creditBalance = 100.0  // Seed balance for new nodes
        modelManager.scanLocalModels()
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

        // Start QUIC transport if network mode requires it
        if networkMode.usesQUIC {
            do {
                try await quicTransport.startServer(port: UInt16(prefs.quicPort))

                // Set up message dispatch
                await quicTransport.setMessageHandler { [weak self] envelope, peer in
                    await self?.handleMessage(envelope, from: peer)
                }
            } catch {
                addEvent(.error("QUIC transport failed: \(error.localizedDescription)"))
            }
        }

        modelManager.scanLocalModels()

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
                role: "seeder",
                version: "0.1.0"
            )

            addEvent(.networkModeChanged(networkMode))
            await bootstrapClient.connect(peerId: peerId, capabilities: caps)
        }
    }

    func stop() async {
        guard isRunning else { return }
        await httpServer.stop()
        await quicTransport.stopServer()
        await bootstrapClient.disconnect()
        bootstrapState = .disconnected
        bootstrapTransport = .none
        bootstrapError = nil
        isRunning = false
        addEvent(.nodeStopped)
    }

    // MARK: - Message Dispatch

    private func handleMessage(_ envelope: MessageEnvelope, from peer: PeerConnection) async {
        switch envelope.type {
        case .ping:
            let pong = MessageBuilders.pong(from: peerId, requestId: envelope.id)
            try? await quicTransport.send(pong, to: peer)

        case .inferenceReq:
            guard let model = envelope.payload["model"]?.stringValue else { return }
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
                let resp = MessageBuilders.inferenceResponse(
                    from: peerId, requestId: envelope.id,
                    text: result.text, model: model,
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens
                )
                try? await quicTransport.send(resp, to: peer)

                // Generate signed credit receipt
                let totalTokens = result.promptTokens + result.completionTokens
                let cost = Double(totalTokens) * 0.001 // 0.001 credits per token
                if let dk = deviceKey {
                    if let receipt = try? await creditLedger.earn(
                        amount: cost, from: envelope.fromPeer,
                        seederId: peerId, model: model,
                        tokens: totalTokens, requestId: envelope.id,
                        deviceKey: dk
                    ) {
                        // Send receipt to consumer
                        let receiptMsg = MessageBuilders.signedCreditReceipt(
                            from: peerId,
                            consumerId: envelope.fromPeer,
                            seederId: peerId,
                            model: model,
                            tokens: totalTokens,
                            cost: cost,
                            timestamp: receipt.timestamp,
                            signature: receipt.signature
                        )
                        try? await quicTransport.send(receiptMsg, to: peer)
                        totalInferences += 1
                        creditBalance = await creditLedger.balance
                        addEvent(.inferenceCompleted(model: model, tokens: totalTokens))
                    }
                }
            } catch {
                let errMsg = MessageBuilders.error(
                    from: peerId, requestId: envelope.id,
                    code: .backendError, message: error.localizedDescription
                )
                try? await quicTransport.send(errMsg, to: peer)
            }

        case .peerQuery:
            let resp = MessageBuilders.peerResponse(from: peerId, requestId: envelope.id, peers: [])
            try? await quicTransport.send(resp, to: peer)

        case .creditReceipt:
            // Incoming receipt from a seeder — verify and record spend
            guard let consumerId = envelope.payload["consumer_id"]?.stringValue,
                  let seederId = envelope.payload["seeder_id"]?.stringValue,
                  let model = envelope.payload["model"]?.stringValue,
                  let tokens = envelope.payload["tokens"]?.intValue,
                  let cost = envelope.payload["cost"]?.doubleValue,
                  let timestamp = envelope.payload["timestamp"]?.doubleValue,
                  let signature = envelope.payload["signature"]?.stringValue else { break }

            // Check replay
            guard await receiptValidator.checkReplay(requestId: envelope.id) else { break }
            guard await receiptValidator.checkCreditRate(peerId: envelope.fromPeer) else { break }

            let receipt = CreditLedger.SignedReceipt(
                consumerId: consumerId, seederId: seederId,
                model: model, tokens: tokens, cost: cost,
                requestId: envelope.id, timestamp: timestamp,
                signature: signature
            )

            // We'd need the seeder's pubkey to verify — for now trust receipts from authenticated peers
            let _ = await creditLedger.spend(
                receipt: receipt,
                seederPubkeyBytes: peer.peerId.isEmpty ? Data() : Data()
            )
            creditBalance = await creditLedger.balance

        case .fleetCommand:
            // TODO: delegate to FleetHandler
            break

        default:
            break
        }
    }

    /// Periodically submit receipts to bootstrap for auditing.
    func flushReceipts() async {
        await creditLedger.submitPendingReceipts()
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

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
    /// Aggregate/public connection state. Mirrors the PUBLIC network's
    /// connection so existing single-connection readers (Chat/Dashboard/
    /// Settings) keep working unchanged.
    var bootstrapState: BootstrapClient.ConnectionState = .disconnected
    var bootstrapTransport: BootstrapClient.Transport = .none
    var bootstrapError: String?

    /// Per-network connection state, keyed by network id. Populated for every
    /// active membership (including "public"), so the UI can show per-network
    /// status while `bootstrapState` still reflects the public connection.
    var networkStates: [String: NetworkConnState] = [:]

    struct NetworkConnState: Sendable {
        var state: BootstrapClient.ConnectionState = .disconnected
        var transport: BootstrapClient.Transport = .none
        var error: String?
    }

    /// Per-network connection state, defaulting to disconnected when unknown.
    func state(for networkId: String) -> NetworkConnState {
        networkStates[networkId] ?? NetworkConnState()
    }

    /// True when at least one network is connected.
    var anyConnected: Bool {
        bootstrapState == .connected || networkStates.values.contains { $0.state == .connected }
    }

    /// Number of connected networks (each participating network counts as a peer
    /// link). Falls back to the aggregate public state before per-network state
    /// is populated.
    var connectedPeers: Int {
        let n = networkStates.values.filter { $0.state == .connected }.count
        return n > 0 ? n : (bootstrapState == .connected ? 1 : 0)
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
    /// Device-level internet reachability (independent of bootstrap state).
    let connectivity = Connectivity()
    /// LAN Bonjour browse — triggers the iOS Local Network permission prompt
    /// (required to reach a coordinator by LAN IP/.local) and discovers coordinators.
    let localDiscovery = LocalNetworkDiscovery()

    // MARK: - Networks
    let networkRegistry = NetworkRegistry()

    // MARK: - Models
    let modelManager = ModelManager()
    let modelDownloader = ModelDownloader()
    let relayManager = RelayManager()

    // MARK: - Services
    private let httpServer = HTTPServer()
    /// Primary connection = the PUBLIC network. Kept as a stable property so
    /// existing readers (e.g. ChatView's QUIC streaming) work unchanged.
    let bootstrapClient = BootstrapClient()
    /// One BootstrapClient per active network membership, keyed by network id.
    /// The "public" entry is `bootstrapClient`; private networks get their own
    /// client (each with its own QUICTransport/state — no shared globals).
    private var networkClients: [String: BootstrapClient] = [:]
    /// One FleetHandler per network so a fleet command arriving over network X's
    /// connection is verified against X's fleet key. The "public" entry is the
    /// shared `fleetHandler` (kept for Settings' global key + back-compat).
    private var fleetHandlers: [String: FleetHandler] = [:]
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

        // Start the LAN browse — this also triggers the iOS Local Network
        // permission prompt, without which connecting to a coordinator by LAN
        // IP or .local is silently blocked at the OS layer.
        localDiscovery.start()

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
            stats.addEvent(.networkModeChanged(networkMode))
            // Connect the PUBLIC network first (honors the editable Settings
            // bootstrap host/port), then every joined private network — the node
            // participates in all of them simultaneously. Memberships toggled
            // OFF (enabled == false) are skipped; Public disabled ⇒ private-only.
            let publicMembership = networkRegistry.memberships.first { $0.id == "public" } ?? .publicNetwork
            if publicMembership.enabled {
                await openConnection(for: publicMembership, prefs: prefs)
            }
            for membership in networkRegistry.memberships where membership.id != "public" && membership.enabled {
                await openConnection(for: membership, prefs: prefs)
            }
        }
    }

    // MARK: - Multi-network connections

    /// The BootstrapClient for a network id, creating one for private networks.
    /// The public network always uses the primary `bootstrapClient`.
    private func client(for networkId: String) -> BootstrapClient {
        if networkId == "public" { return bootstrapClient }
        if let existing = networkClients[networkId] { return existing }
        let c = BootstrapClient()
        networkClients[networkId] = c
        return c
    }

    /// The FleetHandler for a network id. The public network shares the global
    /// `fleetHandler`; private networks get their own so per-network fleet keys
    /// are enforced independently.
    private func fleetHandler(for networkId: String) async -> FleetHandler {
        if networkId == "public" { return fleetHandler }
        if let existing = fleetHandlers[networkId] { return existing }
        let h = FleetHandler()
        await h.setNodeService(self)
        fleetHandlers[networkId] = h
        return h
    }

    /// Build the capability advertisement for a connection declaring `networkIds`.
    private func buildCapabilities(networkIds: [String]) async -> Capabilities {
        let publicModels = modelManager.loadedModels.filter { $0.scope == "public" }
        // Backend label: ask the engine which backend is currently active.
        // mycellm Python advertises "llama.cpp" or "mlx" — match that.
        let backendRaw = await modelManager.engine.backendName  // "MLX" | "llama.cpp" | "none"
        let activeBackendLabel = backendRaw.lowercased() == "mlx" ? "mlx" : "llama.cpp"
        return Capabilities(
            models: publicModels.map { m in
                ModelCapability(name: m.name, backend: activeBackendLabel, scope: m.scope)
            },
            hardware: HardwareInfo.capabilitiesHardware(),
            role: publicModels.isEmpty ? "consumer" : "seeder",
            version: NetworkConfig.version,
            networkIds: networkIds
        )
    }

    /// Configure and connect a single network membership. Idempotent-ish: safe
    /// to call for the public network (uses the editable Settings endpoint) or a
    /// private one (uses the membership's endpoint + its fleet key).
    private func openConnection(for membership: NetworkMembership, prefs: Preferences) async {
        let networkId = membership.id
        let isPublic = networkId == "public"
        let host = isPublic ? prefs.bootstrapHost : membership.bootstrapHost
        let port = isPublic ? UInt16(prefs.quicPort) : UInt16(membership.bootstrapPort)

        let bc = client(for: networkId)
        await bc.configure(host: host, port: port)

        // Per-network connection-state handler → updates connection.networkStates,
        // and mirrors the public network into the aggregate bootstrap* fields.
        let weakConn = Weak(self.connection)
        let weakStats = Weak(self.stats)
        let netName = membership.name
        await bc.setStateHandler { @Sendable state, transport, error in
            Task { @MainActor in
                guard let conn = weakConn.value, let stats = weakStats.value else { return }
                let prev = conn.state(for: networkId).state
                conn.networkStates[networkId] = NodeConnection.NetworkConnState(
                    state: state, transport: transport, error: error
                )
                if isPublic {
                    conn.bootstrapState = state
                    conn.bootstrapTransport = transport
                    conn.bootstrapError = error
                }
                if state != prev {
                    switch state {
                    case .connected:
                        stats.addEvent(.peerConnected("\(netName) via \(transport.rawValue)"))
                    case .failed where prev != .failed:
                        stats.addEvent(.error("\(netName): \(error ?? "connection failed")"))
                    case .fallbackHTTP where prev != .fallbackHTTP:
                        stats.addEvent(.error("\(netName): QUIC unavailable — trying HTTP"))
                    default:
                        break
                    }
                }
            }
        }

        let caps = await buildCapabilities(networkIds: [networkId])

        let weakSelf = Weak(self)
        let weakClient = Weak(bc)
        await bc.setInferenceHandler { @Sendable envelope in
            return await weakSelf.value?.handleRelayedInference(envelope, client: weakClient.value)
        }
        // Fleet-admin commands ride the same outbound relay pipe (F1-P1).
        // Each connection resolves against its network's fleet key, falling back
        // to the global Preferences.fleetAdminKey when the membership has none.
        let handler = await fleetHandler(for: networkId)
        await handler.setFleetKey(membership.fleetKey ?? prefs.fleetAdminKey)
        await bc.setFleetCommandHandler { @Sendable envelope in
            return await weakSelf.value?.handleFleetCommand(envelope, using: handler)
        }

        await bc.connect(
            peerId: peerId, capabilities: caps,
            deviceKey: deviceKey, deviceCert: deviceCert,
            networkIds: [networkId]
        )
    }

    /// Open a connection to a newly-joined membership without restarting the
    /// node. Called by the Join UI so the node starts participating immediately.
    func connectMembership(_ membership: NetworkMembership) async {
        guard isRunning, networkMode.usesBootstrap else { return }
        let prefs = await MainActor.run { Preferences.shared }
        await openConnection(for: membership, prefs: prefs)
    }

    /// Tear down a network's connection — called on Leave (private) and on
    /// Disable (public or private). Public disconnects its shared bootstrapClient
    /// but keeps the global fleetHandler; private networks drop their per-network
    /// client + fleet handler entirely.
    func disconnectMembership(networkId: String) async {
        if networkId == "public" {
            await bootstrapClient.disconnect()
        } else if let bc = networkClients[networkId] {
            await bc.disconnect()
            networkClients.removeValue(forKey: networkId)
            fleetHandlers.removeValue(forKey: networkId)
        }
        await MainActor.run {
            if networkId == "public" {
                connection.bootstrapState = .disconnected
                connection.bootstrapTransport = .none
                connection.bootstrapError = nil
            }
            connection.networkStates.removeValue(forKey: networkId)
        }
    }

    /// Reconnect a single membership (public or private) in place, applying any
    /// edited endpoint/fleet-key without restarting the whole node. Used by the
    /// per-network detail sheet's Reconnect action.
    func reconnectMembership(_ membership: NetworkMembership) async {
        guard isRunning, networkMode.usesBootstrap else { return }
        await disconnectMembership(networkId: membership.id)
        let prefs = await MainActor.run { Preferences.shared }
        await openConnection(for: membership, prefs: prefs)
    }

    func stop() async {
        guard isRunning else { return }
        await httpServer.stop()
        relayManager.stopPolling()
        await bootstrapClient.disconnect()
        for (_, bc) in networkClients {
            await bc.disconnect()
        }
        networkClients.removeAll()
        fleetHandlers.removeAll()
        connection.bootstrapState = .disconnected
        connection.bootstrapTransport = .none
        connection.bootstrapError = nil
        connection.networkStates.removeAll()
        isRunning = false
        stats.addEvent(.nodeStopped)
    }

    // MARK: - Relayed Inference (from bootstrap)

    private func handleRelayedInference(_ envelope: MessageEnvelope, client: BootstrapClient? = nil) async -> MessageEnvelope? {
        // Reply/receipt travels back over the connection the request arrived on
        // (defaults to the public bootstrapClient for back-compat).
        let replyClient = client ?? bootstrapClient
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
                await replyClient.send(receiptMsg)
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
    private func handleFleetCommand(_ envelope: MessageEnvelope, using handler: FleetHandler? = nil) async -> MessageEnvelope? {
        let command = envelope.payload["command"]?.stringValue ?? ""
        let params = envelope.payload["params"]?.mapValue ?? [:]
        let adminKey = envelope.payload["fleet_admin_key"]?.stringValue ?? ""
        let (success, data, error) = await (handler ?? fleetHandler).handle(
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
        networkRegistry.applyScreenshotFixture()
        for m in networkRegistry.memberships {
            connection.networkStates[m.id] = NodeConnection.NetworkConnState(
                state: .connected, transport: .quic, error: nil
            )
        }
        stats.totalInferences = 1287
        stats.creditBalance = 342.75
        stats.networkBalances = [
            NetworkBalance(networkId: "public", balance: 342.75, earned: 409.5, spent: 66.75),
        ]
        modelManager.applyScreenshotFixture()
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

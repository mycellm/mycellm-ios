import Foundation
import Network

/// Bootstrap connection: QUIC preferred (bidirectional streams), HTTP+WS fallback.
actor BootstrapClient {
    static let defaultBootstrap = NetworkConfig.bootstrapHost
    static let defaultPort: UInt16 = 8421
    static let quicRetryBeforeFallback = 2
    static let retryDelays: [TimeInterval] = [2, 5, 15, 30, 60]

    enum ConnectionState: String, Sendable {
        case disconnected = "Disconnected"
        case connecting = "Connecting…"
        case handshaking = "Handshaking…"
        case connected = "Connected"
        case reconnecting = "Reconnecting…"
        case fallbackHTTP = "HTTP Fallback"
        case failed = "Failed"
    }

    enum Transport: String, Sendable {
        case quic = "QUIC"
        case http = "HTTP"
        case none = "—"
    }

    private(set) var state: ConnectionState = .disconnected
    private(set) var transport: Transport = .none
    private(set) var lastError: String?
    private(set) var retryCount: Int = 0
    private(set) var connectedAt: Date?

    private var bootstrapHost: String = defaultBootstrap
    private var bootstrapPort: UInt16 = defaultPort
    private var httpEndpoint: String = NetworkConfig.apiBase
    private var quicTransport: QUICTransport?
    private var retryTask: Task<Void, Never>?
    private var quicRetryTask: Task<Void, Never>?
    private var keepRunning = false
    private var peerId: String = ""
    private var capabilities: Capabilities = Capabilities()
    private var deviceKey: DeviceKey?
    private var deviceCert: DeviceCert?
    private var onStateChange: (@Sendable (ConnectionState, Transport, String?) -> Void)?
    private var onInferenceRequest: ((MessageEnvelope) async -> MessageEnvelope?)?

    func configure(host: String, port: UInt16) {
        bootstrapHost = host
        bootstrapPort = port
        httpEndpoint = host == Self.defaultBootstrap
            ? NetworkConfig.apiBase
            : "http://\(host):\(NetworkConfig.httpPort)"
    }

    func setStateHandler(_ handler: @escaping @Sendable (ConnectionState, Transport, String?) -> Void) {
        onStateChange = handler
    }

    /// Set handler for incoming inference requests from the bootstrap relay.
    func setInferenceHandler(_ handler: @escaping (MessageEnvelope) async -> MessageEnvelope?) {
        onInferenceRequest = handler
    }

    // MARK: - Connect

    func connect(peerId: String, capabilities: Capabilities, deviceKey: DeviceKey?, deviceCert: DeviceCert?) async {
        self.peerId = peerId
        self.capabilities = capabilities
        self.deviceKey = deviceKey
        self.deviceCert = deviceCert
        keepRunning = true
        retryCount = 0
        await attemptQUIC()
    }

    func disconnect() {
        keepRunning = false
        retryTask?.cancel()
        quicRetryTask?.cancel()
        retryTask = nil
        quicRetryTask = nil
        Task { await quicTransport?.disconnect() }
        quicTransport = nil
        setState(.disconnected, transport: .none, error: nil)
    }

    // MARK: - QUIC Path

    private func attemptQUIC() async {
        setState(.connecting, transport: .quic, error: nil)

        let qt = QUICTransport()
        quicTransport = qt

        // Set message handler for server-initiated streams
        await qt.setMessageHandler { [weak self] envelope in
            return await self?.handleIncoming(envelope)
        }

        // Connect with timeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await qt.connect(host: self.bootstrapHost, port: self.bootstrapPort)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw MycellmError.transportError("QUIC timeout")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            await handleQUICFailure(error.localizedDescription)
            return
        }

        // Send NodeHello — payload["hello"] must be CBOR-serialized NodeHello
        setState(.handshaking, transport: .quic, error: nil)

        guard let dk = deviceKey, let cert = deviceCert else {
            await handleQUICFailure("No identity for handshake")
            return
        }

        var nodeHello = NodeHello(
            peerId: peerId,
            devicePubkey: dk.publicBytes,
            cert: cert,
            capabilities: capabilities
        )
        try? nodeHello.sign(with: dk)
        let helloBytes = nodeHello.toCBOR()

        let envelope = MessageEnvelope(
            type: .nodeHello,
            payload: ["hello": .bytes(helloBytes)],
            fromPeer: peerId
        )

        do {
            try await qt.send(envelope)
            // Wait briefly for data to flush over the wire
            try? await Task.sleep(for: .milliseconds(500))
            setState(.connected, transport: .quic, error: nil)
            connectedAt = Date()
            retryCount = 0

            // Wait for server response (hello_ack) to confirm registration
            // Keep connection alive for incoming inference requests
            Log.bootstrap.info(" NodeHello sent, waiting for server response...")
        } catch {
            await handleQUICFailure("Handshake failed: \(error.localizedDescription)")
        }
    }

    private func handleQUICFailure(_ reason: String) async {
        await quicTransport?.disconnect()
        quicTransport = nil
        retryCount += 1

        if retryCount >= Self.quicRetryBeforeFallback {
            await fallbackToHTTP(reason: "QUIC failed (\(retryCount)x): \(reason)")
        } else {
            let delay = Self.retryDelays[min(retryCount - 1, Self.retryDelays.count - 1)]
            setState(.reconnecting, transport: .quic, error: "Retry \(retryCount) in \(Int(delay))s")
            retryTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, keepRunning else { return }
                await attemptQUIC()
            }
        }
    }

    // MARK: - HTTP Fallback

    private func fallbackToHTTP(reason: String) async {
        setState(.fallbackHTTP, transport: .http, error: "Trying HTTP…")

        do {
            try await httpAnnounce()
            setState(.connected, transport: .http, error: nil)
            connectedAt = Date()

            // Re-announce periodically (HTTP is stateless)
            quicRetryTask = Task {
                while !Task.isCancelled && keepRunning {
                    // Re-announce every 60s to stay "online"
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, keepRunning else { break }
                    try? await httpAnnounce()

                    // Also try QUIC silently
                    let qt = QUICTransport()
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { try await qt.connect(host: self.bootstrapHost, port: self.bootstrapPort) }
                            group.addTask { try await Task.sleep(for: .seconds(5)); throw MycellmError.transportError("timeout") }
                            try await group.next()
                            group.cancelAll()
                        }
                        // QUIC works now — upgrade
                        await qt.setMessageHandler { [weak self] envelope in
                            return await self?.handleIncoming(envelope)
                        }
                        quicTransport = qt
                        setState(.connected, transport: .quic, error: nil)
                        break // stop the re-announce loop
                    } catch {
                        await qt.disconnect()
                    }
                }
            }
        } catch {
            setState(.failed, transport: .http, error: error.localizedDescription)
            retryTask = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, keepRunning else { return }
                retryCount = 0
                await attemptQUIC()
            }
        }
    }

    private func httpAnnounce() async throws {
        guard let url = URL(string: "\(httpEndpoint)/v1/admin/nodes/announce") else {
            throw MycellmError.transportError("Invalid endpoint")
        }

        let modelList = capabilities.models.map { m -> [String: Any] in
            var d: [String: Any] = ["name": m.name, "backend": m.backend]
            if !m.quant.isEmpty { d["quant"] = m.quant }
            if m.paramCountB > 0 { d["param_count_b"] = m.paramCountB }
            if !m.scope.isEmpty { d["scope"] = m.scope }
            return d
        }

        let apiPort = await MainActor.run { Preferences.shared.apiPort }
        let localIP = getLocalIPAddress() ?? "0.0.0.0"

        let body: [String: Any] = [
            "peer_id": peerId,
            "platform": "ios",
            "version": "0.1.0",
            "api_addr": "\(localIP):\(apiPort)",
            "capabilities": [
                "role": capabilities.role,
                "models": modelList,
                "hardware": [
                    "gpu": capabilities.hardware.gpu,
                    "vram_gb": capabilities.hardware.vramGb,
                    "backend": capabilities.hardware.backend,
                ] as [String: Any],
                "max_concurrent": capabilities.maxConcurrent,
                "est_tok_s": capabilities.estTokS,
            ] as [String: Any],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MycellmError.transportError("Announce failed (HTTP \(code)): \(body)")
        }
    }

    // MARK: - Incoming Message Dispatch

    private func handleIncoming(_ envelope: MessageEnvelope) async -> MessageEnvelope? {
        Log.bootstrap.info(" Incoming: \(envelope.type.rawValue) id=\(envelope.id)")
        switch envelope.type {
        case .nodeHelloAck:
            Log.bootstrap.info(" Received hello ack from server")
            return nil
        case .inferenceReq:
            return await onInferenceRequest?(envelope)
        case .ping:
            Log.bootstrap.info(" Responding to ping")
            return MessageBuilders.pong(from: peerId, requestId: envelope.id)
        default:
            Log.bootstrap.info(" Unhandled message type: \(envelope.type.rawValue)")
            return nil
        }
    }

    // MARK: - State

    private func setState(_ newState: ConnectionState, transport: Transport, error: String?) {
        state = newState
        self.transport = transport
        lastError = error
        onStateChange?(newState, transport, error)
    }
}

// MARK: - Local IP Detection

private func getLocalIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let addrFamily = interface.ifa_addr.pointee.sa_family
        guard addrFamily == UInt8(AF_INET) else { continue }
        let name = String(cString: interface.ifa_name)
        guard name == "en0" || name == "en1" else { continue }
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
        address = String(cString: hostname)
    }
    return address
}

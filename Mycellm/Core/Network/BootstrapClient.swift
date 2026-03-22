import Foundation
import Network

/// Bootstrap connection: QUIC preferred, HTTP fallback.
/// Maintains connection to bootstrap node for network participation.
actor BootstrapClient {
    static let defaultBootstrap = "bootstrap.mycellm.dev"
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
    private var httpEndpoint: String = "https://api.mycellm.dev"
    private var connection: NWConnection?
    private var retryTask: Task<Void, Never>?
    private var quicRetryTask: Task<Void, Never>?
    private var keepRunning = false
    private var peerId: String = ""
    private var onStateChange: (@Sendable (ConnectionState, Transport, String?) -> Void)?

    func configure(host: String, port: UInt16) {
        bootstrapHost = host
        bootstrapPort = port
        // Derive HTTP endpoint from bootstrap host
        if host == Self.defaultBootstrap {
            httpEndpoint = "https://api.mycellm.dev"
        } else {
            httpEndpoint = "http://\(host):8420"
        }
    }

    func setStateHandler(_ handler: @escaping @Sendable (ConnectionState, Transport, String?) -> Void) {
        onStateChange = handler
    }

    // MARK: - Connect

    func connect(peerId: String, capabilities: Capabilities) async {
        self.peerId = peerId
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
        connection?.cancel()
        connection = nil
        setState(.disconnected, transport: .none, error: nil)
    }

    // MARK: - QUIC Path

    private func attemptQUIC() async {
        setState(.connecting, transport: .quic, error: nil)

        let quicOptions = NWProtocolQUIC.Options(alpn: [QUICTransport.alpn])
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { _, _, completion in completion(true) },
            .main
        )

        let params = NWParameters(quic: quicOptions)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bootstrapHost),
            port: NWEndpoint.Port(rawValue: bootstrapPort)!
        )
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        // Timeout for QUIC connection
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            if await self.state == .connecting {
                conn.cancel()
                await self.handleQUICFailure("Connection timeout")
            }
        }

        conn.stateUpdateHandler = { [weak self] newState in
            timeoutTask.cancel()
            Task { await self?.handleQUICState(newState) }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func handleQUICState(_ newState: NWConnection.State) async {
        switch newState {
        case .ready:
            setState(.connected, transport: .quic, error: nil)
            connectedAt = Date()
            retryCount = 0

        case .failed(let error):
            await handleQUICFailure(error.localizedDescription)

        case .cancelled:
            if keepRunning && state != .fallbackHTTP {
                await handleQUICFailure("Connection cancelled")
            }

        default:
            break
        }
    }

    private func handleQUICFailure(_ reason: String) async {
        connection?.cancel()
        connection = nil
        retryCount += 1

        if retryCount >= Self.quicRetryBeforeFallback {
            // Fall back to HTTP
            await fallbackToHTTP(reason: "QUIC failed after \(retryCount) attempts: \(reason)")
        } else {
            // Retry QUIC
            let delay = Self.retryDelays[min(retryCount - 1, Self.retryDelays.count - 1)]
            setState(.reconnecting, transport: .quic, error: "Retry \(retryCount) in \(Int(delay))s — \(reason)")

            retryTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, keepRunning else { return }
                await attemptQUIC()
            }
        }
    }

    // MARK: - HTTP Fallback

    private func fallbackToHTTP(reason: String) async {
        setState(.fallbackHTTP, transport: .http, error: reason)

        // Register via HTTP
        do {
            try await httpRegister()
            setState(.connected, transport: .http, error: "QUIC unavailable, using HTTP")
            connectedAt = Date()

            // Keep trying QUIC in background every 60s
            quicRetryTask = Task {
                while !Task.isCancelled && keepRunning {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, keepRunning else { break }
                    // Try QUIC silently
                    let success = await tryQUICSilent()
                    if success {
                        // Upgraded to QUIC
                        break
                    }
                }
            }
        } catch {
            setState(.failed, transport: .http, error: "HTTP fallback also failed: \(error.localizedDescription)")
            // Retry everything after delay
            retryTask = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, keepRunning else { return }
                retryCount = 0
                await attemptQUIC()
            }
        }
    }

    private func httpRegister() async throws {
        guard let url = URL(string: "\(httpEndpoint)/v1/node/announce") else {
            throw MycellmError.transportError("Invalid HTTP endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "peer_id": peerId,
            "platform": "ios",
            "version": "0.1.0",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw MycellmError.transportError("HTTP registration failed")
        }
    }

    /// Try QUIC silently — returns true if connected.
    private func tryQUICSilent() async -> Bool {
        let quicOptions = NWProtocolQUIC.Options(alpn: [QUICTransport.alpn])
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { _, _, completion in completion(true) },
            .main
        )

        let params = NWParameters(quic: quicOptions)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bootstrapHost),
            port: NWEndpoint.Port(rawValue: bootstrapPort)!
        )
        let conn = NWConnection(to: endpoint, using: params)
        let resolver = ContinuationResolver()

        return await withCheckedContinuation { cont in
            let timeout = Task {
                try? await Task.sleep(for: .seconds(5))
                if resolver.tryResolve() {
                    conn.cancel()
                    cont.resume(returning: false)
                }
            }

            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if resolver.tryResolve() {
                        timeout.cancel()
                        Task {
                            await self?.connection?.cancel()
                            await self?.upgradeToQUIC(conn)
                            cont.resume(returning: true)
                        }
                    }
                case .failed, .cancelled:
                    if resolver.tryResolve() {
                        timeout.cancel()
                        cont.resume(returning: false)
                    }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }
    private func upgradeToQUIC(_ conn: NWConnection) {
        connection = conn
        quicRetryTask?.cancel()
        quicRetryTask = nil
        setState(.connected, transport: .quic, error: nil)
        connectedAt = Date()
    }

    // MARK: - State

    private func setState(_ newState: ConnectionState, transport: Transport, error: String?) {
        state = newState
        self.transport = transport
        lastError = error
        onStateChange?(newState, transport, error)
    }
}

/// Thread-safe one-shot resolver for continuations.
private final class ContinuationResolver: @unchecked Sendable {
    private var resolved = false
    private let lock = NSLock()

    func tryResolve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }
}

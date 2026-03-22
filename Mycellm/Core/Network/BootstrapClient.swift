import Foundation

/// Bootstrap peer connection for joining the network.
actor BootstrapClient {
    static let defaultBootstrap = "bootstrap.mycellm.dev"
    static let defaultPort: UInt16 = 8421

    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: ConnectionState = .disconnected
    private var bootstrapHost: String = defaultBootstrap
    private var bootstrapPort: UInt16 = defaultPort

    func configure(host: String, port: UInt16) {
        bootstrapHost = host
        bootstrapPort = port
    }

    // Placeholder — Phase 4 will implement QUIC transport
    func connect(with hello: NodeHello) async throws {
        state = .connecting
        // TODO: Phase 4 — NWConnection QUIC with ALPN "mycellm-v1"
        state = .disconnected
    }

    func disconnect() {
        state = .disconnected
    }
}

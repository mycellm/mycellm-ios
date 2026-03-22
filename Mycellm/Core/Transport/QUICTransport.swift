import Foundation
import Network

/// QUIC transport using Network.framework. ALPN: "mycellm-v1".
///
/// Phase 4 will implement full QUIC client/server.
actor QUICTransport {
    static let alpn = "mycellm-v1"
    static let defaultPort: UInt16 = 8421

    enum State: Sendable {
        case stopped
        case listening(UInt16)
        case error(String)
    }

    private(set) var state: State = .stopped
    private var listener: NWListener?
    private var connections: [String: PeerConnection] = [:]

    /// Start listening for incoming QUIC connections.
    func startServer(port: UInt16 = defaultPort) throws {
        // TODO: Phase 4 — Full QUIC server implementation
        // - NWListener with QUIC protocol
        // - Self-signed TLS certificate
        // - ALPN "mycellm-v1"
        // - Message framing on streams
        state = .listening(port)
    }

    /// Stop the QUIC server.
    func stopServer() {
        listener?.cancel()
        listener = nil
        for conn in connections.values {
            conn.close()
        }
        connections.removeAll()
        state = .stopped
    }

    /// Connect to a peer.
    func connect(host: String, port: UInt16) async throws -> PeerConnection {
        // TODO: Phase 4
        throw MycellmError.transportError("QUIC transport not yet implemented (Phase 4)")
    }

    /// Number of active connections.
    var connectionCount: Int { connections.count }
}

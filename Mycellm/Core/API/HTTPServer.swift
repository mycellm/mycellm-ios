import Foundation

/// Local HTTP server on :8420 using Hummingbird 2.
/// Phase 3 will implement the full Hummingbird integration.
actor HTTPServer {
    static let defaultPort: Int = 8420

    enum State: Sendable {
        case stopped
        case starting
        case running(Int)
        case error(String)
    }

    private(set) var state: State = .stopped

    func start(port: Int = defaultPort) async throws {
        state = .starting
        // TODO: Phase 3 — Hummingbird application with routes
        state = .running(port)
    }

    func stop() async {
        state = .stopped
    }
}

import Foundation
import Network

/// Single peer lifecycle over a QUIC connection.
final class PeerConnection: Sendable {
    let peerId: String
    let remoteAddress: String
    let connectedAt: Date

    enum State: Sendable {
        case connecting
        case handshaking
        case authenticated
        case closing
        case closed
    }

    private let _state: UnsafeSendableBox<State>
    var state: State { _state.value }

    init(peerId: String, remoteAddress: String) {
        self.peerId = peerId
        self.remoteAddress = remoteAddress
        self.connectedAt = Date()
        self._state = UnsafeSendableBox(.connecting)
    }

    func close() {
        _state.value = .closed
        // TODO: Phase 4 — NWConnection.cancel()
    }
}

/// Simple thread-safe box. Only used internally for connection state.
final class UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

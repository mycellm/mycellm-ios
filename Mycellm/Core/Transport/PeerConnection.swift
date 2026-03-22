import Foundation
import Network

/// Single peer lifecycle over a QUIC connection.
final class PeerConnection: @unchecked Sendable {
    private(set) var peerId: String
    let remoteAddress: String
    let connectedAt: Date
    var nwConnection: NWConnection?

    enum State: Sendable {
        case connecting
        case handshaking
        case authenticated
        case closing
        case closed
    }

    private(set) var state: State = .connecting

    init(peerId: String, remoteAddress: String) {
        self.peerId = peerId
        self.remoteAddress = remoteAddress
        self.connectedAt = Date()
    }

    func setState(_ newState: State) {
        state = newState
    }

    func setPeerId(_ id: String) {
        peerId = id
    }

    func close() {
        state = .closed
        nwConnection?.cancel()
        nwConnection = nil
    }
}

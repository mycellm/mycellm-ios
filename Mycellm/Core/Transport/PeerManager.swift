import Foundation
import Observation

/// Tracks connected peers and their capabilities.
@Observable
final class PeerManager: @unchecked Sendable {
    private(set) var peers: [PeerInfo] = []

    struct PeerInfo: Identifiable, Sendable {
        var id: String { peerId }
        let peerId: String
        let remoteAddress: String
        let connectedAt: Date
        var role: String
        var models: [String]
        var latencyMs: Double?
        var lastSeen: Date
    }

    func addPeer(_ info: PeerInfo) {
        if let idx = peers.firstIndex(where: { $0.peerId == info.peerId }) {
            peers[idx] = info
        } else {
            peers.append(info)
        }
    }

    func removePeer(id: String) {
        peers.removeAll { $0.peerId == id }
    }

    func updateLatency(peerId: String, latencyMs: Double) {
        if let idx = peers.firstIndex(where: { $0.peerId == peerId }) {
            peers[idx].latencyMs = latencyMs
            peers[idx].lastSeen = Date()
        }
    }

    var connectedCount: Int { peers.count }
}

import Foundation
import Network

/// UDP hole punching for direct P2P QUIC connections.
/// Coordinates through bootstrap, probes remote candidates, upgrades to QUIC on success.
actor HolePuncher {
    static let probeMagic = "mycellm-punch-v1".data(using: .utf8)!
    static let probeTimeout: TimeInterval = 10.0
    static let probeInterval: TimeInterval = 0.25

    private(set) var activeAttempts: [String: PunchAttempt] = [:]

    struct PunchAttempt: Sendable {
        let targetPeerId: String
        let ourCandidates: [NATCandidate]
        var theirCandidates: [NATCandidate] = []
        var resultAddr: (String, Int)?
        var success: Bool = false
        var error: String = ""
    }

    /// Attempt to punch through to a remote peer.
    /// Returns (ip, port) on success, nil on failure.
    func initiate(
        targetPeerId: String,
        theirCandidates: [NATCandidate],
        ourCandidates: [NATCandidate]
    ) async -> (String, Int)? {
        var attempt = PunchAttempt(
            targetPeerId: targetPeerId,
            ourCandidates: ourCandidates,
            theirCandidates: theirCandidates
        )
        activeAttempts[targetPeerId] = attempt

        defer { activeAttempts.removeValue(forKey: targetPeerId) }

        // Send UDP probes to all their candidates
        for candidate in theirCandidates {
            let result = await probeCandidate(ip: candidate.ip, port: UInt16(candidate.port))
            if result {
                let addr = (candidate.ip, candidate.port)
                attempt.success = true
                attempt.resultAddr = addr
                Log.nat.info(" SUCCESS: \(targetPeerId.prefix(16)) via \(candidate.ip):\(candidate.port)")
                return addr
            }
        }

        Log.nat.info(" FAILED: \(targetPeerId.prefix(16)) — no candidates responded")
        return nil
    }

    /// Send a UDP probe and wait for response.
    private nonisolated func probeCandidate(ip: String, port: UInt16) async -> Bool {
        let conn = NWConnection(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        let resolver = ProbeResolver()

        return await withCheckedContinuation { cont in
            resolver.setContinuation(cont)

            let timeout = Task {
                try? await Task.sleep(for: .seconds(Self.probeTimeout))
                conn.cancel()
                resolver.resumeIfNeeded(returning: false)
            }

            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(content: Self.probeMagic, completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: Self.probeMagic.count, maximumLength: 1024) { data, _, _, _ in
                        timeout.cancel()
                        let success = data?.starts(with: Self.probeMagic) ?? false
                        conn.cancel()
                        resolver.resumeIfNeeded(returning: success)
                    }
                } else if case .failed = state {
                    timeout.cancel()
                    resolver.resumeIfNeeded(returning: false)
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }
}

private final class ProbeResolver: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved = false
    private let lock = NSLock()

    func setContinuation(_ cont: CheckedContinuation<Bool, Never>) {
        lock.withLock { continuation = cont }
    }

    func resumeIfNeeded(returning value: Bool) {
        lock.withLock {
            guard !resolved else { return }
            resolved = true
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

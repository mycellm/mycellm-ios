import Foundation
import Network

/// Discovers NAT type and public address via STUN servers.
actor NATDiscovery {
    private static let stunServers: [(String, UInt16)] = [
        ("stun.l.google.com", 19302),
        ("stun.cloudflare.com", 3478),
        ("stun.stunprotocol.org", 3478),
    ]

    private(set) var info = NATInfo()
    private var probeTask: Task<Void, Never>?

    /// Start periodic NAT discovery.
    func start(interval: TimeInterval = 300) async {
        info.localIP = getLocalIPAddress() ?? ""
        await probeOnce()
        probeTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await probeOnce()
            }
        }
    }

    func stop() {
        probeTask?.cancel()
        probeTask = nil
    }

    /// Set observed address from bootstrap NODE_HELLO_ACK.
    func setObservedAddr(_ addr: String) {
        info.observedAddr = addr
        if info.publicIP.isEmpty, let colonIdx = addr.lastIndex(of: ":") {
            info.publicIP = String(addr[addr.startIndex..<colonIdx])
            info.publicPort = Int(addr[addr.index(after: colonIdx)...]) ?? 0
        }
    }

    /// Probe STUN servers once.
    func probeOnce() async {
        var results: [(String, Int)] = []

        for (host, port) in Self.stunServers {
            do {
                let mapped = try await STUNClient.query(host: host, port: port, timeout: 3.0)
                results.append((mapped.ip, mapped.port))
            } catch {
                // Server unreachable, skip
            }
        }

        guard !results.isEmpty else {
            info.natType = .unknown
            info.confidence = 0
            Log.nat.info(" No STUN servers responded")
            return
        }

        // Most common IP
        let ips = results.map(\.0)
        let ports = results.map(\.1)
        let mostCommonIP = ips.mostCommon() ?? ""
        let mostCommonPort = ports.mostCommon() ?? 0

        info.publicIP = mostCommonIP
        info.publicPort = mostCommonPort

        // Classify
        let uniquePorts = Set(ports).count
        if uniquePorts == 1 {
            info.natType = info.localIP == mostCommonIP ? .open : .fullCone
        } else if uniquePorts == results.count {
            info.natType = .symmetric
        } else {
            info.natType = .portRestricted
        }

        info.confidence = Double(results.count) / Double(Self.stunServers.count)
        let natType = info.natType.rawValue
        let pubIP = info.publicIP
        let pubPort = info.publicPort
        let conf = Int(info.confidence * 100)
        let punch = info.natType.canHolePunch
        Log.nat.info("NAT: \(natType) \(pubIP):\(pubPort) (confidence: \(conf)%, punch: \(punch ? "yes" : "no"))")
    }

    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
        }
        return address
    }
}

// MARK: - Helpers

private extension Array where Element: Hashable {
    func mostCommon() -> Element? {
        var counts: [Element: Int] = [:]
        for e in self { counts[e, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}

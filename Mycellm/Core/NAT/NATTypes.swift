import Foundation

/// Classified NAT type based on STUN probing.
enum NATType: String, Sendable, Codable {
    case unknown = "unknown"
    case open = "open"
    case fullCone = "full_cone"
    case restricted = "restricted"
    case portRestricted = "port_restricted"
    case symmetric = "symmetric"

    var canHolePunch: Bool {
        switch self {
        case .open, .fullCone, .restricted, .portRestricted: true
        case .symmetric, .unknown: false
        }
    }

    var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .open: "Open (no NAT)"
        case .fullCone: "Full Cone"
        case .restricted: "Restricted"
        case .portRestricted: "Port Restricted"
        case .symmetric: "Symmetric"
        }
    }
}

/// A network address candidate for hole punching.
struct NATCandidate: Sendable, Codable {
    let ip: String
    let port: Int
    var type: String = "server_reflexive"  // "host" | "server_reflexive" | "relay"
    var priority: Int = 0
}

/// Discovered NAT information for this node.
struct NATInfo: Sendable {
    var publicIP: String = ""
    var publicPort: Int = 0
    var natType: NATType = .unknown
    var localIP: String = ""
    var localPort: Int = 0
    var confidence: Double = 0.0
    var observedAddr: String = ""

    var candidates: [NATCandidate] {
        var c: [NATCandidate] = []
        if !localIP.isEmpty && localPort > 0 {
            c.append(NATCandidate(ip: localIP, port: localPort, type: "host", priority: 100))
        }
        if !publicIP.isEmpty && publicPort > 0 {
            c.append(NATCandidate(ip: publicIP, port: publicPort, type: "server_reflexive", priority: 50))
        }
        return c
    }
}

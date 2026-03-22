import Foundation

/// Network participation mode.
enum NetworkMode: String, Sendable, CaseIterable, Identifiable {
    case standalone
    case `public`
    case `private`
    case fleet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standalone: "Standalone"
        case .public: "Public Network"
        case .private: "Private Network"
        case .fleet: "Fleet Managed"
        }
    }

    var description: String {
        switch self {
        case .standalone: "Personal LLM, no network"
        case .public: "Contribute to the public network"
        case .private: "Organization or team network"
        case .fleet: "Remotely managed node"
        }
    }

    var usesQUIC: Bool { self != .standalone }
    var usesBootstrap: Bool { self != .standalone }
    var requiresFleetKey: Bool { self == .fleet }
    var apiServerEnabled: Bool { self != .standalone }

    var iconName: String {
        switch self {
        case .standalone: "person.fill"
        case .public: "globe"
        case .private: "lock.fill"
        case .fleet: "server.rack"
        }
    }
}

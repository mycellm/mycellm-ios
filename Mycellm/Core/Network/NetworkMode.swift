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
        case .standalone: String(localized: "Standalone")
        case .public: String(localized: "Public Network")
        case .private: String(localized: "Private Network")
        case .fleet: String(localized: "Fleet Managed")
        }
    }

    var description: String {
        switch self {
        case .standalone: String(localized: "Personal LLM, no network")
        case .public: String(localized: "Contribute to the public network")
        case .private: String(localized: "Organization or team network")
        case .fleet: String(localized: "Remotely managed node")
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

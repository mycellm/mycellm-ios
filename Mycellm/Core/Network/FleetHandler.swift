import Foundation

/// Fleet command processing. Requires opt-in fleet admin key.
actor FleetHandler {
    private var fleetAdminKey: String?

    var isEnabled: Bool { fleetAdminKey != nil }

    func setFleetKey(_ key: String?) {
        fleetAdminKey = key
    }

    /// Process an incoming fleet command. Returns response payload.
    func handle(command: String, params: [String: CBORValue], adminKey: String) async -> (success: Bool, data: [String: CBORValue], error: String) {
        guard let expected = fleetAdminKey, adminKey == expected else {
            return (false, [:], ErrorCode.fleetKeyDenied.rawValue)
        }

        switch command {
        case "status":
            return (true, ["status": .string("ok")], "")
        case "load_model":
            // TODO: Phase 2 — delegate to ModelManager
            return (false, [:], "not_implemented")
        case "unload_model":
            return (false, [:], "not_implemented")
        case "set_mode":
            return (false, [:], "not_implemented")
        default:
            return (false, [:], "unknown_command: \(command)")
        }
    }
}

import Foundation

/// Fleet command processing. Requires opt-in fleet admin key.
actor FleetHandler {
    private var fleetAdminKey: String?
    private weak var nodeService: NodeService?

    var isEnabled: Bool { fleetAdminKey != nil }

    func setFleetKey(_ key: String?) {
        fleetAdminKey = key
    }

    func setNodeService(_ service: NodeService) {
        nodeService = service
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
            guard let node = nodeService else {
                return (false, [:], "node_service_unavailable")
            }
            guard let filename = params["filename"]?.stringValue else {
                return (false, [:], "missing_filename")
            }
            let scope = params["scope"]?.stringValue ?? "public"
            let manager = await MainActor.run { node.modelManager }
            let localFiles = await MainActor.run { manager.localFiles }
            guard let file = localFiles.first(where: { $0.filename == filename }) else {
                return (false, [:], "model_not_found: \(filename)")
            }
            do {
                try await manager.loadModel(file: file, scope: scope)
                return (true, ["model": .string(filename)], "")
            } catch {
                return (false, [:], "load_failed: \(error.localizedDescription)")
            }

        case "unload_model":
            guard let node = nodeService else {
                return (false, [:], "node_service_unavailable")
            }
            let manager = await MainActor.run { node.modelManager }
            let loaded = await MainActor.run { manager.loadedModels }
            guard let model = loaded.first else {
                return (false, [:], "no_model_loaded")
            }
            await manager.unloadModel(model)
            return (true, [:], "")

        case "set_mode":
            guard let node = nodeService else {
                return (false, [:], "node_service_unavailable")
            }
            guard let modeStr = params["mode"]?.stringValue,
                  let mode = NetworkMode.allCases.first(where: { $0.rawValue == modeStr }) else {
                return (false, [:], "invalid_mode")
            }
            await MainActor.run { node.setNetworkMode(mode) }
            return (true, ["mode": .string(mode.rawValue)], "")

        default:
            return (false, [:], "unknown_command: \(command)")
        }
    }
}

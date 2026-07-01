import Foundation

/// Fleet command processing. Requires an opt-in fleet admin key.
///
/// Command vocabulary is the dotted namespace shared with the Python node
/// (`node.py::_FLEET_COMMANDS`) so one fleet admin can drive a mixed fleet:
///   node.status, node.config, model.list, model.load, model.unload, model.scope
///
/// F1-P1 scope: shared-secret auth (constant-time compare), read-only config,
/// and loading of an already-present local model. Remote download is F1-P3;
/// Ed25519-signed per-command grants are F1-P2.
actor FleetHandler {
    private var fleetAdminKey: String?
    private weak var nodeService: NodeService?

    var isEnabled: Bool { !(fleetAdminKey ?? "").isEmpty }

    func setFleetKey(_ key: String?) {
        fleetAdminKey = key
    }

    func setNodeService(_ service: NodeService) {
        nodeService = service
    }

    /// Process an incoming fleet command. Returns the response payload triple
    /// (success, data, error) that `MessageBuilders.fleetResponse` serializes.
    func handle(command: String, params: [String: CBORValue], adminKey: String) async -> (success: Bool, data: [String: CBORValue], error: String) {
        guard let expected = fleetAdminKey, !expected.isEmpty else {
            return (false, [:], "Fleet admin key not configured on this node")
        }
        // Constant-time compare so a wrong key can't be recovered via timing.
        guard Self.constantTimeEqual(adminKey, expected) else {
            return (false, [:], ErrorCode.fleetKeyDenied.rawValue)
        }
        guard let node = nodeService else {
            return (false, [:], "node_service_unavailable")
        }

        switch command {
        case "node.status":
            let models = await MainActor.run { node.modelManager.loadedModels }
            var data: [String: CBORValue] = [
                "node_name": .string(node.nodeName),
                "peer_id": .string(node.peerId),
                "role": .string(models.isEmpty ? "consumer" : "seeder"),
                "mode": .string(node.networkMode.rawValue),
                "models": .array(models.map { Self.modelSummary($0) }),
                "credits": .double(node.stats.creditBalance),
            ]
            data["hardware"] = .map(HardwareInfo.systemInfo())
            return (true, data, "")

        case "node.config":
            // Read-only, redacted — never echoes the fleet key or device secrets
            // (mirrors Python node.config).
            let cfg: [String: CBORValue] = await MainActor.run {
                let p = Preferences.shared
                return [
                    "node_name": .string(node.nodeName),
                    "bootstrap_host": .string(p.bootstrapHost),
                    "network_mode": .string(node.networkMode.rawValue),
                    "api_port": .int(Int64(p.apiPort)),
                    "default_ctx_len": .int(Int64(p.defaultCtxLen)),
                    "fleet_admin_key_set": .bool(true),
                ]
            }
            return (true, cfg, "")

        case "model.list":
            let models = await MainActor.run { node.modelManager.loadedModels }
            return (true, ["models": .array(models.map { Self.modelSummary($0) })], "")

        case "model.load":
            // P1 loads an already-present local model (remote download is F1-P3).
            // Accept name / filename / model_path (basename matched) so the same
            // admin command shape works against both Python and iOS nodes.
            guard let want = params["name"]?.stringValue
                ?? params["filename"]?.stringValue
                ?? params["model_path"]?.stringValue else {
                return (false, [:], "model name/filename required")
            }
            let wantBase = (want as NSString).lastPathComponent
            let scope = params["scope"]?.stringValue ?? "public"
            let manager = await MainActor.run { node.modelManager }
            let localFiles = await MainActor.run { manager.localFiles }
            guard let file = localFiles.first(where: { $0.filename == want || $0.filename == wantBase }) else {
                return (false, [:], "model_not_found: \(want)")
            }
            do {
                try await manager.loadModel(file: file, scope: scope)
                return (true, ["status": .string("loaded"), "model": .string(file.filename)], "")
            } catch {
                return (false, [:], "load_failed: \(error.localizedDescription)")
            }

        case "model.unload":
            let manager = await MainActor.run { node.modelManager }
            let loaded = await MainActor.run { manager.loadedModels }
            guard let model = Self.matchModel(params["model"]?.stringValue, in: loaded) else {
                return (false, [:], loaded.isEmpty ? "no_model_loaded" : "model_not_found")
            }
            await manager.unloadModel(model)
            return (true, ["status": .string("unloaded"), "model": .string(model.name)], "")

        case "model.scope":
            guard let scope = params["scope"]?.stringValue, scope == "home" || scope == "public" else {
                return (false, [:], "scope must be 'home' or 'public'")
            }
            let manager = await MainActor.run { node.modelManager }
            let loaded = await MainActor.run { manager.loadedModels }
            guard let model = Self.matchModel(params["model"]?.stringValue, in: loaded) else {
                return (false, [:], "model_not_found")
            }
            await MainActor.run { manager.setScope(scope, for: model) }
            return (true, ["status": .string("updated"), "model": .string(model.name), "scope": .string(scope)], "")

        default:
            return (false, [:], "unknown_command: \(command)")
        }
    }

    /// Match by name/filename, or the single loaded model when unspecified
    /// (iOS holds one model at a time).
    private static func matchModel(_ name: String?, in loaded: [ModelManager.LoadedModel]) -> ModelManager.LoadedModel? {
        guard let name, !name.isEmpty else { return loaded.first }
        return loaded.first { $0.name == name || $0.filename == name }
    }

    private static func modelSummary(_ m: ModelManager.LoadedModel) -> CBORValue {
        .map([
            "name": .string(m.name),
            "filename": .string(m.filename),
            "ctx_len": .int(Int64(m.contextLength)),
            "backend": .string(m.backend),
            "scope": .string(m.scope),
            "size_bytes": .int(Int64(m.sizeBytes)),
        ])
    }

    /// Length-independent constant-time string comparison (UTF-8 bytes).
    /// Mirrors Python's `hmac.compare_digest` use on the node side.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = ab.count ^ bb.count
        let n = max(ab.count, bb.count)
        var i = 0
        while i < n {
            let x = i < ab.count ? Int(ab[i]) : 0
            let y = i < bb.count ? Int(bb[i]) : 0
            diff |= x ^ y
            i += 1
        }
        return diff == 0
    }
}

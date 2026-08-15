import Foundation

/// Node info routes: `/v1/node/status`, `/system`, `/version`, `/peers`,
/// `/connections`. Mirrors the same paths in `src/mycellm/api/node.py`.
enum NodeRoutes {

    /// GET /v1/node/status
    ///
    /// ⚠️ THE ORIGINAL EIGHT KEYS ARE LOAD-BEARING AND STAY. Everything from
    /// `peer_id` down to `credit_balance` predates this route having Python
    /// parity, and the app's own Settings/Dashboard screens plus any LAN client
    /// written against an earlier build read them by name. The Python-shaped
    /// fields are added alongside rather than replacing them — a status
    /// response is cheap and a broken client is not.
    ///
    /// ⚠️ `version` IS WHY THIS ROUTE CHANGED. `menubar/state.py` reads
    /// `status["version"]` and treats its absence as "node older than 0.5.1";
    /// until now every iOS node answered without it and was permanently
    /// misreported as pre-0.5.1 by the fleet's own tooling. It reports the core
    /// parity version — the protocol contract other nodes care about — not the
    /// App Store marketing version, which is in `app_version`.
    static func status(node: NodeService) async -> [String: Any] {
        let models = node.modelManager.loadedModels
        let peers = node.connectedPeerInfo
        let ledger = node.creditLedger
        let balance = await ledger.balance
        let earned = await ledger.totalEarned
        let spent = await ledger.totalSpent
        let nat = await node.natDiscovery.info
        // Captured on the main actor (UIKit owns battery/app state), rendered
        // to JSON here — Snapshot is Sendable so the hop is legal.
        let connectivity = node.connectivity
        let deviceSnapshot = await MainActor.run { DeviceState.capture(connectivity: connectivity) }
        let role = await MainActor.run {
            DeviceState.effectiveRole(hasLoadedModels: !models.isEmpty)
        }

        return [
            // — original surface —
            "peer_id": node.peerId,
            "node_name": node.nodeName,
            "running": node.isRunning,
            "network_mode": node.networkMode.rawValue,
            "connected_peers": node.connection.connectedPeers,
            "loaded_models": models.count,
            "total_inferences": node.stats.totalInferences,
            "credit_balance": node.stats.creditBalance,

            // — Python parity —
            "version": NetworkConfig.version,
            "app_version": AppVersion.marketing,
            "uptime_seconds": node.uptimeSeconds,
            // ⚠️ NOT SIMPLY "HAS A MODEL LOADED". A device that is thermally
            // critical, in Low Power Mode, or under 20% on battery has a model
            // loaded and still cannot usefully serve — see DeviceState.canServe.
            // Reporting `seeder` there invites work this node will fail.
            "role": role,
            // Volatile iOS conditions: thermal, power, network, foreground.
            "device": deviceSnapshot.asDict,
            "mode": node.networkMode.rawValue,
            "tps": node.stats.activity.tps,
            "hardware": hardware(),
            "credits": ["balance": balance, "earned": earned, "spent": spent] as [String: Any],
            "peers": peers.map(peerDict),
            "models": models.map { m in
                [
                    "name": m.name,
                    "quant": m.quant,
                    "ctx_len": m.contextLength,
                    "backend": m.backend,
                    "param_count_b": m.paramCountB,
                    "scope": m.scope,
                    "features": ["streaming"],
                    "loaded_bytes": m.sizeBytes,
                ] as [String: Any]
            },
            // A device serves one model at a time; `active` is 0 or 1 and
            // `max_concurrent` reflects that rather than a configurable pool.
            "inference": ["active": models.isEmpty ? 0 : 1, "max_concurrent": 1] as [String: Any],
            "nat": [
                "local_ip": nat.localIP,
                "public_ip": nat.publicIP,
                "nat_type": nat.natType.rawValue,
            ] as [String: Any],
        ]
    }

    /// GET /v1/node/system
    static func system() -> [String: Any] {
        [
            "chip": HardwareInfo.chipName,
            "model": HardwareInfo.modelIdentifier,
            "total_memory_gb": HardwareInfo.totalMemoryGB,
            "available_memory_gb": HardwareInfo.availableMemoryGB,
            "gpu_cores": HardwareInfo.estimatedGPUCores,
            "neural_engine": HardwareInfo.hasNeuralEngine,
            "backend": "metal",
            "os": "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            // Free space on the models volume, reported the same way the
            // downloader sizes a transfer — `ForImportantUsage`, which excludes
            // purgeable space the system may decline to release. A caller
            // planning a download needs the honest number, not the optimistic
            // one `volumeAvailableCapacity` gives.
            "storage": [
                "models_free_bytes": MLXRepo.freeBytes(),
                "models_dir": ModelManager.modelsDirectory.path,
            ] as [String: Any],
        ]
    }

    /// GET /v1/node/peers
    static func peers(node: NodeService) -> [String: Any] {
        ["peers": node.connectedPeerInfo.map(peerDict)]
    }

    /// GET /v1/node/connections — per-peer diagnostic detail.
    ///
    /// Python reads this from its `PeerManager.get_connections()`, which tracks
    /// QUIC-level state per peer. iOS keeps the same fields and adds the
    /// per-network bootstrap state, because on a device the interesting failure
    /// is usually "which network am I connected to", not "which QUIC stream".
    static func connections(node: NodeService) -> [String: Any] {
        let peerConnections = node.connectedPeerInfo.map { p -> [String: Any] in
            [
                "peer_id": p.peerId,
                "remote_address": p.remoteAddress,
                "connected_at": p.connectedAt.timeIntervalSince1970,
                "last_seen": p.lastSeen.timeIntervalSince1970,
                "latency_ms": p.latencyMs ?? NSNull(),
                "role": p.role,
                "state": "connected",
            ]
        }
        let networks = node.connection.networkStates
            .sorted { $0.key < $1.key }
            .map { id, s -> [String: Any] in
                [
                    "network_id": id,
                    "state": String(describing: s.state),
                    "transport": String(describing: s.transport),
                    "error": s.error ?? NSNull(),
                ]
            }
        return ["connections": peerConnections, "networks": networks]
    }

    /// GET /v1/node/version — current version plus an update check.
    ///
    /// Python asks PyPI whether a newer `mycellm` is published. The iOS
    /// equivalent is the App Store, so this asks the iTunes lookup API for the
    /// live listing and compares against the running marketing version. Both
    /// fail the same way: on timeout or offline, `latest` stays nil and
    /// `update_available` false — an update check must never make the node's
    /// own version unreadable.
    ///
    /// `current` is the core parity version, matching what `/v1/node/status`
    /// reports and what a fleet peer compares against. The App Store version is
    /// separate (`app_version` / `latest_app_version`) because the two version
    /// each other independently — a build can ship with no protocol change.
    static func version() async -> [String: Any] {
        var result: [String: Any] = [
            "current": NetworkConfig.version,
            "app_version": AppVersion.marketing,
            "build": AppVersion.build,
            "latest": NSNull(),
            "latest_app_version": NSNull(),
            "update_available": false,
        ]

        guard let url = URL(string:
            "https://itunes.apple.com/lookup?id=\(AppVersion.appStoreID)&t=\(Int(Date().timeIntervalSince1970))")
        else { return result }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let latest = results.first?["version"] as? String, !latest.isEmpty
        else { return result }

        result["latest_app_version"] = latest
        result["update_available"] = isNewer(latest, than: AppVersion.marketing)
        return result
    }

    /// Dotted-version comparison over the first three components. Anything
    /// unparseable means "not newer" — an update prompt driven by a version
    /// string we don't understand is worse than no prompt.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parse(_ v: String) -> [Int]? {
            let parts = v.split(separator: ".").prefix(3).map { Int($0) }
            guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
            var ints = parts.map { $0! }
            while ints.count < 3 { ints.append(0) }
            return ints
        }
        guard let l = parse(latest), let c = parse(current) else { return false }
        return c.lexicographicallyPrecedes(l)
    }

    // MARK: - Shared shapes

    private static func peerDict(_ p: PeerManager.PeerInfo) -> [String: Any] {
        [
            "peer_id": p.peerId,
            "role": p.role,
            "models": p.models,
            "status": "connected",
            "latency_ms": p.latencyMs ?? NSNull(),
        ]
    }

    private static func hardware() -> [String: Any] {
        [
            "gpu": HardwareInfo.chipName,
            // Unified memory — the GPU's pool is system RAM.
            "vram_gb": HardwareInfo.totalMemoryGB,
            "backend": "metal",
        ]
    }
}

/// The app's own version identity, read from the bundle so it can never drift
/// from what `project.yml` set at build time.
enum AppVersion {
    static let appStoreID = "6761091607"

    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

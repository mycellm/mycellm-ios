import Foundation

/// Node info routes: /v1/node/status, /v1/node/system
enum NodeRoutes {
    /// GET /v1/node/status
    static func status(node: NodeService) -> [String: Any] {
        [
            "peer_id": node.peerId,
            "node_name": node.nodeName,
            "running": node.isRunning,
            "network_mode": node.networkMode.rawValue,
            "connected_peers": node.connectedPeers,
            "loaded_models": node.loadedModels,
            "total_inferences": node.totalInferences,
            "credit_balance": node.creditBalance,
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
        ]
    }
}

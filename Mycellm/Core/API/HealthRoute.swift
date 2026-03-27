import Foundation

/// GET /health — simple health check.
enum HealthRoute {
    static func response(node: NodeService) -> [String: Any] {
        [
            "status": node.isRunning ? "ok" : "stopped",
            "version": NetworkConfig.version,
            "platform": "ios",
        ]
    }
}

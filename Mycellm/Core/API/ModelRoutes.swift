import Foundation

/// Model management routes.
enum ModelRoutes {
    struct LoadRequest: Codable, Sendable {
        let filename: String
        var scope: String? = "home"
    }

    struct UnloadRequest: Codable, Sendable {
        let model: String
    }

    struct ScopeRequest: Codable, Sendable {
        let model: String
        let scope: String
    }

    struct DownloadRequest: Codable, Sendable {
        let repo_id: String
        let filename: String
    }

    struct SearchQuery: Codable, Sendable {
        var query: String = ""
        var limit: Int = 20
    }

    /// Hardware-aware suggested models based on available RAM.
    static func suggestedModels() -> [[String: Any]] {
        let memGB = HardwareInfo.totalMemoryGB
        var suggestions: [[String: Any]] = []

        if memGB >= 4 {
            suggestions.append([
                "name": "Qwen2.5-1.5B-Instruct",
                "repo_id": "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
                "filename": "qwen2.5-1.5b-instruct-q4_k_m.gguf",
                "size_gb": 1.1,
                "params_b": 1.5,
                "fit": "comfortable",
            ])
        }
        if memGB >= 6 {
            suggestions.append([
                "name": "Llama-3.2-3B-Instruct",
                "repo_id": "bartowski/Llama-3.2-3B-Instruct-GGUF",
                "filename": "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                "size_gb": 2.0,
                "params_b": 3.0,
                "fit": "comfortable",
            ])
        }
        if memGB >= 8 {
            suggestions.append([
                "name": "Phi-4-mini-instruct",
                "repo_id": "bartowski/phi-4-mini-instruct-GGUF",
                "filename": "phi-4-mini-instruct-Q4_K_M.gguf",
                "size_gb": 2.5,
                "params_b": 3.8,
                "fit": "comfortable",
            ])
        }
        if memGB >= 12 {
            suggestions.append([
                "name": "Qwen2.5-7B-Instruct",
                "repo_id": "Qwen/Qwen2.5-7B-Instruct-GGUF",
                "filename": "qwen2.5-7b-instruct-q4_k_m.gguf",
                "size_gb": 4.7,
                "params_b": 7.0,
                "fit": memGB >= 16 ? "comfortable" : "tight",
            ])
        }

        return suggestions
    }
}

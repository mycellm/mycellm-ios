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
    /// All URLs verified to be publicly accessible (no auth gating).
    static func suggestedModels() -> [[String: Any]] {
        let memGB = HardwareInfo.totalMemoryGB
        var suggestions: [[String: Any]] = []

        if memGB >= 4 {
            suggestions.append([
                "name": "SmolLM2-1.7B-Instruct",
                "repo_id": "bartowski/SmolLM2-1.7B-Instruct-GGUF",
                "filename": "SmolLM2-1.7B-Instruct-Q4_K_M.gguf",
                "size_gb": 1.1,
                "params_b": 1.7,
                "fit": "comfortable",
            ])
        }
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
                "name": "Gemma-2-2B-IT",
                "repo_id": "bartowski/gemma-2-2b-it-GGUF",
                "filename": "gemma-2-2b-it-Q4_K_M.gguf",
                "size_gb": 1.6,
                "params_b": 2.0,
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
                "name": "Phi-3.5-mini-instruct",
                "repo_id": "bartowski/Phi-3.5-mini-instruct-GGUF",
                "filename": "Phi-3.5-mini-instruct-Q4_K_M.gguf",
                "size_gb": 2.2,
                "params_b": 3.8,
                "fit": "comfortable",
            ])
        }

        return suggestions
    }

    private struct SearchResult: Sendable {
        let repoId: String
        let name: String
        let filename: String
        let downloads: Int
        let hasQ4: Bool

        var dict: [String: Any] {
            ["repo_id": repoId, "name": name, "filename": filename, "downloads": downloads, "has_q4": hasQ4]
        }
    }

    /// Search HuggingFace for GGUF models.
    /// The search endpoint doesn't return file listings, so we fetch details for top results.
    static func searchHuggingFace(query: String) async -> [[String: Any]] {
        let searchQuery = query.isEmpty ? "gguf" : "\(query) gguf"
        guard let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://huggingface.co/api/models?search=\(encoded)&filter=gguf&sort=downloads&direction=-1&limit=20") else {
            return []
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let models = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            let results = await withTaskGroup(of: SearchResult?.self) { group in
                for model in models.prefix(15) {
                    guard let modelId = model["modelId"] as? String,
                          let downloads = model["downloads"] as? Int else { continue }
                    let name = modelId.components(separatedBy: "/").last ?? modelId

                    group.addTask {
                        guard let detailURL = URL(string: "https://huggingface.co/api/models/\(modelId)") else {
                            return SearchResult(repoId: modelId, name: name, filename: "", downloads: downloads, hasQ4: false)
                        }

                        var ggufFiles: [String] = []
                        if let (detailData, _) = try? await URLSession.shared.data(from: detailURL),
                           let detail = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any] {
                            let siblings = detail["siblings"] as? [[String: Any]] ?? []
                            ggufFiles = siblings
                                .compactMap { $0["rfilename"] as? String }
                                .filter { $0.hasSuffix(".gguf") && ($0.contains("Q4_K_M") || $0.contains("q4_k_m")) }
                        }

                        return SearchResult(repoId: modelId, name: name, filename: ggufFiles.first ?? "", downloads: downloads, hasQ4: !ggufFiles.isEmpty)
                    }
                }

                var collected: [SearchResult] = []
                for await result in group {
                    if let r = result { collected.append(r) }
                }
                return collected.sorted { $0.downloads > $1.downloads }
            }

            return results.map(\.dict)
        } catch {
            return []
        }
    }
}

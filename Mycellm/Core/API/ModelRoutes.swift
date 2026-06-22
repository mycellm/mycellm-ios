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
        // Curated cross-family catalog. (name, repo_id, filename, size_gb, params_b, minMemGB)
        let catalog: [(String, String, String, Double, Double, Double)] = [
            ("SmolLM2-1.7B-Instruct", "bartowski/SmolLM2-1.7B-Instruct-GGUF", "SmolLM2-1.7B-Instruct-Q4_K_M.gguf", 1.1, 1.7, 4),
            ("Qwen2.5-1.5B-Instruct", "Qwen/Qwen2.5-1.5B-Instruct-GGUF", "qwen2.5-1.5b-instruct-q4_k_m.gguf", 1.1, 1.5, 4),
            ("Gemma-2-2B-IT", "bartowski/gemma-2-2b-it-GGUF", "gemma-2-2b-it-Q4_K_M.gguf", 1.6, 2.0, 6),
            ("Llama-3.2-3B-Instruct", "bartowski/Llama-3.2-3B-Instruct-GGUF", "Llama-3.2-3B-Instruct-Q4_K_M.gguf", 2.0, 3.0, 6),
            ("Qwen2.5-3B-Instruct", "Qwen/Qwen2.5-3B-Instruct-GGUF", "qwen2.5-3b-instruct-q4_k_m.gguf", 2.0, 3.0, 6),
            ("Qwen3-4B", "Qwen/Qwen3-4B-GGUF", "Qwen3-4B-Q4_K_M.gguf", 2.5, 4.0, 8),
            ("Phi-3.5-mini-instruct", "bartowski/Phi-3.5-mini-instruct-GGUF", "Phi-3.5-mini-instruct-Q4_K_M.gguf", 2.2, 3.8, 8),
            ("Mistral-7B-Instruct-v0.3", "bartowski/Mistral-7B-Instruct-v0.3-GGUF", "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf", 4.4, 7.2, 8),
            ("DeepSeek-R1-Distill-Qwen-7B", "bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF", "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf", 4.7, 7.6, 8),
            ("Qwen2.5-7B-Instruct", "Qwen/Qwen2.5-7B-Instruct-GGUF", "qwen2.5-7b-instruct-q4_k_m.gguf", 4.7, 7.6, 8),
            ("GLM-4-9B-Chat", "bartowski/glm-4-9b-chat-GGUF", "glm-4-9b-chat-Q4_K_M.gguf", 5.5, 9.4, 12),
            ("Qwen2.5-14B-Instruct", "Qwen/Qwen2.5-14B-Instruct-GGUF", "qwen2.5-14b-instruct-q4_k_m.gguf", 8.5, 14.0, 16),
        ]
        func fit(_ minMem: Double) -> String {
            if memGB >= minMem + 4 { return "comfortable" }
            if memGB >= minMem { return "tight" }
            return "heavy"
        }
        // Screenshot mode shows the full catalog regardless of device memory.
        return catalog.filter { ScreenshotMode.isActive || memGB >= $0.5 }.map { m in
            ["name": m.0, "repo_id": m.1, "filename": m.2, "size_gb": m.3, "params_b": m.4, "fit": fit(m.5)]
        }
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

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
        let usable: Bool
        let format: String

        var dict: [String: Any] {
            [
                "repo_id": repoId, "name": name, "filename": filename,
                "downloads": downloads, "format": format, "usable": usable,
                // Kept so older clients keep working; for MLX it means the same
                // thing the name implies — a quantised, downloadable model.
                "has_q4": usable,
            ]
        }
    }

    /// Search HuggingFace for models this node can actually run.
    ///
    /// ⚠️ DEFAULTS TO MLX, and that is a behaviour change worth understanding.
    /// This used to hardcode `filter=gguf` and append " gguf" to every query, so
    /// MLX models were not merely deprioritised — they were unreachable through
    /// search, on a device where MLX is the faster backend (Metal, no GGUF
    /// dequantisation step). Passing `format=gguf` restores the old behaviour
    /// exactly; llama.cpp remains fully supported and is still the right choice
    /// for a quant MLX doesn't publish.
    ///
    /// The search endpoint doesn't return file listings, so details are fetched
    /// for the top results to find out whether a repo actually contains weights
    /// we can use.
    /// GET /v1/node/models/search/{repo_id}/files — the installable variants in
    /// a Hugging Face repo.
    ///
    /// Two layouts, matching Python's: one or more `.gguf` files at the repo
    /// root (each an independent variant, llama.cpp), or a directory of
    /// `.safetensors` shards plus `config.json` (MLX — the *whole repo* is one
    /// variant, which is why its entry carries an empty `filename`; downloading
    /// a single shard would produce an unusable model).
    ///
    /// Warnings are computed against this device's real free space and RAM, so
    /// a picker can grey out a 7B Q8 on an 8 GB iPhone before the user commits
    /// to a multi-gigabyte download.
    static func repoFiles(repoId: String) async -> [String: Any] {
        guard !repoId.isEmpty,
              let encoded = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let treeURL = URL(string: "https://huggingface.co/api/models/\(encoded)/tree/main")
        else { return ["error": "repo_id required", "files": []] }

        guard let (data, response) = try? await URLSession.shared.data(from: treeURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tree = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return ["error": "Could not read repo '\(repoId)'", "files": []] }

        let diskFree = MLXRepo.freeBytes()
        let ramGB = HardwareInfo.totalMemoryGB

        func warnings(forBytes size: Int64) -> [String] {
            var out: [String] = []
            let estRamGB = Double(size) / 1_073_741_824.0 * 1.2
            if size > 0, diskFree > 0, size > diskFree {
                out.append(String(
                    format: "Insufficient disk space (%.1fGB free, need %.1fGB)",
                    Double(diskFree) / 1_073_741_824.0, Double(size) / 1_073_741_824.0))
            }
            if estRamGB > 0, ramGB > 0, estRamGB > ramGB * 0.8 {
                out.append(String(
                    format: "May need more RAM (%.1fGB needed, %.1fGB available)", estRamGB, ramGB))
            }
            return out
        }

        func size(of entry: [String: Any]) -> Int64 {
            if let s = entry["size"] as? Int64, s > 0 { return s }
            if let s = entry["size"] as? Int, s > 0 { return Int64(s) }
            if let lfs = entry["lfs"] as? [String: Any] {
                if let s = lfs["size"] as? Int64 { return s }
                if let s = lfs["size"] as? Int { return Int64(s) }
            }
            return 0
        }

        var files: [[String: Any]] = []
        var safetensorsBytes: Int64 = 0
        var hasSafetensors = false
        var hasConfig = false

        for entry in tree {
            let path = entry["path"] as? String ?? ""
            if path == "config.json" { hasConfig = true; continue }
            if path.hasSuffix(".safetensors") {
                hasSafetensors = true
                safetensorsBytes += size(of: entry)
                continue
            }
            guard path.hasSuffix(".gguf") else { continue }

            let bytes = size(of: entry)
            files.append([
                "filename": path,
                "format": "gguf",
                "backend": "llama.cpp",
                "size_bytes": bytes,
                "size_gb": (Double(bytes) / 1_073_741_824.0 * 100).rounded() / 100,
                "quant": quantLabel(from: path),
                "est_ram_gb": (Double(bytes) / 1_073_741_824.0 * 1.2 * 10).rounded() / 10,
                "warnings": warnings(forBytes: bytes),
            ])
        }

        if hasConfig, hasSafetensors, files.isEmpty {
            files.append([
                "filename": "",
                "format": "mlx",
                "backend": "mlx",
                "size_bytes": safetensorsBytes,
                "size_gb": (Double(safetensorsBytes) / 1_073_741_824.0 * 100).rounded() / 100,
                "quant": quantLabel(from: repoId),
                "est_ram_gb": (Double(safetensorsBytes) / 1_073_741_824.0 * 1.2 * 10).rounded() / 10,
                "warnings": warnings(forBytes: safetensorsBytes),
            ])
        }

        return ["repo_id": repoId, "files": files]
    }

    /// Pull a quantisation label out of a filename or repo id — `Q4_K_M`,
    /// `IQ3_XS`, `f16`. Mirrors the regex Python uses.
    static func quantLabel(from name: String) -> String {
        let pattern = "[._-](Q\\d[_A-Z0-9]*|[Ff]16|[Ff]32|IQ\\d[_A-Z0-9]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name)
        else { return "" }
        return String(name[range])
    }

    static func searchHuggingFace(query: String, format: String = "mlx") async -> [[String: Any]] {
        let wantsMLX = format.lowercased() != "gguf"
        let tag = wantsMLX ? "mlx" : "gguf"
        let searchQuery = query.isEmpty ? tag : "\(query) \(tag)"
        guard let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://huggingface.co/api/models?search=\(encoded)&filter=\(tag)&sort=downloads&direction=-1&limit=20") else {
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
                            return SearchResult(repoId: modelId, name: name, filename: "",
                                                downloads: downloads, usable: false, format: tag)
                        }

                        var siblings: [String] = []
                        if let (detailData, _) = try? await URLSession.shared.data(from: detailURL),
                           let detail = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any] {
                            siblings = (detail["siblings"] as? [[String: Any]] ?? [])
                                .compactMap { $0["rfilename"] as? String }
                        }

                        if wantsMLX {
                            // ⚠️ NO FILENAME FOR MLX — the model IS the repo.
                            // A caller that treats this like the GGUF case and
                            // downloads one .safetensors gets a shard, not a
                            // model. `filename` stays empty deliberately so that
                            // mistake can't be made silently; the download
                            // endpoint takes the repo id.
                            let hasWeights = siblings.contains { $0.hasSuffix(".safetensors") }
                                && siblings.contains { $0 == "config.json" }
                            return SearchResult(repoId: modelId, name: name, filename: "",
                                                downloads: downloads, usable: hasWeights, format: "mlx")
                        }

                        let ggufFiles = siblings.filter {
                            $0.hasSuffix(".gguf") && ($0.contains("Q4_K_M") || $0.contains("q4_k_m"))
                        }
                        return SearchResult(repoId: modelId, name: name, filename: ggufFiles.first ?? "",
                                            downloads: downloads, usable: !ggufFiles.isEmpty, format: "gguf")
                    }
                }

                var collected: [SearchResult] = []
                for await result in group {
                    if let r = result { collected.append(r) }
                }
                // Repos we can't use sink below ones we can — a search that
                // leads with undownloadable results reads as a broken search.
                return collected.sorted {
                    $0.usable == $1.usable ? $0.downloads > $1.downloads : $0.usable
                }
            }

            return results.map(\.dict)
        } catch {
            return []
        }
    }
}

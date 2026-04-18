import Foundation

// MLX inference backend for Apple Silicon.
//
// Uses Apple's mlx-swift framework via the MLXLLM library for native
// Metal-accelerated inference with safetensors models from HuggingFace.
//
// Advantages over llama.cpp on Apple Silicon:
// - Native Metal compute graph (no C FFI overhead)
// - KV cache quantization support (when enabled in MLX)
// - Direct HuggingFace safetensors loading (mlx-community ecosystem)
// - SSD expert streaming for MoE models (future, via MLX)
//
// Dependencies (add to Package.swift / Xcode project):
//   .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main")
//   Products: MLXLLM, MLXLMCommon
//
// Credits:
// - mlx-swift by Apple (MIT) — github.com/ml-explore/mlx-swift
// - mlx-swift-lm by Apple (MIT) — github.com/ml-explore/mlx-swift-lm
// - SwiftLM by SharpAI (MIT) — github.com/SharpAI/SwiftLM
//   Reference implementation for MLX inference server + TurboQuant KV cache

#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon

actor MLXBackend: InferenceBackend {
    let backendName = "MLX"
    private(set) var loadedModel: String?
    private(set) var tokensPerSecond: Double = 0.0

    private var container: ModelContainer?

    func loadModel(path: String, name: String) async throws {
        // Clean up previous model
        container = nil

        // Load from local directory (must contain config.json + safetensors)
        let modelURL = URL(filePath: path)

        // Check available memory vs model size
        let modelSize = directorySize(modelURL)
        let fit = HardwareInfo.ramFit(modelSizeBytes: modelSize)
        guard fit != .tooLarge else {
            throw MycellmError.modelTooLarge(needed: modelSize, available: HardwareInfo.availableMemory)
        }

        // Set MLX memory limits
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)  // 256MB cache

        let newContainer = try await LLMModelFactory.shared.loadContainer(
            hub: modelURL,
            configuration: .init(id: name)
        ) { progress in
            // Progress callback — could pipe to UI if needed
        }

        container = newContainer
        loadedModel = name
    }

    func unloadModel() {
        container = nil
        loadedModel = nil
        tokensPerSecond = 0
    }

    func complete(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int
    ) async throws -> InferenceResult {
        guard let container else {
            throw MycellmError.modelNotLoaded("No MLX model loaded")
        }

        let userInput = formatMessages(messages)
        let lmInput = try await container.prepare(input: userInput)
        let promptTokens = lmInput.text.tokens.size

        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(temperature)
        )

        var fullText = ""
        var completionTokens = 0
        let startTime = Date()

        let stream = try await container.generate(input: lmInput, parameters: parameters)
        for await result in stream {
            if let chunk = result.chunk {
                fullText += chunk
                completionTokens += 1
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        tokensPerSecond = elapsed > 0 ? Double(completionTokens) / elapsed : 0

        return InferenceResult(
            text: fullText,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }

    func stream(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let container = self.container else {
                        throw MycellmError.modelNotLoaded("No MLX model loaded")
                    }

                    let userInput = self.formatMessages(messages)
                    let lmInput = try await container.prepare(input: userInput)

                    let parameters = GenerateParameters(
                        maxTokens: maxTokens,
                        temperature: Float(temperature)
                    )

                    let startTime = Date()
                    var tokenCount = 0

                    let stream = try await container.generate(input: lmInput, parameters: parameters)
                    for await result in stream {
                        if Task.isCancelled { break }
                        if let chunk = result.chunk {
                            continuation.yield(chunk)
                            tokenCount += 1
                        }
                    }

                    let elapsed = Date().timeIntervalSince(startTime)
                    self.tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func resetContext() throws {
        // MLX manages context internally per generation — no explicit reset needed
    }

    func cleanup() {
        container = nil
        loadedModel = nil
    }

    // MARK: - Helpers

    /// Format chat messages into a single prompt string.
    /// MLX's ChatSession handles templates, but for direct generate() we format manually.
    private func formatMessages(_ messages: [[String: String]]) -> String {
        // Use ChatML as default template — MLX will use the model's template if available
        var prompt = ""
        for msg in messages {
            let role = msg["role"] ?? "user"
            let content = msg["content"] ?? ""
            prompt += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }

    /// Calculate total size of a model directory.
    private func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }
}

#else

// Stub when MLXLLM is not available (dependency not added yet)
actor MLXBackend: InferenceBackend {
    let backendName = "MLX"
    private(set) var loadedModel: String?
    private(set) var tokensPerSecond: Double = 0.0

    func loadModel(path: String, name: String) async throws {
        throw MycellmError.inferenceError(
            "MLX backend requires the mlx-swift-lm package. " +
            "Add .package(url: \"https://github.com/ml-explore/mlx-swift-lm\", branch: \"main\") " +
            "to your Swift package dependencies."
        )
    }
    func unloadModel() {}
    func complete(messages: [[String: String]], temperature: Double, maxTokens: Int) async throws -> InferenceResult {
        throw MycellmError.inferenceError("MLX backend not available")
    }
    func stream(messages: [[String: String]], temperature: Double, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: MycellmError.inferenceError("MLX backend not available")) }
    }
    func resetContext() throws {}
    func cleanup() {}
}

#endif

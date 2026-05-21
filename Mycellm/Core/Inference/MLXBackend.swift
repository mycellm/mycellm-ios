import Foundation

// MLX inference backend for Apple Silicon.
//
// Uses Apple's mlx-swift framework via the MLXLLM library for native
// Metal-accelerated inference on local safetensors models.
//
// Why a custom TokenizerLoader instead of MLXHuggingFace's macro:
//   The reference example app (mlx-swift-examples MLXChatExample) uses
//   #huggingFaceTokenizerLoader() which expands to code that imports
//   the HuggingFace module from `swift-huggingface`. That module is for
//   HF-Hub download flows we don't ship — mycellm-ios loads only from
//   on-device cached directories. By implementing TokenizerLoader
//   directly we drop two transitive dependencies (swift-huggingface +
//   MLXHuggingFace) plus their macro-trust UI prompts, and we still get
//   correct local-model loading via AutoTokenizer.from(modelFolder:).
//
// Reference:
//   - mlx-swift-lm/Libraries/MLXLMCommon (TokenizerLoader protocol)
//   - swift-transformers/Sources/Tokenizers (AutoTokenizer)
//   - mlx-swift-examples/Applications/MLXChatExample (production iOS app)
//
// Dependencies (project.yml packages, not Package.swift):
//   - mlx-swift-lm@main : MLXLLM, MLXLMCommon
//   - swift-transformers@0.1.0+ : Transformers (Tokenizers target)

#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Adapt swift-transformers' Tokenizers.Tokenizer to MLXLMCommon.Tokenizer.
/// The two protocols are near-identical (same model of encode/decode/
/// convert/special-tokens) but live in different modules. MLXLMCommon's
/// `decode` uses argument label `tokenIds` where swift-transformers uses
/// `tokens`; applyChatTemplate has incompatible Message/ToolSpec types
/// — we render manually with ChatML to avoid the type-translation surface,
/// which works for Qwen3 / Llama-3 / Mistral / most on-device families.
///
/// @unchecked Sendable because the upstream protocol isn't marked
/// Sendable but the underlying AutoTokenizer-returned instance is
/// immutable after construction.
private struct MLXTokenizerAdapter: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }
    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    /// Render messages with ChatML manually, then tokenize. We deliberately
    /// don't forward to upstream.applyChatTemplate because its Message /
    /// ToolSpec types are incompatible with MLXLMCommon's dict-based shape
    /// — translating would require a lot of glue for marginal benefit when
    /// most on-device models accept ChatML.
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        var prompt = ""
        for msg in messages {
            let role = (msg["role"] as? String) ?? "user"
            let content = (msg["content"] as? String) ?? ""
            prompt += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return upstream.encode(text: prompt, addSpecialTokens: false)
    }
}

/// TokenizerLoader for on-device cached models. Wraps AutoTokenizer so
/// MLX can read a Qwen / Llama / Mistral / etc. tokenizer.json from a
/// local directory without going through the HF Hub.
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let hf = try await AutoTokenizer.from(modelFolder: directory)
        return MLXTokenizerAdapter(upstream: hf)
    }
}

actor MLXBackend: InferenceBackend {
    let backendName = "MLX"
    private(set) var loadedModel: String?
    private(set) var tokensPerSecond: Double = 0.0

    private var container: ModelContainer?

    func loadModel(path: String, name: String, ctxLen: Int) async throws {
        // Clean up previous model
        container = nil

        let modelURL = URL(filePath: path)

        // Check available memory vs model size
        let modelSize = directorySize(modelURL)
        let fit = HardwareInfo.ramFit(modelSizeBytes: modelSize)
        guard fit != .tooLarge else {
            throw MycellmError.modelTooLarge(needed: modelSize, available: HardwareInfo.availableMemory)
        }

        // Set MLX memory limits (256MB GPU cache; mlx-swift caches large
        // intermediate arrays here for reuse across forward passes).
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)

        // Load from local directory with our custom tokenizer loader.
        // mlx-swift-lm's loadContainer(from:URL, using:TokenizerLoader)
        // overload skips the hub/downloader path entirely and reads
        // weights + config directly from disk.
        container = try await LLMModelFactory.shared.loadContainer(
            from: modelURL,
            using: LocalTokenizerLoader()
        )
        loadedModel = name
        // ctxLen is honored by the model's KV cache at inference time;
        // MLX doesn't expose a load-time context budget like llama.cpp's
        // n_ctx — the max tokens are bounded by the model's config and
        // the prompt-fit logic in complete()/stream().
    }

    func unloadModel() {
        container = nil
        loadedModel = nil
        tokensPerSecond = 0
    }

    func complete(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        tools: [OpenAIRoutes.Tool]
    ) async throws -> InferenceResult {
        guard let container else {
            throw MycellmError.modelNotLoaded("No MLX model loaded")
        }

        let augmented = injectToolsIntoSystem(messages, tools: tools)
        let prompt = formatMessages(augmented)
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(temperature)
        )
        let startTime = Date()

        // container.perform's closure is @Sendable; capture-by-value the
        // primitives + build UserInput inside the closure to avoid
        // non-Sendable type capture. Return the result tuple out.
        let (rawText, promptTokens, completionTokens) = try await container.perform { context in
            let userInput = UserInput(prompt: prompt)
            let lmInput = try await context.processor.prepare(input: userInput)
            let promptCount = lmInput.text.tokens.size
            var text = ""
            var completed = 0
            let stream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            )
            for await batch in stream {
                if let chunk = batch.chunk {
                    text += chunk
                    completed += 1
                }
            }
            return (text, promptCount, completed)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        tokensPerSecond = elapsed > 0 ? Double(completionTokens) / elapsed : 0

        if tools.isEmpty {
            return InferenceResult(
                text: rawText,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )
        }
        let parsed = ToolCallParser.extract(from: rawText)
        return InferenceResult(
            text: parsed.residualContent,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            toolCalls: parsed.toolCalls
        )
    }

    func stream(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        tools: [OpenAIRoutes.Tool]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let container = self.container else {
                        throw MycellmError.modelNotLoaded("No MLX model loaded")
                    }
                    let augmented = self.injectToolsIntoSystem(messages, tools: tools)
                    let prompt = self.formatMessages(augmented)
                    let parameters = GenerateParameters(
                        maxTokens: maxTokens,
                        temperature: Float(temperature)
                    )
                    let startTime = Date()

                    // continuation is Sendable; safe to capture. UserInput
                    // is non-Sendable so we build it inside the closure
                    // and pass a count out via the return value.
                    let count: Int = try await container.perform { context in
                        let userInput = UserInput(prompt: prompt)
                        let lmInput = try await context.processor.prepare(input: userInput)
                        let stream = try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )
                        var emitted = 0
                        for await batch in stream {
                            if Task.isCancelled { break }
                            if let chunk = batch.chunk {
                                continuation.yield(chunk)
                                emitted += 1
                            }
                        }
                        return emitted
                    }

                    let elapsed = Date().timeIntervalSince(startTime)
                    await self.updateTPS(count: count, elapsed: elapsed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func resetContext() throws {
        // MLX manages KV cache per-generation — no explicit reset.
    }

    func cleanup() {
        container = nil
        loadedModel = nil
    }

    // MARK: - Helpers

    private func updateTPS(count: Int, elapsed: TimeInterval) {
        tokensPerSecond = elapsed > 0 ? Double(count) / elapsed : 0
    }

    /// Inject tools as a system-prompt addendum, matching what
    /// LlamaCppBackend does. MLX's UserInput has a `tools` field but
    /// it requires the tokenizer's chat template to handle tools, which
    /// not all on-device models do — system-prompt injection is the
    /// most reliable path across model families.
    private func injectToolsIntoSystem(
        _ messages: [[String: String]],
        tools: [OpenAIRoutes.Tool]
    ) -> [[String: String]] {
        guard !tools.isEmpty else { return messages }
        let addendum = ToolCallParser.formatToolsForSystemPrompt(tools)
        guard !addendum.isEmpty else { return messages }

        var result = messages
        if let i = result.firstIndex(where: { $0["role"] == "system" }) {
            let existing = result[i]["content"] ?? ""
            result[i]["content"] = existing.isEmpty ? addendum : existing + "\n\n" + addendum
        } else {
            result.insert(["role": "system", "content": addendum], at: 0)
        }
        return result
    }

    /// Render messages into a ChatML prompt. MLX's UserInput accepts a
    /// raw prompt string — we format manually because most on-device
    /// models accept ChatML and we'd otherwise need to invoke the
    /// model's own chat template via the tokenizer (extra surface).
    private func formatMessages(_ messages: [[String: String]]) -> String {
        var prompt = ""
        for msg in messages {
            let role = msg["role"] ?? "user"
            let content = msg["content"] ?? ""
            prompt += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }

    /// Sum of all file sizes in a directory (for memory-fit check).
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

// Stub when MLXLLM isn't linked (e.g. CI without mlx-swift-lm pinned).
actor MLXBackend: InferenceBackend {
    let backendName = "MLX"
    private(set) var loadedModel: String?
    private(set) var tokensPerSecond: Double = 0.0

    func loadModel(path: String, name: String, ctxLen: Int) async throws {
        throw MycellmError.inferenceError("MLX backend requires the mlx-swift-lm package.")
    }
    func unloadModel() {}
    func complete(messages: [[String: String]], temperature: Double, maxTokens: Int, tools: [OpenAIRoutes.Tool]) async throws -> InferenceResult {
        throw MycellmError.inferenceError("MLX backend not available")
    }
    func stream(messages: [[String: String]], temperature: Double, maxTokens: Int, tools: [OpenAIRoutes.Tool]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: MycellmError.inferenceError("MLX backend not available")) }
    }
    func resetContext() throws {}
    func cleanup() {}
}

#endif

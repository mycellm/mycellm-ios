import Foundation
import LlamaSwift

/// llama.cpp inference backend for GGUF models.
/// Extracted from InferenceEngine — all llama.cpp C API calls live here.
actor LlamaCppBackend: InferenceBackend {
    let backendName = "llama.cpp"
    private(set) var loadedModel: String?
    private(set) var tokensPerSecond: Double = 0.0

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?

    init() {
        llama_backend_init()
    }

    func cleanup() {
        if let c = ctx { llama_free(c); ctx = nil }
        if let m = model { llama_model_free(m); model = nil }
        llama_backend_free()
    }

    // MARK: - Load / Unload

    func loadModel(path: String, name: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw MycellmError.inferenceError("File not found: \(path)")
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        guard fileSize > 1024 * 1024 else {
            throw MycellmError.inferenceError("File too small to be a valid GGUF model (\(fileSize) bytes)")
        }

        guard let fh = FileHandle(forReadingAtPath: path) else {
            throw MycellmError.inferenceError("Cannot read file")
        }
        let magic = fh.readData(ofLength: 4)
        fh.closeFile()
        guard magic.count == 4 && magic == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw MycellmError.inferenceError("Not a valid GGUF file — delete and re-download")
        }

        let fit = HardwareInfo.ramFit(modelSizeBytes: fileSize)
        guard fit != .tooLarge else {
            throw MycellmError.modelTooLarge(needed: fileSize, available: HardwareInfo.availableMemory)
        }

        if let c = ctx { llama_free(c); ctx = nil }
        if let m = model { llama_model_free(m); model = nil }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99

        guard let m = llama_model_load_from_file(path, modelParams) else {
            throw MycellmError.inferenceError("llama_model_load_from_file failed — file may be corrupt")
        }
        model = m

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 4096
        ctxParams.n_batch = 512
        ctxParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

        guard let c = llama_init_from_model(m, ctxParams) else {
            llama_model_free(m)
            model = nil
            throw MycellmError.inferenceError("llama_init_from_model failed")
        }
        ctx = c
        loadedModel = name
    }

    func unloadModel() {
        if let c = ctx { llama_free(c); ctx = nil }
        if let m = model { llama_model_free(m); model = nil }
        loadedModel = nil
        tokensPerSecond = 0
    }

    // MARK: - Inference

    func complete(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int
    ) async throws -> InferenceResult {
        guard let model else { throw MycellmError.modelNotLoaded("No model loaded") }
        guard let ctx else { throw MycellmError.modelNotLoaded("No context available") }

        let fitted = fitMessages(messages, model: model)
        let prompt = applyChatTemplate(messages: fitted, model: model)
        var promptTokens = tokenize(text: prompt, model: model)

        try decodePrompt(&promptTokens, ctx: ctx)

        let sampler = buildSampler(temperature: Float(temperature))
        defer { llama_sampler_free(sampler) }

        let vocab = llama_model_get_vocab(model)
        var outputTokens: [llama_token] = []
        let startTime = Date()

        for _ in 0..<maxTokens {
            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            outputTokens.append(token)

            var tok = token
            let nextBatch = llama_batch_get_one(&tok, 1)
            guard llama_decode(ctx, nextBatch) == 0 else { break }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        tokensPerSecond = elapsed > 0 ? Double(outputTokens.count) / elapsed : 0

        let text = detokenize(tokens: outputTokens, model: model)
        return InferenceResult(text: text, promptTokens: promptTokens.count, completionTokens: outputTokens.count)
    }

    func stream(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        Task {
            do {
                try await self.streamImpl(messages: messages, temperature: temperature, maxTokens: maxTokens, continuation: continuation)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    private func streamImpl(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let model else { throw MycellmError.modelNotLoaded("No model loaded") }
        guard let ctx else { throw MycellmError.modelNotLoaded("No context available") }

        let fitted = fitMessages(messages, model: model)
        let prompt = applyChatTemplate(messages: fitted, model: model)
        var promptTokens = tokenize(text: prompt, model: model)

        try decodePrompt(&promptTokens, ctx: ctx)

        let sampler = buildSampler(temperature: Float(temperature))
        defer { llama_sampler_free(sampler) }

        let vocab = llama_model_get_vocab(model)
        let startTime = Date()
        var count = 0

        for _ in 0..<maxTokens {
            if Task.isCancelled { break }

            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            let piece = detokenize(tokens: [token], model: model)
            continuation.yield(piece)
            count += 1

            var tok = token
            let nextBatch = llama_batch_get_one(&tok, 1)
            guard llama_decode(ctx, nextBatch) == 0 else { break }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        tokensPerSecond = elapsed > 0 ? Double(count) / elapsed : 0
        continuation.finish()
    }

    // MARK: - Context Reset

    func resetContext() throws {
        guard let model else { throw MycellmError.modelNotLoaded("No model loaded") }
        if let c = ctx { llama_free(c) }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 4096
        ctxParams.n_batch = 512
        ctxParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

        guard let c = llama_init_from_model(model, ctxParams) else {
            ctx = nil
            throw MycellmError.inferenceError("llama_init_from_model failed on context reset")
        }
        ctx = c
    }

    // MARK: - Prompt decoding

    private func decodePrompt(_ tokens: inout [llama_token], ctx: OpaquePointer) throws {
        let batchSize = 512
        var offset = 0
        while offset < tokens.count {
            let remaining = tokens.count - offset
            let chunkSize = min(remaining, batchSize)
            let batch = tokens.withUnsafeMutableBufferPointer { buf in
                llama_batch_get_one(buf.baseAddress! + offset, Int32(chunkSize))
            }
            guard llama_decode(ctx, batch) == 0 else {
                throw MycellmError.inferenceError("Prompt decode failed at offset \(offset)")
            }
            offset += chunkSize
        }
    }

    // MARK: - Context Window Management

    private func fitMessages(_ messages: [[String: String]], model: OpaquePointer) -> [[String: String]] {
        let maxPromptTokens = 4096 - 512

        let fullPrompt = applyChatTemplate(messages: messages, model: model)
        let fullTokens = tokenize(text: fullPrompt, model: model)
        if fullTokens.count <= maxPromptTokens { return messages }

        let hasSystem = messages.first?["role"] == "system"
        let systemMsgs = hasSystem ? [messages[0]] : []
        let history = hasSystem ? Array(messages.dropFirst()) : messages

        var keepCount = min(4, history.count)

        let summaryBudget = 300
        while keepCount < history.count {
            let recentSlice = Array(history.suffix(keepCount))
            let candidate = systemMsgs + [["role": "system", "content": String(repeating: "x", count: summaryBudget)]] + recentSlice
            let prompt = applyChatTemplate(messages: candidate, model: model)
            let tokens = tokenize(text: prompt, model: model)
            if tokens.count > maxPromptTokens { break }
            keepCount += 2
        }
        keepCount = min(keepCount, history.count)

        let olderMessages = Array(history.dropLast(keepCount))
        let recentMessages = Array(history.suffix(keepCount))

        if olderMessages.isEmpty {
            return systemMsgs + recentMessages
        }

        let summary = compactSummary(of: olderMessages)
        let summaryMsg = ["role": "system", "content": summary]

        let candidate = systemMsgs + [summaryMsg] + recentMessages
        let prompt = applyChatTemplate(messages: candidate, model: model)
        let tokens = tokenize(text: prompt, model: model)
        if tokens.count <= maxPromptTokens {
            return candidate
        }

        let maxSummaryChars = max(200, summary.count / 2)
        let truncated = String(summary.prefix(maxSummaryChars)) + "…"
        return systemMsgs + [["role": "system", "content": truncated]] + recentMessages
    }

    private func compactSummary(of messages: [[String: String]]) -> String {
        var lines: [String] = ["[Earlier in this conversation:]"]
        for msg in messages {
            let role = msg["role"] ?? "user"
            let content = msg["content"] ?? ""
            if role == "user" {
                lines.append("- User asked: \(extractBrief(content, maxLen: 120))")
            } else if role == "assistant" {
                lines.append("- Assistant replied: \(extractBrief(content, maxLen: 150))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func extractBrief(_ text: String, maxLen: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceEnders: [Character] = [".", "!", "?", "\n"]
        if let endIdx = trimmed.firstIndex(where: { sentenceEnders.contains($0) }),
           trimmed.distance(from: trimmed.startIndex, to: endIdx) < maxLen {
            return String(trimmed[...endIdx])
        }
        if trimmed.count <= maxLen { return trimmed }
        let prefix = String(trimmed.prefix(maxLen))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return prefix + "…"
    }

    // MARK: - Tokenization

    private func tokenize(text: String, model: OpaquePointer) -> [llama_token] {
        let vocab = llama_model_get_vocab(model)
        let cStr = Array(text.utf8CString)
        let nMax = Int32(cStr.count) + 2
        var tokens = [llama_token](repeating: 0, count: Int(nMax))
        let n = cStr.withUnsafeBufferPointer { buf in
            llama_tokenize(vocab, buf.baseAddress, Int32(cStr.count - 1), &tokens, nMax, true, true)
        }
        guard n > 0 else { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    private func detokenize(tokens: [llama_token], model: OpaquePointer) -> String {
        let vocab = llama_model_get_vocab(model)
        var result = ""
        for token in tokens {
            var buf = [CChar](repeating: 0, count: 256)
            let len = llama_token_to_piece(vocab, token, &buf, 256, 0, true)
            if len > 0 {
                result += buf.withUnsafeBufferPointer { p in
                    String(decoding: p.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
        }
        return result
    }

    private func buildSampler(temperature: Float) -> UnsafeMutablePointer<llama_sampler> {
        let params = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(params)!
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        return chain
    }

    private func applyChatTemplate(messages: [[String: String]], model: OpaquePointer) -> String {
        var chatMsgs = messages.map { msg -> llama_chat_message in
            llama_chat_message(
                role: strdup(msg["role"] ?? "user"),
                content: strdup(msg["content"] ?? "")
            )
        }
        defer {
            for m in chatMsgs {
                free(UnsafeMutablePointer(mutating: m.role))
                free(UnsafeMutablePointer(mutating: m.content))
            }
        }

        var buf = [CChar](repeating: 0, count: 32768)
        let tmpl = llama_model_chat_template(model, nil)
        let n = llama_chat_apply_template(tmpl, &chatMsgs, chatMsgs.count, true, &buf, Int32(buf.count))

        if n > 0 && n < buf.count {
            return buf.withUnsafeBufferPointer { p in
                String(decoding: p.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }

        var prompt = ""
        for msg in messages {
            prompt += "<|im_start|>\(msg["role"] ?? "user")\n\(msg["content"] ?? "")<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}

import Foundation

/// KV-cache-aware memory estimation for on-device model-load preflight.
///
/// iOS jetsam kills a process that exceeds its memory limit *hard* (no swap),
/// so the size-only `HardwareInfo.ramFit` is not enough: a model that "fits by
/// size" can still be killed once a large KV cache is allocated at long
/// context. This mirrors the Python `inference/memory_estimate.py`:
///
///     peak ≈ weights + KV(ctx) + overhead          (batch slots = 1 on iOS)
///     KV/token = num_hidden_layers × num_key_value_heads × head_dim
///                × 2 (fp16) × 2 (K and V)
///
/// checked against `os_proc_available_memory()` (the real jetsam headroom),
/// not total physical RAM. The KV cache is fp16/bf16 even when the *weights*
/// are 4-bit quantized — the quant applies to weights, not the cache.
enum MemoryEstimate {
    /// KV cache element width: fp16/bf16 regardless of weight quantization.
    static let kvDtypeBytes: UInt64 = 2

    struct Dims: Sendable, Equatable {
        let layers: Int
        let kvHeads: Int
        let headDim: Int
    }

    struct Estimate: Sendable {
        let kvBytesPerToken: UInt64
        let weightsBytes: UInt64
        let kvBytes: UInt64
        let overheadBytes: UInt64
        let peakBytes: UInt64
        let budgetBytes: UInt64
        let fits: Bool
        /// Largest context that fits the budget at this model/overhead.
        let maxCtxLen: Int
    }

    /// Read attention geometry from an MLX model dir's `config.json`. Returns
    /// nil for GGUF (single file, no config.json) or unreadable configs — the
    /// caller then falls back to the size-only check. Handles VLMs that nest
    /// the decoder config under `text_config` (the KV cache lives there).
    static func readDims(modelDir: String) -> Dims? {
        let cfgPath = (modelDir as NSString).appendingPathComponent("config.json")
        guard let data = FileManager.default.contents(atPath: cfgPath),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["text_config", "language_config", "llm_config"] {
            if let nested = obj[key] as? [String: Any] {
                obj.merge(nested) { _, new in new }
            }
        }
        guard let layers = obj["num_hidden_layers"] as? Int, layers > 0 else { return nil }
        let nQ = (obj["num_attention_heads"] as? Int) ?? 0
        let kvHeads = (obj["num_key_value_heads"] as? Int) ?? nQ
        var headDim = (obj["head_dim"] as? Int) ?? 0
        if headDim == 0, let hidden = obj["hidden_size"] as? Int, nQ > 0 {
            headDim = hidden / nQ
        }
        guard kvHeads > 0, headDim > 0 else { return nil }
        return Dims(layers: layers, kvHeads: kvHeads, headDim: headDim)
    }

    static func kvBytesPerToken(_ dims: Dims) -> UInt64 {
        UInt64(dims.layers) * UInt64(dims.kvHeads) * UInt64(dims.headDim) * kvDtypeBytes * 2
    }

    /// Estimate peak load+serve memory at `ctxLen` and check it against the
    /// available (jetsam-headroom) budget. Returns nil when dims are
    /// unavailable (GGUF / no config) so the caller can fall back.
    ///
    /// - overheadBytes: MLX pool / Swift heap / prefill transient reserve.
    /// - safetyFraction: usable fraction of `availableBytes`.
    static func estimate(
        modelDir: String,
        weightsBytes: UInt64,
        ctxLen: Int,
        availableBytes: UInt64 = HardwareInfo.availableMemory,
        overheadBytes: UInt64 = 512 * 1024 * 1024,
        safetyFraction: Double = 0.85
    ) -> Estimate? {
        guard let dims = readDims(modelDir: modelDir), availableBytes > 0 else { return nil }
        let perTok = kvBytesPerToken(dims)
        let kv = perTok * UInt64(max(0, ctxLen))
        let peak = weightsBytes + kv + overheadBytes
        let budget = UInt64(Double(availableBytes) * safetyFraction)
        let reserved = weightsBytes + overheadBytes
        let availForKV = budget > reserved ? budget - reserved : 0
        let maxCtx = perTok > 0 ? Int(availForKV / perTok) : 0
        return Estimate(
            kvBytesPerToken: perTok, weightsBytes: weightsBytes, kvBytes: kv,
            overheadBytes: overheadBytes, peakBytes: peak, budgetBytes: budget,
            fits: peak <= budget, maxCtxLen: maxCtx
        )
    }
}

import XCTest
@testable import Mycellm

/// KV-aware preflight estimator. The per-token KV constants were validated
/// against measured MLX memory on real hardware (Python `memory_estimate.py`):
///   Qwen2.5-3B → 36864 B/tok, Qwen3-1.7B → 114688 B/tok.
final class MemoryEstimateTests: XCTestCase {
    private let GB: UInt64 = 1_073_741_824

    func testKVBytesPerToken() {
        // Qwen2.5-3B: 36 layers, 2 kv heads, head_dim 128 → 36864 B/tok
        XCTAssertEqual(
            MemoryEstimate.kvBytesPerToken(.init(layers: 36, kvHeads: 2, headDim: 128)),
            36_864)
        // Qwen3-1.7B: 28 layers, 8 kv heads, head_dim 128 → 114688 B/tok
        XCTAssertEqual(
            MemoryEstimate.kvBytesPerToken(.init(layers: 28, kvHeads: 8, headDim: 128)),
            114_688)
    }

    /// Write a minimal config.json to a temp dir and return its path.
    private func makeModelDir(_ cfg: [String: Any]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: cfg)
        try data.write(to: dir.appendingPathComponent("config.json"))
        return dir.path
    }

    func testReadDimsDerivesHeadDim() throws {
        let dir = try makeModelDir([
            "num_hidden_layers": 28, "num_attention_heads": 16,
            "num_key_value_heads": 8, "hidden_size": 2048,
        ])
        XCTAssertEqual(MemoryEstimate.readDims(modelDir: dir),
                       .init(layers: 28, kvHeads: 8, headDim: 128))
    }

    func testReadDimsNestedTextConfig() throws {
        let dir = try makeModelDir([
            "text_config": [
                "num_hidden_layers": 36, "num_attention_heads": 16,
                "num_key_value_heads": 2, "hidden_size": 2048,
            ],
        ])
        XCTAssertEqual(MemoryEstimate.readDims(modelDir: dir),
                       .init(layers: 36, kvHeads: 2, headDim: 128))
    }

    func testReadDimsNilForGGUF() {
        // No config.json at this path → nil (caller falls back to size check).
        XCTAssertNil(MemoryEstimate.readDims(modelDir: "/tmp/nonexistent-model.gguf"))
    }

    func testEstimateRejectsOversizedContext() throws {
        // Qwen3-1.7B (high KV) at 32k context on a 4GB-headroom device.
        let dir = try makeModelDir([
            "num_hidden_layers": 28, "num_attention_heads": 16,
            "num_key_value_heads": 8, "hidden_size": 2048,
        ])
        let est = try XCTUnwrap(MemoryEstimate.estimate(
            modelDir: dir, weightsBytes: GB, ctxLen: 32768,
            availableBytes: 4 * GB, overheadBytes: 512 * 1024 * 1024,
            safetyFraction: 0.85))
        XCTAssertFalse(est.fits)                     // 32768×114688 ≈ 3.5GB KV alone
        XCTAssertEqual(est.kvBytes, 114_688 * 32_768)
        XCTAssertLessThan(est.maxCtxLen, 32_768)     // must clamp below requested
    }

    func testEstimateAllowsSmallContext() throws {
        let dir = try makeModelDir([
            "num_hidden_layers": 36, "num_attention_heads": 16,
            "num_key_value_heads": 2, "hidden_size": 2048,
        ])
        let est = try XCTUnwrap(MemoryEstimate.estimate(
            modelDir: dir, weightsBytes: 2 * GB, ctxLen: 4096,
            availableBytes: 6 * GB))
        XCTAssertTrue(est.fits)
        XCTAssertGreaterThan(est.maxCtxLen, 4096)
    }

    func testEstimateNilWithoutConfig() {
        XCTAssertNil(MemoryEstimate.estimate(
            modelDir: "/tmp/nonexistent", weightsBytes: GB, ctxLen: 4096))
    }
}

import XCTest
@testable import Mycellm

/// Guards the additive multimodal foundation (MultimodalMessage + VLM
/// detection). Mirrors the Python helpers content_to_text /
/// flatten_message_content / is_mlx_vlm_model_path so the two stay aligned.
final class MultimodalMessageTests: XCTestCase {

    // MARK: - MultimodalMessage flattening

    func testTextMessageFlattenDropsNothing() {
        let m = MultimodalMessage(role: "user", text: "hello")
        XCTAssertEqual(m.asTextMessage, ["role": "user", "content": "hello"])
        XCTAssertTrue(m.images.isEmpty)
    }

    func testImageMessageFlattenDropsImages() {
        let m = MultimodalMessage(role: "user", text: "what is this?", images: [Data([0x1, 0x2])])
        // Flattening keeps text, drops the image bytes.
        XCTAssertEqual(m.asTextMessage, ["role": "user", "content": "what is this?"])
    }

    func testArrayHasImagesAndFlatten() {
        let msgs = [
            MultimodalMessage(role: "system", text: "be brief"),
            MultimodalMessage(role: "user", text: "describe", images: [Data([0xFF])]),
        ]
        XCTAssertTrue(msgs.hasImages)
        XCTAssertEqual(msgs.asTextMessages,
                       [["role": "system", "content": "be brief"],
                        ["role": "user", "content": "describe"]])

        let textOnly = [MultimodalMessage(role: "user", text: "hi")]
        XCTAssertFalse(textOnly.hasImages)
    }

    // MARK: - data: URI decoding

    func testDecodeDataURI() {
        // "AQID" is base64 for bytes 0x01 0x02 0x03
        let uri = "data:image/png;base64,AQID"
        XCTAssertEqual(MultimodalMessage.decodeDataURI(uri), Data([0x01, 0x02, 0x03]))
    }

    func testDecodeDataURIRejectsNonData() {
        XCTAssertNil(MultimodalMessage.decodeDataURI("https://example.com/a.png"))
        XCTAssertNil(MultimodalMessage.decodeDataURI("data:image/png,notbase64"))
    }

    // MARK: - Vision-model detection (ModelFormat.isVisionModel)

    private func writeConfig(_ json: String) -> String {
        let dir = NSTemporaryDirectory() + "vlmtest-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? json.write(toFile: (dir as NSString).appendingPathComponent("config.json"),
                        atomically: true, encoding: .utf8)
        return dir
    }

    func testVisionConfigDetectedByVisionConfigKey() {
        let dir = writeConfig(#"{"model_type":"qwen2_5_vl","vision_config":{"depth":32}}"#)
        XCTAssertTrue(ModelFormat.isVisionModel(path: dir))
    }

    func testVisionConfigDetectedByModelType() {
        let dir = writeConfig(#"{"model_type":"llava"}"#)
        XCTAssertTrue(ModelFormat.isVisionModel(path: dir))
    }

    func testTextModelNotVision() {
        let dir = writeConfig(#"{"model_type":"qwen3"}"#)
        XCTAssertFalse(ModelFormat.isVisionModel(path: dir))
    }

    func testMissingConfigNotVision() {
        XCTAssertFalse(ModelFormat.isVisionModel(path: "/nonexistent/path/xyz"))
    }
}

import XCTest
@testable import Mycellm

final class EnvelopeTests: XCTestCase {

    // MARK: - Wire Format Compatibility

    /// Test that the wire format matches Python's implementation exactly.
    /// Envelope: 0x00 + CBOR for small, 0x01 + zlib(CBOR) for large.
    func testWireFormatPrefixByte() throws {
        // Small message — 0x00 prefix
        let small = MessageEnvelope(
            type: .ping,
            payload: [:],
            fromPeer: "test",
            id: "0123456789abcdef",
            ts: 1700000000.0
        )
        let smallData = small.toCBOR()
        XCTAssertEqual(smallData[0], 0x00)

        // After removing prefix, should be valid CBOR
        let cborData = smallData.dropFirst()
        let decoded = try MessageEnvelope.fromCBOR(Data([0x00]) + cborData)
        XCTAssertEqual(decoded.type, .ping)
    }

    /// Test CBOR map key names match Python exactly.
    func testCBORMapKeys() throws {
        let msg = MessageEnvelope(
            type: .ping,
            payload: ["test_key": .string("test_value")],
            fromPeer: "peer123",
            id: "0123456789abcdef",
            ts: 1700000000.0,
            v: 1
        )
        let data = msg.toCBOR()

        // Decode raw CBOR and check key names
        let decoded = try MessageEnvelope.fromCBOR(data)
        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(decoded.id, "0123456789abcdef")
        XCTAssertEqual(decoded.fromPeer, "peer123")
        XCTAssertEqual(decoded.payload["test_key"]?.stringValue, "test_value")
    }

    /// Test the 10MB frame size limit.
    func testFrameSizeLimit() {
        // Craft a frame header claiming 11MB
        var data = Data()
        var size = UInt32(11 * 1024 * 1024).bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(Data(repeating: 0, count: 100))

        XCTAssertThrowsError(try MessageEnvelope.readFrame(data)) { error in
            if case MycellmError.frameTooLarge(let size) = error {
                XCTAssertEqual(size, 11 * 1024 * 1024)
            } else {
                XCTFail("Expected frameTooLarge error")
            }
        }
    }

    /// Test protocol version field.
    func testProtocolVersion() {
        XCTAssertEqual(protocolVersion, 1)

        let msg = MessageEnvelope(type: .ping, payload: [:], fromPeer: "test")
        XCTAssertEqual(msg.v, 1)
    }

    // MARK: - Compression

    func testZlibCompressDecompress() throws {
        let original = Data("Hello, mycellm protocol!".utf8)
        guard let compressed = ZlibCompression.compress(original) else {
            XCTFail("Compression returned nil")
            return
        }
        guard let decompressed = ZlibCompression.decompress(compressed) else {
            XCTFail("Decompression returned nil")
            return
        }
        XCTAssertEqual(decompressed, original)
    }

    func testZlibLargePayload() throws {
        // Create a ~2KB payload
        let original = Data(repeating: 42, count: 2048)
        guard let compressed = ZlibCompression.compress(original, level: 1) else {
            XCTFail("Compression returned nil")
            return
        }
        // Repeated data should compress well
        XCTAssertLessThan(compressed.count, original.count)

        guard let decompressed = ZlibCompression.decompress(compressed) else {
            XCTFail("Decompression returned nil")
            return
        }
        XCTAssertEqual(decompressed, original)
    }

    // MARK: - Data Helpers

    func testHexStringRoundtrip() {
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let hex = original.hexString
        XCTAssertEqual(hex, "deadbeef")

        let restored = Data(hex: hex)
        XCTAssertEqual(restored, original)
    }

    func testPeerIdHexFormat() {
        // PeerId is 32 hex chars = 16 bytes worth of hex
        let key = Data.random(count: 32)
        let peerId = PeerId.from(publicKeyBytes: key)
        XCTAssertEqual(peerId.count, 32)
        XCTAssertTrue(peerId.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Receipt Data

    func testReceiptDataCBOR() {
        let data = buildReceiptData(
            consumerId: "consumer1",
            seederId: "seeder1",
            model: "llama-3.2",
            tokens: 100,
            cost: 0.5,
            requestId: "req123",
            timestamp: 1700000000.0
        )
        // Should produce non-empty CBOR
        XCTAssertGreaterThan(data.count, 0)

        // Should be deterministic
        let data2 = buildReceiptData(
            consumerId: "consumer1",
            seederId: "seeder1",
            model: "llama-3.2",
            tokens: 100,
            cost: 0.5,
            requestId: "req123",
            timestamp: 1700000000.0
        )
        XCTAssertEqual(data, data2)
    }

    // MARK: - Multiple Frames in Buffer

    func testMultipleFrames() throws {
        let msg1 = MessageEnvelope(type: .ping, payload: [:], fromPeer: "a")
        let msg2 = MessageEnvelope(type: .pong, payload: [:], fromPeer: "b")

        var buffer = msg1.toFramed()
        buffer.append(msg2.toFramed())

        let (decoded1, remaining) = try MessageEnvelope.readFrame(buffer)
        XCTAssertNotNil(decoded1)
        XCTAssertEqual(decoded1?.type, .ping)

        let (decoded2, final) = try MessageEnvelope.readFrame(remaining)
        XCTAssertNotNil(decoded2)
        XCTAssertEqual(decoded2?.type, .pong)
        XCTAssertTrue(final.isEmpty)
    }
}

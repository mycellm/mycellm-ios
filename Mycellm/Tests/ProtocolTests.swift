import XCTest
import Crypto
@testable import Mycellm

final class ProtocolTests: XCTestCase {

    // MARK: - MessageType

    func testAllMessageTypesHavePythonValues() {
        // Ensure all 17 message types match Python enum values
        let expectedTypes: [String] = [
            "node_hello", "node_hello_ack",
            "peer_announce", "peer_query", "peer_response",
            "inference_req", "inference_resp", "inference_stream", "inference_done",
            "ping", "pong",
            "credit_receipt",
            "inference_relay",
            "peer_exchange",
            "fleet_command", "fleet_response",
            "error",
        ]
        let actualTypes = MessageType.allCases.map(\.rawValue)
        XCTAssertEqual(Set(actualTypes), Set(expectedTypes))
        XCTAssertEqual(actualTypes.count, 17)
    }

    // MARK: - MessageEnvelope

    func testEnvelopeSerializationRoundtrip() throws {
        let original = MessageEnvelope(
            type: .ping,
            payload: ["key": .string("value")],
            fromPeer: "abc123",
            id: "0123456789abcdef",
            ts: 1700000000.0
        )

        let data = original.toCBOR()
        let decoded = try MessageEnvelope.fromCBOR(data)

        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(decoded.fromPeer, "abc123")
        XCTAssertEqual(decoded.id, "0123456789abcdef")
        XCTAssertEqual(decoded.ts, 1700000000.0, accuracy: 0.001)
        XCTAssertEqual(decoded.payload["key"]?.stringValue, "value")
    }

    func testEnvelopeUncompressedPrefix() throws {
        // Small payload should be uncompressed (0x00 prefix)
        let msg = MessageEnvelope(type: .ping, payload: [:], fromPeer: "test")
        let data = msg.toCBOR()
        XCTAssertEqual(data[0], 0x00, "Small messages should have 0x00 prefix")
    }

    func testEnvelopeCompressedPrefix() throws {
        // Large payload should be compressed (0x01 prefix)
        var largePayload: [String: CBORValue] = [:]
        for i in 0..<100 {
            largePayload["key_\(i)"] = .string(String(repeating: "x", count: 100))
        }
        let msg = MessageEnvelope(type: .inferenceResp, payload: largePayload, fromPeer: "test")
        let data = msg.toCBOR()
        XCTAssertEqual(data[0], 0x01, "Large messages should have 0x01 prefix")

        // Should still round-trip
        let decoded = try MessageEnvelope.fromCBOR(data)
        XCTAssertEqual(decoded.type, .inferenceResp)
        XCTAssertEqual(decoded.payload.count, 100)
    }

    func testEnvelopeFraming() throws {
        let msg = MessageEnvelope(type: .ping, payload: [:], fromPeer: "test")
        let framed = msg.toFramed()

        // First 4 bytes are big-endian length
        let length = Int(framed.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        XCTAssertEqual(framed.count, 4 + length)

        // Read back
        let (decoded, remaining) = try MessageEnvelope.readFrame(framed)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(decoded?.type, .ping)
    }

    func testIncompleteFrame() throws {
        let msg = MessageEnvelope(type: .ping, payload: [:], fromPeer: "test")
        let framed = msg.toFramed()

        // Incomplete frame (missing last byte)
        let incomplete = framed.dropLast()
        let (decoded, remaining) = try MessageEnvelope.readFrame(Data(incomplete))
        XCTAssertNil(decoded)
        XCTAssertEqual(remaining.count, incomplete.count)
    }

    // MARK: - NodeHello

    func testNodeHelloSignAndVerify() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()
        let cert = try DeviceCert.create(accountKey: account, deviceKey: device, deviceName: "test")
        let peerId = PeerId.from(publicKey: device.publicKey)

        var hello = NodeHello(
            peerId: peerId,
            devicePubkey: device.publicBytes,
            cert: cert,
            capabilities: Capabilities()
        )
        try hello.sign(with: device)

        XCTAssertEqual(hello.signature.count, 64)

        let (valid, error) = hello.verify()
        XCTAssertTrue(valid, "NodeHello verification failed: \(error)")
    }

    func testNodeHelloRejectsWrongPeerId() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()
        let cert = try DeviceCert.create(accountKey: account, deviceKey: device)

        var hello = NodeHello(
            peerId: "wrongpeerid000000000000000000000",
            devicePubkey: device.publicBytes,
            cert: cert,
            capabilities: Capabilities()
        )
        try hello.sign(with: device)

        let (valid, _) = hello.verify()
        XCTAssertFalse(valid)
    }

    func testNodeHelloRejectsOldTimestamp() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()
        let cert = try DeviceCert.create(accountKey: account, deviceKey: device)
        let peerId = PeerId.from(publicKey: device.publicKey)

        var hello = NodeHello(
            peerId: peerId,
            devicePubkey: device.publicBytes,
            cert: cert,
            capabilities: Capabilities(),
            timestamp: Date().timeIntervalSince1970 - 600 // 10 minutes old
        )
        try hello.sign(with: device)

        let (valid, error) = hello.verify(maxAgeSeconds: 300)
        XCTAssertFalse(valid)
        XCTAssertTrue(error.contains("too old"))
    }

    func testNodeHelloCBORRoundtrip() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()
        let cert = try DeviceCert.create(accountKey: account, deviceKey: device)
        let peerId = PeerId.from(publicKey: device.publicKey)

        var original = NodeHello(
            peerId: peerId,
            devicePubkey: device.publicBytes,
            cert: cert,
            capabilities: Capabilities(role: "seeder", version: "0.1.0")
        )
        original.observedAddr = "192.168.1.1:8421"
        original.networkIds = ["net1", "net2"]
        try original.sign(with: device)

        let data = original.toCBOR()
        let decoded = try NodeHello.fromCBOR(data)

        XCTAssertEqual(decoded.peerId, original.peerId)
        XCTAssertEqual(decoded.devicePubkey, original.devicePubkey)
        XCTAssertEqual(decoded.nonce, original.nonce)
        XCTAssertEqual(decoded.signature, original.signature)
        XCTAssertEqual(decoded.observedAddr, "192.168.1.1:8421")
        XCTAssertEqual(decoded.networkIds, ["net1", "net2"])

        // Decoded hello should also verify
        let (valid, _) = decoded.verify()
        XCTAssertTrue(valid)
    }

    // MARK: - Capabilities

    func testCapabilitiesRoundtrip() {
        let original = Capabilities(
            models: [
                ModelCapability(name: "llama-3.2-3b", quant: "q4_k_m", paramCountB: 3.0, features: ["streaming"]),
            ],
            hardware: HardwareCapability(gpu: "A17 Pro", vramGb: 8.0, backend: "metal"),
            maxConcurrent: 1,
            estTokS: 25.0,
            role: "seeder",
            version: "0.1.0",
            networkIds: ["public"]
        )

        let dict = original.toDict()
        let decoded = Capabilities.fromDict(dict)

        XCTAssertEqual(decoded.models.count, 1)
        XCTAssertEqual(decoded.models[0].name, "llama-3.2-3b")
        XCTAssertEqual(decoded.models[0].quant, "q4_k_m")
        XCTAssertEqual(decoded.models[0].paramCountB, 3.0)
        XCTAssertEqual(decoded.hardware.gpu, "A17 Pro")
        XCTAssertEqual(decoded.hardware.backend, "metal")
        XCTAssertEqual(decoded.role, "seeder")
        XCTAssertEqual(decoded.networkIds, ["public"])
    }

    // MARK: - ErrorCode

    func testAllErrorCodesMatchPython() {
        let expectedCodes = [
            "auth_failed", "cert_expired", "cert_revoked", "peer_unreachable",
            "model_unavailable", "overloaded", "timeout", "backend_error",
            "insufficient_credit", "protocol_version_mismatch", "invalid_message",
            "fleet_key_denied", "unknown",
        ]
        for code in expectedCodes {
            XCTAssertNotNil(ErrorCode(rawValue: code), "Missing ErrorCode: \(code)")
        }
    }

    // MARK: - MessageBuilders

    func testPingPongRoundtrip() throws {
        let ping = MessageBuilders.ping(from: "peer1")
        XCTAssertEqual(ping.type, .ping)

        let pong = MessageBuilders.pong(from: "peer2", requestId: ping.id)
        XCTAssertEqual(pong.type, .pong)
        XCTAssertEqual(pong.id, ping.id)
    }

    func testInferenceRequestBuilder() throws {
        let req = MessageBuilders.inferenceRequest(
            from: "peer1",
            model: "llama-3.2-3b",
            messages: [["role": "user", "content": "hello"]],
            temperature: 0.8,
            maxTokens: 1024,
            stream: true
        )

        XCTAssertEqual(req.type, .inferenceReq)
        XCTAssertEqual(req.payload["model"]?.stringValue, "llama-3.2-3b")
        XCTAssertEqual(req.payload["temperature"]?.doubleValue, 0.8)
        XCTAssertEqual(req.payload["stream"]?.boolValue, true)
    }

    func testCreditReceiptBuilder() {
        let receipt = MessageBuilders.signedCreditReceipt(
            from: "seeder1",
            consumerId: "consumer1",
            seederId: "seeder1",
            model: "llama-3.2-3b",
            tokens: 100,
            cost: 0.5,
            timestamp: 1700000000.0,
            signature: "abc123"
        )

        XCTAssertEqual(receipt.type, .creditReceipt)
        XCTAssertEqual(receipt.payload["consumer_id"]?.stringValue, "consumer1")
        XCTAssertEqual(receipt.payload["tokens"]?.intValue, 100)
    }
}

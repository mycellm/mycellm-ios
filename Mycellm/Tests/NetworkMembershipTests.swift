import XCTest
@testable import Mycellm

final class NetworkMembershipTests: XCTestCase {

    // MARK: - Port sanitization (crash-loop regression)

    func testDecodeHealsOutOfRangePort() throws {
        // An install that persisted a >65535 port (pre-validation builds)
        // crash-looped at launch: UInt16(84219421) traps. Decode must heal it.
        let json = """
        [{"id":"abc","name":"lab","bootstrapHost":"10.1.1.10","bootstrapPort":84219421}]
        """.data(using: .utf8)!
        let ms = try JSONDecoder().decode([NetworkMembership].self, from: json)
        XCTAssertEqual(ms[0].bootstrapPort, 8421)
    }

    func testDecodeKeepsValidPort() throws {
        let json = """
        [{"id":"abc","name":"lab","bootstrapHost":"10.1.1.10","bootstrapPort":9000}]
        """.data(using: .utf8)!
        let ms = try JSONDecoder().decode([NetworkMembership].self, from: json)
        XCTAssertEqual(ms[0].bootstrapPort, 9000)
    }

    func testSanitizePort() {
        XCTAssertEqual(NetworkMembership.sanitizePort(8421), 8421)
        XCTAssertEqual(NetworkMembership.sanitizePort(1), 1)
        XCTAssertEqual(NetworkMembership.sanitizePort(65535), 65535)
        XCTAssertEqual(NetworkMembership.sanitizePort(0), 8421)
        XCTAssertEqual(NetworkMembership.sanitizePort(-5), 8421)
        XCTAssertEqual(NetworkMembership.sanitizePort(65536), 8421)
        XCTAssertEqual(NetworkMembership.sanitizePort(84219421), 8421)
        XCTAssertEqual(NetworkMembership.sanitizePort(nil), 8421)
    }

    // MARK: - joinKey persistence + back-compat

    func testJoinKeyRoundTripsAndOldSavesDecode() throws {
        var m = NetworkMembership(
            id: "d44bc271cfcd13ed", name: "mijkal-lab",
            bootstrapHost: "10.1.1.10"
        )
        m.joinKey = "sekrit"
        let data = try JSONEncoder().encode([m])
        let back = try JSONDecoder().decode([NetworkMembership].self, from: data)
        XCTAssertEqual(back[0].joinKey, "sekrit")

        // Pre-joinKey save (no key present) must decode with nil.
        let old = """
        [{"id":"x","name":"old","bootstrapHost":"h","bootstrapPort":8421}]
        """.data(using: .utf8)!
        let oldBack = try JSONDecoder().decode([NetworkMembership].self, from: old)
        XCTAssertNil(oldBack[0].joinKey)
    }

    // MARK: - Invite token parsing (Python InviteToken.to_portable format)

    func testParsesPythonPortableInvite() throws {
        let payload: [String: Any] = [
            "network_id": "d44bc271cfcd13ed0011223344556677",
            "allowed_roles": ["seeder"],
            "max_uses": 0, "uses": 0, "expires_at": 0,
            "created_at": 1_780_000_000.0,
            "token_id": "aabbccdd00112233",
            "signature": "sig",
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        // urlsafe base64, padding stripped (as copy/paste often does)
        let portable = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        let parsed = ParsedInvite.parse(portable)
        XCTAssertEqual(parsed?.networkId, "d44bc271cfcd13ed0011223344556677")
        XCTAssertEqual(parsed?.tokenId, "aabbccdd00112233")

        // Same token wrapped in the join URL the CLI prints.
        let viaURL = ParsedInvite.parse("https://mycellm.dev/join?token=\(portable)")
        XCTAssertEqual(viaURL?.networkId, "d44bc271cfcd13ed0011223344556677")
    }

    func testRejectsGarbageInvite() {
        XCTAssertNil(ParsedInvite.parse(""))
        XCTAssertNil(ParsedInvite.parse("not-a-token"))
        XCTAssertNil(ParsedInvite.parse("https://mycellm.dev/join"))
    }

    // MARK: - join() adopts the host network id

    @MainActor
    func testJoinUsesProvidedNetworkId() {
        let registry = NetworkRegistry()
        defer { registry.leave(networkId: "d44bc271cfcd13ed") }
        let m = registry.join(
            name: "mijkal-lab", bootstrapHost: "10.1.1.10",
            networkId: "d44bc271cfcd13ed", joinKey: "k1"
        )
        XCTAssertEqual(m.id, "d44bc271cfcd13ed")
        XCTAssertEqual(m.joinKey, "k1")
    }
}

final class NodeHelloJoinKeysTests: XCTestCase {

    private func makeHello() throws -> NodeHello {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()
        let cert = try DeviceCert.create(accountKey: account, deviceKey: device, deviceName: "test")
        return NodeHello(
            peerId: PeerId.from(publicKey: device.publicKey),
            devicePubkey: device.publicBytes,
            cert: cert,
            capabilities: Capabilities()
        )
    }

    func testJoinKeysRoundTripThroughCBOR() throws {
        var hello = try makeHello()
        hello.networkIds = ["d44bc271cfcd13ed"]
        hello.joinKeys = ["d44bc271cfcd13ed": "sekrit"]
        let back = try NodeHello.fromCBOR(hello.toCBOR())
        XCTAssertEqual(back.joinKeys, ["d44bc271cfcd13ed": "sekrit"])
        XCTAssertEqual(back.networkIds, ["d44bc271cfcd13ed"])
    }

    func testEmptyJoinKeysOmittedFromWire() throws {
        // Python omits join_keys when empty; matching that keeps the hello
        // byte-identical for keyless nodes (pre-0.6.2 host compatibility).
        let hello = try makeHello()
        let encoded = hello.toCBOR()
        XCTAssertFalse(findKey("join_keys", in: encoded))
        let back = try NodeHello.fromCBOR(encoded)
        XCTAssertTrue(back.joinKeys.isEmpty)
    }

    func testJoinKeysOutsideSignature() throws {
        // join_keys (like network_ids) must not affect the signed payload —
        // signable data is only {nonce, timestamp, peer_id}.
        var hello = try makeHello()
        let before = hello.signableData()
        hello.joinKeys = ["net": "key"]
        XCTAssertEqual(hello.signableData(), before)
    }

    private func findKey(_ key: String, in cbor: Data) -> Bool {
        // Text keys appear literally in CBOR; good enough for an omission check.
        cbor.range(of: Data(key.utf8)) != nil
    }
}

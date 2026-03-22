import XCTest
import Crypto
@testable import Mycellm

final class IdentityTests: XCTestCase {

    // MARK: - Key Generation

    func testAccountKeyGeneration() {
        let key = AccountKey.generate()
        XCTAssertEqual(key.publicBytes.count, 32)
        XCTAssertEqual(key.publicHex.count, 64)
    }

    func testDeviceKeyGeneration() {
        let key = DeviceKey.generate()
        XCTAssertEqual(key.publicBytes.count, 32)
        XCTAssertEqual(key.publicHex.count, 64)
    }

    func testKeyRoundtrip() throws {
        let original = DeviceKey.generate()
        let rawBytes = Data(original.privateKey.rawRepresentation)
        let restored = try DeviceKey(rawPrivateKey: rawBytes)
        XCTAssertEqual(original.publicBytes, restored.publicBytes)
    }

    func testAccountKeySignature() throws {
        let key = AccountKey.generate()
        let data = Data("test message".utf8)
        let sig = try key.sign(data)
        XCTAssertEqual(sig.count, 64) // Ed25519 signatures are 64 bytes
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: data))
    }

    func testDeviceKeySignature() throws {
        let key = DeviceKey.generate()
        let data = Data("test message".utf8)
        let sig = try key.sign(data)
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: data))
    }

    // MARK: - PeerId

    func testPeerIdFromPublicKey() {
        let key = DeviceKey.generate()
        let peerId = PeerId.from(publicKey: key.publicKey)
        XCTAssertEqual(peerId.count, 32)

        // Should be deterministic
        let peerId2 = PeerId.from(publicKey: key.publicKey)
        XCTAssertEqual(peerId, peerId2)
    }

    func testPeerIdFromBytes() {
        let key = DeviceKey.generate()
        let peerId1 = PeerId.from(publicKey: key.publicKey)
        let peerId2 = PeerId.from(publicKeyBytes: key.publicBytes)
        XCTAssertEqual(peerId1, peerId2)
    }

    func testPeerIdFormat() {
        // PeerId should be 32 lowercase hex characters
        let key = DeviceKey.generate()
        let peerId = PeerId.from(publicKey: key.publicKey)
        XCTAssertTrue(peerId.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(peerId, peerId.lowercased())
    }

    /// Verify wire compatibility with Python:
    /// Python: hashlib.sha256(raw_32_byte_pubkey).hexdigest()[:32]
    func testPeerIdWireCompatibility() {
        // Known test vector: all-zero key
        let zeroKey = Data(repeating: 0, count: 32)
        let peerId = PeerId.from(publicKeyBytes: zeroKey)
        // SHA256 of 32 zero bytes = 66687aadf862bd776c8fc18b8e9f8e20...
        XCTAssertEqual(peerId, "66687aadf862bd776c8fc18b8e9f8e20")
    }

    // MARK: - DeviceCert

    func testDeviceCertCreation() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()

        let cert = try DeviceCert.create(accountKey: account, deviceKey: device, deviceName: "test-node")

        XCTAssertEqual(cert.accountPubkey, account.publicBytes)
        XCTAssertEqual(cert.devicePubkey, device.publicBytes)
        XCTAssertEqual(cert.deviceName, "test-node")
        XCTAssertEqual(cert.role, "seeder")
        XCTAssertFalse(cert.revoked)
        XCTAssertEqual(cert.signature.count, 64)
    }

    func testDeviceCertVerification() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()

        let cert = try DeviceCert.create(accountKey: account, deviceKey: device)
        XCTAssertTrue(cert.verify())
        XCTAssertTrue(cert.verify(accountPubkey: account.publicBytes))
    }

    func testDeviceCertRejectsWrongAccount() throws {
        let account = AccountKey.generate()
        let wrongAccount = AccountKey.generate()
        let device = DeviceKey.generate()

        let cert = try DeviceCert.create(accountKey: account, deviceKey: device)
        XCTAssertFalse(cert.verify(accountPubkey: wrongAccount.publicBytes))
    }

    func testDeviceCertRevokedRejected() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()

        var cert = try DeviceCert.create(accountKey: account, deviceKey: device)
        cert.revoked = true
        XCTAssertFalse(cert.verify())
    }

    func testDeviceCertExpiredRejected() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()

        // Create cert that expired 1 second ago
        let cert = try DeviceCert.create(accountKey: account, deviceKey: device, ttlSeconds: -1)
        XCTAssertTrue(cert.isExpired)
        XCTAssertFalse(cert.verify())
    }

    func testDeviceCertCBORRoundtrip() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()

        let original = try DeviceCert.create(accountKey: account, deviceKey: device, deviceName: "roundtrip-test")
        let cbor = original.toCBOR()
        let decoded = try DeviceCert.fromCBOR(cbor)

        XCTAssertEqual(decoded.accountPubkey, original.accountPubkey)
        XCTAssertEqual(decoded.devicePubkey, original.devicePubkey)
        XCTAssertEqual(decoded.deviceName, original.deviceName)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.signature, original.signature)
        XCTAssertTrue(decoded.verify())
    }

    func testDeviceCertPeerId() throws {
        let account = AccountKey.generate()
        let device = DeviceKey.generate()

        let cert = try DeviceCert.create(accountKey: account, deviceKey: device)
        let expected = PeerId.from(publicKey: device.publicKey)
        XCTAssertEqual(cert.peerId, expected)
    }
}

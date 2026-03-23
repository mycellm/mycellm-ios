import Foundation
import CryptoKit
import SwiftCBOR

/// Identity binding message exchanged after QUIC+TLS connection.
///
/// Proves the connecting node controls the claimed device key
/// and holds a valid certificate from an account.
struct NodeHello: Sendable {
    let peerId: String
    let devicePubkey: Data      // 32-byte raw Ed25519
    let cert: DeviceCert
    let capabilities: Capabilities
    var nonce: Data
    var timestamp: Double
    var signature: Data = Data()
    var observedAddr: String = ""
    var networkIds: [String] = []

    init(
        peerId: String,
        devicePubkey: Data,
        cert: DeviceCert,
        capabilities: Capabilities,
        nonce: Data = Data.random(count: 32),
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        self.peerId = peerId
        self.devicePubkey = devicePubkey
        self.cert = cert
        self.capabilities = capabilities
        self.nonce = nonce
        self.timestamp = timestamp
    }

    /// Data that gets signed by device key.
    /// Wire-compatible with Python: `cbor2.dumps({"nonce": ..., "timestamp": ..., "peer_id": ...})`
    func signableData() -> Data {
        // Key order MUST match Python: nonce, timestamp, peer_id
        Data(encodeOrderedMap([
            ("nonce", .byteString(Array(nonce))),
            ("timestamp", .double(timestamp)),
            ("peer_id", .utf8String(peerId)),
        ]))
    }

    /// Sign this hello with the device key.
    mutating func sign(with deviceKey: DeviceKey) throws {
        signature = try deviceKey.sign(signableData())
    }

    // MARK: - CBOR Serialization

    func toCBOR() -> Data {
        // Key order matches Python NodeHello.to_cbor()
        Data(encodeOrderedMap([
            ("peer_id", .utf8String(peerId)),
            ("device_pubkey", .byteString(Array(devicePubkey))),
            ("cert", .byteString(Array(cert.toCBOR()))),
            ("capabilities", capabilities.toCBORValue()),
            ("nonce", .byteString(Array(nonce))),
            ("timestamp", .double(timestamp)),
            ("signature", .byteString(Array(signature))),
            ("observed_addr", .utf8String(observedAddr)),
            ("network_ids", .array(networkIds.map { .utf8String($0) })),
        ]))
    }

    static func fromCBOR(_ data: Data) throws -> NodeHello {
        guard let cbor = try CBOR.decode(Array(data)),
              case let .map(map) = cbor else {
            throw MycellmError.invalidCBOR("Expected CBOR map for NodeHello")
        }

        guard let peerId = map[.utf8String("peer_id")]?.stringValue,
              let devicePubkey = map[.utf8String("device_pubkey")]?.bytesValue,
              let certBytes = map[.utf8String("cert")]?.bytesValue,
              let nonce = map[.utf8String("nonce")]?.bytesValue,
              let timestamp = map[.utf8String("timestamp")]?.doubleValue,
              let signature = map[.utf8String("signature")]?.bytesValue else {
            throw MycellmError.invalidCBOR("Missing required NodeHello fields")
        }

        let cert = try DeviceCert.fromCBOR(Data(certBytes))

        let caps: Capabilities
        if let capsMap = map[.utf8String("capabilities")] {
            caps = Capabilities.fromCBORValue(capsMap)
        } else {
            caps = Capabilities()
        }

        var hello = NodeHello(
            peerId: peerId,
            devicePubkey: Data(devicePubkey),
            cert: cert,
            capabilities: caps,
            nonce: Data(nonce),
            timestamp: timestamp
        )
        hello.signature = Data(signature)
        hello.observedAddr = map[.utf8String("observed_addr")]?.stringValue ?? ""
        if case let .array(ids) = map[.utf8String("network_ids")] {
            hello.networkIds = ids.compactMap(\.stringValue)
        }
        return hello
    }

    // MARK: - Verification

    /// Verify a NodeHello message (6-step check).
    func verify(maxAgeSeconds: Double = 300.0) -> (Bool, String) {
        // 1. Timestamp freshness
        let age = abs(Date().timeIntervalSince1970 - timestamp)
        if age > maxAgeSeconds {
            return (false, "NodeHello timestamp too old")
        }

        // 2. Certificate validity (signature + expiry + revocation)
        if !cert.verify() {
            return (false, "Device certificate invalid")
        }

        // 3. Cert device key matches presented key
        if cert.devicePubkey != devicePubkey {
            return (false, "Device key mismatch between cert and hello")
        }

        // 4. PeerId matches device public key
        let expectedPeerId = PeerId.from(publicKeyBytes: devicePubkey)
        if peerId != expectedPeerId {
            return (false, "PeerId does not match device public key")
        }

        // 5. Verify signature over nonce+timestamp+peer_id
        do {
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: devicePubkey)
            guard pub.isValidSignature(signature, for: signableData()) else {
                return (false, "NodeHello signature invalid")
            }
        } catch {
            return (false, "NodeHello signature invalid: \(error)")
        }

        return (true, "")
    }
}


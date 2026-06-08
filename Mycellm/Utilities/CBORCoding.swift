import Foundation
import SwiftCBOR

/// Extensions for SwiftCBOR interop.

extension Data {
    /// Hex string representation.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Initialize from hex string.
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self = Data(bytes)
    }

    /// Generate random data of specified length.
    static func random(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

/// Build canonical CBOR receipt data for signing/verification.
/// Wire-compatible with Python `receipts.build_receipt_data()`.
func buildReceiptData(
    consumerId: String,
    seederId: String,
    model: String,
    tokens: Int,
    cost: Double,
    requestId: String = "",
    timestamp: Double = 0.0
) -> Data {
    let ts = timestamp > 0 ? timestamp : Date().timeIntervalSince1970
    // Encode the map manually in INSERTION ORDER to byte-match Python's
    // cbor2.dumps (which preserves dict insertion order). SwiftCBOR's
    // `.map([CBOR: CBOR])` is backed by an unordered Swift Dictionary, so its
    // key order varies per process and the signature never verifies against
    // the Python tracker — every receipt was rejected as "Invalid signature".
    var bytes: [UInt8] = [0xA7] // CBOR map header, 7 pairs
    func put(_ key: String, _ value: CBOR) {
        bytes.append(contentsOf: CBOR.utf8String(key).encode())
        bytes.append(contentsOf: value.encode())
    }
    put("consumer", .utf8String(consumerId))
    put("seeder", .utf8String(seederId))
    put("model", .utf8String(model))
    put("tokens", .unsignedInt(UInt64(tokens)))
    put("cost", .double(cost))
    put("request_id", .utf8String(requestId))
    put("ts", .double(ts))
    return Data(bytes)
}

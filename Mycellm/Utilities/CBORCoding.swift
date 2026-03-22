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
    let map: CBOR = .map([
        .utf8String("consumer"): .utf8String(consumerId),
        .utf8String("seeder"): .utf8String(seederId),
        .utf8String("model"): .utf8String(model),
        .utf8String("tokens"): .unsignedInt(UInt64(tokens)),
        .utf8String("cost"): .double(cost),
        .utf8String("request_id"): .utf8String(requestId),
        .utf8String("ts"): .double(ts),
    ])
    return Data(map.encode())
}

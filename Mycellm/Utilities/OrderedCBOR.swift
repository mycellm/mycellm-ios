import Foundation
import SwiftCBOR

/// Encode a CBOR map with deterministic key ordering.
/// Python's cbor2.dumps() preserves insertion order — this function
/// produces identical bytes when given keys in the same order.
func encodeOrderedMap(_ pairs: [(String, CBOR)]) -> [UInt8] {
    // CBOR map header: major type 5 (map)
    var bytes: [UInt8] = []

    // Map header
    let count = pairs.count
    if count < 24 {
        bytes.append(0xa0 | UInt8(count)) // map(n) for n < 24
    } else if count < 256 {
        bytes.append(0xb8)
        bytes.append(UInt8(count))
    } else {
        bytes.append(0xb9)
        bytes.append(UInt8((count >> 8) & 0xff))
        bytes.append(UInt8(count & 0xff))
    }

    // Key-value pairs in order
    for (key, value) in pairs {
        // Encode key as UTF-8 string
        bytes.append(contentsOf: CBOR.utf8String(key).encode())
        // Encode value
        bytes.append(contentsOf: value.encode())
    }

    return bytes
}

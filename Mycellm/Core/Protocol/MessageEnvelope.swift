import Foundation
import SwiftCBOR
import Compression

/// Protocol version constant.
let protocolVersion: UInt64 = 1

/// Compress CBOR payloads above this size.
private let compressThreshold = 1024

/// Protocol message envelope. Wire-compatible with Python `MessageEnvelope`.
///
/// Wire format:
///   `0x00` + CBOR bytes = uncompressed
///   `0x01` + zlib bytes = compressed
struct MessageEnvelope: Sendable {
    let type: MessageType
    let payload: [String: CBORValue]
    var fromPeer: String = ""
    var id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    var ts: Double = Date().timeIntervalSince1970
    var v: UInt64 = protocolVersion

    // MARK: - CBOR Serialization

    /// Serialize to wire format: prefix byte + CBOR (optionally zlib-compressed).
    func toCBOR() -> Data {
        let map: CBOR = .map([
            .utf8String("v"): .unsignedInt(v),
            .utf8String("type"): .utf8String(type.rawValue),
            .utf8String("id"): .utf8String(String(id)),
            .utf8String("ts"): .double(ts),
            .utf8String("from"): .utf8String(fromPeer),
            .utf8String("payload"): payload.toCBOR(),
        ])
        let raw = Data(map.encode())

        if raw.count >= compressThreshold {
            if let compressed = ZlibCompression.compress(raw, level: 1) {
                if compressed.count < raw.count - 16 {
                    return Data([0x01]) + compressed
                }
            }
        }
        return Data([0x00]) + raw
    }

    /// Deserialize from wire format.
    static func fromCBOR(_ data: Data) throws -> MessageEnvelope {
        guard !data.isEmpty else {
            throw MycellmError.invalidCBOR("Empty message data")
        }

        let cborData: Data
        switch data[data.startIndex] {
        case 0x01:
            guard let decompressed = ZlibCompression.decompress(data.dropFirst()) else {
                throw MycellmError.invalidCBOR("Failed to decompress message")
            }
            cborData = decompressed
        case 0x00:
            cborData = Data(data.dropFirst())
        default:
            // Legacy uncompressed (no prefix)
            cborData = data
        }

        guard let cbor = try CBOR.decode(Array(cborData)),
              case let .map(map) = cbor else {
            throw MycellmError.invalidCBOR("Expected CBOR map for MessageEnvelope")
        }

        guard let typeStr = map[.utf8String("type")]?.stringValue,
              let type = MessageType(rawValue: typeStr) else {
            throw MycellmError.invalidCBOR("Missing or unknown message type")
        }

        let v: UInt64 = map[.utf8String("v")]?.unsignedIntValue ?? protocolVersion
        let id = map[.utf8String("id")]?.stringValue ?? ""
        let ts = map[.utf8String("ts")]?.doubleValue ?? 0.0
        let fromPeer = map[.utf8String("from")]?.stringValue ?? ""
        let payload = map[.utf8String("payload")]?.toDictionary() ?? [:]

        return MessageEnvelope(
            type: type,
            payload: payload,
            fromPeer: fromPeer,
            id: id,
            ts: ts,
            v: v
        )
    }

    /// Encode with 4-byte big-endian length prefix for transport framing.
    func toFramed() -> Data {
        let payload = toCBOR()
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }

    /// Read one framed message from buffer.
    /// Returns (message, remaining) or (nil, data) if incomplete.
    static func readFrame(_ data: Data) throws -> (MessageEnvelope?, Data) {
        guard data.count >= 4 else { return (nil, data) }
        let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard length <= 10 * 1024 * 1024 else {
            throw MycellmError.frameTooLarge(length)
        }
        guard data.count >= 4 + length else { return (nil, data) }
        let msg = try fromCBOR(Data(data[4 ..< 4 + length]))
        return (msg, Data(data[(4 + length)...]))
    }
}

// MARK: - CBOR Value Bridging

/// A type-erased CBOR value for payload dictionaries.
enum CBORValue: Sendable {
    case string(String)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case bool(Bool)
    case bytes(Data)
    case array([CBORValue])
    case map([String: CBORValue])
    case null

    func toCBOR() -> CBOR {
        switch self {
        case .string(let s): return .utf8String(s)
        case .int(let i): return i >= 0 ? .unsignedInt(UInt64(i)) : .negativeInt(UInt64(-1 - i))
        case .uint(let u): return .unsignedInt(u)
        case .double(let d): return .double(d)
        case .bool(let b): return .boolean(b)
        case .bytes(let d): return .byteString(Array(d))
        case .array(let a): return .array(a.map { $0.toCBOR() })
        case .map(let m):
            let pairs: [(CBOR, CBOR)] = m.map { (CBOR.utf8String($0.key), $0.value.toCBOR()) }
            return .map(Dictionary<CBOR, CBOR>(uniqueKeysWithValues: pairs))
        case .null: return .null
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .uint(let u): return Int(u)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [CBORValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var mapValue: [String: CBORValue]? {
        if case .map(let m) = self { return m }
        return nil
    }
}

extension Dictionary where Key == String, Value == CBORValue {
    func toCBOR() -> CBOR {
        let pairs: [(CBOR, CBOR)] = map { (CBOR.utf8String($0.key), $0.value.toCBOR()) }
        let cborMap: [CBOR: CBOR] = Dictionary<CBOR, CBOR>(uniqueKeysWithValues: pairs)
        return .map(cborMap)
    }
}

// MARK: - CBOR → CBORValue Conversion

extension CBOR {
    var stringValue: String? {
        if case let .utf8String(s) = self { return s }
        return nil
    }

    var bytesValue: [UInt8]? {
        if case let .byteString(b) = self { return b }
        return nil
    }

    var boolValue: Bool? {
        if case let .boolean(b) = self { return b }
        return nil
    }

    var unsignedIntValue: UInt64? {
        if case let .unsignedInt(u) = self { return u }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .float(let f): return Double(f)
        case .half(let h): return Double(h)
        case .unsignedInt(let u): return Double(u)
        case .negativeInt(let n): return Double(-1 - Int64(n))
        default: return nil
        }
    }

    func toDictionary() -> [String: CBORValue] {
        guard case let .map(map) = self else { return [:] }
        var result: [String: CBORValue] = [:]
        for (key, value) in map {
            guard case let .utf8String(k) = key else { continue }
            result[k] = value.toCBORValue()
        }
        return result
    }

    func toCBORValue() -> CBORValue {
        switch self {
        case .utf8String(let s): return .string(s)
        case .unsignedInt(let u): return .uint(u)
        case .negativeInt(let n): return .int(-1 - Int64(n))
        case .double(let d): return .double(d)
        case .float(let f): return .double(Double(f))
        case .half(let h): return .double(Double(h))
        case .boolean(let b): return .bool(b)
        case .byteString(let b): return .bytes(Data(b))
        case .array(let a): return .array(a.map { $0.toCBORValue() })
        case .map(let m):
            var result: [String: CBORValue] = [:]
            for (key, value) in m {
                guard case let .utf8String(k) = key else { continue }
                result[k] = value.toCBORValue()
            }
            return .map(result)
        case .null, .undefined: return .null
        default: return .null
        }
    }
}

import Foundation

/// Application-level errors.
enum MycellmError: Error, LocalizedError {
    case invalidCBOR(String)
    case frameTooLarge(Int)
    case keychainError(OSStatus)
    case identityNotInitialized
    case modelTooLarge(needed: UInt64, available: UInt64)
    case modelNotLoaded(String)
    case inferenceError(String)
    case transportError(String)
    case protocolError(ErrorCode, String)

    var errorDescription: String? {
        switch self {
        case .invalidCBOR(let msg): "Invalid CBOR: \(msg)"
        case .frameTooLarge(let size): "Frame too large: \(size) bytes"
        case .keychainError(let status): "Keychain error: \(status)"
        case .identityNotInitialized: "Identity not initialized"
        case .modelTooLarge(let needed, let available): "Model requires \(needed / 1_073_741_824)GB, only \(available / 1_073_741_824)GB available"
        case .modelNotLoaded(let name): "Model not loaded: \(name)"
        case .inferenceError(let msg): "Inference error: \(msg)"
        case .transportError(let msg): "Transport error: \(msg)"
        case .protocolError(let code, let msg): "[\(code.rawValue)] \(msg)"
        }
    }
}

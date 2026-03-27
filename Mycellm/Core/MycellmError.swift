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
        case .invalidCBOR(let msg): String(localized: "Invalid CBOR: \(msg)")
        case .frameTooLarge(let size): String(localized: "Frame too large: \(size) bytes")
        case .keychainError(let status): String(localized: "Keychain error: \(status)")
        case .identityNotInitialized: String(localized: "Identity not initialized")
        case .modelTooLarge(let needed, let available): String(localized: "Model requires \(needed / 1_073_741_824)GB, only \(available / 1_073_741_824)GB available")
        case .modelNotLoaded(let name): String(localized: "Model not loaded: \(name)")
        case .inferenceError(let msg): String(localized: "Inference error: \(msg)")
        case .transportError(let msg): String(localized: "Transport error: \(msg)")
        case .protocolError(let code, let msg): "[\(code.rawValue)] \(msg)"
        }
    }
}

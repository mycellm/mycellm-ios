import Foundation

/// Protocol error codes. Wire-compatible with Python `ErrorCode(str, Enum)`.
enum ErrorCode: String, Sendable {
    case authFailed = "auth_failed"
    case certExpired = "cert_expired"
    case certRevoked = "cert_revoked"
    case peerUnreachable = "peer_unreachable"
    case modelUnavailable = "model_unavailable"
    case overloaded = "overloaded"
    case timeout = "timeout"
    case backendError = "backend_error"
    case insufficientCredit = "insufficient_credit"
    case protocolVersionMismatch = "protocol_version_mismatch"
    case invalidMessage = "invalid_message"
    case fleetKeyDenied = "fleet_key_denied"
    case unknown = "unknown"
}

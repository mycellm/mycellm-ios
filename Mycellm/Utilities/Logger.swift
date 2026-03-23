import os

/// Centralized logging for mycellm. Uses os.Logger for structured output.
enum Log {
    static let quic = os.Logger(subsystem: "com.mycellm.app", category: "QUIC")
    static let bootstrap = os.Logger(subsystem: "com.mycellm.app", category: "Bootstrap")
    static let nat = os.Logger(subsystem: "com.mycellm.app", category: "NAT")
    static let inference = os.Logger(subsystem: "com.mycellm.app", category: "Inference")
    static let general = os.Logger(subsystem: "com.mycellm.app", category: "General")
}

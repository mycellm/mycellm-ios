import Foundation

/// Central network configuration. Fork-friendly — change these values to run your own network.
/// All hardcoded endpoints flow through here so forks only need to edit one file.
enum NetworkConfig {
    /// Bootstrap server hostname for peer discovery and relay.
    static let bootstrapHost = "bootstrap.mycellm.dev"

    /// HTTPS API base for the bootstrap server.
    static let apiBase = "https://api.mycellm.dev"

    /// Default remote endpoint for network chat (public gateway).
    static let publicGateway = "https://api.mycellm.dev/v1/public"

    /// Default QUIC port for P2P transport.
    static let quicPort: UInt16 = 8421

    /// Default HTTP API port for local server.
    static let httpPort: Int = 8420

    /// Privacy policy URL.
    static let privacyURL = "https://mycellm.ai/privacy/"

    /// Terms of service URL.
    static let termsURL = "https://mycellm.ai/terms/"

    /// Keychain service prefix.
    static let keychainPrefix = "com.mycellm"
}

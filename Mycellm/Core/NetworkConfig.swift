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

    /// Privacy policy URL — served from the canonical marketing site
    /// (Astro `site: https://mycellm.dev`; build produces /privacy/index.html).
    /// The api. subdomain is REST only. Verified live (200).
    static let privacyURL = "https://mycellm.dev/privacy"

    /// Terms of service URL — same hosting as privacyURL. Verified live (200).
    static let termsURL = "https://mycellm.dev/terms"

    /// Keychain service prefix.
    static let keychainPrefix = "com.mycellm"

    /// Protocol/core version — must match the Python CLI version.
    /// Single source of truth: SettingsView, HealthRoute, BootstrapClient,
    /// NodeService (peer hello), and Capabilities all read this. Bump when
    /// upstream Python mycellm cuts a release that changes the wire
    /// protocol or the OpenAI-API surface that iOS mirrors.
    /// 0.6.2 = join-key-era core; this build also mirrors the 0.6.3
    /// hardening surface (stop-holdback, download verification, usage,
    /// context_length, bounded KV).
    static let version = "0.6.2"
}

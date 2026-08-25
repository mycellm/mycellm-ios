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
    /// protocol or the OpenAI-API surface that iOS mirrors — and on a security
    /// fix shipped on both platforms, so an operator can tell a patched node
    /// from an unpatched one. That second reason is why this reads 0.7.1: the
    /// path-containment fix changes no wire format, but without the bump a
    /// patched build and a vulnerable one report the same version and the
    /// fleet cannot be audited from `/v1/node/status` alone.
    ///
    /// 0.8.0 = adaptive inference fabric. iOS speaks the additive half: it
    /// advertises `execution_roles` (so a planner stops routing chat to an
    /// embedding model instead of learning by refusal) and the device
    /// constraint telemetry the rest of the fleet had no way to see, and it
    /// decodes serving-group and parallelism fields from peers. Everything is
    /// omitted when unset, so a 0.7.x peer receives a byte-identical payload.
    /// 0.7.1 = download destinations contained inside the models directory.
    /// 0.7.0 = leaf-node parity core (node management surface, /v1/embeddings,
    /// Prometheus /metrics, activity + log SSE, URL and MLX-manifest installs
    /// with per-file digest verification) — released fleet-wide 2026-08-15.
    /// Supersedes 0.6.3, the hardening-era core (stop-holdback, download
    /// verification, exact usage, context_length, bounded KV).
    static let version = "0.8.0"
}

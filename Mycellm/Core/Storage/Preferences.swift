import Foundation

/// UserDefaults wrapper for app preferences.
@Observable
final class Preferences: @unchecked Sendable {
    @MainActor static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: - Node

    var nodeName: String {
        get { defaults.string(forKey: "node_name") ?? NodeNameGenerator.generate() }
        set { defaults.set(newValue, forKey: "node_name") }
    }

    var apiPort: Int {
        get { defaults.integer(forKey: "api_port").nonZero ?? 8420 }
        set { defaults.set(newValue, forKey: "api_port") }
    }

    var quicPort: Int {
        get { defaults.integer(forKey: "quic_port").nonZero ?? 8421 }
        set { defaults.set(newValue, forKey: "quic_port") }
    }

    // MARK: - Network

    var networkMode: NetworkMode {
        get { NetworkMode(rawValue: defaults.string(forKey: "network_mode") ?? "public") ?? .public }
        set { defaults.set(newValue.rawValue, forKey: "network_mode") }
    }

    var lastLoadedModel: String? {
        get { defaults.string(forKey: "last_loaded_model") }
        set { defaults.set(newValue, forKey: "last_loaded_model") }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "has_completed_onboarding") }
        set { defaults.set(newValue, forKey: "has_completed_onboarding") }
    }

    var bootstrapHost: String {
        get { defaults.string(forKey: "bootstrap_host") ?? BootstrapClient.defaultBootstrap }
        set { defaults.set(newValue, forKey: "bootstrap_host") }
    }

    var fleetAdminKey: String? {
        get { defaults.string(forKey: "fleet_admin_key") }
        set { defaults.set(newValue, forKey: "fleet_admin_key") }
    }

    // MARK: - API

    var httpServerEnabled: Bool {
        get { defaults.bool(forKey: "http_server_enabled") }
        set { defaults.set(newValue, forKey: "http_server_enabled") }
    }

    var apiKey: String {
        get { defaults.string(forKey: "api_key") ?? "" }
        set { defaults.set(newValue, forKey: "api_key") }
    }

    // MARK: - Remote Endpoint

    var remoteEndpoint: String {
        get { defaults.string(forKey: "remote_endpoint") ?? "https://api.mycellm.dev/v1/public" }
        set { defaults.set(newValue, forKey: "remote_endpoint") }
    }

    var remoteApiKey: String {
        get { defaults.string(forKey: "remote_api_key") ?? "" }
        set { defaults.set(newValue, forKey: "remote_api_key") }
    }

    var remoteModel: String {
        get { defaults.string(forKey: "remote_model") ?? "" }
        set { defaults.set(newValue, forKey: "remote_model") }
    }

    // MARK: - Privacy Guard

    var sensitiveGuardEnabled: Bool {
        get { defaults.object(forKey: "sensitive_guard_enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sensitive_guard_enabled") }
    }

    // MARK: - Display

    var keepAwake: Bool {
        get { defaults.bool(forKey: "keep_awake") }
        set { defaults.set(newValue, forKey: "keep_awake") }
    }

    var screenSaverEnabled: Bool {
        get { defaults.bool(forKey: "screen_saver_enabled") }
        set { defaults.set(newValue, forKey: "screen_saver_enabled") }
    }

    /// Minutes of idle before screensaver activates (0 = immediate with keep awake)
    var screenSaverDelay: Int {
        get { defaults.integer(forKey: "screen_saver_delay").nonZero ?? 5 }
        set { defaults.set(newValue, forKey: "screen_saver_delay") }
    }

    // MARK: - Telemetry

    var telemetryEnabled: Bool {
        get { defaults.bool(forKey: "telemetry_enabled") }
        set { defaults.set(newValue, forKey: "telemetry_enabled") }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

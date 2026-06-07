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
        get { defaults.string(forKey: "remote_endpoint") ?? NetworkConfig.publicGateway }
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

    // MARK: - Reasoning ("thinking")

    /// When true, requests to /v1/chat/completions with no explicit `reasoning`
    /// block strip <think>...</think> from responses and ask Qwen3-family
    /// templates to suppress thinking. End-user chat feels clean by default;
    /// power users can opt in to seeing reasoning via the chat UI toggle.
    var hideReasoningByDefault: Bool {
        get { defaults.object(forKey: "hide_reasoning_by_default") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hide_reasoning_by_default") }
    }

    /// Per-chat UI toggle: when true, ChatView shows reasoning in a
    /// collapsible disclosure panel above the answer. Doesn't change
    /// server policy — sends `reasoning: {"exclude": false}` in the
    /// request body so the server emits reasoning_content.
    var chatShowReasoning: Bool {
        get { defaults.bool(forKey: "chat_show_reasoning") }
        set { defaults.set(newValue, forKey: "chat_show_reasoning") }
    }

    // MARK: - Inference

    /// Default context window for loaded models. Explicit ctx_len on
    /// load requests still wins.
    ///
    /// Unlike Python's MYCELLM_DEFAULT_CTX_LEN=32768, iOS defaults scale
    /// with device physical memory. llama.cpp / MLX allocate KV-cache
    /// AND activation buffers sized by n_ctx, so a 32K context can OOM
    /// Metal on an 8 GB phone even before any tokens are generated.
    /// Recommended tier (matches Apple's per-device memory caps with
    /// the increased-memory-limit entitlement):
    ///
    ///   tier         RAM          default ctx
    ///   ─────────────────────────────────────
    ///   phone-base    6-8 GB      4096
    ///   phone-pro    12 GB        8192
    ///   tablet-pro   16+ GB      16384
    ///
    /// Users can override via the Settings UI or per-load HTTP body.
    var defaultCtxLen: Int {
        get {
            if let n = defaults.object(forKey: "default_ctx_len") as? Int, n > 0 {
                return n
            }
            let gb = HardwareInfo.totalMemoryGB
            if gb >= 14 { return 16384 }
            if gb >= 10 { return 8192 }
            return 4096
        }
        set { defaults.set(newValue, forKey: "default_ctx_len") }
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

    var screenSaverShowLogo: Bool {
        get { defaults.object(forKey: "screen_saver_show_logo") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "screen_saver_show_logo") }
    }

    var screenSaverShowHostInfo: Bool {
        get { defaults.bool(forKey: "screen_saver_show_host_info") }
        set { defaults.set(newValue, forKey: "screen_saver_show_host_info") }
    }

    var screenSaverShowTime: Bool {
        get { defaults.bool(forKey: "screen_saver_show_time") }
        set { defaults.set(newValue, forKey: "screen_saver_show_time") }
    }

    var screenSaverShowStats: Bool {
        get { defaults.bool(forKey: "screen_saver_show_stats") }
        set { defaults.set(newValue, forKey: "screen_saver_show_stats") }
    }

    // MARK: - Chat State

    var chatRoute: String {
        get { defaults.string(forKey: "chat_route") ?? "Network" }
        set { defaults.set(newValue, forKey: "chat_route") }
    }

    var lastSessionId: String? {
        get { defaults.string(forKey: "last_session_id") }
        set { defaults.set(newValue, forKey: "last_session_id") }
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

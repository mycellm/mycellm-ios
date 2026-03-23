import Foundation

/// Scans outgoing messages for sensitive data patterns before sending to the network.
/// Client-side only — never touches the network.
@Observable
final class SensitiveDataGuard: @unchecked Sendable {

    // MARK: - Types

    enum Severity: String, Codable, Sendable, CaseIterable {
        case high   // Block + redirect to local
        case medium // Warn with indicator
        case low    // Informational only
    }

    enum Action: Sendable {
        case allow          // No sensitive data found
        case indicate       // LOW: subtle indicator
        case warn           // MEDIUM: amber indicator, send allowed
        case blockRedirect  // HIGH + local model: auto-route on-device
        case blockAsk       // HIGH + no local model: show dialog
    }

    struct Rule: Identifiable, Codable, Sendable {
        let id: String
        var label: String
        var pattern: String
        var severity: Severity
        var category: String
        var enabled: Bool
        var builtin: Bool

        init(id: String, label: String, pattern: String, severity: Severity, category: String, enabled: Bool = true, builtin: Bool = true) {
            self.id = id
            self.label = label
            self.pattern = pattern
            self.severity = severity
            self.category = category
            self.enabled = enabled
            self.builtin = builtin
        }
    }

    struct Match: Identifiable, Sendable {
        let id = UUID()
        let rule: Rule
        let matchedText: String // redacted — first 4 + last 2 chars only
        let range: Range<String.Index>
    }

    struct ScanResult: Sendable {
        let matches: [Match]
        let action: Action
        let highestSeverity: Severity?
    }

    // MARK: - State

    private(set) var rules: [Rule] = []
    var isEnabled: Bool = true

    // MARK: - Init

    init() {
        rules = Self.builtinRules
        loadCustomRules()
    }

    // MARK: - Scanning

    /// Scan text for sensitive patterns. Returns matches and recommended action.
    func scan(_ text: String, trustLevel: NetworkMembership.TrustLevel = .strict, hasLocalModel: Bool = false) -> ScanResult {
        guard isEnabled, !text.isEmpty else {
            return ScanResult(matches: [], action: .allow, highestSeverity: nil)
        }

        // Honor trust = skip entirely
        if trustLevel == .honor {
            return ScanResult(matches: [], action: .allow, highestSeverity: nil)
        }

        var matches: [Match] = []

        for rule in rules where rule.enabled {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }

            let nsText = text as NSString
            let results = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

            for result in results {
                guard let range = Range(result.range, in: text) else { continue }
                let matched = String(text[range])

                // Context exclusion: skip if preceded by "example", "sample", "test", "dummy", "placeholder"
                if isExcludedByContext(text: text, matchRange: range) { continue }

                // Redact for display: show first 4 + "…" + last 2
                let redacted = redactForDisplay(matched)

                matches.append(Match(rule: rule, matchedText: redacted, range: range))
            }
        }

        let highestSeverity = matches.map(\.rule.severity).max(by: { severityOrder($0) < severityOrder($1) })

        let action: Action
        switch (highestSeverity, trustLevel) {
        case (.high, .strict):
            action = hasLocalModel ? .blockRedirect : .blockAsk
        case (.high, .relaxed):
            action = .warn
        case (.medium, .strict):
            action = .warn
        case (.medium, .relaxed):
            action = .allow
        case (.low, _):
            action = matches.isEmpty ? .allow : .indicate
        case (nil, _):
            action = .allow
        default:
            action = .allow
        }

        return ScanResult(matches: matches, action: action, highestSeverity: highestSeverity)
    }

    // MARK: - Context Exclusion

    private func isExcludedByContext(text: String, matchRange: Range<String.Index>) -> Bool {
        let lookback = 30
        let startIdx = text.index(matchRange.lowerBound, offsetBy: -min(lookback, text.distance(from: text.startIndex, to: matchRange.lowerBound)), limitedBy: text.startIndex) ?? text.startIndex
        let prefix = text[startIdx..<matchRange.lowerBound].lowercased()

        let exclusions = ["example", "sample", "placeholder", "dummy", "test", "fake", "demo"]
        return exclusions.contains(where: { prefix.contains($0) })
    }

    // MARK: - Helpers

    private func redactForDisplay(_ text: String) -> String {
        guard text.count > 8 else { return String(repeating: "•", count: text.count) }
        let prefix = String(text.prefix(4))
        let suffix = String(text.suffix(2))
        return "\(prefix)…\(suffix)"
    }

    private func severityOrder(_ s: Severity) -> Int {
        switch s {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    // MARK: - Custom Rules

    func addCustomRule(label: String, pattern: String, severity: Severity, category: String = "Custom") {
        let id = "custom_\(UUID().uuidString.prefix(8).lowercased())"
        let rule = Rule(id: id, label: label, pattern: pattern, severity: severity, category: category, enabled: true, builtin: false)
        rules.append(rule)
        saveCustomRules()
    }

    func toggleRule(id: String, enabled: Bool) {
        if let idx = rules.firstIndex(where: { $0.id == id }) {
            rules[idx].enabled = enabled
            saveCustomRules()
        }
    }

    func removeCustomRule(id: String) {
        rules.removeAll { $0.id == id && !$0.builtin }
        saveCustomRules()
    }

    private func saveCustomRules() {
        let custom = rules.filter { !$0.builtin }
        let disabled = rules.filter { $0.builtin && !$0.enabled }.map(\.id)
        let data: [String: Any] = [
            "custom": (try? JSONEncoder().encode(custom)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
            "disabled_builtins": disabled,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data) {
            UserDefaults.standard.set(json, forKey: "sensitive_guard_rules")
        }
    }

    private func loadCustomRules() {
        guard let json = UserDefaults.standard.data(forKey: "sensitive_guard_rules"),
              let data = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }

        if let customStr = data["custom"] as? String,
           let customData = customStr.data(using: .utf8),
           let custom = try? JSONDecoder().decode([Rule].self, from: customData) {
            rules.append(contentsOf: custom)
        }

        if let disabled = data["disabled_builtins"] as? [String] {
            for id in disabled {
                if let idx = rules.firstIndex(where: { $0.id == id }) {
                    rules[idx].enabled = false
                }
            }
        }
    }

    // MARK: - Built-in Rules

    static let builtinRules: [Rule] = [
        // API Keys — HIGH
        Rule(id: "api_key_openai", label: "OpenAI API key", pattern: "sk-[a-zA-Z0-9]{16,}", severity: .high, category: "API Keys"),
        Rule(id: "api_key_anthropic", label: "Anthropic API key", pattern: "sk-ant-[a-zA-Z0-9\\-]{16,}", severity: .high, category: "API Keys"),
        Rule(id: "api_key_openrouter", label: "OpenRouter API key", pattern: "sk-or-v1-[a-zA-Z0-9]{10,}", severity: .high, category: "API Keys"),
        Rule(id: "api_key_github", label: "GitHub token", pattern: "gh[ps]_[a-zA-Z0-9]{20,}", severity: .high, category: "API Keys"),
        Rule(id: "api_key_aws", label: "AWS access key", pattern: "AKIA[A-Z0-9]{12,}", severity: .high, category: "API Keys"),
        Rule(id: "api_key_slack", label: "Slack token", pattern: "xox[baprs]-[a-zA-Z0-9\\-]{10,}", severity: .high, category: "API Keys"),
        Rule(id: "api_key_hf", label: "HuggingFace token", pattern: "hf_[a-zA-Z0-9]{10,}", severity: .high, category: "API Keys"),
        Rule(id: "api_key_stripe", label: "Stripe key", pattern: "sk_(?:live|test)_[a-zA-Z0-9]{20,}", severity: .high, category: "API Keys"),
        Rule(id: "api_key_google", label: "Google API key", pattern: "AIza[a-zA-Z0-9_\\-]{30,}", severity: .high, category: "API Keys"),

        // Secrets — HIGH
        Rule(id: "private_key", label: "Private key block", pattern: "-----BEGIN\\s+(?:RSA|EC|DSA|OPENSSH|PGP)\\s+PRIVATE\\s+KEY", severity: .high, category: "Secrets"),
        Rule(id: "jwt_token", label: "JSON Web Token", pattern: "eyJ[a-zA-Z0-9_-]{10,}\\.eyJ[a-zA-Z0-9_-]{10,}\\.[a-zA-Z0-9_-]{10,}", severity: .high, category: "Secrets"),
        Rule(id: "connection_string", label: "Database URL", pattern: "(?:postgresql|mysql|mongodb|redis|amqp)://[^\\s]{10,}", severity: .high, category: "Secrets"),
        Rule(id: "password_assign", label: "Password assignment", pattern: "(?:password|passwd|pwd)\\s*[=:]\\s*['\"]?[^\\s'\"]{6,}", severity: .high, category: "Secrets"),
        Rule(id: "generic_secret", label: "Secret/token assignment", pattern: "(?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token)\\s*[=:]\\s*['\"]?[^\\s'\"]{8,}", severity: .high, category: "Secrets"),

        // Financial — HIGH
        Rule(id: "credit_card", label: "Credit card number", pattern: "\\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|6(?:011|5[0-9]{2})[0-9]{12})\\b", severity: .high, category: "Financial"),
        Rule(id: "ssn", label: "Social Security Number", pattern: "\\b\\d{3}-\\d{2}-\\d{4}\\b", severity: .high, category: "Financial"),

        // PII — MEDIUM
        Rule(id: "email_address", label: "Email address", pattern: "\\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}\\b", severity: .medium, category: "PII"),
        Rule(id: "phone_number", label: "Phone number", pattern: "\\b(?:\\+1|1)?[-. ]?\\(?\\d{3}\\)?[-. ]?\\d{3}[-. ]?\\d{4}\\b", severity: .medium, category: "PII"),
        Rule(id: "private_ip", label: "Private IP address", pattern: "\\b(?:10\\.|172\\.(?:1[6-9]|2\\d|3[01])\\.|192\\.168\\.)\\d{1,3}\\.\\d{1,3}\\b", severity: .medium, category: "PII"),

        // Low — informational
        Rule(id: "street_address", label: "Street address", pattern: "\\b\\d{1,5}\\s+[A-Z][a-z]+\\s+(?:St|Ave|Rd|Blvd|Dr|Ln|Ct)\\.?\\b", severity: .low, category: "PII", enabled: false),
    ]
}

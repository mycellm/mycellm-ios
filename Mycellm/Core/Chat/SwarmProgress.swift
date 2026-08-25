import Foundation

/// A progress frame from a streaming swarm.
///
/// The server sends these on the `mycellm` field with an **empty delta**, so a
/// client that only concatenates `delta.content` is unaffected and sees exactly
/// the answer. Reading them is what turns the several seconds a swarm spends
/// fanning out from an undifferentiated typing indicator into
/// "Asking 3 models on aurora, hokulea…" — which is the one moment the fabric
/// is visible to a user at all.
struct SwarmProgress: Equatable {
    enum Phase: String {
        case proposing
        case synthesizing
    }

    let phase: Phase
    var planned: Int = 0
    var targets: [String] = []
    var target: String = ""
    var fromProposals: Int = 0

    /// Parse from an SSE chunk's `mycellm` object. Returns nil for anything
    /// that is not a progress frame — the same object also carries the final
    /// execution plan, which is a different shape entirely.
    init?(mycellm: [String: Any]) {
        guard (mycellm["type"] as? String) == "progress",
              let raw = mycellm["phase"] as? String,
              let phase = Phase(rawValue: raw) else { return nil }
        self.phase = phase
        self.planned = (mycellm["planned"] as? Int) ?? 0
        self.targets = (mycellm["targets"] as? [String]) ?? []
        self.target = (mycellm["target"] as? String) ?? ""
        self.fromProposals = (mycellm["from_proposals"] as? Int) ?? 0
    }

    /// One short line for the typing indicator.
    var label: String {
        switch phase {
        case .proposing:
            let n = planned > 0 ? planned : targets.count
            let names = Array(NSOrderedSet(array: targets.map(Self.shortTarget)))
                .compactMap { $0 as? String }
            let where_ = names.isEmpty ? "" : " on \(names.joined(separator: ", "))"
            return "Asking \(n) model\(n == 1 ? "" : "s")\(where_)…"
        case .synthesizing:
            let on = target.isEmpty ? "" : " on \(Self.shortTarget(target))"
            return "Synthesising \(fromProposals) answer\(fromProposals == 1 ? "" : "s")\(on)…"
        }
    }

    /// A target string rendered as something a person recognises.
    ///
    /// ⚠️ NEVER RETURN THE PLACEHOLDER. A serving group with no id prints as
    /// `group:external:<model>`, and naively taking the second segment renders
    /// "Asking 3 models on external" — three distinct models collapsed into one
    /// meaningless word. When the group is unnamed the MODEL is the identifying
    /// fact, so fall through to it. (Caught in a browser on the dashboard; the
    /// same rule applies here, which is why both sides carry this comment.)
    ///
    ///     local:qwen3-9b           → this device
    ///     peer:1a2b3c4d:qwen3-9b   → 1a2b3c4d
    ///     group:abc123:qwen3-9b    → abc123
    ///     group:external:qwen3-9b  → qwen3-9b
    static func shortTarget(_ target: String) -> String {
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard let kind = parts.first else { return target }
        if kind == "local" { return "this device" }
        let second = parts.count > 1 ? parts[1] : ""
        let model = parts.count > 2 ? parts[2...].joined(separator: ":") : second
        if kind == "group" && (second.isEmpty || second == "external") {
            return model.isEmpty ? target : model
        }
        if second.isEmpty { return model.isEmpty ? target : model }
        return String(second.prefix(8))
    }
}

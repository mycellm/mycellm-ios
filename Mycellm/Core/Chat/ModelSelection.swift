import Foundation

/// One control, one value — what the user picked for network chat.
///
/// ⚠️ TIER AND MODEL ARE MUTUALLY EXCLUSIVE, AND THIS TYPE IS WHY THAT IS
/// STRUCTURAL RATHER THAN A RULE SOMEONE HAS TO KNOW. A quality floor
/// (`min_tier`) only constrains the node while it is still *choosing* a model;
/// once the caller names one there is nothing left to constrain, and the node
/// rejects a request that asks for both. Two separate controls could express
/// that contradiction. One value cannot.
///
/// Deliberately a mirror of the dashboard's `lib/selection.ts` and the same
/// vocabulary the Python resolver uses (`router/model_resolver.TIER_THRESHOLDS`),
/// so a tier means the same thing on a phone, in a browser, and on the node.
enum ModelSelection: Equatable, Hashable {
    /// The node picks, unconstrained. The default, and it stays the default.
    case auto
    /// The node picks, but not below this tier.
    case tier(Tier)
    /// This exact model, or a strategy such as `mycellm/swarm`.
    case model(String)

    enum Tier: String, CaseIterable, Identifiable {
        case frontier, capable, fast, tiny

        var id: String { rawValue }

        /// Highest first — the order the picker renders, and of quality.
        static var ordered: [Tier] { [.frontier, .capable, .fast, .tiny] }

        var label: String {
            switch self {
            case .frontier: return "Frontier (65B+)"
            case .capable:  return "Capable (13B+)"
            case .fast:     return "Fast (3B+)"
            case .tiny:     return "Tiny (<3B)"
            }
        }

        var rank: Int {
            switch self {
            case .frontier: return 4
            case .capable:  return 3
            case .fast:     return 2
            case .tiny:     return 1
            }
        }

        /// Tier a parameter count falls into. Mirrors `derive_tier`.
        static func forParams(_ paramsB: Double) -> Tier {
            if paramsB >= 65 { return .frontier }
            if paramsB >= 13 { return .capable }
            if paramsB >= 3 { return .fast }
            return .tiny
        }
    }

    // MARK: - Persistence

    /// Prefix used to encode a tier into the single stored string, so the
    /// existing `remote_model` preference keeps working: an old install with
    /// "qwen3-9b" saved still decodes to `.model("qwen3-9b")`.
    static let tierPrefix = "tier:"

    /// Decode from the stored preference string.
    init(stored: String) {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "auto" || trimmed == "default" {
            self = .auto
        } else if trimmed.hasPrefix(Self.tierPrefix),
                  let tier = Tier(rawValue: String(trimmed.dropFirst(Self.tierPrefix.count))) {
            self = .tier(tier)
        } else {
            self = .model(trimmed)
        }
    }

    /// Encode for storage.
    var stored: String {
        switch self {
        case .auto:            return ""
        case .tier(let tier):  return Self.tierPrefix + tier.rawValue
        case .model(let name): return name
        }
    }

    // MARK: - What goes on the wire

    /// The `model` field. Empty for auto and for any tier — both leave the
    /// choice to the node, which is exactly when a floor is meaningful.
    var wireModel: String {
        if case .model(let name) = self { return name }
        return ""
    }

    /// The `mycellm.min_tier` field, or nil when there is no floor.
    var wireMinTier: String? {
        if case .tier(let tier) = self { return tier.rawValue }
        return nil
    }

    /// True when the node is still choosing — i.e. when resolution
    /// constraints apply at all.
    var isResolving: Bool { wireModel.isEmpty }

    /// What to show in the chat header and the picker's collapsed row.
    var label: String {
        switch self {
        case .auto:            return "Automatic"
        case .tier(let tier):  return tier.label
        case .model(let name): return name
        }
    }
}

/// A model advertised by a node, with the tier the node derived for it.
///
/// `tier` is optional on purpose: a 0.7 node does not send one, and a model
/// whose size cannot be determined has none. Absent means **unknown**, never
/// "qualifies" — claiming otherwise would offer a Frontier route that the
/// resolver then refuses.
struct RemoteModel: Equatable, Hashable {
    let id: String
    let tier: ModelSelection.Tier?

    init(id: String, tierName: String? = nil) {
        self.id = id
        self.tier = tierName.flatMap { ModelSelection.Tier(rawValue: $0) }
    }
}

extension Array where Element == RemoteModel {
    /// How many of these satisfy a floor. A floor admits its own tier and
    /// everything above it, matching the server's comparison.
    func count(atLeast tier: ModelSelection.Tier) -> Int {
        filter { ($0.tier?.rank ?? 0) >= tier.rank }.count
    }
}

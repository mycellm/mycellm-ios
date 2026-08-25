import SwiftUI

/// Mycellm brand color system.
extension Color {
    /// Background: #0A0A0A (void)
    static let voidBlack = Color(red: 0.039, green: 0.039, blue: 0.039)

    /// Primary: #22C55E (spore green)
    static let sporeGreen = Color(red: 0.133, green: 0.773, blue: 0.369)

    /// #EF4444 (compute red) — inference, and errors. The palette used to
    /// claim purple was the error colour; nothing ever used it that way. Red
    /// is what the app actually marks failures with, so the comment is now
    /// describing the code rather than contradicting it.
    static let computeRed = Color(red: 0.937, green: 0.267, blue: 0.267)

    /// #3B82F6 (relay blue)
    static let relayBlue = Color(red: 0.231, green: 0.510, blue: 0.965)

    /// Credits: #FACC15 (ledger gold)
    static let ledgerGold = Color(red: 0.980, green: 0.800, blue: 0.082)

    /// #A855F7 (poison purple)
    static let poisonPurple = Color(red: 0.659, green: 0.333, blue: 0.969)

    /// #F97316 — the one hue the brand palette lacked. Added for GGUF rather
    /// than reusing ledger gold, which already means credits and reads as a
    /// warning next to it.
    static let formatOrange = Color(red: 0.976, green: 0.451, blue: 0.086)

    /// Text: #E5E5E5 (console)
    static let consoleText = Color(red: 0.898, green: 0.898, blue: 0.898)

    /// Subtle text
    static let consoleDim = Color(red: 0.5, green: 0.5, blue: 0.5)

    /// Card background
    static let cardBackground = Color(red: 0.08, green: 0.08, blue: 0.08)

    /// Card border
    static let cardBorder = Color(red: 0.15, green: 0.15, blue: 0.15)
}

/// Brand font helpers — JetBrains Mono to match web dashboard.
extension Font {
    /// Pre-TF baseline bump (+2pt). Sizes still fixed (no Dynamic Type) —
    /// this just raises legibility for Larger Text users until a proper
    /// `relativeTo:` pass lands post-TF.
    static let monoBaselineBump: CGFloat = 2

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold: name = "JetBrainsMono-Bold"
        case .semibold: name = "JetBrainsMono-SemiBold"
        case .medium: name = "JetBrainsMono-Medium"
        default: name = "JetBrainsMono-Regular"
        }
        return Font.custom(name, size: size + Self.monoBaselineBump)
    }
}

/// Semantic colour conventions.
///
/// ⚠️ TWO AXES, AND THEY USED TO SHARE COLOURS. Green meant both "GGUF" and
/// "on device"; blue meant both "MLX" and "network". A green badge could not
/// tell you which of two unrelated things it was asserting, which is worse than
/// no colour at all.
///
/// They are now disjoint:
///
///   FORMAT   — what the weights are:  MLX = blue,  GGUF = orange
///   LOCATION — where it runs:         device = green, network = purple
///
/// Purple is free for location because nothing in the app ever used it for
/// errors; failures are red, and always have been.
extension Color {
    /// Model format.
    static func format(_ backend: String) -> Color {
        backend.lowercased().contains("mlx") ? .relayBlue : .formatOrange
    }

    /// Where inference runs. `local` covers this device; anything else is a
    /// hop off it.
    static func location(isLocal: Bool) -> Color {
        isLocal ? .sporeGreen : .poisonPurple
    }
}

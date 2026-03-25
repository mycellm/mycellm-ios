import SwiftUI

/// Mycellm brand color system.
extension Color {
    /// Background: #0A0A0A (void)
    static let voidBlack = Color(red: 0.039, green: 0.039, blue: 0.039)

    /// Primary: #22C55E (spore green)
    static let sporeGreen = Color(red: 0.133, green: 0.773, blue: 0.369)

    /// Inference: #EF4444 (compute red)
    static let computeRed = Color(red: 0.937, green: 0.267, blue: 0.267)

    /// Network: #3B82F6 (relay blue)
    static let relayBlue = Color(red: 0.231, green: 0.510, blue: 0.965)

    /// Credits: #FACC15 (ledger gold)
    static let ledgerGold = Color(red: 0.980, green: 0.800, blue: 0.082)

    /// Error: #A855F7 (poison purple)
    static let poisonPurple = Color(red: 0.659, green: 0.333, blue: 0.969)

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
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold: name = "JetBrainsMono-Bold"
        case .semibold: name = "JetBrainsMono-SemiBold"
        case .medium: name = "JetBrainsMono-Medium"
        default: name = "JetBrainsMono-Regular"
        }
        return Font.custom(name, size: size)
    }
}

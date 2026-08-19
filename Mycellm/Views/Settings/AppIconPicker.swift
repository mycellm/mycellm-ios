import SwiftUI
import UIKit

/// Alternate app icons — the mushroom in each brand colour.
///
/// The variants are true vector re-renders, not recoloured PNGs: every icon
/// comes from the same Illustrator-exported SVG with one fill substituted, so
/// the pixel-art edges stay crisp at every size instead of picking up the
/// resampling fringe a hue-shifted raster would.
enum AppIconOption: String, CaseIterable, Identifiable {
    /// `nil` alternate name = the primary icon. Red stays the default.
    case red, orange, yellow, green, lightBlue, purple

    var id: String { rawValue }

    /// The catalog name iOS wants. `nil` means the primary AppIcon.
    var alternateName: String? {
        switch self {
        case .red: nil
        case .orange: "AppIcon-Orange"
        case .yellow: "AppIcon-Yellow"
        case .green: "AppIcon-Green"
        case .lightBlue: "AppIcon-LightBlue"
        case .purple: "AppIcon-Purple"
        }
    }

    var label: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .lightBlue: "Light Blue"
        case .purple: "Purple"
        }
    }

    /// Cap colour, matching the hex baked into that icon exactly.
    var swatch: Color {
        switch self {
        case .red: .computeRed
        case .orange: Color(red: 0.976, green: 0.451, blue: 0.086)   // #F97316
        case .yellow: .ledgerGold
        case .green: .sporeGreen
        case .lightBlue: Color(red: 0.220, green: 0.741, blue: 0.973) // #38BDF8
        case .purple: .poisonPurple
        }
    }

    static func current() -> AppIconOption {
        let name = UIApplication.shared.alternateIconName
        return AppIconOption.allCases.first { $0.alternateName == name } ?? .red
    }
}

struct AppIconPicker: View {
    @State private var selected: AppIconOption = .red
    @State private var failure: String?

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(AppIconOption.allCases) { option in
                    Button {
                        apply(option)
                    } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.voidBlack)
                                .frame(width: 56, height: 56)
                                .overlay(
                                    // A mushroom silhouette in the cap colour —
                                    // enough to identify the icon without
                                    // shipping six more preview assets.
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(option.swatch)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(selected == option ? option.swatch : Color.cardBorder,
                                                lineWidth: selected == option ? 2 : 1)
                                )
                            Text(option.label)
                                .font(.mono(9))
                                .foregroundStyle(selected == option ? option.swatch : Color.consoleDim)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if let failure {
                Text(failure)
                    .font(.mono(10))
                    .foregroundStyle(Color.computeRed)
            }
        }
        .onAppear { selected = AppIconOption.current() }
    }

    private func apply(_ option: AppIconOption) {
        // ⚠️ SET THE STATE FROM THE SYSTEM, NOT FROM THE TAP. iOS can refuse
        // the change (and does, on a device where alternate icons are
        // unavailable), so optimistically selecting would leave the picker
        // claiming an icon the home screen does not have.
        guard UIApplication.shared.supportsAlternateIcons else {
            failure = "This device does not support alternate icons."
            return
        }
        UIApplication.shared.setAlternateIconName(option.alternateName) { error in
            Task { @MainActor in
                if let error {
                    failure = "Could not change icon: \(error.localizedDescription)"
                } else {
                    failure = nil
                }
                selected = AppIconOption.current()
            }
        }
    }
}

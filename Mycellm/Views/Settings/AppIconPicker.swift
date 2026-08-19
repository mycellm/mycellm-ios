import SwiftUI
import UIKit

/// Alternate app icons — the mushroom in each brand colour.
///
/// Each variant is the SHIPPED app icon with only the cap hue-mapped, not a
/// re-render of the logo artwork. That distinction was learned the hard way:
/// the logo SVG is a different mushroom (different eyes, different cap
/// silhouette) and rendering it filled the squircle edge-to-edge while the
/// real icon sits inset, so the variants were visibly larger than red.
///
/// Hue-mapped rather than flood-filled, because the cap carries faint seam
/// lines between its pixel blocks; a flat fill erased them. The mask comes from
/// alpha rather than from painting the cap white — the spots are already white,
/// so a white marker swept them in and greyed them. Red round-trips through
/// this pipeline byte-identical to the shipped icon, which is the check that
/// catches all three mistakes at once.
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

    /// Cap colour, matching the hex baked into that icon exactly. Used for the
    /// selection ring only — the tile itself shows the real artwork.
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

    /// The actual icon artwork, generated from the same PNG that ships as the
    /// icon. A coloured circle stood in for this and was worse than useless:
    /// it advertised a colour without showing what the home screen would
    /// actually get.
    var previewAsset: String {
        switch self {
        case .red: "IconPreview-red"
        case .orange: "IconPreview-orange"
        case .yellow: "IconPreview-yellow"
        case .green: "IconPreview-green"
        case .lightBlue: "IconPreview-lightblue"
        case .purple: "IconPreview-purple"
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

    // ⚠️ FIXED-WIDTH CELLS, NOT `.adaptive`. With adaptive sizing the cell grew
    // to whatever the label needed, so "Light Blue" wrapped to two lines and
    // pushed its row out of alignment with the others. The tile is the fixed
    // element; the label lives inside that width and shrinks rather than wraps.
    private static let tile: CGFloat = 60
    private static let cell: CGFloat = 76

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell), spacing: 10)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(AppIconOption.allCases) { option in
                    Button { apply(option) } label: { tile(for: option) }
                        .buttonStyle(.plain)
                }
            }

            if let failure {
                Text(failure)
                    .font(.mono(10))
                    .foregroundStyle(Color.computeRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { selected = AppIconOption.current() }
    }

    private func tile(for option: AppIconOption) -> some View {
        let isSelected = selected == option
        return VStack(spacing: 5) {
            Image(option.previewAsset)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.tile, height: Self.tile)
                // iOS masks home-screen icons to a squircle; matching that here
                // means the preview reads as the icon rather than as a picture
                // of one. 22.37% of the side is Apple's continuous-corner ratio.
                .clipShape(RoundedRectangle(cornerRadius: Self.tile * 0.2237, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.tile * 0.2237, style: .continuous)
                        .stroke(isSelected ? option.swatch : Color.cardBorder,
                                lineWidth: isSelected ? 2.5 : 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(option.swatch, Color.voidBlack)
                            .offset(x: 4, y: 4)
                    }
                }

            Text(option.label)
                .font(.mono(9))
                .lineLimit(1)
                // The longest label is "Light Blue"; shrinking keeps every cell
                // exactly one line tall so the rows stay square with each other.
                .minimumScaleFactor(0.7)
                .frame(width: Self.cell)
                .foregroundStyle(isSelected ? option.swatch : Color.consoleDim)
        }
        .frame(width: Self.cell)
        .accessibilityLabel("\(option.label) app icon")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
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

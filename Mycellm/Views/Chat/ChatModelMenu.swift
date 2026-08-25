import SwiftUI

/// Model / quality picker, in the chat bar.
///
/// ⚠️ THIS EXISTS BECAUSE THE PICKER WAS ONLY IN SETTINGS, AND THAT WAS WRONG.
/// The dashboard and the public chat box both put the selector directly in the
/// chat toolbar; on iOS you had to leave the conversation, open Settings,
/// scroll to Remote Endpoint, change it, and come back. Same capability, three
/// screens away — so in practice nobody changed it and every network chat went
/// out as Automatic, which is the exact outcome replacing the old free-text
/// field was supposed to prevent.
///
/// Automatic remains the default. This is an override for when you want
/// something specific, not a step on the way to a first message.
struct ChatModelMenu: View {
    @Bindable var preferences: Preferences
    @State private var catalog = RemoteModelCatalog.shared

    private var selection: ModelSelection {
        ModelSelection(stored: preferences.remoteModel)
    }

    var body: some View {
        Menu {
            Button {
                preferences.remoteModel = ModelSelection.auto.stored
            } label: {
                Label("Automatic", systemImage: isAuto ? "checkmark" : "wand.and.stars")
            }

            Section("Quality floor") {
                ForEach(ModelSelection.Tier.ordered) { tier in
                    Button {
                        preferences.remoteModel = ModelSelection.tier(tier).stored
                    } label: {
                        // An empty tier is offered and labelled, never hidden:
                        // the point of a floor is to say what you want even
                        // when nothing currently meets it. Hiding it would
                        // quietly downgrade the request to whatever is awake.
                        let n = catalog.models.count(atLeast: tier)
                        Text(n > 0 ? "\(tier.label) — \(n)" : "\(tier.label) — none available")
                        if isTier(tier) { Image(systemName: "checkmark") }
                    }
                }
            }

            if !catalog.models.isEmpty {
                Section("Specific model") {
                    ForEach(catalog.models, id: \.id) { model in
                        Button {
                            preferences.remoteModel = ModelSelection.model(model.id).stored
                        } label: {
                            Text(model.id)
                            if isModel(model.id) { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selection.label)
                    .font(.mono(9))
                    .foregroundStyle(isAuto ? Color.consoleDim : Color.relayBlue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
                    .foregroundStyle(Color.consoleDim)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isAuto ? Color.cardBorder : Color.relayBlue.opacity(0.35), lineWidth: 1)
            )
        }
        .task { await catalog.refresh() }
    }

    private var isAuto: Bool { if case .auto = selection { return true }; return false }
    private func isTier(_ t: ModelSelection.Tier) -> Bool {
        if case .tier(let s) = selection { return s == t }
        return false
    }
    private func isModel(_ id: String) -> Bool {
        if case .model(let s) = selection { return s == id }
        return false
    }
}

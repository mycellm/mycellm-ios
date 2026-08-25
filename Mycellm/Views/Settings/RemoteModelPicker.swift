import SwiftUI

/// Model / quality picker for network chat.
///
/// Replaces a free-text field that expected the user to know a model's exact
/// name — which meant that in practice nobody set it, and every network chat
/// went out as "default". The picker offers the same three kinds of choice as
/// the dashboard and the public chat box, in the same order and with the same
/// meanings: Automatic, a quality floor, or one named model.
///
/// ⚠️ AUTOMATIC IS THE DEFAULT AND MUST STAY THE DEFAULT. The fabric choosing
/// well is the product; picking is an override for when someone wants
/// something specific, not a step on the way to a first message.
struct RemoteModelPicker: View {
    @Bindable var preferences: Preferences

    /// Shared with the chat bar's picker — one fetch, one list, no chance of
    /// the two disagreeing about what a tier currently reaches.
    @State private var catalog = RemoteModelCatalog.shared

    private var selection: ModelSelection {
        ModelSelection(stored: preferences.remoteModel)
    }

    var body: some View {
        Group {
            Picker("Model", selection: Binding(
                get: { preferences.remoteModel },
                set: { preferences.remoteModel = $0 }
            )) {
                Text("Automatic").tag("")

                Section("Quality floor") {
                    ForEach(ModelSelection.Tier.ordered) { tier in
                        // An empty tier is offered and labelled rather than
                        // hidden. Hiding it would quietly turn "I want
                        // frontier" into "I got whatever was awake" — the
                        // silent downgrade the node now refuses to perform.
                        let n = catalog.models.count(atLeast: tier)
                        Text(n > 0 ? "\(tier.label) — \(n)" : "\(tier.label) — none available")
                            .tag(ModelSelection.tierPrefix + tier.rawValue)
                    }
                }

                if !catalog.models.isEmpty {
                    Section("Specific model") {
                        ForEach(catalog.models, id: \.id) { model in
                            Text(model.id).tag(model.id)
                        }
                    }
                }

                // A model chosen on another device (or typed into an older
                // build) must remain selectable, or opening Settings would
                // silently reset it to Automatic.
                if case .model(let name) = selection,
                   !catalog.models.contains(where: { $0.id == name }) {
                    Section("Configured") {
                        Text(name).tag(name)
                    }
                }
            }
            .font(.mono(13))

            if catalog.loading {
                Text("Loading models…")
                    .font(.mono(10))
                    .foregroundStyle(Color.consoleDim)
            } else if !catalog.error.isEmpty {
                // Say the list is incomplete rather than showing a short list
                // as if it were the whole truth.
                Text(catalog.error)
                    .font(.mono(10))
                    .foregroundStyle(Color.ledgerGold)
            } else if case .tier = selection {
                Text("The network picks, at or above this tier.")
                    .font(.mono(10))
                    .foregroundStyle(Color.consoleDim)
            }
        }
        // Force here: opening Settings is exactly when someone has just changed
        // the endpoint and wants to see what it actually serves.
        .task { await catalog.refresh(force: true) }
    }
}

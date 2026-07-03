import SwiftUI

/// Owns EVERYTHING for a single network membership: endpoint, fleet key, trust,
/// sharing, enable/disable, reconnect, and (private only) leave. A network's
/// settings live WITH that network here — not split across Settings.
///
/// For the PUBLIC membership (id "public") the endpoint IS
/// Preferences.shared.bootstrapHost / .quicPort and the key is the global
/// Preferences.shared.fleetAdminKey, so the pre-existing global config becomes
/// the Public network's config. Private memberships edit their own fields via
/// NetworkRegistry.update(_:).
struct NetworkDetailSheet: View {
    let networkId: String

    @Environment(NodeService.self) private var node
    @Environment(\.dismiss) private var dismiss
    @State private var preferences = Preferences.shared

    private var isPublic: Bool { networkId == "public" }

    private var membership: NetworkMembership? {
        node.networkRegistry.memberships.first { $0.id == networkId }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let membership {
                    content(membership)
                } else {
                    EmptyState(message: "Network not found", icon: "questionmark")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.voidBlack)
            .navigationTitle(membership?.name ?? "Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.mono(13))
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ membership: NetworkMembership) -> some View {
        List {
            statusSection(membership)
            endpointSection(membership)
            credentialsSection(membership)
            if !isPublic { trustSection(membership) }
            sharingSection(membership)
            participationSection(membership)
        }
    }

    // MARK: - Status

    private func statusSection(_ membership: NetworkMembership) -> some View {
        Section {
            let netState = node.connection.state(for: membership.id)
            LabeledContent("Status") {
                HStack(spacing: 5) {
                    Circle()
                        .fill(dotColor(for: netState.state))
                        .frame(width: 6, height: 6)
                    Text(membership.enabled ? netState.state.displayName : "Disabled")
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleDim)
                }
            }
            if membership.enabled, netState.transport != .none {
                LabeledContent("Transport") {
                    Text(netState.transport.displayName)
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleDim)
                }
            }
            if let error = netState.error {
                Text(error)
                    .font(.mono(10))
                    .foregroundStyle(Color.computeRed)
            }
            if !isPublic {
                // The id this device claims in NodeHello. For join-key
                // networks it must equal the host's network id — surfacing it
                // makes "why won't it authorize" diagnosable. Long-press to copy.
                LabeledContent("Network ID") {
                    Text(membership.id)
                        .font(.mono(11))
                        .foregroundStyle(Color.consoleDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Endpoint

    private func endpointSection(_ membership: NetworkMembership) -> some View {
        Section(header: Text("Endpoint"), footer: Text(isPublic
            ? "The coordinator this device connects to for the public network. Change it and tap Reconnect to point at your own public coordinator."
            : "The bootstrap coordinator for this private network.").font(.mono(10))) {
            HStack {
                Text("Host").font(.mono(13)).foregroundStyle(Color.consoleDim)
                TextField("bootstrap.mycellm.dev", text: hostBinding(membership))
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("QUIC Port").font(.mono(13)).foregroundStyle(Color.consoleDim)
                TextField("8421", text: portBinding(membership))
                    .accessibilityIdentifier("detail.port")
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            reconnectButton(membership)
        }
    }

    private func reconnectButton(_ membership: NetworkMembership) -> some View {
        Button {
            let m = membership
            Task { await node.reconnectMembership(m) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13))
                Text("Reconnect").font(.mono(13, weight: .medium))
            }
            .foregroundStyle(membership.enabled ? Color.relayBlue : Color.consoleDim)
        }
        .disabled(!membership.enabled)
    }

    // MARK: - Credentials (fleet key)

    @ViewBuilder
    private func credentialsSection(_ membership: NetworkMembership) -> some View {
        Section(header: Text("Fleet Key"), footer: Text("Lets a fleet admin remotely query this node and load/unload/scope its models over this network's connection. Leave blank to disable remote management on this network.").font(.mono(10))) {
            HStack {
                Text("Admin Key").font(.mono(13)).foregroundStyle(Color.consoleDim)
                RevealableSecureField("not set", text: fleetKeyBinding(membership))
                    .accessibilityIdentifier("detail.fleetKey")
            }
        }
        if !isPublic {
            Section(header: Text("Join Key"), footer: Text("Shared secret for a key-protected network — ask the host (mycellm network set-key). Sent when connecting; without it the host ignores this device on that network. Tap Reconnect to apply a change.").font(.mono(10))) {
                HStack {
                    Text("Join Key").font(.mono(13)).foregroundStyle(Color.consoleDim)
                    RevealableSecureField("not set", text: joinKeyBinding(membership))
                        .accessibilityIdentifier("detail.joinKey")
                }
            }
        }
    }

    // MARK: - Trust (private only)

    private func trustSection(_ membership: NetworkMembership) -> some View {
        Section(header: Text("Trust"), footer: Text(membership.trustLevel.description).font(.mono(10))) {
            Picker("Trust Level", selection: trustBinding(membership)) {
                ForEach(NetworkMembership.TrustLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .font(.mono(13))
        }
    }

    // MARK: - Sharing

    @ViewBuilder
    private func sharingSection(_ membership: NetworkMembership) -> some View {
        if isPublic {
            Section(footer: Text("Shares loaded models on the public network so this device seeds inference. Turn off to keep loaded models private to this device.").font(.mono(10))) {
                Toggle("Share Models on Public", isOn: Binding(
                    get: { preferences.shareModelsPublicly },
                    set: { on in
                        preferences.shareModelsPublicly = on
                        // Re-scope already-loaded models so the toggle takes
                        // effect immediately (next capability announce carries it).
                        let scope = on ? "public" : "home"
                        for m in node.modelManager.loadedModels {
                            node.modelManager.setScope(scope, for: m)
                        }
                    }
                ))
                .font(.mono(13))
            }
        }
    }

    // MARK: - Participation (enable / leave)

    private func participationSection(_ membership: NetworkMembership) -> some View {
        Section(footer: Text(isPublic
            ? "Disabling the Public network stops connecting and seeding to it — run private-only. Public can't be removed, only disabled."
            : "Disabling keeps this network but stops connecting to it. Leave removes it entirely.").font(.mono(10))) {
            Toggle("Enabled", isOn: Binding(
                get: { membership.enabled },
                set: { setEnabled($0) }
            ))
            .font(.mono(13))

            if !isPublic {
                Button(role: .destructive) {
                    let id = membership.id
                    Task { await node.disconnectMembership(networkId: id) }
                    node.networkRegistry.leave(networkId: id)
                    dismiss()
                } label: {
                    Text("Leave Network").font(.mono(13))
                }
            }
        }
    }

    // MARK: - Bindings

    private func hostBinding(_ membership: NetworkMembership) -> Binding<String> {
        Binding(
            get: { isPublic ? preferences.bootstrapHost : membership.bootstrapHost },
            set: { newVal in
                let t = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                if isPublic {
                    if !t.isEmpty { preferences.bootstrapHost = t }
                } else {
                    updateMembership { $0.bootstrapHost = t }
                }
            }
        )
    }

    private func portBinding(_ membership: NetworkMembership) -> Binding<String> {
        Binding(
            get: { isPublic ? String(preferences.quicPort) : String(membership.bootstrapPort) },
            set: { newVal in
                // Only persist a dialable port. Out-of-range input (e.g. a
                // typo like 84211) used to persist and trap UInt16() on every
                // launch — never store it.
                guard let n = Int(newVal.filter(\.isNumber)),
                      (1...65535).contains(n) else { return }
                if isPublic {
                    preferences.quicPort = n
                } else {
                    updateMembership { $0.bootstrapPort = n }
                }
            }
        )
    }

    private func joinKeyBinding(_ membership: NetworkMembership) -> Binding<String> {
        Binding(
            get: { membership.joinKey ?? "" },
            set: { newVal in
                let t = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                updateMembership { $0.joinKey = t.isEmpty ? nil : t }
            }
        )
    }

    private func fleetKeyBinding(_ membership: NetworkMembership) -> Binding<String> {
        Binding(
            get: { (isPublic ? preferences.fleetAdminKey : membership.fleetKey) ?? "" },
            set: { newVal in
                let t = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                let value: String? = t.isEmpty ? nil : t
                if isPublic {
                    preferences.fleetAdminKey = value
                    // Apply to the running public fleet handler immediately.
                    Task { await node.fleetHandler.setFleetKey(value) }
                } else {
                    updateMembership { $0.fleetKey = value }
                }
            }
        )
    }

    private func trustBinding(_ membership: NetworkMembership) -> Binding<NetworkMembership.TrustLevel> {
        Binding(
            get: { membership.trustLevel },
            set: { level in updateMembership { $0.trustLevel = level } }
        )
    }

    // MARK: - Helpers

    private func updateMembership(_ mutate: (inout NetworkMembership) -> Void) {
        guard var m = membership else { return }
        mutate(&m)
        node.networkRegistry.update(m)
    }

    private func setEnabled(_ on: Bool) {
        guard var m = membership else { return }
        m.enabled = on
        node.networkRegistry.update(m)
        Task {
            if on { await node.connectMembership(m) }
            else { await node.disconnectMembership(networkId: m.id) }
        }
    }

    private func dotColor(for state: BootstrapClient.ConnectionState) -> Color {
        switch state {
        case .connected: .sporeGreen
        case .connecting, .handshaking, .reconnecting: .ledgerGold
        case .fallbackHTTP: .relayBlue
        case .disconnected: .consoleDim
        case .failed: .computeRed
        }
    }
}

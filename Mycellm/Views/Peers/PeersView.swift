import SwiftUI

/// Identifiable wrapper so a network id can drive a `.sheet(item:)`.
private struct NetworkSelection: Identifiable { let id: String }

struct PeersView: View {
    @Environment(NodeService.self) private var node
    @State private var showJoinSheet = false
    @State private var selection: NetworkSelection?
    @State private var preferences = Preferences.shared
    @State private var joinName = ""
    @State private var joinHost = ""
    @State private var joinPort = "8421"
    @State private var joinToken = ""
    @State private var joinFleetKey = ""
    @State private var joinTrust: NetworkMembership.TrustLevel = .strict

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Network memberships
                    networksSection

                    // Connected peers
                    peersSection
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }
            .background(Color.voidBlack)
            .navigationTitle("Network")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if node.networkRegistry.canJoinNewNetworks {
                        Button {
                            showJoinSheet = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.sporeGreen)
                        }
                    }
                }
            }
            .sheet(isPresented: $showJoinSheet) {
                joinNetworkSheet
            }
            .sheet(item: $selection) { sel in
                NetworkDetailSheet(networkId: sel.id)
            }
        }
    }

    /// Enable/disable a membership: persist the flag and apply live — connect on,
    /// tear the connection down on off. Works for Public (disable ⇒ private-only).
    private func setEnabled(_ membership: NetworkMembership, _ on: Bool) {
        var m = membership
        m.enabled = on
        node.networkRegistry.update(m)
        Task {
            if on { await node.connectMembership(m) }
            else { await node.disconnectMembership(networkId: m.id) }
        }
    }

    // MARK: - Networks

    private var networksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Networks", count: node.networkRegistry.memberships.count)

            ForEach(node.networkRegistry.memberships) { membership in
                networkCard(membership)
            }

            if !node.networkRegistry.canJoinNewNetworks {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                    Text("Fleet policy restricts joining additional networks")
                        .font(.mono(10))
                }
                .foregroundStyle(Color.consoleDim)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
    }

    private func networkCard(_ membership: NetworkMembership) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: name + status
            HStack(spacing: 10) {
                Image(systemName: membership.id == "public" ? "globe" : "lock.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(membership.id == "public" ? Color.relayBlue : Color.poisonPurple)

                VStack(alignment: .leading, spacing: 2) {
                    Text(membership.name)
                        .font(.mono(13, weight: .semibold))
                        .foregroundStyle(Color.consoleText)

                    Text(endpointLabel(membership))
                        .font(.mono(10))
                        .foregroundStyle(Color.consoleDim)
                }

                Spacer()

                // Per-network connection status. Every active membership now has
                // its own connection, tracked in connection.networkStates.
                let netState = node.connection.state(for: membership.id)
                HStack(spacing: 4) {
                    Circle()
                        .fill(membership.enabled ? dotColor(for: netState.state) : Color.consoleDim.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(membership.enabled ? netState.state.displayName : "Disabled")
                        .font(.mono(9))
                        .foregroundStyle(Color.consoleDim)
                    if netState.transport != .none {
                        Text(netState.transport.displayName)
                            .font(.mono(8))
                            .foregroundStyle(Color.consoleDim)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.consoleDim.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }

            // Tags row
            HStack(spacing: 6) {
                trustBadge(membership.trustLevel)

                if membership.creditMultiplier != 1.0 {
                    Text("\(String(format: "%.0f", membership.creditMultiplier))x credits")
                        .font(.mono(9))
                        .foregroundStyle(Color.ledgerGold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.ledgerGold.opacity(0.15))
                        .clipShape(Capsule())
                }

                if membership.fleetKey != nil {
                    HStack(spacing: 2) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                        Text("Fleet")
                            .font(.mono(9))
                    }
                    .foregroundStyle(Color.relayBlue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.relayBlue.opacity(0.15))
                    .clipShape(Capsule())
                }

                if !membership.policy.allowFederationInbound || !membership.policy.allowFederationOutbound {
                    Text("No federation")
                        .font(.mono(9))
                        .foregroundStyle(Color.consoleDim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.consoleDim.opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                // Enable/disable this network live. Public can be disabled
                // (private-only) but never removed — Leave lives in the detail
                // sheet for private nets only.
                Toggle("", isOn: Binding(
                    get: { membership.enabled },
                    set: { setEnabled(membership, $0) }
                ))
                .labelsHidden()
                .tint(Color.sporeGreen)
            }

            // Credits for this network
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ledgerGold)
                if membership.id == "public" {
                    Text(String(format: "%.1f credits", node.stats.creditBalance))
                        .font(.mono(10))
                        .foregroundStyle(Color.ledgerGold)
                } else {
                    Text("100.0 credits")
                        .font(.mono(10))
                        .foregroundStyle(Color.ledgerGold)
                }
                Spacer()
                Text("\(node.stats.totalInferences) inferences")
                    .font(.mono(9))
                    .foregroundStyle(Color.consoleDim)
            }

            // Error
            if let error = node.connection.state(for: membership.id).error {
                Text(error)
                    .font(.mono(9))
                    .foregroundStyle(Color.computeRed)
            }
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(membership.id == "public" ? Color.relayBlue.opacity(0.2) : Color.cardBorder, lineWidth: 1)
        )
        // Tapping the card opens the per-network detail sheet, which owns every
        // setting for this network (endpoint, key, trust, sharing, enable, leave).
        .contentShape(Rectangle())
        .onTapGesture { selection = NetworkSelection(id: membership.id) }
    }

    /// Effective endpoint shown on a card. For Public the endpoint lives in
    /// Preferences (not the membership fields), so reflect that.
    private func endpointLabel(_ membership: NetworkMembership) -> String {
        if membership.id == "public" {
            return preferences.bootstrapHost + ":" + String(preferences.quicPort)
        }
        return membership.bootstrapHost + ":" + String(membership.bootstrapPort)
    }

    private func trustBadge(_ level: NetworkMembership.TrustLevel) -> some View {
        let (color, icon): (Color, String) = switch level {
        case .strict: (Color.sporeGreen, "checkmark.shield.fill")
        case .relaxed: (Color.ledgerGold, "shield.fill")
        case .honor: (Color.consoleDim, "heart.fill")
        }
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(level.displayName)
                .font(.mono(9))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
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

    // MARK: - Peers

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if DEBUG
            if ScreenshotMode.isActive {
                SectionHeader(title: "Peers", count: ScreenshotMode.mockPeers.count)
                ForEach(ScreenshotMode.mockPeers) { peer in mockPeerRow(peer) }
            } else {
                SectionHeader(title: "Peers", count: 0)
                EmptyState(message: "No connected peers", icon: "person.2")
            }
            #else
            SectionHeader(title: "Peers", count: 0)
            EmptyState(message: "No connected peers", icon: "person.2")
            #endif
        }
        .padding(.horizontal)
    }

    #if DEBUG
    private func mockPeerRow(_ peer: ScreenshotMode.MockPeer) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.sporeGreen)
                .frame(width: 8, height: 8)
                .shadow(color: Color.sporeGreen.opacity(0.6), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.name)
                        .font(.mono(13, weight: .semibold))
                        .foregroundStyle(Color.consoleText)
                    Text(peer.net)
                        .font(.mono(8))
                        .foregroundStyle(peer.net == "Public" ? Color.relayBlue : Color.poisonPurple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((peer.net == "Public" ? Color.relayBlue : Color.poisonPurple).opacity(0.15), in: Capsule())
                }
                Text(peer.device)
                    .font(.mono(10))
                    .foregroundStyle(Color.consoleDim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(peer.model)
                    .font(.mono(10))
                    .foregroundStyle(Color.consoleText)
                Text(String(format: "%.0f tok/s", peer.tps))
                    .font(.mono(9))
                    .foregroundStyle(Color.sporeGreen)
            }
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder, lineWidth: 1))
    }
    #endif

    // MARK: - Join Network Sheet

    private var joinNetworkSheet: some View {
        NavigationStack {
            List {
                Section("Network") {
                    HStack {
                        Text("Name")
                            .font(.mono(13))
                            .foregroundStyle(Color.consoleDim)
                        TextField("My Lab Network", text: $joinName)
                            .font(.mono(13))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                    }
                    HStack {
                        Text("Bootstrap Host")
                            .font(.mono(13))
                            .foregroundStyle(Color.consoleDim)
                        TextField("192.168.1.100", text: $joinHost)
                            .font(.mono(13))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Text("Port")
                            .font(.mono(13))
                            .foregroundStyle(Color.consoleDim)
                        TextField("8421", text: $joinPort)
                            .font(.mono(13))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                }

                Section("Credentials") {
                    HStack {
                        Text("Invite Token")
                            .font(.mono(13))
                            .foregroundStyle(Color.consoleDim)
                        TextField("optional", text: $joinToken)
                            .font(.mono(13))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Text("Fleet Key")
                            .font(.mono(13))
                            .foregroundStyle(Color.consoleDim)
                        SecureField("optional", text: $joinFleetKey)
                            .font(.mono(13))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Trust") {
                    Picker("Trust Level", selection: $joinTrust) {
                        ForEach(NetworkMembership.TrustLevel.allCases) { level in
                            VStack(alignment: .leading) {
                                Text(level.displayName)
                            }
                            .tag(level)
                        }
                    }
                    .font(.mono(13))

                    Text(joinTrust.description)
                        .font(.mono(10))
                        .foregroundStyle(Color.consoleDim)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.voidBlack)
            .navigationTitle("Join Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showJoinSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        let membership = node.networkRegistry.join(
                            name: joinName,
                            bootstrapHost: joinHost,
                            bootstrapPort: Int(joinPort) ?? 8421,
                            inviteToken: joinToken.isEmpty ? nil : joinToken,
                            fleetKey: joinFleetKey.isEmpty ? nil : joinFleetKey,
                            trustLevel: joinTrust
                        )
                        // Start participating in the new network immediately.
                        Task { await node.connectMembership(membership) }
                        showJoinSheet = false
                        joinName = ""
                        joinHost = ""
                        joinToken = ""
                        joinFleetKey = ""
                    }
                    .disabled(joinName.isEmpty || joinHost.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}

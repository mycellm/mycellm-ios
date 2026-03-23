import SwiftUI

struct PeersView: View {
    @Environment(NodeService.self) private var node
    @State private var showJoinSheet = false
    @State private var joinName = ""
    @State private var joinHost = ""
    @State private var joinPort = "8421"
    @State private var joinToken = ""
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
            .sheet(isPresented: $showJoinSheet) {
                joinNetworkSheet
            }
        }
    }

    // MARK: - Networks

    private var networksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Networks", count: node.networkRegistry.memberships.count)
                Spacer()
                if node.networkRegistry.canJoinNewNetworks {
                    Button {
                        showJoinSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12))
                            Text("Join")
                                .font(.mono(11, weight: .medium))
                        }
                        .foregroundStyle(Color.sporeGreen)
                    }
                }
            }

            ForEach(node.networkRegistry.memberships) { membership in
                networkCard(membership)
            }

            if !node.networkRegistry.canJoinNewNetworks {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
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
                    .font(.system(size: 14))
                    .foregroundStyle(membership.id == "public" ? Color.relayBlue : Color.poisonPurple)

                VStack(alignment: .leading, spacing: 2) {
                    Text(membership.name)
                        .font(.mono(13, weight: .semibold))
                        .foregroundStyle(Color.consoleText)

                    Text(membership.bootstrapHost + ":" + String(membership.bootstrapPort))
                        .font(.mono(10))
                        .foregroundStyle(Color.consoleDim)
                }

                Spacer()

                // Connection status (for public, use node's bootstrap state)
                if membership.id == "public" {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bootstrapDotColor)
                            .frame(width: 6, height: 6)
                        Text(node.bootstrapState.rawValue)
                            .font(.mono(9))
                            .foregroundStyle(Color.consoleDim)
                        if node.bootstrapTransport != .none {
                            Text(node.bootstrapTransport.rawValue)
                                .font(.mono(8))
                                .foregroundStyle(Color.consoleDim)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.consoleDim.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    Circle()
                        .fill(Color.consoleDim)
                        .frame(width: 6, height: 6)
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
                            .font(.system(size: 8))
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

                // Leave button (not for public)
                if membership.id != "public" {
                    Button {
                        node.networkRegistry.leave(networkId: membership.id)
                    } label: {
                        Text("Leave")
                            .font(.mono(10))
                            .foregroundStyle(Color.computeRed)
                    }
                }
            }

            // Error
            if membership.id == "public", let error = node.bootstrapError {
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
    }

    private func trustBadge(_ level: NetworkMembership.TrustLevel) -> some View {
        let (color, icon): (Color, String) = switch level {
        case .strict: (Color.sporeGreen, "checkmark.shield.fill")
        case .relaxed: (Color.ledgerGold, "shield.fill")
        case .honor: (Color.consoleDim, "heart.fill")
        }
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(level.rawValue)
                .font(.mono(9))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }

    private var bootstrapDotColor: Color {
        switch node.bootstrapState {
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
            SectionHeader(title: "Peers", count: 0)

            EmptyState(message: "No connected peers", icon: "person.2")
        }
        .padding(.horizontal)
    }

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
                }

                Section("Trust") {
                    Picker("Trust Level", selection: $joinTrust) {
                        ForEach(NetworkMembership.TrustLevel.allCases) { level in
                            VStack(alignment: .leading) {
                                Text(level.rawValue)
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
                        let _ = node.networkRegistry.join(
                            name: joinName,
                            bootstrapHost: joinHost,
                            bootstrapPort: Int(joinPort) ?? 8421,
                            inviteToken: joinToken.isEmpty ? nil : joinToken,
                            trustLevel: joinTrust
                        )
                        showJoinSheet = false
                        joinName = ""
                        joinHost = ""
                        joinToken = ""
                    }
                    .disabled(joinName.isEmpty || joinHost.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

import SwiftUI

struct PeersView: View {
    @Environment(NodeService.self) private var node
    @State private var peerManager = PeerManager()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Network mode selector
                    modeSelector

                    // Bootstrap status
                    bootstrapStatus

                    // Connected peers
                    peersSection
                }
                .padding(.vertical)
            }
            .background(Color.voidBlack)
            .navigationTitle("Network")
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode")
                .font(.mono(13, weight: .semibold))
                .foregroundStyle(Color.consoleDim)

            ForEach(NetworkMode.allCases) { mode in
                Button {
                    node.setNetworkMode(mode)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 16))
                            .foregroundStyle(node.networkMode == mode ? Color.sporeGreen : Color.consoleDim)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.mono(13, weight: .medium))
                                .foregroundStyle(Color.consoleText)
                            Text(mode.description)
                                .font(.mono(10))
                                .foregroundStyle(Color.consoleDim)
                        }

                        Spacer()

                        if node.networkMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.sporeGreen)
                        }
                    }
                    .padding(12)
                    .background(node.networkMode == mode ? Color.sporeGreen.opacity(0.08) : Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(node.networkMode == mode ? Color.sporeGreen.opacity(0.3) : Color.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private var bootstrapStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bootstrap")
                .font(.mono(13, weight: .semibold))
                .foregroundStyle(Color.consoleDim)

            HStack(spacing: 12) {
                Circle()
                    .fill(node.networkMode == .standalone ? Color.consoleDim : Color.ledgerGold)
                    .frame(width: 8, height: 8)

                Text(node.networkMode == .standalone ? "Disabled (standalone mode)" : "bootstrap.mycellm.dev:8421")
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleText)

                Spacer()

                if node.networkMode != .standalone {
                    Text("Phase 4")
                        .font(.mono(9))
                        .foregroundStyle(Color.consoleDim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.consoleDim.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(12)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal)
    }

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Peers", count: peerManager.connectedCount)

            if peerManager.peers.isEmpty {
                EmptyState(message: "No connected peers", icon: "person.2")
            } else {
                ForEach(peerManager.peers) { peer in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(peer.peerId.prefix(16)) + "…")
                                .font(.mono(12, weight: .medium))
                                .foregroundStyle(Color.consoleText)
                            HStack(spacing: 8) {
                                Text(peer.role)
                                    .font(.mono(10))
                                    .foregroundStyle(Color.consoleDim)
                                if !peer.models.isEmpty {
                                    Text("\(peer.models.count) models")
                                        .font(.mono(10))
                                        .foregroundStyle(Color.sporeGreen)
                                }
                            }
                        }

                        Spacer()

                        if let latency = peer.latencyMs {
                            Text(String(format: "%.0fms", latency))
                                .font(.mono(11))
                                .foregroundStyle(latency < 100 ? Color.sporeGreen : latency < 500 ? Color.ledgerGold : Color.computeRed)
                        }
                    }
                    .padding(12)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(.horizontal)
    }
}

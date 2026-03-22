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

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(bootstrapDotColor)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.networkMode == .standalone
                            ? "Disabled (standalone mode)"
                            : Preferences.shared.bootstrapHost + ":" + String(Preferences.shared.quicPort))
                            .font(.mono(12))
                            .foregroundStyle(Color.consoleText)

                        if node.networkMode != .standalone {
                            HStack(spacing: 6) {
                                Text(node.bootstrapState.rawValue)
                                    .font(.mono(10))
                                    .foregroundStyle(bootstrapDotColor)
                                if node.bootstrapTransport != .none {
                                    Text(node.bootstrapTransport.rawValue)
                                        .font(.mono(9))
                                        .foregroundStyle(Color.consoleDim)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.consoleDim.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    Spacer()

                    if node.bootstrapState == .connected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.sporeGreen)
                    }
                }

                if let error = node.bootstrapError {
                    Text(error)
                        .font(.mono(9))
                        .foregroundStyle(Color.computeRed)
                }
            }
            .padding(12)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal)
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

import SwiftUI

struct DashboardView: View {
    @Environment(NodeService.self) private var node

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        Image("MycellmLockup")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 32)
                        Spacer()
                    }
                    .padding(.horizontal)

                    nodeStatusHeader
                    metricCards
                    firstRunNudge
                    nodeToggle
                    activityFeed
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }
            .background(Color.voidBlack)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var metricCards: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ], spacing: 12) {
            MetricCard(
                title: "Inference",
                value: "\(node.stats.totalInferences)",
                subtitle: "total requests",
                color: .computeRed,
                icon: "brain"
            )
            MetricCard(
                title: "Network",
                value: "\(node.connection.connectedPeers)",
                subtitle: "peers",
                color: .relayBlue,
                icon: "network"
            )
            MetricCard(
                title: "Models",
                value: "\(node.loadedModels)",
                subtitle: "loaded",
                color: .sporeGreen,
                icon: "cube.box"
            )
            MetricCard(
                title: "Credits",
                value: String(format: "%.2f", node.stats.creditBalance),
                subtitle: "balance",
                color: .ledgerGold,
                icon: "dollarsign.circle"
            )
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var firstRunNudge: some View {
        if node.modelManager.localFiles.isEmpty {
            HStack(spacing: 12) {
                Image("MycellmLogo-red")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get Started")
                        .font(.mono(13, weight: .semibold))
                        .foregroundStyle(Color.consoleText)
                    Text("Download a model from the Models tab to start chatting on-device and contributing to the network.")
                        .font(.mono(11))
                        .foregroundStyle(Color.consoleDim)
                }
            }
            .padding(14)
            .background(Color.sporeGreen.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.sporeGreen.opacity(0.2), lineWidth: 1))
            .padding(.horizontal)
        }
    }

    private var nodeStatusHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(node.isRunning ? Color.sporeGreen : Color.computeRed)
                .frame(width: 12, height: 12)
                .shadow(color: node.isRunning ? Color.sporeGreen.opacity(0.6) : .clear, radius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.nodeName)
                    .font(.mono(16, weight: .semibold))
                    .foregroundStyle(Color.consoleText)
                Text(node.peerId.isEmpty ? "No identity" : String(node.peerId.prefix(16)) + "…")
                    .font(.mono(11))
                    .foregroundStyle(Color.consoleDim)
            }

            Spacer()

            if node.networkMode != .standalone && node.isRunning {
                bootstrapBadge
            }

            Text(node.networkMode.displayName)
                .font(.mono(11, weight: .medium))
                .foregroundStyle(Color.relayBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.relayBlue.opacity(0.15), in: Capsule())
        }
        .padding(.horizontal)
    }

    private var bootstrapBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(bootstrapStatusColor)
                .frame(width: 6, height: 6)
            Text(node.connection.bootstrapState.displayName)
                .font(.mono(9))
                .foregroundStyle(Color.consoleDim)
            if node.connection.bootstrapTransport != .none {
                Text(node.connection.bootstrapTransport.displayName)
                    .font(.mono(8))
                    .foregroundStyle(Color.consoleDim)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.cardBackground)
        .clipShape(Capsule())
    }

    private var bootstrapStatusColor: Color {
        switch node.connection.bootstrapState {
        case .connected: Color.sporeGreen
        case .connecting, .handshaking, .reconnecting: Color.ledgerGold
        case .fallbackHTTP: Color.relayBlue
        case .disconnected: Color.consoleDim
        case .failed: Color.computeRed
        }
    }

    private var nodeToggle: some View {
        Button {
            Task {
                if node.isRunning { await node.stop() } else { await node.start() }
            }
        } label: {
            HStack {
                Image(systemName: node.isRunning ? "stop.fill" : "play.fill")
                Text(node.isRunning ? "Stop Node" : "Start Node")
                    .font(.mono(14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(node.isRunning ? Color.computeRed.opacity(0.2) : Color.sporeGreen.opacity(0.2))
            .foregroundStyle(node.isRunning ? Color.computeRed : Color.sporeGreen)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(node.isRunning ? Color.computeRed.opacity(0.3) : Color.sporeGreen.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(.horizontal)
    }

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity")
                .font(.mono(13, weight: .semibold))
                .foregroundStyle(Color.consoleDim)
                .padding(.bottom, 4)

            if node.stats.recentEvents.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.consoleDim.opacity(0.5))
                        Text("No recent activity")
                            .font(.mono(11))
                            .foregroundStyle(Color.consoleDim)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(node.stats.recentEvents.prefix(20)) { event in
                        ActivityRow(event: event)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}

// MARK: - Activity Row (extracted to reduce type-checker load)

private struct ActivityRow: View {
    let event: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 14, height: 14)
            Text(event.description)
                .font(.mono(11))
                .foregroundStyle(Color.consoleText)
            Spacer()
            Text(event.relativeTime)
                .font(.mono(9))
                .foregroundStyle(Color.consoleDim.opacity(0.6))
                .layoutPriority(1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var color: Color {
        switch event.kind {
        case .nodeStarted: .sporeGreen
        case .nodeStopped: .computeRed
        case .networkModeChanged: .relayBlue
        case .modelLoaded: .sporeGreen
        case .modelUnloaded: .ledgerGold
        case .inferenceCompleted: .computeRed
        case .httpServerStarted: .relayBlue
        case .creditEarned: .ledgerGold
        case .creditSpent: .ledgerGold
        case .peerConnected: .sporeGreen
        case .peerDisconnected: .consoleDim
        case .networkInfo: .relayBlue
        case .relayDiscovered: .poisonPurple
        case .error: .computeRed
        }
    }
}

// MARK: - Metric Card

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                Text(title)
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(Color.consoleDim)
            }

            Text(value)
                .font(.mono(28, weight: .bold))
                .foregroundStyle(color)

            Text(subtitle)
                .font(.mono(10))
                .foregroundStyle(Color.consoleDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
    }
}

import SwiftUI

struct DashboardView: View {
    @Environment(NodeService.self) private var node

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Logo lockup
                    HStack {
                        Image("MycellmLockup")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 32)
                        Spacer()
                    }
                    .padding(.horizontal)

                    // Node status header
                    nodeStatusHeader

                    // Metric cards (2x2 grid)
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ], spacing: 12) {
                        MetricCard(
                            title: "Inference",
                            value: "\(node.totalInferences)",
                            subtitle: "total requests",
                            color: .computeRed,
                            icon: "brain"
                        )
                        MetricCard(
                            title: "Network",
                            value: "\(node.connectedPeers)",
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
                            value: String(format: "%.1f", node.creditBalance),
                            subtitle: "balance",
                            color: .ledgerGold,
                            icon: "dollarsign.circle"
                        )
                    }
                    .padding(.horizontal)

                    // Start/Stop toggle
                    nodeToggle

                    // Activity feed
                    activityFeed
                }
                .padding(.vertical)
            }
            .background(Color.voidBlack)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var nodeStatusHeader: some View {
        HStack(spacing: 12) {
            // Pulsing status dot
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

            Text(node.networkMode.displayName)
                .font(.mono(11, weight: .medium))
                .foregroundStyle(Color.relayBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.relayBlue.opacity(0.15), in: Capsule())
        }
        .padding(.horizontal)
    }

    private var nodeToggle: some View {
        Button {
            Task {
                if node.isRunning {
                    await node.stop()
                } else {
                    await node.start()
                }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.mono(13, weight: .semibold))
                .foregroundStyle(Color.consoleDim)
                .padding(.horizontal)

            if node.recentEvents.isEmpty {
                Text("No recent activity")
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(node.recentEvents.prefix(20)) { event in
                    HStack(spacing: 10) {
                        Image(systemName: event.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.consoleDim)
                            .frame(width: 20)

                        Text(event.description)
                            .font(.mono(12))
                            .foregroundStyle(Color.consoleText)

                        Spacer()

                        Text(event.timestamp, style: .relative)
                            .font(.mono(10))
                            .foregroundStyle(Color.consoleDim)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
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

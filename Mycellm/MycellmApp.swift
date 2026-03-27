import SwiftUI
import SwiftData

// MARK: - Screensaver Environment Key

private struct ShowScreenSaverKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var showScreenSaver: Binding<Bool> {
        get { self[ShowScreenSaverKey.self] }
        set { self[ShowScreenSaverKey.self] = newValue }
    }
}

@main
struct MycellmApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Root view that shows splash immediately, then loads heavy resources.
struct RootView: View {
    @State private var phase: LaunchPhase = .splash
    @State private var nodeService: NodeService?
    @State private var modelContainer: ModelContainer?
    @State private var showScreenSaver = false
    @State private var lastInteraction = Date()

    enum LaunchPhase {
        case splash
        case ready
    }

    var body: some View {
        ZStack {
            switch phase {
            case .splash:
                SplashView()

            case .ready:
                if let node = nodeService, let container = modelContainer {
                    ZStack {
                        MainTabView()
                            .environment(node)
                            .environment(\.showScreenSaver, $showScreenSaver)
                            .modelContainer(container)
                            .scrollDismissesKeyboard(.interactively)

                        if showScreenSaver {
                            ScreenSaverView(
                                onTap: {
                                    showScreenSaver = false
                                    lastInteraction = Date()
                                },
                                nodeName: node.nodeName,
                                localIP: localIPAddress() ?? "",
                                connectedPeers: node.connection.connectedPeers,
                                loadedModels: node.modelManager.loadedModels.count,
                                tokensPerSec: 0
                            )
                        }
                    }
                    // Task-based idle check + receipt flush (replaces Timer.publish)
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(30))
                            guard !Task.isCancelled else { break }
                            checkIdle(node: node)
                            await node.flushReceipts()
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                        let taskId = UIApplication.shared.beginBackgroundTask {}
                        Task {
                            try? await Task.sleep(for: .seconds(25))
                            UIApplication.shared.endBackgroundTask(taskId)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                        applyKeepAwake(node: node)
                        lastInteraction = Date()
                    }
                    .onChange(of: node.isRunning) { _, _ in applyKeepAwake(node: node) }
                }
            }
        }
        .task {
            async let node = await MainActor.run { NodeService() }
            async let container = await MainActor.run {
                try? ModelContainer(for: StoredModel.self, ChatMessage.self, ChatSession.self, ActivityEvent.self)
            }

            let n = await node
            let c = await container

            await MainActor.run { KeyboardWarmer.warm() }

            await n.modelManager.autoLoadLastModel()

            Task { await n.start() }

            try? await Task.sleep(for: .seconds(2.0))

            nodeService = n
            modelContainer = c
            phase = .ready
        }
    }

    private func applyKeepAwake(node: NodeService) {
        UIApplication.shared.isIdleTimerDisabled = Preferences.shared.keepAwake && node.isRunning
    }

    private func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
        }
        return address
    }

    private func checkIdle(node: NodeService) {
        let prefs = Preferences.shared
        guard prefs.keepAwake && prefs.screenSaverEnabled && node.isRunning else {
            if showScreenSaver { showScreenSaver = false }
            return
        }
        if Date().timeIntervalSince(lastInteraction) / 60.0 >= Double(prefs.screenSaverDelay) && !showScreenSaver {
            showScreenSaver = true
        }
    }
}

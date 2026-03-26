import SwiftUI
import SwiftData

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
                            .modelContainer(container)
                            .scrollDismissesKeyboard(.interactively)

                        if showScreenSaver {
                            ScreenSaverView {
                                showScreenSaver = false
                                lastInteraction = Date()
                            }
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

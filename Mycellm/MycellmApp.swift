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
                    .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                        checkIdle(node: node)
                        // Submit pending receipts to bootstrap
                        Task { await node.flushReceipts() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                        // Request background time to finish in-progress inference
                        let taskId = UIApplication.shared.beginBackgroundTask {
                            // Expiration handler — clean up
                        }
                        Task {
                            // Give in-progress inference 25s to complete
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
            // Heavy init happens here — splash is already visible
            async let node = await MainActor.run { NodeService() }
            async let container = await MainActor.run {
                try? ModelContainer(for: StoredModel.self, ChatMessage.self, ChatSession.self, ActivityEvent.self)
            }

            let n = await node
            let c = await container

            // Pre-warm keyboard during splash so first tap is instant
            await MainActor.run { KeyboardWarmer.warm() }

            // Auto-load last model
            await n.modelManager.autoLoadLastModel()

            // Auto-start the node
            await n.start()

            // Wait for boot text to finish
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

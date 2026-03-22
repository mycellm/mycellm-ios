import SwiftUI
import SwiftData

@main
struct MycellmApp: App {
    @State private var nodeService = NodeService()
    @State private var showScreenSaver = false
    @State private var showSplash = true
    @State private var lastInteraction = Date()

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainTabView()
                    .environment(nodeService)
                    .preferredColorScheme(.dark)
                    .opacity(showSplash ? 0 : 1)

                if showScreenSaver {
                    ScreenSaverView {
                        showScreenSaver = false
                        resetIdleTimer()
                    }
                    .transition(.opacity)
                }

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: showSplash)
            .animation(.easeInOut(duration: 1.0), value: showScreenSaver)
            .task {
                // Give the app time to load views, then fade out splash
                try? await Task.sleep(for: .seconds(1.5))
                showSplash = false
            }
            .onAppear { applyKeepAwake() }
            .onChange(of: nodeService.isRunning) { _, _ in applyKeepAwake() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                // no-op
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                applyKeepAwake()
                resetIdleTimer()
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                checkIdle()
            }
        }
        .modelContainer(for: [
            StoredModel.self,
            ChatMessage.self,
            ChatSession.self,
            ActivityEvent.self,
        ])
    }

    private func applyKeepAwake() {
        let prefs = Preferences.shared
        let shouldKeepAwake = prefs.keepAwake && nodeService.isRunning
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
    }

    private func resetIdleTimer() {
        lastInteraction = Date()
    }

    private func checkIdle() {
        let prefs = Preferences.shared
        guard prefs.keepAwake && prefs.screenSaverEnabled && nodeService.isRunning else {
            if showScreenSaver { showScreenSaver = false }
            return
        }
        let idleMinutes = Date().timeIntervalSince(lastInteraction) / 60.0
        if idleMinutes >= Double(prefs.screenSaverDelay) && !showScreenSaver {
            showScreenSaver = true
        }
    }
}

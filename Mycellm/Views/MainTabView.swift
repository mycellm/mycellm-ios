import SwiftUI

/// 5-tab root navigation.
struct MainTabView: View {
    // Persist the last-opened tab so reopening the app returns the user to
    // where they were. First launch defaults to Chat (tag 1) — it's the
    // primary action and works out of the box (Network mode → public
    // bootstrap), so it's the strongest first impression and return-to.
    @AppStorage("lastSelectedTab") private var selectedTab = 1

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent")
                }
                .tag(0)

            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(1)

            ModelsView()
                .tabItem {
                    Label("Models", systemImage: "cube.box")
                }
                .tag(2)

            PeersView()
                .tabItem {
                    Label("Network", systemImage: "network")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(4)
        }
        .tint(Color.sporeGreen)
    }
}

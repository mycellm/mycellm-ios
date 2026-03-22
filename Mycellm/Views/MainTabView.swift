import SwiftUI

/// 5-tab root navigation.
struct MainTabView: View {
    @State private var selectedTab = 0

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

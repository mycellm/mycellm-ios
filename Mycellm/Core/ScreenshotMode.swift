import Foundation
import SwiftData

/// App Store screenshot / demo mode.
///
/// When active, the app seeds rich, realistic mock data — a populated
/// Dashboard (running node, credits, activity), an on-device Chat
/// conversation, loaded Models, and Network credits — so marketing captures
/// look alive without depending on live inference or a reachable network.
///
/// Activate by launching the app with the `-screenshotMode YES` launch
/// argument (Maestro `launchArguments: { screenshotMode: true }`) or with the
/// environment variable `SCREENSHOT_MODE=1`.
///
/// In **Release** builds this is entirely inert: `isActive` is compiled to
/// `false` and every fixture method is `#if DEBUG`-gated, so no mock-data path
/// ships in the App Store binary.
enum ScreenshotMode {
    static var isActive: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SCREENSHOT_MODE"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "screenshotMode")
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Mock connected peers for the Network screen marketing capture.
    struct MockPeer: Identifiable {
        let id = UUID()
        let name: String
        let device: String
        let model: String
        let tps: Double
        let net: String
    }

    static let mockPeers: [MockPeer] = [
        .init(name: "studio-m5max", device: "Mac Studio · M5 Max", model: "Qwen2.5-32B", tps: 78.4, net: "Homelab"),
        .init(name: "mac-mini", device: "Mac mini · M4", model: "Llama-3.2-3B", tps: 61.2, net: "Homelab"),
        .init(name: "ipad-pro", device: "iPad Pro · M4", model: "Gemma-2-9B", tps: 44.0, net: "Homelab"),
        .init(name: "aurora", device: "MacBook Pro · M1 Max", model: "Qwen2.5-Coder-7B", tps: 33.5, net: "Public"),
        .init(name: "calm-grove", device: "RTX 4090 rig", model: "GLM-4-9B", tps: 121.0, net: "Public"),
    ]

    private static let demoTitle = "On-device chat"

    /// Seed a showcase on-device conversation into the chat store so the Chat
    /// tab opens onto a finished, product-telling exchange. Idempotent across
    /// repeated capture runs on a reused simulator.
    @MainActor
    static func seedChat(into container: ModelContainer) {
        let ctx = container.mainContext
        if let existing = try? ctx.fetch(FetchDescriptor<ChatSession>()),
           existing.contains(where: { $0.title == demoTitle }) {
            return
        }

        // Trusted-device story: the phone runs a big model by routing to a
        // device the user trusts (their Mac Studio) on their private network.
        let bigModel = "Qwen2.5-32B-Instruct"
        let trustedNode = "studio-m5max"
        let session = ChatSession(title: demoTitle, model: bigModel)
        ctx.insert(session)

        let now = Date()
        func add(_ role: String, _ content: String, tps: Double = 0, tokens: Int = 0, offset: TimeInterval) {
            let m = ChatMessage(
                role: role,
                content: content,
                model: role == "assistant" ? bigModel : "",
                routedVia: role == "assistant" ? "network" : "local"
            )
            m.timestamp = now.addingTimeInterval(offset)
            m.tokensPerSecond = tps
            m.tokenCount = tokens
            m.sourceNode = role == "assistant" ? trustedNode : ""
            m.session = session
            ctx.insert(m)
        }

        add("user", "Can my iPhone run a 32B model?", offset: -240)
        add("assistant",
            "On its own, no — but this reply is served by your Mac Studio (M5 Max) on your private network. Your phone stays light; a device you trust does the heavy lifting. No cloud involved.",
            tps: 78.4, tokens: 56, offset: -236)
        add("user", "And when I'm away from home?", offset: -120)
        add("assistant",
            "Switch to On-Device for a smaller local model, or tap the public network. Same chat — you choose where it runs.",
            tps: 75.9, tokens: 30, offset: -116)

        session.updatedAt = now
        try? ctx.save()
    }
    #endif
}

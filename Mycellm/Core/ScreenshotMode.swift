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

        let session = ChatSession(title: demoTitle, model: "Qwen2.5-3B-Instruct")
        ctx.insert(session)

        let now = Date()
        func add(_ role: String, _ content: String, tps: Double = 0, tokens: Int = 0, offset: TimeInterval) {
            let m = ChatMessage(
                role: role,
                content: content,
                model: role == "assistant" ? "Qwen2.5-3B-Instruct" : "",
                routedVia: "local"
            )
            m.timestamp = now.addingTimeInterval(offset)
            m.tokensPerSecond = tps
            m.tokenCount = tokens
            m.sourceNode = role == "assistant" ? "this device" : ""
            m.session = session
            ctx.insert(m)
        }

        add("user", "What can you run entirely on-device?", offset: -240)
        add("assistant",
            "Right now I'm replying from Qwen2.5-3B running locally on this iPhone — no cloud, no account, fully private. For heavier models, mycellm can route to a peer on your network and split the work.",
            tps: 41.2, tokens: 48, offset: -236)
        add("user", "Does it cost anything?", offset: -120)
        add("assistant",
            "No. You earn credits by sharing spare compute with the network, and spend them when you borrow it. It's all peer-to-peer.",
            tps: 39.7, tokens: 34, offset: -116)

        session.updatedAt = now
        try? ctx.save()
    }
    #endif
}

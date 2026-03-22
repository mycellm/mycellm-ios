import SwiftUI
import SwiftData

/// Chat routing: where inference runs.
enum ChatRoute: String, CaseIterable, Identifiable {
    case network = "Network"
    case onDevice = "On-Device"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .network: "globe"
        case .onDevice: "ipad"
        }
    }
}

struct ChatView: View {
    @Environment(NodeService.self) private var node
    @State private var inputText = ""
    @State private var messages: [DisplayMessage] = []
    @State private var route: ChatRoute = .network
    @State private var isGenerating = false
    @State private var streamTask: Task<Void, Never>?
    @State private var remoteClient = RemoteClient()

    struct DisplayMessage: Identifiable {
        let id = UUID()
        let role: String
        var content: String
        var tokenCount: Int
        let routedVia: String
        let timestamp: Date
        var isStreaming: Bool = false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Route toggle + model
                routeBar

                Divider().background(Color.cardBorder)

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: messages.last?.content) { _, _ in
                        scrollToBottom(proxy)
                    }
                }

                Divider().background(Color.cardBorder)

                // Input bar
                inputBar
            }
            .background(Color.voidBlack)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { configureRemoteClient() }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Route Bar

    private var routeBar: some View {
        HStack(spacing: 12) {
            // Route toggle
            HStack(spacing: 0) {
                ForEach(ChatRoute.allCases) { r in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { route = r }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: r.icon)
                                .font(.system(size: 10))
                            Text(r.rawValue)
                                .font(.mono(11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(route == r ? routeColor.opacity(0.2) : Color.clear)
                        .foregroundStyle(route == r ? routeColor : Color.consoleDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))

            Spacer()

            // Status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.mono(10))
                    .foregroundStyle(Color.consoleDim)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.cardBackground)
    }

    private var routeColor: Color {
        route == .network ? .relayBlue : .sporeGreen
    }

    private var statusColor: Color {
        switch route {
        case .network:
            return Preferences.shared.remoteEndpoint.isEmpty ? .computeRed : .sporeGreen
        case .onDevice:
            return .ledgerGold
        }
    }

    private var statusText: String {
        switch route {
        case .network:
            let endpoint = Preferences.shared.remoteEndpoint
            if endpoint.isEmpty { return "No endpoint" }
            let model = Preferences.shared.remoteModel
            return model.isEmpty ? endpoint : model
        case .onDevice:
            return "No model loaded"
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message…", text: $inputText, axis: .vertical)
                .font(.mono(14))
                .foregroundStyle(Color.consoleText)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit { sendMessage() }

            Button {
                if isGenerating {
                    stopGenerating()
                } else {
                    sendMessage()
                }
            } label: {
                Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(inputText.isEmpty && !isGenerating ? Color.consoleDim : routeColor)
            }
            .disabled(inputText.isEmpty && !isGenerating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.cardBackground)
    }

    // MARK: - Send

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        messages.append(DisplayMessage(
            role: "user", content: text, tokenCount: 0,
            routedVia: "local", timestamp: Date()
        ))

        switch route {
        case .network:
            sendNetworkMessage()
        case .onDevice:
            messages.append(DisplayMessage(
                role: "assistant",
                content: "On-device inference requires a loaded model. Download one from the Models tab, or switch to Network mode.",
                tokenCount: 0, routedVia: "local", timestamp: Date()
            ))
        }
    }

    private func sendNetworkMessage() {
        isGenerating = true

        let placeholder = DisplayMessage(
            role: "assistant", content: "", tokenCount: 0,
            routedVia: "network", timestamp: Date(), isStreaming: true
        )
        messages.append(placeholder)
        let responseIdx = messages.count - 1

        let chatMessages = messages
            .dropLast()
            .map { RemoteClient.ChatMessage(role: $0.role, content: $0.content) }

        let model = Preferences.shared.remoteModel.isEmpty
            ? "default"
            : Preferences.shared.remoteModel

        streamTask = Task {
            do {
                var tokenCount = 0
                for try await chunk in await remoteClient.stream(
                    model: model,
                    messages: Array(chatMessages)
                ) {
                    messages[responseIdx].content += chunk
                    tokenCount += 1
                }
                messages[responseIdx].tokenCount = tokenCount
                messages[responseIdx].isStreaming = false
            } catch {
                if messages[responseIdx].content.isEmpty {
                    messages[responseIdx].content = "Error: \(error.localizedDescription)"
                }
                messages[responseIdx].isStreaming = false
            }
            isGenerating = false
        }
    }

    private func stopGenerating() {
        streamTask?.cancel()
        streamTask = nil
        isGenerating = false
        if let last = messages.last, last.isStreaming {
            messages[messages.count - 1].isStreaming = false
        }
    }

    private func configureRemoteClient() {
        let prefs = Preferences.shared
        Task {
            await remoteClient.configure(
                endpoint: prefs.remoteEndpoint,
                apiKey: prefs.remoteApiKey
            )
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatView.DisplayMessage

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content.isEmpty && message.isStreaming ? "…" : message.content)
                    .font(.mono(13))
                    .foregroundStyle(Color.consoleText)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    if message.tokenCount > 0 {
                        Text("\(message.tokenCount) tokens")
                            .font(.mono(9))
                            .foregroundStyle(Color.consoleDim)
                    }
                    if !isUser && message.routedVia == "network" {
                        HStack(spacing: 2) {
                            Image(systemName: "globe")
                                .font(.system(size: 8))
                            Text("network")
                                .font(.mono(9))
                        }
                        .foregroundStyle(Color.relayBlue)
                    }
                    if message.isStreaming {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .padding(12)
            .background(isUser ? Color.sporeGreen.opacity(0.15) : Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

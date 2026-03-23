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
        var routedVia: String
        var sourceNode: String = ""  // hashed node ID for attribution
        let timestamp: Date
        var isStreaming: Bool = false
        var isError: Bool = false
        var startTime: Date = Date()
        var endTime: Date?
        var tokensPerSecond: Double = 0

        var durationMs: Int? {
            guard let end = endTime else { return nil }
            return Int(end.timeIntervalSince(startTime) * 1000)
        }
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
                                MessageBubble(message: msg) {
                                    // Retry: resend the last user message
                                    if let lastUser = messages.last(where: { $0.role == "user" }) {
                                        messages.removeAll { $0.isError }
                                        inputText = lastUser.content
                                        sendMessage()
                                    }
                                }
                                .id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showEndpointDetail = false

    // MARK: - Route Bar

    private var routeBar: some View {
        VStack(spacing: 4) {
            // Lockup centered
            Image("MycellmLockup")
                .resizable()
                .scaledToFit()
                .frame(height: 16)

            // Controls row
            HStack(spacing: 6) {
                // Route toggle — compact
                ForEach(ChatRoute.allCases) { r in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { route = r }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: r.icon)
                                .font(.system(size: 9))
                            Text(r.rawValue)
                                .font(.mono(10, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(route == r ? routeColor.opacity(0.2) : Color.cardBackground)
                        .foregroundStyle(route == r ? routeColor : Color.consoleDim)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(route == r ? routeColor.opacity(0.3) : Color.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Status — compact dot + short label, tap for detail
                Button {
                    showEndpointDetail.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusShort)
                            .font(.mono(9))
                            .foregroundStyle(Color.consoleDim)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showEndpointDetail) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(route == .network ? "Network Endpoint" : "On-Device")
                            .font(.mono(12, weight: .semibold))
                            .foregroundStyle(Color.consoleText)
                        Text(statusText)
                            .font(.mono(11))
                            .foregroundStyle(Color.consoleDim)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .frame(minWidth: 250)
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.cardBackground)
    }

    private var statusShort: String {
        switch route {
        case .network:
            if Preferences.shared.remoteEndpoint.isEmpty { return "No endpoint" }
            let model = Preferences.shared.remoteModel
            if !model.isEmpty { return model }
            return "Connected"
        case .onDevice:
            if let first = node.modelManager.loadedModels.first {
                // Truncate long model names
                let name = first.name
                return name.count > 20 ? String(name.prefix(18)) + "…" : name
            }
            return "No model"
        }
    }

    private var routeColor: Color {
        route == .network ? .relayBlue : .sporeGreen
    }

    private var statusColor: Color {
        switch route {
        case .network:
            return Preferences.shared.remoteEndpoint.isEmpty ? .computeRed : .sporeGreen
        case .onDevice:
            return node.modelManager.loadedModels.isEmpty ? .ledgerGold : .sporeGreen
        }
    }

    private var statusText: String {
        switch route {
        case .network:
            let endpoint = Preferences.shared.remoteEndpoint
            if endpoint.isEmpty { return "No endpoint — configure in Settings" }
            let model = Preferences.shared.remoteModel
            return model.isEmpty ? endpoint : model
        case .onDevice:
            if let first = node.modelManager.loadedModels.first {
                return first.name
            }
            return node.modelManager.localFiles.isEmpty
                ? "No models — download from Models tab"
                : "\(node.modelManager.localFiles.count) on disk — select in Models tab"
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Type a message…", text: $inputText, prompt: Text("Type a message…").foregroundStyle(Color.consoleDim.opacity(0.8)), axis: .vertical)
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
            if node.modelManager.loadedModels.isEmpty {
                messages.append(DisplayMessage(
                    role: "assistant",
                    content: node.modelManager.localFiles.isEmpty
                        ? "No models downloaded. Go to the Models tab to get one."
                        : "No model selected. Go to the Models tab and select one.",
                    tokenCount: 0, routedVia: "local", timestamp: Date()
                ))
            } else {
                sendLocalMessage()
            }
        }
    }

    private func sendLocalMessage() {
        isGenerating = true

        var placeholder = DisplayMessage(
            role: "assistant", content: "", tokenCount: 0,
            routedVia: "on-device", timestamp: Date(), isStreaming: true
        )
        placeholder.startTime = Date()
        messages.append(placeholder)
        let responseIdx = messages.count - 1

        let chatMessages = messages.dropLast().map { ["role": $0.role, "content": $0.content] }

        streamTask = Task {
            do {
                var tokenCount = 0
                let stream = await node.modelManager.engine.stream(
                    messages: Array(chatMessages)
                )
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    messages[responseIdx].content += chunk
                    tokenCount += 1
                }
                let endTime = Date()
                let elapsed = endTime.timeIntervalSince(messages[responseIdx].startTime)
                messages[responseIdx].tokenCount = tokenCount
                messages[responseIdx].endTime = endTime
                messages[responseIdx].tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
                messages[responseIdx].isStreaming = false
            } catch {
                if messages[responseIdx].content.isEmpty {
                    messages[responseIdx].content = "Error: \(error.localizedDescription)"
                }
                messages[responseIdx].endTime = Date()
                messages[responseIdx].isStreaming = false
            }
            isGenerating = false
        }
    }

    private func sendNetworkMessage() {
        isGenerating = true

        var placeholder = DisplayMessage(
            role: "assistant", content: "", tokenCount: 0,
            routedVia: "network", timestamp: Date(), isStreaming: true
        )
        placeholder.startTime = Date()
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
                var gotFirstToken = false

                // Timeout: 30s for first token, then no timeout during streaming
                let stream = await remoteClient.stream(
                    model: model,
                    messages: Array(chatMessages)
                )

                for try await chunk in stream {
                    if Task.isCancelled { break }
                    if !gotFirstToken {
                        gotFirstToken = true
                        messages[responseIdx].content = "" // clear "thinking" state
                    }
                    messages[responseIdx].content += chunk
                    tokenCount += 1
                }
                let endTime = Date()
                let elapsed = endTime.timeIntervalSince(messages[responseIdx].startTime)
                messages[responseIdx].tokenCount = tokenCount
                messages[responseIdx].endTime = endTime
                messages[responseIdx].tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
                messages[responseIdx].isStreaming = false
            } catch is CancellationError {
                messages[responseIdx].endTime = Date()
                messages[responseIdx].isStreaming = false
            } catch is CancellationError {
                messages[responseIdx].endTime = Date()
                messages[responseIdx].isStreaming = false
            } catch {
                let errMsg = error.localizedDescription
                messages[responseIdx].isStreaming = false
                messages[responseIdx].endTime = Date()

                // Try local fallback if network fails and a model is loaded
                if !node.modelManager.loadedModels.isEmpty {
                    messages[responseIdx].content = ""
                    messages[responseIdx].routedVia = "on-device"
                    messages[responseIdx].isStreaming = true
                    do {
                        var tokenCount = 0
                        let localMessages = chatMessages.map { ["role": $0.role, "content": $0.content] }
                        let localStream = await node.modelManager.engine.stream(messages: localMessages)
                        for try await chunk in localStream {
                            messages[responseIdx].content += chunk
                            tokenCount += 1
                        }
                        let endTime = Date()
                        messages[responseIdx].tokenCount = tokenCount
                        messages[responseIdx].endTime = endTime
                        messages[responseIdx].tokensPerSecond = endTime.timeIntervalSince(messages[responseIdx].startTime) > 0
                            ? Double(tokenCount) / endTime.timeIntervalSince(messages[responseIdx].startTime) : 0
                        messages[responseIdx].isStreaming = false
                    } catch {
                        messages[responseIdx].content = "Network failed, local fallback also failed: \(error.localizedDescription)"
                        messages[responseIdx].isError = true
                        messages[responseIdx].isStreaming = false
                    }
                } else {
                    if messages[responseIdx].content.isEmpty {
                        messages[responseIdx].content = errMsg
                    } else {
                        messages[responseIdx].content += "\n\n[Error: \(errMsg)]"
                    }
                    messages[responseIdx].isError = true
                }
            }
            isGenerating = false
        }

        // Connection timeout
        Task {
            try? await Task.sleep(for: .seconds(30))
            guard isGenerating,
                  messages.indices.contains(responseIdx),
                  messages[responseIdx].content.isEmpty else { return }
            messages[responseIdx].content = "Connection timed out."
            messages[responseIdx].isError = true
            messages[responseIdx].isStreaming = false
            stopGenerating()
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
    var onRetry: (() -> Void)? = nil

    var isUser: Bool { message.role == "user" }
    var isThinking: Bool { message.isStreaming && message.content.isEmpty }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if isThinking {
                    ThinkingIndicator()
                } else if isUser {
                    Text(message.content)
                        .font(.mono(13))
                        .foregroundStyle(Color.consoleText)
                        .textSelection(.enabled)
                } else {
                    // Render markdown for assistant messages
                    Text(LocalizedStringKey(message.content))
                        .font(.mono(13))
                        .foregroundStyle(Color.consoleText)
                        .textSelection(.enabled)
                        .tint(Color.relayBlue)
                }

                // Stats bar
                if !isUser && !isThinking {
                    HStack(spacing: 8) {
                        if message.isStreaming {
                            BlinkingCursor()
                        }

                        // Route badge
                        if message.routedVia == "network" {
                            HStack(spacing: 2) {
                                Image(systemName: "globe")
                                    .font(.system(size: 8))
                                Text("network")
                                    .font(.mono(9))
                            }
                            .foregroundStyle(Color.relayBlue)
                        } else if message.routedVia == "on-device" {
                            HStack(spacing: 2) {
                                Image(systemName: "ipad")
                                    .font(.system(size: 8))
                                Text("on-device")
                                    .font(.mono(9))
                            }
                            .foregroundStyle(Color.sporeGreen)
                        }

                        if message.tokenCount > 0 {
                            Text("\(message.tokenCount) tok")
                                .font(.mono(9))
                                .foregroundStyle(Color.consoleDim)
                        }

                        if message.tokensPerSecond > 0 {
                            Text(String(format: "%.1f t/s", message.tokensPerSecond))
                                .font(.mono(9))
                                .foregroundStyle(Color.consoleDim)
                        }

                        if let ms = message.durationMs {
                            Text(ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000))
                                .font(.mono(9))
                                .foregroundStyle(Color.consoleDim)
                        }
                    }
                }

                // Retry button for errors
                if message.isError, let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("Retry")
                                .font(.mono(10, weight: .medium))
                        }
                        .foregroundStyle(Color.relayBlue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.relayBlue.opacity(0.15))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(12)
            .background(isUser ? Color.sporeGreen.opacity(0.15) : message.isError ? Color.computeRed.opacity(0.08) : Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(message.isError ? RoundedRectangle(cornerRadius: 12).stroke(Color.computeRed.opacity(0.2), lineWidth: 1) : nil)

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

/// Animated thinking dots: ● ● ●
struct ThinkingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.consoleDim)
                    .frame(width: 6, height: 6)
                    .opacity(i <= phase ? 1.0 : 0.3)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 4
        }
    }
}

/// Blinking cursor while streaming
struct BlinkingCursor: View {
    @State private var visible = true
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("▊")
            .font(.mono(10))
            .foregroundStyle(Color.sporeGreen)
            .opacity(visible ? 1 : 0)
            .onReceive(timer) { _ in visible.toggle() }
    }
}

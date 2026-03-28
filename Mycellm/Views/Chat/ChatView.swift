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
    @Environment(\.modelContext) private var modelContext
    @State private var inputText = ""
    @State private var messages: [DisplayMessage] = []
    @State private var route: ChatRoute = ChatRoute(rawValue: Preferences.shared.chatRoute) ?? .network
    @State private var isGenerating = false
    @State private var streamTask: Task<Void, Never>?
    @State private var remoteClient = RemoteClient()
    @State private var guard_ = SensitiveDataGuard()
    @State private var scanResult = SensitiveDataGuard.ScanResult(matches: [], action: .allow, highestSeverity: nil)
    @State private var showSensitiveAlert = false
    @State private var scanTask: Task<Void, Never>?
    @AppStorage("chat_ai_disclaimer_dismissed") private var disclaimerDismissed = false
    @State private var showNewSessionConfirm = false

    // Session management
    @State private var currentSession: ChatSession?
    @State private var showSessionList = false
    @State private var isPrivateSession = false
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    /// In-memory message for UI rendering. Crash-safe: mutations use ID lookup, never raw index.
    struct DisplayMessage: Identifiable {
        let id: UUID
        let role: String
        var content: String
        var tokenCount: Int
        var routedVia: String
        var sourceNode: String = ""
        var modelUsed: String = ""
        let timestamp: Date
        var isStreaming: Bool = false
        var isError: Bool = false
        var startTime: Date = Date()
        var endTime: Date?
        var tokensPerSecond: Double = 0

        init(role: String, content: String, tokenCount: Int = 0, routedVia: String = "local",
             timestamp: Date = Date(), isStreaming: Bool = false) {
            self.id = UUID()
            self.role = role
            self.content = content
            self.tokenCount = tokenCount
            self.routedVia = routedVia
            self.timestamp = timestamp
            self.isStreaming = isStreaming
        }

        var durationMs: Int? {
            guard let end = endTime else { return nil }
            return Int(end.timeIntervalSince(startTime) * 1000)
        }
    }

    // MARK: - Safe message mutation

    /// Find message index by ID. Returns nil if message was removed.
    private func idx(for id: UUID) -> Int? {
        messages.firstIndex(where: { $0.id == id })
    }

    /// Safely mutate a message by ID. No-op if message is gone.
    /// Must run on MainActor since messages is @State.
    @MainActor private func mutate(_ id: UUID, _ block: (inout DisplayMessage) -> Void) {
        guard let i = idx(for: id) else { return }
        block(&messages[i])
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                routeBar

                Divider().background(Color.cardBorder)

                ScrollViewReader { proxy in
                    Group {
                        if messages.isEmpty {
                            emptyState
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                                        // Date divider
                                        if shouldShowDateDivider(at: index) {
                                            DateDivider(date: msg.timestamp)
                                        }

                                        MessageBubble(message: msg) {
                                            retryLastMessage()
                                        }
                                        .id(msg.id)
                                        .contextMenu {
                                            Button {
                                                UIPasteboard.general.string = msg.content
                                            } label: {
                                                Label("Copy", systemImage: "doc.on.doc")
                                            }
                                            Button(role: .destructive) {
                                                deleteMessage(msg)
                                            } label: {
                                                Label("Delete Message", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .padding()
                            }
                            .scrollDismissesKeyboard(.interactively)
                        }
                    }
                    .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
                    .onChange(of: messages.last?.content) { _, _ in scrollToBottom(proxy) }
                }

                Divider().background(Color.cardBorder)

                if !disclaimerDismissed { aiDisclaimer }
                inputBar
            }
            .background {
                Color.voidBlack
                SporeBackground()
            }
            .overlay(alignment: .top) {
                if showNewSessionConfirm {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.sporeGreen)
                        Text("New chat started")
                            .font(.mono(12, weight: .medium))
                            .foregroundStyle(Color.consoleText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.cardBackground)
                    .clipShape(Capsule())
                    .shadow(color: Color.sporeGreen.opacity(0.2), radius: 8)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeOut(duration: 0.3), value: showNewSessionConfirm)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                configureRemoteClient()
                loadOrCreateSession()
            }
            .sheet(isPresented: $showSessionList) {
                SessionListView(
                    sessions: sessions,
                    currentSession: currentSession,
                    onSelect: { switchToSession($0) },
                    onDelete: { deleteSession($0) },
                    onNew: { newSession() },
                    onNewPrivate: { newSession(private: true) }
                )
            }
        }
    }

    // MARK: - Session Management

    private func loadOrCreateSession() {
        // Restore last active session
        if let savedId = Preferences.shared.lastSessionId,
           let saved = sessions.first(where: { $0.persistentModelID.hashValue.description == savedId || $0.title == savedId }) {
            switchToSession(saved)
        } else if let last = sessions.first {
            switchToSession(last)
        } else {
            newSession()
        }
    }

    private func newSession(private isPrivate: Bool = false) {
        stopGenerating()
        isPrivateSession = isPrivate

        let session = ChatSession(title: isPrivate ? "Private Chat" : "New Chat")
        if !isPrivate {
            modelContext.insert(session)
            try? modelContext.save()
        }
        currentSession = session
        messages = []
        showSessionList = false

        // Brief visual confirmation
        showNewSessionConfirm = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showNewSessionConfirm = false
        }
    }

    private func switchToSession(_ session: ChatSession) {
        stopGenerating()
        isPrivateSession = false
        currentSession = session
        Preferences.shared.lastSessionId = session.persistentModelID.hashValue.description
        // Load persisted messages into display messages
        let sorted = session.messages.sorted { $0.timestamp < $1.timestamp }
        messages = sorted.map { msg in
            var dm = DisplayMessage(
                role: msg.role, content: msg.content,
                tokenCount: msg.tokenCount, routedVia: msg.routedVia,
                timestamp: msg.timestamp
            )
            dm.sourceNode = msg.sourceNode
            dm.modelUsed = msg.model
            dm.tokensPerSecond = msg.tokensPerSecond
            dm.isError = msg.isError
            if msg.durationMs > 0 {
                dm.endTime = msg.timestamp.addingTimeInterval(Double(msg.durationMs) / 1000)
            }
            return dm
        }
        showSessionList = false
    }

    private func deleteSession(_ session: ChatSession) {
        let wasCurrent = session === currentSession
        modelContext.delete(session)
        try? modelContext.save()
        if wasCurrent {
            if let next = sessions.first(where: { $0 !== session }) {
                switchToSession(next)
            } else {
                newSession()
            }
        }
    }

    private func deleteMessage(_ msg: DisplayMessage) {
        messages.removeAll { $0.id == msg.id }
        // Remove from SwiftData
        if let session = currentSession,
           let stored = session.messages.first(where: { $0.timestamp == msg.timestamp && $0.role == msg.role }) {
            modelContext.delete(stored)
            try? modelContext.save()
        }
    }

    /// Persist a DisplayMessage to the current session.
    private func persist(_ msg: DisplayMessage) {
        guard !isPrivateSession, let session = currentSession else { return }
        let stored = ChatMessage(role: msg.role, content: msg.content, model: msg.modelUsed, routedVia: msg.routedVia)
        stored.tokenCount = msg.tokenCount
        stored.sourceNode = msg.sourceNode
        stored.tokensPerSecond = msg.tokensPerSecond
        stored.durationMs = msg.durationMs ?? 0
        stored.isError = msg.isError
        stored.timestamp = msg.timestamp
        stored.session = session
        session.updatedAt = Date()
        session.autoTitle()
        modelContext.insert(stored)
        try? modelContext.save()
    }

    // MARK: - Share / Export

    private func exportCurrentSession() {
        guard let session = currentSession else { return }
        let text = formatSessionForExport(messages: messages, title: session.title)
        ShareHelper.share(text)
    }

    private func formatSessionForExport(messages: [DisplayMessage], title: String) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("Date: \(Date().formatted(date: .abbreviated, time: .shortened))")
        lines.append("")
        for msg in messages {
            let role = msg.role == "user" ? "You" : "Assistant"
            lines.append("**\(role)**")
            lines.append(msg.content)
            if msg.role == "assistant" {
                var meta: [String] = []
                if msg.tokenCount > 0 { meta.append("\(msg.tokenCount) tokens") }
                if msg.tokensPerSecond > 0 { meta.append(String(format: "%.1f t/s", msg.tokensPerSecond)) }
                if !msg.modelUsed.isEmpty { meta.append(msg.modelUsed) }
                if !msg.routedVia.isEmpty { meta.append("via \(msg.routedVia)") }
                if !meta.isEmpty { lines.append("_\(meta.joined(separator: " · "))_") }
            }
            lines.append("")
        }
        lines.append("---")
        lines.append("Exported from mycellm iOS")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func retryLastMessage() {
        if let lastUser = messages.last(where: { $0.role == "user" }) {
            messages.removeAll { $0.isError }
            inputText = lastUser.content
            sendMessage()
        }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showEndpointDetail = false

    // MARK: - AI Disclaimer

    private var aiDisclaimer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text("AI responses may be inaccurate. Verify important information.")
                .font(.mono(9))
            Spacer()
            Button {
                withAnimation { disclaimerDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.consoleText.opacity(0.7))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.15))
    }

    // MARK: - Date Dividers

    private func shouldShowDateDivider(at index: Int) -> Bool {
        guard index > 0 else { return true }  // Always show for first message
        let current = messages[index].timestamp
        let previous = messages[index - 1].timestamp
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("MycellmLogo-green")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .opacity(0.15)
            Text("Start a conversation")
                .font(.mono(12))
                .foregroundStyle(Color.consoleDim.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Route Bar

    private var routeBar: some View {
        VStack(spacing: 8) {
            ZStack {
                // Center: logo (always truly centered)
                Image("MycellmLockup")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 24)

                // Left: session list
                HStack {
                    Button { showSessionList = true } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.consoleDim)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                // Right: actions
                HStack(spacing: 14) {
                    Spacer()

                    if isPrivateSession {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.poisonPurple.opacity(0.8))
                    }

                    Button { exportCurrentSession() } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.consoleDim)
                    }
                    .buttonStyle(.plain)
                    .disabled(messages.isEmpty)

                    Button { newSession() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(messages.isEmpty ? Color.consoleDim : Color.sporeGreen)
                    }
                    .buttonStyle(.plain)
                    .disabled(messages.isEmpty)
                }
            }

            HStack(spacing: 6) {
                ForEach(ChatRoute.allCases) { r in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            route = r
                            Preferences.shared.chatRoute = r.rawValue
                        }
                    } label: {
                        routeToggleLabel(r)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button { showEndpointDetail.toggle() } label: {
                    statusDot
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showEndpointDetail) {
                    endpointPopover
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.cardBackground)
    }

    private func routeToggleLabel(_ r: ChatRoute) -> some View {
        HStack(spacing: 4) {
            Image(systemName: r.icon).font(.system(size: 11))
            Text(r.rawValue).font(.mono(12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(route == r ? routeColor.opacity(0.2) : Color.cardBackground)
        .foregroundStyle(route == r ? routeColor : Color.consoleDim)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(route == r ? routeColor.opacity(0.3) : Color.cardBorder, lineWidth: 1))
    }

    private var statusDot: some View {
        HStack(spacing: 3) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(statusShort)
                .font(.mono(9))
                .foregroundStyle(Color.consoleDim)
                .lineLimit(1)
        }
    }

    private var endpointPopover: some View {
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

    private var statusShort: String {
        switch route {
        case .network:
            if Preferences.shared.remoteEndpoint.isEmpty { return "No endpoint" }
            let model = Preferences.shared.remoteModel
            return model.isEmpty ? "Connected" : model
        case .onDevice:
            if let first = node.modelManager.loadedModels.first {
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
            if let first = node.modelManager.loadedModels.first { return first.name }
            return node.modelManager.localFiles.isEmpty
                ? "No models — download from Models tab"
                : "\(node.modelManager.localFiles.count) on disk — select in Models tab"
        }
    }

    // MARK: - Input Bar

    private var guardBorderColor: Color {
        switch scanResult.highestSeverity {
        case .high: Color.computeRed
        case .medium: Color.ledgerGold
        default: Color.clear
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            sensitiveWarningBanner
            inputRow
        }
        .alert("Sensitive Data Detected", isPresented: $showSensitiveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Send Anyway", role: .destructive) { sendMessage() }
        } message: {
            Text(sensitiveAlertText)
        }
    }

    @ViewBuilder
    private var sensitiveWarningBanner: some View {
        if !scanResult.matches.isEmpty && route == .network {
            HStack(spacing: 6) {
                Image(systemName: scanResult.highestSeverity == .high ? "exclamationmark.shield.fill" : "shield.fill")
                    .font(.system(size: 11))
                Text(scanResult.highestSeverity == .high
                    ? "Sensitive data detected — will route locally"
                    : "\(scanResult.matches.count) potential PII detected")
                    .font(.mono(10))
                Spacer()
                Button { showSensitiveAlert = true } label: {
                    Text("Details").font(.mono(9))
                }
            }
            .foregroundStyle(scanResult.highestSeverity == .high ? Color.computeRed : Color.ledgerGold)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background((scanResult.highestSeverity == .high ? Color.computeRed : Color.ledgerGold).opacity(0.1))
        }
    }

    private var sensitiveAlertText: String {
        let labels = scanResult.matches.map { "• \($0.rule.label): \($0.matchedText)" }.joined(separator: "\n")
        return "This message contains:\n\(labels)\n\nIt would be sent to untrusted nodes on the public network."
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Type a message…", text: $inputText, prompt: Text("Type a message…").foregroundStyle(Color.consoleDim.opacity(0.8)), axis: .vertical)
                .font(.mono(14))
                .foregroundStyle(Color.consoleText)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit { sendMessage() }
                .onChange(of: inputText) { _, newValue in
                    scanTask?.cancel()
                    scanTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        let hasLocal = !node.modelManager.loadedModels.isEmpty
                        scanResult = guard_.scan(newValue, trustLevel: route == .onDevice ? .honor : .strict, hasLocalModel: hasLocal)
                    }
                }

            sendButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(Color.cardBackground)
        .overlay(alignment: .top) {
            if scanResult.highestSeverity != nil {
                guardBorderColor.frame(height: 2)
            }
        }
    }

    private var sendButton: some View {
        Button {
            if isGenerating {
                stopGenerating()
            } else if scanResult.action == .blockAsk {
                showSensitiveAlert = true
            } else {
                sendMessage()
            }
        } label: {
            Image(systemName: isGenerating ? "stop.circle.fill"
                : scanResult.highestSeverity == .high ? "shield.fill"
                : "arrow.right.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(sendButtonColor)
        }
        .disabled(inputText.isEmpty && !isGenerating)
    }

    private var sendButtonColor: Color {
        if inputText.isEmpty && !isGenerating { return Color.consoleDim }
        if scanResult.highestSeverity == .high { return Color.computeRed }
        return routeColor
    }

    // MARK: - Send

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let effectiveRoute: ChatRoute
        if scanResult.action == .blockRedirect && route == .network {
            effectiveRoute = .onDevice
        } else {
            effectiveRoute = route
        }

        inputText = ""
        scanResult = SensitiveDataGuard.ScanResult(matches: [], action: .allow, highestSeverity: nil)

        // Dismiss keyboard on send in landscape (reclaim screen space)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        let userRoute = effectiveRoute == .network ? "network" : "on-device"
        let userMsg = DisplayMessage(role: "user", content: text, routedVia: userRoute)
        messages.append(userMsg)
        persist(userMsg)

        switch effectiveRoute {
        case .network:
            sendNetworkMessage()
        case .onDevice:
            if !node.hasLoadedModel {
                let errMsg = DisplayMessage(
                    role: "assistant",
                    content: node.modelManager.localFiles.isEmpty
                        ? "No models downloaded. Go to the Models tab to get one."
                        : "No model selected. Go to the Models tab and select one.",
                    routedVia: "local"
                )
                messages.append(errMsg)
            } else {
                sendLocalMessage()
            }
        }
    }

    private func sendLocalMessage() {
        isGenerating = true

        var placeholder = DisplayMessage(role: "assistant", content: "", routedVia: "on-device", isStreaming: true)
        placeholder.startTime = Date()
        messages.append(placeholder)
        let responseId = placeholder.id

        let chatMessages = messages.dropLast().map { ["role": $0.role, "content": $0.content] }

        streamTask = Task {
            do {
                var tokenCount = 0
                let stream = await node.streamLocalInference(messages: Array(chatMessages))
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    mutate(responseId) { $0.content += chunk }
                    tokenCount += 1
                }
                let endTime = Date()
                mutate(responseId) { msg in
                    let elapsed = endTime.timeIntervalSince(msg.startTime)
                    msg.tokenCount = tokenCount
                    msg.endTime = endTime
                    msg.tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
                    msg.isStreaming = false
                }
            } catch {
                mutate(responseId) { msg in
                    if msg.content.isEmpty { msg.content = "Error: \(error.localizedDescription)" }
                    msg.endTime = Date()
                    msg.isStreaming = false
                    msg.isError = true
                }
            }
            if let i = idx(for: responseId) { persist(messages[i]) }
            isGenerating = false
        }
    }

    private func sendNetworkMessage() {
        isGenerating = true

        var placeholder = DisplayMessage(role: "assistant", content: "", routedVia: "network", isStreaming: true)
        placeholder.startTime = Date()
        messages.append(placeholder)
        let responseId = placeholder.id

        let chatMessages = messages.dropLast()
            .map { RemoteClient.ChatMessage(role: $0.role, content: $0.content) }

        let model = Preferences.shared.remoteModel.isEmpty ? "default" : Preferences.shared.remoteModel

        // Try QUIC streaming first (token-by-token), fall back to HTTP
        let useQUICStream = node.connection.bootstrapState == .connected && node.connection.bootstrapTransport == .quic

        streamTask = Task {
            do {
                if useQUICStream {
                    // Stream over QUIC — tokens arrive one-by-one
                    let rawMessages = Array(chatMessages).map { ["role": $0.role, "content": $0.content] }
                    var tokenCount = 0
                    for try await text in await node.bootstrapClient.streamInference(
                        model: model, messages: rawMessages
                    ) {
                        guard !Task.isCancelled else { break }
                        mutate(responseId) { $0.content += text }
                        tokenCount += 1
                    }
                    mutate(responseId) { msg in
                        msg.tokenCount = tokenCount
                        let elapsed = Date().timeIntervalSince(msg.startTime)
                        msg.tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
                        msg.isStreaming = false
                        msg.endTime = Date()
                        msg.routedVia = "quic"
                    }
                } else {
                    // HTTP fallback — full response at once
                    let result = try await remoteClient.completeWithMetadata(
                        model: model, messages: Array(chatMessages)
                    )
                    applyNetworkResult(result, to: responseId, model: model)
                }
            } catch is CancellationError {
                mutate(responseId) { $0.endTime = Date(); $0.isStreaming = false }
            } catch {
                await handleNetworkError(error, responseId: responseId, model: model, chatMessages: Array(chatMessages))
            }
            if let i = idx(for: responseId) { persist(messages[i]) }
            isGenerating = false
        }

        // Connection timeout
        Task {
            try? await Task.sleep(for: .seconds(60))
            guard isGenerating, let i = idx(for: responseId),
                  messages[i].content.isEmpty else { return }
            mutate(responseId) { msg in
                msg.content = "Connection timed out."
                msg.isError = true
                msg.isStreaming = false
            }
            stopGenerating()
        }
    }

    /// Validate a network response for obviously malformed/poison content.
    private func validateResponse(_ result: RemoteClient.CompletionResult) -> String? {
        // Empty response
        if result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Empty response from node"
        }
        // Absurdly large response (>100KB — likely garbage)
        if result.content.count > 100_000 {
            return "Response too large (\(result.content.count / 1000)KB) — possible malformed data"
        }
        // High ratio of control characters (binary garbage)
        let controlCount = result.content.unicodeScalars.filter { $0.value < 32 && $0.value != 10 && $0.value != 13 && $0.value != 9 }.count
        if controlCount > result.content.count / 4 && result.content.count > 20 {
            return "Response contains excessive control characters — possible corrupted data"
        }
        return nil  // Valid
    }

    private func applyNetworkResult(_ result: RemoteClient.CompletionResult, to responseId: UUID, model: String) {
        // Validate before applying
        if let validationError = validateResponse(result) {
            mutate(responseId) { msg in
                msg.content = validationError
                msg.isError = true
                msg.isStreaming = false
                msg.endTime = Date()
            }
            return
        }

        let content = result.content
        mutate(responseId) { msg in
            msg.content = content
            let endTime = Date()
            let elapsed = endTime.timeIntervalSince(msg.startTime)
            msg.tokenCount = result.completionTokens > 0
                ? result.completionTokens
                : content.split(separator: " ").count * 4 / 3
            msg.sourceNode = result.sourceNode
            msg.modelUsed = result.model.isEmpty ? model : result.model
            msg.endTime = endTime
            msg.tokensPerSecond = elapsed > 0 ? Double(msg.tokenCount) / elapsed : 0
            msg.isStreaming = false
        }

        // Estimate tokens if the API didn't return usage
        let reportedTokens = result.promptTokens + result.completionTokens
        let estimatedTokens = result.content.count / 4 + 50  // ~4 chars/token + prompt overhead
        let tokens = reportedTokens > 0 ? reportedTokens : estimatedTokens
        let cost = Double(tokens) * 0.001
        if cost > 0 {
            node.debitCredit(amount: cost, network: "public")
        }
    }

    private func handleNetworkError(_ error: Error, responseId: UUID, model: String, chatMessages: [RemoteClient.ChatMessage]) async {
        // Auto-retry once on 503 or transient errors
        let isRetryable = error.localizedDescription.contains("503")
            || error.localizedDescription.contains("timeout")
            || error.localizedDescription.contains("connection")
        if isRetryable {
            try? await Task.sleep(for: .seconds(1))
            if let retry = try? await remoteClient.completeWithMetadata(model: model, messages: chatMessages),
               validateResponse(retry) == nil {
                applyNetworkResult(retry, to: responseId, model: model)
                return
            }
        }

        let errMsg = error.localizedDescription
            .replacingOccurrences(of: "Transport error: HTTP 503: ", with: "")
            .replacingOccurrences(of: "{\"error\":{\"message\":\"", with: "")
            .replacingOccurrences(of: "\"}}", with: "")

        // Try local fallback
        if node.hasLoadedModel {
            mutate(responseId) { $0.content = ""; $0.routedVia = "on-device"; $0.isStreaming = true }
            do {
                var tokenCount = 0
                let localMessages = chatMessages.map { ["role": $0.role, "content": $0.content] }
                let localStream = await node.streamLocalInference(messages: localMessages)
                for try await chunk in localStream {
                    mutate(responseId) { $0.content += chunk }
                    tokenCount += 1
                }
                let endTime = Date()
                mutate(responseId) { msg in
                    msg.tokenCount = tokenCount
                    msg.endTime = endTime
                    let elapsed = endTime.timeIntervalSince(msg.startTime)
                    msg.tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
                    msg.isStreaming = false
                }
            } catch {
                mutate(responseId) { msg in
                    msg.content = "Network failed, local fallback also failed: \(error.localizedDescription)"
                    msg.isError = true
                    msg.isStreaming = false
                }
            }
        } else {
            mutate(responseId) { msg in
                msg.isStreaming = false
                msg.endTime = Date()
                if msg.content.isEmpty {
                    msg.content = errMsg
                } else {
                    msg.content += "\n\n[Error: \(errMsg)]"
                }
                msg.isError = true
            }
        }
    }

    private func stopGenerating() {
        streamTask?.cancel()
        streamTask = nil
        isGenerating = false
        if let last = messages.last, last.isStreaming {
            mutate(last.id) { $0.isStreaming = false }
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

// MARK: - Session List

struct SessionListView: View {
    let sessions: [ChatSession]
    let currentSession: ChatSession?
    let onSelect: (ChatSession) -> Void
    let onDelete: (ChatSession) -> Void
    let onNew: () -> Void
    var onNewPrivate: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { session in
                    sessionRow(session)
                        .swipeActions(edge: .leading) {
                            Button {
                                shareSession(session)
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.relayBlue)
                        }
                }
                .onDelete { offsets in
                    for i in offsets { onDelete(sessions[i]) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.voidBlack)
            .navigationTitle("Threads")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button { onNewPrivate?() } label: {
                            Image(systemName: "eye.slash")
                        }
                        Button { onNew() } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
    }

    private func shareSession(_ session: ChatSession) {
        let sorted = session.messages.sorted { $0.timestamp < $1.timestamp }
        var lines: [String] = ["# \(session.title)", ""]
        for msg in sorted {
            let role = msg.role == "user" ? "You" : "Assistant"
            lines.append("**\(role)**: \(msg.content)")
            lines.append("")
        }
        lines.append("---\nExported from mycellm iOS")
        ShareHelper.share(lines.joined(separator: "\n"))
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        Button { onSelect(session) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.title)
                        .font(.mono(13, weight: session === currentSession ? .semibold : .regular))
                        .foregroundStyle(Color.consoleText)
                        .lineLimit(1)
                    Spacer()
                    if session === currentSession {
                        Circle().fill(Color.sporeGreen).frame(width: 6, height: 6)
                    }
                }
                HStack(spacing: 8) {
                    Text("\(session.messages.count) messages")
                        .font(.mono(10))
                        .foregroundStyle(Color.consoleDim)
                    if !session.model.isEmpty {
                        Text(session.model)
                            .font(.mono(10))
                            .foregroundStyle(Color.relayBlue)
                    }
                    Spacer()
                    Text(session.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.mono(10))
                        .foregroundStyle(Color.consoleDim)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Date Divider

struct DateDivider: View {
    let date: Date

    var body: some View {
        HStack {
            line
            Text(label)
                .font(.mono(9))
                .foregroundStyle(Color.consoleDim.opacity(0.6))
            line
        }
        .padding(.vertical, 4)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.cardBorder.opacity(0.4))
            .frame(height: 0.5)
    }

    private var label: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatView.DisplayMessage
    var onRetry: (() -> Void)? = nil

    var isUser: Bool { message.role == "user" }
    var isThinking: Bool { message.isStreaming && message.content.isEmpty }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 4) {
                if isUser {
                    timestampLabel
                    Spacer(minLength: 40)
                }

                bubble

                if !isUser {
                    Spacer(minLength: 40)
                    timestampLabel
                }
            }

            // Stats bar — below the bubble, not inside it
            if !isUser && !isThinking && !message.isStreaming {
                statsBar
                    .padding(.horizontal, 4)
            }

            // Streaming indicator
            if !isUser && message.isStreaming {
                HStack(spacing: 4) {
                    BlinkingCursor()
                    routeBadge
                }
                .padding(.horizontal, 4)
            }

            retryButton
        }
    }

    private var timestampLabel: some View {
        Text(message.timestamp.formatted(.dateTime.hour().minute()))
            .font(.mono(9))
            .foregroundStyle(Color.consoleDim.opacity(0.5))
    }

    private var bubble: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            messageText
        }
        .padding(12)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(bubbleBorderColor.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var messageText: some View {
        if isThinking {
            ThinkingIndicator()
        } else if isUser {
            Text(message.content)
                .font(.mono(13))
                .foregroundStyle(Color.consoleText)
                .textSelection(.enabled)
        } else {
            Text(LocalizedStringKey(message.content))
                .font(.system(size: 14))
                .foregroundStyle(Color.consoleText)
                .textSelection(.enabled)
                .tint(Color.relayBlue)
        }
    }

    private var statsBar: some View {
        WrappingHStack(spacing: 6) {
            routeBadge
            if message.tokenCount > 0 {
                statPill("\(message.tokenCount) tok")
            }
            if message.tokensPerSecond > 0 {
                statPill(String(format: "%.1f t/s", message.tokensPerSecond))
            }
            if let ms = message.durationMs {
                statPill(ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000))
            }
            if !message.modelUsed.isEmpty {
                statPill(message.modelUsed)
            }
            if !message.sourceNode.isEmpty {
                Text("node:\(message.sourceNode)")
                    .font(.mono(8))
                    .foregroundStyle(Color.relayBlue)
            }
        }
    }

    private func statPill(_ text: String) -> some View {
        Text(text)
            .font(.mono(8))
            .foregroundStyle(Color.consoleDim)
    }

    @ViewBuilder
    private var routeBadge: some View {
        if message.routedVia == "network" {
            HStack(spacing: 2) {
                Image(systemName: "globe").font(.system(size: 7))
                Text("network").font(.mono(8))
            }.foregroundStyle(Color.relayBlue)
        } else if message.routedVia == "on-device" {
            HStack(spacing: 2) {
                Image(systemName: "ipad").font(.system(size: 7))
                Text("on-device").font(.mono(8))
            }.foregroundStyle(Color.sporeGreen)
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        if message.isError, let onRetry {
            Button { onRetry() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    Text("Retry").font(.mono(10, weight: .medium))
                }
                .foregroundStyle(Color.relayBlue)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.relayBlue.opacity(0.15))
                .clipShape(Capsule())
            }
        }
    }

    private var bubbleBackground: Color {
        if isUser { return Color.sporeGreen.opacity(0.15) }
        if message.isError { return Color.computeRed.opacity(0.08) }
        return Color.cardBackground
    }

    private var bubbleBorderColor: Color {
        if message.isError { return Color.computeRed }
        switch message.routedVia {
        case "network": return Color.relayBlue
        case "on-device": return Color.sporeGreen
        default: return Color.cardBorder
        }
    }
}

// MARK: - Wrapping HStack (flow layout for stats on narrow screens)

struct WrappingHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

/// Animated thinking dots — Task-based timer with proper lifecycle.
struct ThinkingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.consoleDim).frame(width: 6, height: 6)
                    .opacity(i <= phase ? 1.0 : 0.3)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { break }
                phase = (phase + 1) % 4
            }
        }
    }
}

/// Blinking cursor while streaming — Task-based timer with proper lifecycle.
struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Text("▊")
            .font(.mono(10))
            .foregroundStyle(Color.sporeGreen)
            .opacity(visible ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { break }
                    visible.toggle()
                }
            }
    }
}

// MARK: - Share Helper

enum ShareHelper {
    @MainActor
    static func share(_ text: String) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        // Walk to the topmost presented VC
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = top.view
        activity.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: 40, width: 0, height: 0)
        activity.popoverPresentationController?.permittedArrowDirections = .up
        top.present(activity, animated: true)
    }
}

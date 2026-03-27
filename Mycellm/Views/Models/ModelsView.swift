import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @Environment(NodeService.self) private var node
    private var modelManager: ModelManager { node.modelManager }
    private var downloader: ModelDownloader { node.modelDownloader }

    enum ModelTab: String, CaseIterable {
        case onDisk = "On Disk"
        case huggingFace = "HuggingFace"
        case apiProvider = "API"
        case relay = "Relay"
    }

    @State private var selectedTab: ModelTab = .onDisk
    @State private var searchText = ""
    @State private var searchResults: [[String: Any]] = []
    @State private var isSearching = false
    @State private var showDeleteConfirm = false
    @State private var fileToDelete: ModelManager.LocalModelFile?
    @State private var showFileImporter = false
    @State private var importError: String?

    // API Provider state
    @State private var apiName = ""
    @State private var apiBase = ""
    @State private var apiKey = ""
    @State private var apiModel = ""
    @State private var apiCtxLen = "4096"
    @State private var apiConnecting = false
    @State private var apiResult: (success: Bool, message: String)?

    // Relay state
    @State private var relayURL = ""
    @State private var relayLabel = ""
    @State private var relayAdding = false
    @State private var relayResult: (success: Bool, message: String)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab bar
                tabBar

                ScrollView {
                    VStack(spacing: 20) {
                        switch selectedTab {
                        case .onDisk:
                            modelsOnDiskSection
                        case .huggingFace:
                            searchSection
                            suggestedModelsSection
                        case .apiProvider:
                            apiProviderSection
                        case .relay:
                            relaySection
                        }
                    }
                    .padding(.vertical)
                }
            }
            .background(Color.voidBlack)
            .navigationTitle("Models")
            .onAppear { modelManager.scanLocalModels() }
            .alert("Delete Model?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let file = fileToDelete {
                        modelManager.deleteModel(file: file)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let file = fileToDelete {
                    Text("Delete \(file.filename)?\nThis will free \(file.sizeDescription).")
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard url.pathExtension.lowercased() == "gguf" else {
                        importError = "Only .gguf files are supported"
                        return
                    }
                    do {
                        try modelManager.importFile(from: url)
                        importError = nil
                    } catch {
                        importError = error.localizedDescription
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ModelTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tabIcon(tab))
                            .font(.system(size: 14))
                        Text(tab.rawValue)
                            .font(.mono(10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(selectedTab == tab ? Color.sporeGreen : Color.consoleDim)
                    .overlay(alignment: .bottom) {
                        if selectedTab == tab {
                            Rectangle()
                                .fill(Color.sporeGreen)
                                .frame(height: 2)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .background(Color.cardBackground)
    }

    private func tabIcon(_ tab: ModelTab) -> String {
        switch tab {
        case .onDisk: "internaldrive"
        case .huggingFace: "magnifyingglass"
        case .apiProvider: "cloud"
        case .relay: "display"
        }
    }

    // MARK: - Models On Disk

    private var modelsOnDiskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "On Disk", count: modelManager.localFiles.count)
                if modelManager.totalStorageUsed > 0 {
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(modelManager.totalStorageUsed), countStyle: .file) + " total")
                        .font(.mono(10))
                        .foregroundStyle(Color.consoleDim)
                }
            }

            // Import button
            Button {
                showFileImporter = true
            } label: {
                HStack {
                    Image(systemName: "doc.badge.plus")
                        .foregroundStyle(Color.relayBlue)
                    Text("Import GGUF from Files")
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.consoleDim)
                }
                .padding(12)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let error = importError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.computeRed)
                    Text(error)
                        .font(.mono(10))
                        .foregroundStyle(Color.computeRed)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") { importError = nil }
                        .font(.mono(10))
                        .foregroundStyle(Color.consoleDim)
                }
                .padding(10)
                .background(Color.computeRed.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Load error
            if let error = modelManager.loadError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.computeRed)
                    Text(error)
                        .font(.mono(10))
                        .foregroundStyle(Color.computeRed)
                        .lineLimit(2)
                }
                .padding(10)
                .background(Color.computeRed.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Active downloads
            ForEach(downloader.activeDownloads.filter { $0.state == .downloading || $0.state == .pending }) { dl in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(dl.filename)
                            .font(.mono(12, weight: .medium))
                            .foregroundStyle(Color.consoleText)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            downloader.cancelDownload(id: dl.id)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Cancel")
                                    .font(.mono(10))
                                Image(systemName: "xmark.circle.fill")
                            }
                            .foregroundStyle(Color.computeRed)
                        }
                    }
                    ProgressView(value: dl.progress)
                        .tint(Color.sporeGreen)
                    HStack {
                        Text(dl.progressDescription)
                            .font(.mono(10))
                            .foregroundStyle(Color.consoleDim)
                        Spacer()
                        if !dl.speedDescription.isEmpty {
                            Text(dl.speedDescription)
                                .font(.mono(10))
                                .foregroundStyle(Color.sporeGreen)
                        }
                        if !dl.etaDescription.isEmpty {
                            Text(dl.etaDescription)
                                .font(.mono(10))
                                .foregroundStyle(Color.consoleDim)
                        }
                    }
                }
                .padding(12)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Failed/cancelled (dismissable)
            ForEach(downloader.activeDownloads.filter { $0.state == .failed || $0.state == .cancelled }) { dl in
                HStack {
                    Image(systemName: dl.state == .failed ? "exclamationmark.triangle.fill" : "xmark.circle")
                        .foregroundStyle(Color.computeRed)
                    Text(dl.filename)
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleDim)
                        .lineLimit(1)
                    Spacer()
                    Text(dl.state == .failed ? "Failed" : "Cancelled")
                        .font(.mono(10))
                        .foregroundStyle(Color.computeRed)
                    Button("Dismiss") {
                        downloader.removeDownload(id: dl.id)
                    }
                    .font(.mono(10))
                    .foregroundStyle(Color.consoleDim)
                }
                .padding(10)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Completed downloads auto-dismiss and refresh file list
            .onChange(of: downloader.activeDownloads.filter({ $0.state == .completed }).count) { _, newCount in
                if newCount > 0 {
                    for dl in downloader.activeDownloads where dl.state == .completed {
                        downloader.removeDownload(id: dl.id)
                    }
                    modelManager.scanLocalModels()
                }
            }

            if modelManager.localFiles.isEmpty && downloader.activeDownloads.isEmpty {
                EmptyState(message: "No models yet — download or import one", icon: "doc")
            } else {
                ForEach(modelManager.localFiles) { file in
                    localFileRow(file)
                }
            }
        }
        .padding(.horizontal)
    }

    private func localFileRow(_ file: ModelManager.LocalModelFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename)
                        .font(.mono(12, weight: .medium))
                        .foregroundStyle(Color.consoleText)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(ramFitColor(file.ramFit))
                                .frame(width: 6, height: 6)
                            Text(file.sizeDescription)
                                .font(.mono(10))
                                .foregroundStyle(Color.consoleDim)
                        }
                        Text(ramFitLabel(file.ramFit))
                            .font(.mono(9))
                            .foregroundStyle(ramFitColor(file.ramFit))
                    }
                }

                Spacer()

                HStack(spacing: 16) {
                    if file.isLoaded {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.sporeGreen)
                                .frame(width: 6, height: 6)
                            Text("Active")
                                .font(.mono(10, weight: .medium))
                                .foregroundStyle(Color.sporeGreen)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.sporeGreen.opacity(0.15))
                        .clipShape(Capsule())
                    } else if modelManager.isLoading && modelManager.loadingModelName == file.filename {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Loading...")
                                .font(.mono(10, weight: .medium))
                                .foregroundStyle(Color.ledgerGold)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.ledgerGold.opacity(0.15))
                        .clipShape(Capsule())
                    } else {
                        Button("Load") {
                            Task { try? await modelManager.loadModel(file: file) }
                        }
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Color.sporeGreen)
                        .disabled(modelManager.isLoading)
                    }

                    Button {
                        fileToDelete = file
                        showDeleteConfirm = true
                    } label: {
                        Text("Delete")
                            .font(.mono(10))
                            .foregroundStyle(Color.computeRed)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Search HuggingFace

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Search HuggingFace")

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.consoleDim)
                TextField("Search GGUF models...", text: $searchText)
                    .font(.mono(13))
                    .foregroundStyle(Color.consoleText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { search() }

                if isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.consoleDim)
                    }
                }
            }
            .padding(10)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            ForEach(Array(searchResults.enumerated()), id: \.offset) { _, result in
                searchResultRow(result)
            }
        }
        .padding(.horizontal)
    }

    private func searchResultRow(_ result: [String: Any]) -> some View {
        let name = result["name"] as? String ?? ""
        let repoId = result["repo_id"] as? String ?? ""
        let filename = result["filename"] as? String ?? ""
        let downloads = result["downloads"] as? Int ?? 0
        let hasQ4 = result["has_q4"] as? Bool ?? false

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.mono(12, weight: .medium))
                    .foregroundStyle(Color.consoleText)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(repoId)
                        .font(.mono(9))
                        .foregroundStyle(Color.consoleDim)
                        .lineLimit(1)
                    if downloads > 0 {
                        Text("\(formatCount(downloads)) downloads")
                            .font(.mono(9))
                            .foregroundStyle(Color.consoleDim)
                    }
                }
            }

            Spacer()

            if hasQ4 && !filename.isEmpty {
                if isDownloaded(filename: filename) {
                    Text("Downloaded")
                        .font(.mono(10))
                        .foregroundStyle(Color.sporeGreen)
                } else {
                    Button("Download") {
                        downloader.download(repoId: repoId, filename: filename)
                    }
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(Color.relayBlue)
                }
            } else {
                Text("No Q4_K_M")
                    .font(.mono(9))
                    .foregroundStyle(Color.consoleDim)
            }
        }
        .padding(10)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Suggested

    private var suggestedModelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Suggested for This Device")

            let suggestions = ModelRoutes.suggestedModels()
            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                HStack {
                    Circle()
                        .fill(ramFitColor(fitLevel(suggestion["fit"] as? String)))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion["name"] as? String ?? "")
                            .font(.mono(12, weight: .medium))
                            .foregroundStyle(Color.consoleText)
                        Text(String(format: "%.1f GB", suggestion["size_gb"] as? Double ?? 0))
                            .font(.mono(10))
                            .foregroundStyle(Color.consoleDim)
                    }

                    Spacer()

                    if isDownloaded(filename: suggestion["filename"] as? String ?? "") {
                        Text("Downloaded")
                            .font(.mono(10))
                            .foregroundStyle(Color.sporeGreen)
                    } else {
                        Button("Download") {
                            downloader.download(
                                repoId: suggestion["repo_id"] as? String ?? "",
                                filename: suggestion["filename"] as? String ?? ""
                            )
                        }
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Color.relayBlue)
                    }
                }
                .padding(10)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal)
    }

    // MARK: - API Provider

    private var apiProviderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Connect API Provider")

            Text("Connect an OpenAI-compatible endpoint (OpenAI, Anthropic, OpenRouter, Ollama, LM Studio, etc.).")
                .font(.mono(11))
                .foregroundStyle(Color.consoleDim)
                .padding(.horizontal)

            // Presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    presetButton("Ollama", base: "http://localhost:11434/v1")
                    presetButton("LM Studio", base: "http://localhost:1234/v1")
                    presetButton("OpenAI", base: "https://api.openai.com/v1")
                    presetButton("OpenRouter", base: "https://openrouter.ai/api/v1")
                    presetButton("Anthropic", base: "https://api.anthropic.com/v1")
                }
                .padding(.horizontal)
            }

            // Form
            VStack(spacing: 10) {
                formField("Name", text: $apiName, placeholder: "my-model")
                formField("API Base URL", text: $apiBase, placeholder: "https://...")
                SecureField("API Key (optional)", text: $apiKey)
                    .font(.mono(12))
                    .padding(10)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                formField("Upstream Model", text: $apiModel, placeholder: "e.g. gpt-4o")
                formField("Context Length", text: $apiCtxLen, placeholder: "4096")

                Button {
                    connectAPI()
                } label: {
                    HStack {
                        if apiConnecting {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "link")
                        }
                        Text("Connect")
                            .font(.mono(13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color.voidBlack)
                    .background(apiName.isEmpty || apiBase.isEmpty ? Color.consoleDim : Color.sporeGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(apiName.isEmpty || apiBase.isEmpty || apiConnecting)

                if let result = apiResult {
                    HStack {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.success ? Color.sporeGreen : Color.computeRed)
                        Text(result.message)
                            .font(.mono(11))
                            .foregroundStyle(result.success ? Color.sporeGreen : Color.computeRed)
                    }
                }
            }
            .padding(.horizontal)

            // Connected API models
            let apiModels = modelManager.loadedModels.filter { $0.filename.hasPrefix("api:") }
            if !apiModels.isEmpty {
                SectionHeader(title: "Connected APIs", count: apiModels.count)
                    .padding(.horizontal)
                ForEach(apiModels) { model in
                    HStack {
                        Circle()
                            .fill(Color.sporeGreen)
                            .frame(width: 6, height: 6)
                        Text(model.name)
                            .font(.mono(12, weight: .medium))
                            .foregroundStyle(Color.consoleText)
                        Spacer()
                        Text("API")
                            .font(.mono(9))
                            .foregroundStyle(Color.relayBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.relayBlue.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .padding(10)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                }
            }
        }
    }

    private func presetButton(_ name: String, base: String) -> some View {
        Button {
            apiBase = base
            if apiName.isEmpty { apiName = name.lowercased() }
        } label: {
            Text(name)
                .font(.mono(11, weight: .medium))
                .foregroundStyle(apiBase == base ? Color.voidBlack : Color.consoleText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(apiBase == base ? Color.sporeGreen : Color.cardBackground)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    private func formField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        TextField(label + " — " + placeholder, text: text)
            .font(.mono(12))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func connectAPI() {
        guard !apiName.isEmpty, !apiBase.isEmpty else { return }
        apiConnecting = true
        apiResult = nil

        Task {
            do {
                try await modelManager.loadAPIModel(
                    name: apiName,
                    apiBase: apiBase,
                    apiKey: apiKey,
                    apiModel: apiModel.isEmpty ? apiName : apiModel,
                    ctxLen: Int(apiCtxLen) ?? 4096
                )
                apiResult = (true, "Connected: \(apiName)")
                apiName = ""
                apiBase = ""
                apiKey = ""
                apiModel = ""
            } catch {
                apiResult = (false, error.localizedDescription)
            }
            apiConnecting = false
        }
    }

    // MARK: - Device Relay

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Device Relay")

            Text("Connect LAN devices running an OpenAI-compatible API (another mycellm node, Ollama, LM Studio, etc.). Their models are discovered and served through this node.")
                .font(.mono(11))
                .foregroundStyle(Color.consoleDim)
                .padding(.horizontal)

            // Connected relays
            let relays = node.relayManager.relays
            if !relays.isEmpty {
                ForEach(relays) { relay in
                    HStack {
                        Circle()
                            .fill(relay.online ? Color.sporeGreen : Color.computeRed)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(relay.name.isEmpty ? relay.url : relay.name)
                                .font(.mono(12, weight: .medium))
                                .foregroundStyle(Color.consoleText)
                            HStack(spacing: 6) {
                                Text(relay.url)
                                    .font(.mono(9))
                                    .foregroundStyle(Color.consoleDim)
                                if relay.online {
                                    Text("\(relay.models.count) model\(relay.models.count == 1 ? "" : "s")")
                                        .font(.mono(9))
                                        .foregroundStyle(Color.sporeGreen)
                                } else if !relay.error.isEmpty {
                                    Text(relay.error)
                                        .font(.mono(9))
                                        .foregroundStyle(Color.computeRed)
                                        .lineLimit(1)
                                }
                            }
                            if relay.online && !relay.models.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(relay.models, id: \.self) { model in
                                        Text(model)
                                            .font(.mono(8))
                                            .foregroundStyle(Color.relayBlue)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.relayBlue.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        Spacer()
                        Button {
                            Task { await node.relayManager.remove(url: relay.url) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.computeRed)
                        }
                    }
                    .padding(10)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                }

                Button {
                    Task { await node.relayManager.refreshAll() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh All")
                            .font(.mono(11))
                    }
                    .foregroundStyle(Color.relayBlue)
                }
                .padding(.horizontal)
            }

            // Add relay form
            VStack(spacing: 10) {
                formField("Device URL", text: $relayURL, placeholder: "http://10.1.1.112:8420")
                formField("Label", text: $relayLabel, placeholder: "iPad Pro (optional)")

                Button {
                    addRelay()
                } label: {
                    HStack {
                        if relayAdding {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "plus.circle.fill")
                        }
                        Text("Add Relay")
                            .font(.mono(13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color.voidBlack)
                    .background(relayURL.isEmpty ? Color.consoleDim : Color.relayBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(relayURL.isEmpty || relayAdding)

                if let result = relayResult {
                    HStack {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.success ? Color.sporeGreen : Color.computeRed)
                        Text(result.message)
                            .font(.mono(11))
                            .foregroundStyle(result.success ? Color.sporeGreen : Color.computeRed)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func addRelay() {
        guard !relayURL.isEmpty else { return }
        relayAdding = true
        relayResult = nil

        Task {
            do {
                let relay = try await node.relayManager.add(url: relayURL, name: relayLabel)
                relayResult = (true, "Added \(relay.name) (\(relay.models.count) models)")
                relayURL = ""
                relayLabel = ""
            } catch {
                relayResult = (false, error.localizedDescription)
            }
            relayAdding = false
        }
    }

    // MARK: - Helpers

    private func search() {
        guard !searchText.isEmpty else { return }
        isSearching = true
        Task {
            searchResults = await ModelRoutes.searchHuggingFace(query: searchText)
            isSearching = false
        }
    }

    private func ramFitColor(_ level: HardwareInfo.RAMFitLevel) -> Color {
        switch level {
        case .comfortable: Color.sporeGreen
        case .tight: Color.ledgerGold
        case .tooLarge: Color.computeRed
        }
    }

    private func ramFitLabel(_ level: HardwareInfo.RAMFitLevel) -> String {
        switch level {
        case .comfortable: "fits well"
        case .tight: "tight fit"
        case .tooLarge: "too large"
        }
    }

    private func fitLevel(_ str: String?) -> HardwareInfo.RAMFitLevel {
        switch str {
        case "comfortable": .comfortable
        case "tight": .tight
        default: .tooLarge
        }
    }

    private func isDownloaded(filename: String) -> Bool {
        modelManager.localFiles.contains { $0.filename == filename }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Reusable Components

struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.mono(13, weight: .semibold))
                .foregroundStyle(Color.consoleDim)
            if let count {
                Text("(\(count))")
                    .font(.mono(11))
                    .foregroundStyle(Color.consoleDim)
            }
            Spacer()
        }
    }
}

struct ScopeBadge: View {
    let scope: String

    var body: some View {
        Text(scope)
            .font(.mono(10, weight: .medium))
            .foregroundStyle(scope == "public" ? Color.sporeGreen : Color.consoleDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((scope == "public" ? Color.sporeGreen : Color.consoleDim).opacity(0.15))
            .clipShape(Capsule())
    }
}

struct EmptyState: View {
    let message: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Color.consoleDim)
            Text(message)
                .font(.mono(12))
                .foregroundStyle(Color.consoleDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

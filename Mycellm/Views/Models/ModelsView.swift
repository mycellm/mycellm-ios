import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @Environment(NodeService.self) private var node
    private var modelManager: ModelManager { node.modelManager }
    private var downloader: ModelDownloader { node.modelDownloader }

    enum AddSource: String, Identifiable {
        case huggingFace = "HuggingFace"
        case apiProvider = "API Provider"
        case relay = "Device Relay"
        var id: String { rawValue }
    }

    @State private var showDeleteConfirm = false
    @State private var fileToDelete: ModelManager.LocalModelFile?
    @State private var showFileImporter = false
    @State private var showAddMenu = false
    @State private var activeSheet: AddSource?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    modelsOnDiskSection
                }
                .padding(.vertical)
            }
            .background(Color.voidBlack)
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            activeSheet = .huggingFace
                        } label: {
                            Label("Browse HuggingFace", systemImage: "magnifyingglass")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Import Local File", systemImage: "doc.badge.plus")
                        }
                        Button {
                            activeSheet = .apiProvider
                        } label: {
                            Label("Connect API Provider", systemImage: "cloud")
                        }
                        Button {
                            activeSheet = .relay
                        } label: {
                            Label("Add Device Relay", systemImage: "display")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.sporeGreen)
                    }
                }
            }
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
            .sheet(item: $activeSheet) { source in
                switch source {
                case .huggingFace:
                    HuggingFaceSheet(modelManager: modelManager, downloader: downloader)
                case .apiProvider:
                    APIProviderSheet(modelManager: modelManager)
                case .relay:
                    RelaySheet(relayManager: node.relayManager)
                }
            }
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
                downloadRow(dl)
            }

            // Failed/cancelled
            ForEach(downloader.activeDownloads.filter { $0.state == .failed || $0.state == .cancelled }) { dl in
                failedDownloadRow(dl)
            }
            .onChange(of: downloader.activeDownloads.filter({ $0.state == .completed }).count) { _, newCount in
                if newCount > 0 {
                    for dl in downloader.activeDownloads where dl.state == .completed {
                        downloader.removeDownload(id: dl.id)
                    }
                    modelManager.scanLocalModels()
                }
            }

            // Connected API models
            let apiModels = modelManager.loadedModels.filter { $0.filename.hasPrefix("api:") }
            ForEach(apiModels) { model in
                HStack {
                    Circle().fill(Color.sporeGreen).frame(width: 6, height: 6)
                    Text(model.name)
                        .font(.mono(12, weight: .medium))
                        .foregroundStyle(Color.consoleText)
                    Spacer()
                    Text("API")
                        .font(.mono(9))
                        .foregroundStyle(Color.relayBlue)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.relayBlue.opacity(0.15))
                        .clipShape(Capsule())
                    Button {
                        modelManager.removeAPIModel(name: model.name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.computeRed)
                    }
                }
                .padding(10)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Connected relays summary
            let relays = node.relayManager.relays.filter(\.online)
            ForEach(relays) { relay in
                HStack {
                    Circle().fill(Color.sporeGreen).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(relay.name.isEmpty ? relay.url : relay.name)
                            .font(.mono(12, weight: .medium))
                            .foregroundStyle(Color.consoleText)
                        if !relay.models.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(relay.models, id: \.self) { model in
                                    Text(model).font(.mono(8))
                                        .foregroundStyle(Color.relayBlue)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.relayBlue.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    Spacer()
                    Text("Relay")
                        .font(.mono(9))
                        .foregroundStyle(Color.poisonPurple)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.poisonPurple.opacity(0.15))
                        .clipShape(Capsule())
                    Button {
                        Task { await node.relayManager.remove(url: relay.url) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.computeRed)
                    }
                }
                .padding(10)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if modelManager.localFiles.isEmpty && downloader.activeDownloads.isEmpty && apiModels.isEmpty && relays.isEmpty {
                EmptyState(message: "No models yet — tap + to add one", icon: "doc")
            } else {
                ForEach(modelManager.localFiles) { file in
                    localFileRow(file)
                }
            }
        }
        .padding(.horizontal)
    }

    private func downloadRow(_ dl: ModelDownloader.Download) -> some View {
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
                        Text("Cancel").font(.mono(10))
                        Image(systemName: "xmark.circle.fill")
                    }
                    .foregroundStyle(Color.computeRed)
                }
            }
            ProgressView(value: dl.progress).tint(Color.sporeGreen)
            HStack {
                Text(dl.progressDescription)
                    .font(.mono(10)).foregroundStyle(Color.consoleDim)
                Spacer()
                if !dl.speedDescription.isEmpty {
                    Text(dl.speedDescription)
                        .font(.mono(10)).foregroundStyle(Color.sporeGreen)
                }
                if !dl.etaDescription.isEmpty {
                    Text(dl.etaDescription)
                        .font(.mono(10)).foregroundStyle(Color.consoleDim)
                }
            }
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func failedDownloadRow(_ dl: ModelDownloader.Download) -> some View {
        HStack {
            Image(systemName: dl.state == .failed ? "exclamationmark.triangle.fill" : "xmark.circle")
                .foregroundStyle(Color.computeRed)
            Text(dl.filename)
                .font(.mono(12)).foregroundStyle(Color.consoleDim).lineLimit(1)
            Spacer()
            Text(dl.state == .failed ? "Failed" : "Cancelled")
                .font(.mono(10)).foregroundStyle(Color.computeRed)
            Button("Dismiss") { downloader.removeDownload(id: dl.id) }
                .font(.mono(10)).foregroundStyle(Color.consoleDim)
        }
        .padding(10)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                            Circle().fill(ramFitColor(file.ramFit)).frame(width: 6, height: 6)
                            Text(file.sizeDescription)
                                .font(.mono(10)).foregroundStyle(Color.consoleDim)
                        }
                        Text(ramFitLabel(file.ramFit))
                            .font(.mono(9)).foregroundStyle(ramFitColor(file.ramFit))
                    }
                }
                Spacer()
                HStack(spacing: 16) {
                    if file.isLoaded {
                        Button("Unload") {
                            if let model = modelManager.loadedModels.first(where: { $0.filename == file.filename }) {
                                Task { await modelManager.unloadModel(model) }
                            }
                        }
                        .font(.mono(10, weight: .medium))
                        .foregroundStyle(Color.ledgerGold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.ledgerGold.opacity(0.15))
                        .clipShape(Capsule())
                    } else if modelManager.isLoading && modelManager.loadingModelName == file.filename {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.6)
                            Text("Loading...")
                                .font(.mono(10, weight: .medium))
                                .foregroundStyle(Color.ledgerGold)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
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
                        Text("Delete").font(.mono(10)).foregroundStyle(Color.computeRed)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

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

// MARK: - HuggingFace Sheet

private struct HuggingFaceSheet: View {
    let modelManager: ModelManager
    let downloader: ModelDownloader
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchResults: [[String: Any]] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Search
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
                            ProgressView().scaleEffect(0.7)
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
                    .padding(.horizontal)

                    // Results
                    ForEach(Array(searchResults.enumerated()), id: \.offset) { _, result in
                        searchResultRow(result)
                    }
                    .padding(.horizontal)

                    // Suggested
                    SectionHeader(title: "Suggested for This Device").padding(.horizontal)
                    ForEach(Array(ModelRoutes.suggestedModels().enumerated()), id: \.offset) { _, suggestion in
                        suggestedRow(suggestion)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .background(Color.voidBlack)
            .navigationTitle("HuggingFace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.font(.mono(13))
                }
            }
        }
    }

    private func search() {
        guard !searchText.isEmpty else { return }
        isSearching = true
        Task {
            searchResults = await ModelRoutes.searchHuggingFace(query: searchText)
            isSearching = false
        }
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
                    Text(repoId).font(.mono(9)).foregroundStyle(Color.consoleDim).lineLimit(1)
                    if downloads > 0 {
                        Text("\(formatCount(downloads)) downloads")
                            .font(.mono(9)).foregroundStyle(Color.consoleDim)
                    }
                }
            }
            Spacer()
            if hasQ4 && !filename.isEmpty {
                if modelManager.localFiles.contains(where: { $0.filename == filename }) {
                    Text("Downloaded").font(.mono(10)).foregroundStyle(Color.sporeGreen)
                } else {
                    Button("Download") {
                        downloader.download(repoId: repoId, filename: filename)
                    }
                    .font(.mono(11, weight: .medium)).foregroundStyle(Color.relayBlue)
                }
            } else {
                Text("No Q4_K_M").font(.mono(9)).foregroundStyle(Color.consoleDim)
            }
        }
        .padding(10)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func suggestedRow(_ suggestion: [String: Any]) -> some View {
        let name = suggestion["name"] as? String ?? ""
        let filename = suggestion["filename"] as? String ?? ""
        let repoId = suggestion["repo_id"] as? String ?? ""
        let sizeGb = suggestion["size_gb"] as? Double ?? 0

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.mono(12, weight: .medium)).foregroundStyle(Color.consoleText)
                Text(String(format: "%.1f GB", sizeGb)).font(.mono(10)).foregroundStyle(Color.consoleDim)
            }
            Spacer()
            if modelManager.localFiles.contains(where: { $0.filename == filename }) {
                Text("Downloaded").font(.mono(10)).foregroundStyle(Color.sporeGreen)
            } else {
                Button("Download") {
                    downloader.download(repoId: repoId, filename: filename)
                }
                .font(.mono(11, weight: .medium)).foregroundStyle(Color.relayBlue)
            }
        }
        .padding(10)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - API Provider Sheet

private struct APIProviderSheet: View {
    let modelManager: ModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var apiName = ""
    @State private var apiBase = ""
    @State private var apiKey = ""
    @State private var apiModel = ""
    @State private var apiCtxLen = "4096"
    @State private var connecting = false
    @State private var result: (success: Bool, message: String)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Connect an OpenAI-compatible endpoint.")
                        .font(.mono(11)).foregroundStyle(Color.consoleDim)

                    // Presets
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            presetButton("Ollama", base: "http://localhost:11434/v1")
                            presetButton("LM Studio", base: "http://localhost:1234/v1")
                            presetButton("OpenAI", base: "https://api.openai.com/v1")
                            presetButton("OpenRouter", base: "https://openrouter.ai/api/v1")
                            presetButton("Anthropic", base: "https://api.anthropic.com/v1")
                        }
                    }

                    formField("Name", text: $apiName, placeholder: "my-model")
                    formField("API Base URL", text: $apiBase, placeholder: "https://...")
                    SecureField("API Key (optional)", text: $apiKey)
                        .font(.mono(12)).padding(10)
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    formField("Upstream Model", text: $apiModel, placeholder: "e.g. gpt-4o")
                    formField("Context Length", text: $apiCtxLen, placeholder: "4096")

                    Button {
                        connect()
                    } label: {
                        HStack {
                            if connecting { ProgressView().scaleEffect(0.7) }
                            else { Image(systemName: "link") }
                            Text("Connect").font(.mono(13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(Color.voidBlack)
                        .background(apiName.isEmpty || apiBase.isEmpty ? Color.consoleDim : Color.sporeGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(apiName.isEmpty || apiBase.isEmpty || connecting)

                    if let result {
                        HStack {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? Color.sporeGreen : Color.computeRed)
                            Text(result.message).font(.mono(11))
                                .foregroundStyle(result.success ? Color.sporeGreen : Color.computeRed)
                        }
                    }
                }
                .padding()
            }
            .background(Color.voidBlack)
            .navigationTitle("API Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.font(.mono(13))
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
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(apiBase == base ? Color.sporeGreen : Color.cardBackground)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    private func formField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        TextField(label + " — " + placeholder, text: text)
            .font(.mono(12)).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(10).background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func connect() {
        connecting = true
        result = nil
        Task {
            do {
                try await modelManager.loadAPIModel(
                    name: apiName, apiBase: apiBase, apiKey: apiKey,
                    apiModel: apiModel.isEmpty ? apiName : apiModel,
                    ctxLen: Int(apiCtxLen) ?? 4096
                )
                result = (true, "Connected: \(apiName)")
                apiName = ""; apiBase = ""; apiKey = ""; apiModel = ""
            } catch {
                result = (false, error.localizedDescription)
            }
            connecting = false
        }
    }
}

// MARK: - Relay Sheet

private struct RelaySheet: View {
    let relayManager: RelayManager
    @Environment(\.dismiss) private var dismiss
    @State private var relayURL = ""
    @State private var relayLabel = ""
    @State private var adding = false
    @State private var result: (success: Bool, message: String)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Connect LAN devices running an OpenAI-compatible API. Their models are discovered and served through this node.")
                        .font(.mono(11)).foregroundStyle(Color.consoleDim)

                    // Connected relays
                    if !relayManager.relays.isEmpty {
                        ForEach(relayManager.relays) { relay in
                            HStack {
                                Circle()
                                    .fill(relay.online ? Color.sporeGreen : Color.computeRed)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(relay.name.isEmpty ? relay.url : relay.name)
                                        .font(.mono(12, weight: .medium))
                                        .foregroundStyle(Color.consoleText)
                                    HStack(spacing: 6) {
                                        Text(relay.url).font(.mono(9)).foregroundStyle(Color.consoleDim)
                                        if relay.online {
                                            Text("\(relay.models.count) model\(relay.models.count == 1 ? "" : "s")")
                                                .font(.mono(9)).foregroundStyle(Color.sporeGreen)
                                        } else if !relay.error.isEmpty {
                                            Text(relay.error).font(.mono(9))
                                                .foregroundStyle(Color.computeRed).lineLimit(1)
                                        }
                                    }
                                    if relay.online && !relay.models.isEmpty {
                                        HStack(spacing: 4) {
                                            ForEach(relay.models, id: \.self) { model in
                                                Text(model).font(.mono(8))
                                                    .foregroundStyle(Color.relayBlue)
                                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                                    .background(Color.relayBlue.opacity(0.12))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                    }
                                }
                                Spacer()
                                Button {
                                    Task { await relayManager.remove(url: relay.url) }
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 12))
                                        .foregroundStyle(Color.computeRed)
                                }
                            }
                            .padding(10).background(Color.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        Button {
                            Task { await relayManager.refreshAll() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh All").font(.mono(11))
                            }.foregroundStyle(Color.relayBlue)
                        }
                    }

                    // Add form
                    formField("Device URL", text: $relayURL, placeholder: "http://10.1.1.112:8420")
                    formField("Label", text: $relayLabel, placeholder: "iPad Pro (optional)")

                    Button {
                        addRelay()
                    } label: {
                        HStack {
                            if adding { ProgressView().scaleEffect(0.7) }
                            else { Image(systemName: "plus.circle.fill") }
                            Text("Add Relay").font(.mono(13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(Color.voidBlack)
                        .background(relayURL.isEmpty ? Color.consoleDim : Color.relayBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(relayURL.isEmpty || adding)

                    if let result {
                        HStack {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? Color.sporeGreen : Color.computeRed)
                            Text(result.message).font(.mono(11))
                                .foregroundStyle(result.success ? Color.sporeGreen : Color.computeRed)
                        }
                    }
                }
                .padding()
            }
            .background(Color.voidBlack)
            .navigationTitle("Device Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.font(.mono(13))
                }
            }
        }
    }

    private func formField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        TextField(label + " — " + placeholder, text: text)
            .font(.mono(12)).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(10).background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func addRelay() {
        adding = true; result = nil
        Task {
            do {
                let relay = try await relayManager.add(url: relayURL, name: relayLabel)
                result = (true, "Added \(relay.name) (\(relay.models.count) models)")
                relayURL = ""; relayLabel = ""
            } catch {
                result = (false, error.localizedDescription)
            }
            adding = false
        }
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
                Text("(\(count))").font(.mono(11)).foregroundStyle(Color.consoleDim)
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
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((scope == "public" ? Color.sporeGreen : Color.consoleDim).opacity(0.15))
            .clipShape(Capsule())
    }
}

struct EmptyState: View {
    let message: String
    let icon: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Color.consoleDim)
            Text(message).font(.mono(12)).foregroundStyle(Color.consoleDim)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

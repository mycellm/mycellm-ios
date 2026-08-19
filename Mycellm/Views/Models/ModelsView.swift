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
                            .font(.system(size: 22))
                            .foregroundStyle(Color.sporeGreen)
                    }
                }
            }
            .onAppear {
                if ScreenshotMode.isActive {
                    activeSheet = .huggingFace   // show the model catalog for marketing capture
                } else {
                    modelManager.scanLocalModels()
                }
            }
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
                        .presentationDetents([.large])
                case .apiProvider:
                    APIProviderSheet(modelManager: modelManager)
                        .presentationDetents([.large])
                case .relay:
                    RelaySheet(relayManager: node.relayManager)
                        .presentationDetents([.large])
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

            // MLX repos in flight
            ForEach(downloader.repoDownloads.filter { $0.state == .downloading || $0.state == .pending }) { dl in
                repoDownloadRow(dl)
            }

            // Failed/cancelled
            ForEach(downloader.activeDownloads.filter { $0.state == .failed || $0.state == .cancelled }) { dl in
                failedDownloadRow(dl)
            }

            ForEach(downloader.repoDownloads.filter { $0.state == .failed || $0.state == .cancelled }) { dl in
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.computeRed)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dl.name).font(.mono(11)).foregroundStyle(Color.consoleText).lineLimit(1)
                        // The reason matters here more than for a single file:
                        // "not enough space" and "gated repo" need different
                        // actions from the user, and both are common.
                        if let err = dl.error {
                            Text(err).font(.mono(9)).foregroundStyle(Color.consoleDim).lineLimit(3)
                        }
                    }
                    Spacer()
                    Button("Dismiss") { downloader.removeRepoDownload(id: dl.id) }
                        .font(.mono(10)).foregroundStyle(Color.relayBlue)
                }
                .padding(10)
                .background(Color.computeRed.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .onChange(of: downloader.repoDownloads.filter({ $0.state == .completed }).count) { _, newCount in
                if newCount > 0 {
                    for dl in downloader.repoDownloads where dl.state == .completed {
                        downloader.removeRepoDownload(id: dl.id)
                    }
                    // The directory only becomes visible to the picker once the
                    // atomic publish has happened, so rescanning here is what
                    // makes a finished MLX model appear.
                    modelManager.scanLocalModels()
                }
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
                            .font(.system(size: 16))
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
                        node.relayManager.remove(url: relay.url)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.computeRed)
                    }
                }
                .padding(10)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if modelManager.localFiles.isEmpty && downloader.activeDownloads.isEmpty && apiModels.isEmpty && relays.isEmpty {
                VStack(spacing: 16) {
                    Image("MycellmLogo-green")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .opacity(0.4)

                    Text("No models loaded")
                        .font(.mono(14, weight: .medium))
                        .foregroundStyle(Color.consoleText)

                    Text("Download a model from HuggingFace, import a\nlocal GGUF, or connect an API provider.")
                        .font(.mono(11))
                        .foregroundStyle(Color.consoleDim)
                        .multilineTextAlignment(.center)

                    Button {
                        activeSheet = .huggingFace
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("Browse HuggingFace")
                                .font(.mono(12, weight: .medium))
                        }
                        .foregroundStyle(Color.voidBlack)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.sporeGreen)
                        .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
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

    private func repoDownloadRow(_ dl: ModelDownloader.RepoDownload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dl.name).font(.mono(11, weight: .medium))
                    .foregroundStyle(Color.consoleText).lineLimit(1)
                FormatBadge("MLX")
                Spacer()
                Button {
                    downloader.cancelRepo(id: dl.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.consoleDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            }
            ProgressView(value: dl.progress).tint(Color.relayBlue)
            HStack {
                Text(dl.progressDescription).font(.mono(9)).foregroundStyle(Color.consoleDim)
                Spacer()
                if !dl.speedDescription.isEmpty {
                    Text("\(dl.speedDescription) · \(dl.etaDescription)")
                        .font(.mono(9)).foregroundStyle(Color.consoleDim)
                }
            }
        }
        .padding(10)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                            // Share on the public network by default (opt-out via Settings),
                            // so loading a model makes this node seed public chat.
                            let scope = Preferences.shared.shareModelsPublicly ? "public" : "home"
                            Task { try? await modelManager.loadModel(file: file, scope: scope) }
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
    /// MLX first: it's the faster backend on Apple silicon, and until now search
    /// couldn't reach it at all. GGUF stays one tap away for quants MLX lacks.
    @State private var searchFormat = "mlx"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Search
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.consoleDim)
                        TextField(searchFormat == "mlx" ? "Search MLX models..." : "Search GGUF models...", text: $searchText)
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

                    Picker("Format", selection: $searchFormat) {
                        Text("MLX").tag("mlx")
                        Text("GGUF").tag("gguf")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .onChange(of: searchFormat) { _, _ in
                        // Results from the other format are meaningless here —
                        // different repos, and for MLX a row has no filename at
                        // all. Clear rather than show stale rows.
                        searchResults = []
                        if !searchText.isEmpty { search() }
                    }

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
            searchResults = await ModelRoutes.searchHuggingFace(query: searchText, format: searchFormat)
            isSearching = false
        }
    }

    private func searchResultRow(_ result: [String: Any]) -> some View {
        let name = result["name"] as? String ?? ""
        let repoId = result["repo_id"] as? String ?? ""
        let filename = result["filename"] as? String ?? ""
        let downloads = result["downloads"] as? Int ?? 0
        let usable = (result["usable"] as? Bool) ?? (result["has_q4"] as? Bool ?? false)
        let isMLX = (result["format"] as? String ?? "gguf") == "mlx"

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.mono(12, weight: .medium))
                    .foregroundStyle(Color.consoleText)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    FormatBadge(isMLX ? "MLX" : "GGUF")
                    Text(repoId).font(.mono(9)).foregroundStyle(Color.consoleDim).lineLimit(1)
                    if downloads > 0 {
                        Text("\(formatCount(downloads)) downloads")
                            .font(.mono(9)).foregroundStyle(Color.consoleDim)
                    }
                }
            }
            Spacer()
            if usable {
                // For MLX the model is the whole repo, so the thing that lands
                // on disk is a directory named after it — not `filename`, which
                // is deliberately empty for MLX.
                downloadControl(
                    localName: isMLX ? MLXRepo.directoryName(for: repoId) : filename,
                    action: {
                        if isMLX {
                            downloader.downloadRepo(repoId: repoId)
                        } else {
                            downloader.download(repoId: repoId, filename: filename)
                        }
                    }
                )
            } else {
                Image(systemName: "slash.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.consoleDim)
                    .accessibilityLabel(isMLX ? "No MLX weights in this repo" : "No Q4_K_M build available")
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
            downloadControl(localName: filename) {
                downloader.download(repoId: repoId, filename: filename)
            }
        }
        .padding(10)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Download / downloading / downloaded, as one icon.
    ///
    /// ⚠️ EVERY STATE CARRIES AN ACCESSIBILITY LABEL. Replacing the words
    /// "Download" and "Downloaded" with glyphs is fine visually and silent to
    /// VoiceOver — an unlabelled `Image` in a `Button` is announced as nothing
    /// useful, so the row becomes unusable rather than merely terser.
    @ViewBuilder
    private func downloadControl(localName: String, action: @escaping () -> Void) -> some View {
        let inFlight = downloader.repoDownloads.first {
            $0.name == localName && ($0.state == .downloading || $0.state == .pending)
        }
        if modelManager.localFiles.contains(where: { $0.filename == localName }) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.sporeGreen)
                .accessibilityLabel("Downloaded")
        } else if let inFlight {
            // Percentage rather than an indeterminate spinner: these run for
            // minutes and a spinner can't tell "working" from "stuck".
            Text("\(Int(inFlight.progress * 100))%")
                .font(.mono(10))
                .foregroundStyle(Color.relayBlue)
                .accessibilityLabel("Downloading, \(Int(inFlight.progress * 100)) percent")
        } else {
            Button(action: action) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.relayBlue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download")
        }
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
                    RevealableSecureField("API Key (optional)", text: $apiKey, alignment: .leading)
                        .padding(10)
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
                                    relayManager.remove(url: relay.url)
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 14))
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
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Color.consoleDim)
            Text(message).font(.mono(12)).foregroundStyle(Color.consoleDim)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Format badge — blue for MLX, orange for GGUF. See `Color.format`.
///
/// The two used to be blue and green, which collided with the colours meaning
/// "network" and "on device": a green badge could be asserting either of two
/// unrelated things, so it asserted nothing.
struct FormatBadge: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.mono(8, weight: .medium))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.format(label).opacity(0.2))
            .foregroundStyle(Color.format(label))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

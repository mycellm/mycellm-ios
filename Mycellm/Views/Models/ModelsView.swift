import SwiftUI

struct ModelsView: View {
    @Environment(NodeService.self) private var node
    private var modelManager: ModelManager { node.modelManager }
    private var downloader: ModelDownloader { node.modelDownloader }
    @State private var searchText = ""
    @State private var searchResults: [[String: Any]] = []
    @State private var isSearching = false
    @State private var showDeleteConfirm = false
    @State private var fileToDelete: ModelManager.LocalModelFile?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Models (downloads + on disk, merged)
                    modelsOnDiskSection

                    // HuggingFace search
                    searchSection

                    // Suggested models
                    suggestedModelsSection
                }
                .padding(.vertical)
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
        }
    }

    // MARK: - Models (downloads + on disk merged)

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
                EmptyState(message: "No models yet — download one below", icon: "doc")
            } else {
                ForEach(modelManager.localFiles) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        // Filename + actions
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.filename)
                                    .font(.mono(12, weight: .medium))
                                    .foregroundStyle(Color.consoleText)
                                    .lineLimit(1)

                                HStack(spacing: 8) {
                                    // RAM fit indicator
                                    HStack(spacing: 3) {
                                        Circle()
                                            .fill(ramFitColor(file.ramFit))
                                            .frame(width: 6, height: 6)
                                        Text(file.sizeDescription)
                                            .font(.mono(10))
                                            .foregroundStyle(Color.consoleDim)
                                    }

                                    // RAM fit label
                                    Text(ramFitLabel(file.ramFit))
                                        .font(.mono(9))
                                        .foregroundStyle(ramFitColor(file.ramFit))
                                }
                            }

                            Spacer()

                            // Actions
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
                                        Text("Loading…")
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
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Search

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Search HuggingFace")

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.consoleDim)
                TextField("Search GGUF models…", text: $searchText)
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
                let name = result["name"] as? String ?? ""
                let repoId = result["repo_id"] as? String ?? ""
                let filename = result["filename"] as? String ?? ""
                let downloads = result["downloads"] as? Int ?? 0
                let hasQ4 = result["has_q4"] as? Bool ?? false

                HStack {
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
        }
        .padding(.horizontal)
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

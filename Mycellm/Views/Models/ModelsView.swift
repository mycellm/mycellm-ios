import SwiftUI

struct ModelsView: View {
    @State private var modelManager = ModelManager()
    @State private var downloader = ModelDownloader()
    @State private var searchText = ""
    @State private var showingSuggestions = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Loaded models
                    loadedModelsSection

                    // Local files
                    localFilesSection

                    // Active downloads
                    if !downloader.activeDownloads.isEmpty {
                        downloadsSection
                    }

                    // Suggested models
                    suggestedModelsSection
                }
                .padding(.vertical)
            }
            .background(Color.voidBlack)
            .navigationTitle("Models")
            .onAppear { modelManager.scanLocalModels() }
        }
    }

    private var loadedModelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Loaded", count: modelManager.loadedModels.count)

            if modelManager.loadedModels.isEmpty {
                EmptyState(message: "No models loaded", icon: "cube.box")
            } else {
                ForEach(modelManager.loadedModels) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .font(.mono(13, weight: .medium))
                                .foregroundStyle(Color.consoleText)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(model.sizeBytes), countStyle: .file))
                                .font(.mono(11))
                                .foregroundStyle(Color.consoleDim)
                        }

                        Spacer()

                        ScopeBadge(scope: model.scope)
                    }
                    .padding(12)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .swipeActions(edge: .trailing) {
                        Button("Unload") {
                            Task { await modelManager.unloadModel(model) }
                        }
                        .tint(Color.computeRed)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private var localFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "On Disk", count: modelManager.localFiles.count)

            if modelManager.localFiles.isEmpty {
                EmptyState(message: "No GGUF files found", icon: "doc")
            } else {
                ForEach(modelManager.localFiles) { file in
                    HStack {
                        Circle()
                            .fill(ramFitColor(file.ramFit))
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.filename)
                                .font(.mono(12))
                                .foregroundStyle(Color.consoleText)
                            Text(file.sizeDescription)
                                .font(.mono(10))
                                .foregroundStyle(Color.consoleDim)
                        }

                        Spacer()

                        if file.isLoaded {
                            Text("Loaded")
                                .font(.mono(10))
                                .foregroundStyle(Color.sporeGreen)
                        } else {
                            Button("Load") {
                                Task { try? await modelManager.loadModel(file: file) }
                            }
                            .font(.mono(11, weight: .medium))
                            .foregroundStyle(Color.sporeGreen)
                        }
                    }
                    .padding(10)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.horizontal)
    }

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Downloads", count: downloader.activeDownloads.count)

            ForEach(downloader.activeDownloads) { dl in
                VStack(alignment: .leading, spacing: 6) {
                    Text(dl.filename)
                        .font(.mono(12, weight: .medium))
                        .foregroundStyle(Color.consoleText)

                    ProgressView(value: dl.progress)
                        .tint(Color.sporeGreen)

                    Text(dl.progressDescription)
                        .font(.mono(10))
                        .foregroundStyle(Color.consoleDim)
                }
                .padding(12)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal)
    }

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
                        Text(String(format: "%.1f GB • %.1fB params", suggestion["size_gb"] as? Double ?? 0, suggestion["params_b"] as? Double ?? 0))
                            .font(.mono(10))
                            .foregroundStyle(Color.consoleDim)
                    }

                    Spacer()

                    Button("Download") {
                        Task {
                            try? await downloader.download(
                                repoId: suggestion["repo_id"] as? String ?? "",
                                filename: suggestion["filename"] as? String ?? ""
                            )
                        }
                    }
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(Color.relayBlue)
                }
                .padding(10)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal)
    }

    private func ramFitColor(_ level: HardwareInfo.RAMFitLevel) -> Color {
        switch level {
        case .comfortable: .sporeGreen
        case .tight: .ledgerGold
        case .tooLarge: .computeRed
        }
    }

    private func fitLevel(_ str: String?) -> HardwareInfo.RAMFitLevel {
        switch str {
        case "comfortable": .comfortable
        case "tight": .tight
        default: .tooLarge
        }
    }
}

// MARK: - Helpers

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

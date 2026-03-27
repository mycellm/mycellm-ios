import Foundation

/// Manages model loading, unloading, and discovery on disk.
@Observable
final class ModelManager: @unchecked Sendable {
    private(set) var loadedModels: [LoadedModel] = []
    private(set) var localFiles: [LocalModelFile] = []
    private(set) var isScanning = false
    private(set) var isLoading = false
    private(set) var loadingModelName: String?
    private(set) var loadError: String?

    let engine = InferenceEngine()

    struct LoadedModel: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let filename: String
        let sizeBytes: UInt64
        let scope: String
        let loadedAt: Date
    }

    struct LocalModelFile: Identifiable, Sendable {
        let id = UUID()
        let filename: String
        let path: String
        let sizeBytes: UInt64
        let isLoaded: Bool

        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
        }

        var ramFit: HardwareInfo.RAMFitLevel {
            HardwareInfo.ramFit(modelSizeBytes: sizeBytes)
        }
    }

    /// Models directory in app's Documents.
    static var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scan the models directory for GGUF files.
    func scanLocalModels() {
        isScanning = true
        defer { isScanning = false }

        let dir = Self.modelsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return }

        let loadedNames = Set(loadedModels.map(\.filename))

        localFiles = files
            .filter { $0.pathExtension == "gguf" }
            .compactMap { url -> LocalModelFile? in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return LocalModelFile(
                    filename: url.lastPathComponent,
                    path: url.path,
                    sizeBytes: UInt64(size),
                    isLoaded: loadedNames.contains(url.lastPathComponent)
                )
            }
            .sorted { $0.filename < $1.filename }
    }

    /// Load a model from disk into the inference engine.
    func loadModel(file: LocalModelFile, scope: String = "home") async throws {
        isLoading = true
        loadingModelName = file.filename
        loadError = nil

        do {
            try await engine.loadModel(path: file.path, name: file.filename)
            let loaded = LoadedModel(
                name: file.filename, filename: file.filename,
                sizeBytes: file.sizeBytes, scope: scope, loadedAt: Date()
            )
            loadedModels = [loaded] // Only one model at a time on iOS
            isLoading = false
            loadingModelName = nil
            // Remember for auto-load on next launch
            await MainActor.run { Preferences.shared.lastLoadedModel = file.filename }
            scanLocalModels()
        } catch {
            isLoading = false
            loadingModelName = nil
            loadError = error.localizedDescription
            throw error
        }
    }

    /// Unload a model.
    func unloadModel(_ model: LoadedModel) async {
        await engine.unloadModel()
        loadedModels.removeAll { $0.id == model.id }
        scanLocalModels()
    }

    /// Set model scope (home/public/networks).
    func setScope(_ scope: String, for model: LoadedModel) {
        if let idx = loadedModels.firstIndex(where: { $0.id == model.id }) {
            let m = loadedModels[idx]
            loadedModels[idx] = LoadedModel(
                name: m.name, filename: m.filename,
                sizeBytes: m.sizeBytes, scope: scope, loadedAt: m.loadedAt
            )
        }
    }

    /// Delete a model file from disk.
    func deleteModel(file: LocalModelFile) {
        try? FileManager.default.removeItem(atPath: file.path)
        scanLocalModels()
    }

    /// Auto-load the last used model if available and RAM allows.
    func autoLoadLastModel() async {
        let lastFilename = await MainActor.run { Preferences.shared.lastLoadedModel }
        guard loadedModels.isEmpty,
              let filename = lastFilename,
              let file = localFiles.first(where: { $0.filename == filename }),
              file.ramFit != .tooLarge else { return }

        try? await loadModel(file: file, scope: "public")
    }

    /// Load an API-backed model (OpenAI-compatible endpoint).
    /// This registers the model without loading a GGUF — inference is proxied to the remote API.
    func loadAPIModel(name: String, apiBase: String, apiKey: String, apiModel: String, ctxLen: Int) async throws {
        // Validate connectivity by listing models
        var base = apiBase.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/v1") && !base.contains("/v1/") { base += "/v1" }

        var request = URLRequest(url: URL(string: "\(base)/models")!)
        request.timeoutInterval = 10
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) else {
            throw MycellmError.transportError("Cannot reach \(base)")
        }

        // Store config for persistence
        let config = APIModelConfig(name: name, apiBase: base, apiKey: apiKey, apiModel: apiModel, ctxLen: ctxLen)
        var saved = loadSavedAPIConfigs()
        saved.removeAll { $0.name == name }
        saved.append(config)
        saveAPIConfigs(saved)

        let loaded = LoadedModel(
            name: name, filename: "api:\(name)",
            sizeBytes: 0, scope: "home", loadedAt: Date()
        )
        loadedModels.append(loaded)
    }

    struct APIModelConfig: Codable {
        let name: String
        let apiBase: String
        let apiKey: String
        let apiModel: String
        let ctxLen: Int
    }

    func loadSavedAPIConfigs() -> [APIModelConfig] {
        guard let data = UserDefaults.standard.data(forKey: "api_model_configs"),
              let configs = try? JSONDecoder().decode([APIModelConfig].self, from: data) else { return [] }
        return configs
    }

    private func saveAPIConfigs(_ configs: [APIModelConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: "api_model_configs")
        }
    }

    /// Import a GGUF file from an external URL (Files.app, iCloud, USB drive).
    /// Copies the file into the models directory with security-scoped access.
    func importFile(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let dest = Self.modelsDirectory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw MycellmError.inferenceError("File already exists: \(url.lastPathComponent)")
        }
        try FileManager.default.copyItem(at: url, to: dest)

        // Exclude from iCloud backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var destMutable = dest
        try destMutable.setResourceValues(resourceValues)

        scanLocalModels()
    }

    /// Total size of all downloaded models.
    var totalStorageUsed: UInt64 {
        localFiles.reduce(0) { $0 + $1.sizeBytes }
    }
}

import Foundation

/// Manages model loading, unloading, and discovery on disk.
@Observable
final class ModelManager: @unchecked Sendable {
    private(set) var loadedModels: [LoadedModel] = []
    private(set) var localFiles: [LocalModelFile] = []
    private(set) var isScanning = false

    private let engine = InferenceEngine()

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

    /// Load a model from disk.
    func loadModel(file: LocalModelFile, scope: String = "home") async throws {
        try await engine.loadModel(path: file.path, name: file.filename)
        let loaded = LoadedModel(
            name: file.filename, filename: file.filename,
            sizeBytes: file.sizeBytes, scope: scope, loadedAt: Date()
        )
        loadedModels.append(loaded)
        scanLocalModels() // refresh isLoaded flags
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

    /// Total size of all downloaded models.
    var totalStorageUsed: UInt64 {
        localFiles.reduce(0) { $0 + $1.sizeBytes }
    }
}

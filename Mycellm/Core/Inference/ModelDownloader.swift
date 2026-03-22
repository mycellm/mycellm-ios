import Foundation
import Observation

/// Downloads GGUF models from HuggingFace.
@Observable
final class ModelDownloader: @unchecked Sendable {
    private(set) var activeDownloads: [Download] = []

    struct Download: Identifiable, Sendable {
        let id = UUID()
        let repoId: String
        let filename: String
        var progress: Double = 0.0
        var bytesDownloaded: Int64 = 0
        var totalBytes: Int64 = 0
        var state: State = .pending

        enum State: Sendable {
            case pending
            case downloading
            case completed
            case failed(String)
            case cancelled
        }

        var progressDescription: String {
            let downloaded = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
            if totalBytes > 0 {
                let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                return "\(downloaded) / \(total)"
            }
            return downloaded
        }
    }

    /// Download a GGUF file from HuggingFace.
    func download(repoId: String, filename: String) async throws {
        let urlString = "https://huggingface.co/\(repoId)/resolve/main/\(filename)"
        guard let url = URL(string: urlString) else {
            throw MycellmError.inferenceError("Invalid download URL")
        }

        var download = Download(repoId: repoId, filename: filename)
        download.state = .downloading
        activeDownloads.append(download)
        let downloadId = download.id

        let destination = ModelManager.modelsDirectory.appendingPathComponent(filename)

        // Exclude large files from iCloud backup
        var destURL = destination
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
            let totalBytes = Int64(response.expectedContentLength)
            updateDownload(id: downloadId) { $0.totalBytes = totalBytes }

            let fileHandle = try FileHandle(forWritingTo: {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                return destination
            }())

            var bytesWritten: Int64 = 0
            var buffer = Data()
            let chunkSize = 1024 * 1024 // 1MB chunks

            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= chunkSize {
                    fileHandle.write(buffer)
                    bytesWritten += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    let progress = totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0
                    updateDownload(id: downloadId) {
                        $0.bytesDownloaded = bytesWritten
                        $0.progress = progress
                    }
                }
            }
            // Flush remaining
            if !buffer.isEmpty {
                fileHandle.write(buffer)
                bytesWritten += Int64(buffer.count)
            }
            fileHandle.closeFile()

            // Mark as excluded from backup
            try destURL.setResourceValues(resourceValues)

            updateDownload(id: downloadId) {
                $0.state = .completed
                $0.progress = 1.0
                $0.bytesDownloaded = bytesWritten
            }
        } catch {
            updateDownload(id: downloadId) { $0.state = .failed(error.localizedDescription) }
            throw error
        }
    }

    func cancelDownload(id: UUID) {
        updateDownload(id: id) { $0.state = .cancelled }
        // TODO: cancel URLSession task
    }

    private func updateDownload(id: UUID, update: (inout Download) -> Void) {
        if let idx = activeDownloads.firstIndex(where: { $0.id == id }) {
            update(&activeDownloads[idx])
        }
    }
}

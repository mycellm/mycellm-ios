import Foundation
import Observation

/// Downloads GGUF models from HuggingFace with real-time progress.
@Observable
final class ModelDownloader: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    private(set) var activeDownloads: [Download] = []
    private var tasks: [Int: UUID] = [:]  // taskIdentifier → download ID
    private var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    struct Download: Identifiable {
        let id = UUID()
        let repoId: String
        let filename: String
        var progress: Double = 0.0
        var bytesDownloaded: Int64 = 0
        var totalBytes: Int64 = 0
        var bytesPerSecond: Int64 = 0
        var state: State = .pending
        var startTime: Date = Date()
        var task: URLSessionDownloadTask?

        enum State: String {
            case pending = "Pending"
            case downloading = "Downloading"
            case completed = "Completed"
            case failed = "Failed"
            case cancelled = "Cancelled"
        }

        var progressDescription: String {
            let downloaded = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
            if totalBytes > 0 {
                let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                let pct = Int(progress * 100)
                return "\(downloaded) / \(total) (\(pct)%)"
            }
            return downloaded
        }

        var speedDescription: String {
            guard bytesPerSecond > 0 else { return "" }
            return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file) + "/s"
        }

        var etaDescription: String {
            guard bytesPerSecond > 0, totalBytes > bytesDownloaded else { return "" }
            let remaining = totalBytes - bytesDownloaded
            let seconds = Int(remaining / bytesPerSecond)
            if seconds < 60 { return "\(seconds)s" }
            if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
            return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
        }
    }

    /// Start downloading a GGUF file from HuggingFace.
    func download(repoId: String, filename: String) {
        let urlString = "https://huggingface.co/\(repoId)/resolve/main/\(filename)"
        guard let url = URL(string: urlString) else { return }

        var dl = Download(repoId: repoId, filename: filename)
        dl.state = .downloading
        dl.startTime = Date()

        let task = session.downloadTask(with: url)
        dl.task = task
        tasks[task.taskIdentifier] = dl.id
        activeDownloads.append(dl)

        task.resume()
    }

    func cancelDownload(id: UUID) {
        guard let idx = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        activeDownloads[idx].task?.cancel()
        activeDownloads[idx].state = .cancelled
    }

    func removeDownload(id: UUID) {
        activeDownloads.removeAll { $0.id == id }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let dlId = tasks[downloadTask.taskIdentifier],
              let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }

        let elapsed = max(1, Date().timeIntervalSince(activeDownloads[idx].startTime))
        let speed = Int64(Double(totalBytesWritten) / elapsed)

        activeDownloads[idx].bytesDownloaded = totalBytesWritten
        activeDownloads[idx].totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        activeDownloads[idx].progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        activeDownloads[idx].bytesPerSecond = speed
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dlId = tasks[downloadTask.taskIdentifier],
              let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }

        // Check HTTP status
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            activeDownloads[idx].state = .failed
            tasks.removeValue(forKey: downloadTask.taskIdentifier)
            return
        }

        let filename = activeDownloads[idx].filename
        let destination = ModelManager.modelsDirectory.appendingPathComponent(filename)

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)

            // Verify GGUF magic
            if let fh = FileHandle(forReadingAtPath: destination.path) {
                let magic = fh.readData(ofLength: 4)
                fh.closeFile()
                guard magic == Data([0x47, 0x47, 0x55, 0x46]) else {
                    try? FileManager.default.removeItem(at: destination)
                    activeDownloads[idx].state = .failed
                    tasks.removeValue(forKey: downloadTask.taskIdentifier)
                    return
                }
            }

            // Exclude from iCloud backup
            var destURL = destination
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try destURL.setResourceValues(resourceValues)

            activeDownloads[idx].state = .completed
            activeDownloads[idx].progress = 1.0
        } catch {
            activeDownloads[idx].state = .failed
        }

        tasks.removeValue(forKey: downloadTask.taskIdentifier)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error,
              let dlId = tasks[task.taskIdentifier],
              let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }

        if (error as NSError).code == NSURLErrorCancelled {
            activeDownloads[idx].state = .cancelled
        } else {
            activeDownloads[idx].state = .failed
        }
        tasks.removeValue(forKey: task.taskIdentifier)
    }
}

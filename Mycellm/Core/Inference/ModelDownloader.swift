import Foundation
import Observation

/// Downloads GGUF models from HuggingFace with real-time progress.
@Observable
final class ModelDownloader: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    private(set) var activeDownloads: [Download] = []
    private var tasks: [Int: UUID] = [:]  // taskIdentifier → download ID
    private var session: URLSession!
    private let delegateQueue: OperationQueue
    private var lastProgressUpdate = Date.distantPast

    override init() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.mycellm.downloader"
        self.delegateQueue = queue
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    struct Download: Identifiable {
        let id = UUID()
        let repoId: String
        let filename: String
        /// Where the bytes came from, and how to prove they are the right ones.
        ///
        /// ⚠️ AN ARBITRARY URL IS THE ONE PATH WITH NO PUBLISHED HASH TO CHECK
        /// AGAINST. Hugging Face downloads verify against the tree API's
        /// `lfs.oid`, so the node can always tell whether it got the file it
        /// asked for. A URL an admin supplies has no such attestation, which
        /// would make it the only way to put unverified weights on a device.
        /// So the digest is not optional there — the caller commits to a
        /// sha256 up front and the download is checked against it.
        enum Origin: Sendable, Equatable {
            case huggingFace
            case url(String, sha256: String)
        }
        var origin: Origin = .huggingFace
        var progress: Double = 0.0
        var bytesDownloaded: Int64 = 0
        var totalBytes: Int64 = 0
        var bytesPerSecond: Int64 = 0
        var state: State = .pending
        var startTime: Date = Date()
        /// Last (bytes, time) sample, for a CURRENT rate rather than an average.
        var lastSampleBytes: Int64 = 0
        var lastSampleAt: Date = Date()
        var task: URLSessionDownloadTask?

        enum State: String {
            case pending = "Pending"
            case downloading = "Downloading"
            case verifying = "Verifying"
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

    // MARK: - MLX repositories (multi-file)

    /// An MLX model in flight. Separate from `Download` because the unit is a
    /// directory: progress is the sum over several files, and there is no single
    /// `filename` to name it by.
    struct RepoDownload: Identifiable {
        let id = UUID()
        let repoId: String
        let name: String                    // directory name on disk
        var bytesDownloaded: Int64 = 0
        var totalBytes: Int64 = 0
        var progress: Double = 0
        var bytesPerSecond: Int64 = 0
        var state: Download.State = .pending
        var error: String?
        var startTime: Date = Date()
        /// Last (bytes, time) sample, for a CURRENT rate rather than an average.
        var lastSampleBytes: Int64 = 0
        var lastSampleAt: Date = Date()

        var progressDescription: String {
            let done = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
            guard totalBytes > 0 else { return done }
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(done) / \(total) (\(Int(progress * 100))%)"
        }

        var speedDescription: String {
            guard bytesPerSecond > 0 else { return "" }
            return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file) + "/s"
        }

        var etaDescription: String {
            guard bytesPerSecond > 0, totalBytes > bytesDownloaded else { return "" }
            let seconds = Int((totalBytes - bytesDownloaded) / bytesPerSecond)
            if seconds < 60 { return "\(seconds)s" }
            if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
            return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
        }
    }

    private(set) var repoDownloads: [RepoDownload] = []
    private var repoTasks: [UUID: Task<Void, Never>] = [:]

    /// Called when a download finishes and the models directory has changed.
    ///
    /// ⚠️ WITHOUT THIS, A DOWNLOAD THE UI DIDN'T START IS INVISIBLE. Nothing
    /// rescanned the models directory except ModelsView's `.onChange`, so a
    /// model pulled through /v1/node/models/download landed on disk correctly
    /// and then didn't exist as far as the node was concerned: absent from
    /// /v1/node/models/local, absent from /v1/models, and unloadable by name
    /// until someone opened the Models tab. Which is precisely the person a
    /// remote download exists to avoid needing.
    @MainActor var onModelsChanged: (@MainActor () -> Void)?

    /// Install an MLX model from a manifest — the directory-shaped counterpart
    /// to a single-URL GGUF install. Same staging, resume and publish path as a
    /// Hugging Face repo; only the source and verification differ.
    @discardableResult
    @MainActor
    func downloadManifest(assets: [MLXRepo.Asset], name: String, allowExpensive: Bool = false) -> UUID {
        if let existing = repoDownloads.first(where: {
            $0.name == name && ($0.state == .downloading || $0.state == .pending)
        }) {
            return existing.id
        }
        var dl = RepoDownload(repoId: "manifest", name: name)
        dl.state = .downloading
        dl.startTime = Date()
        repoDownloads.append(dl)
        let id = dl.id

        repoTasks[id] = Task { [weak self] in
            do {
                try await MLXRepo.download(
                    manifest: assets, name: name, allowExpensive: allowExpensive
                ) { done, total in
                    Task { @MainActor in self?.updateRepo(id, done: done, total: total) }
                }
                guard let self, let i = repoDownloads.firstIndex(where: { $0.id == id }) else { return }
                repoDownloads[i].state = .completed
                repoDownloads[i].progress = 1.0
                repoTasks[id] = nil
                onModelsChanged?()
            } catch {
                let cancelled = error is CancellationError
                    || (error as NSError).code == NSURLErrorCancelled
                if cancelled { MLXRepo.discardStaging(name: name) }
                guard let self, let i = repoDownloads.firstIndex(where: { $0.id == id }) else { return }
                repoDownloads[i].state = cancelled ? .cancelled : .failed
                repoDownloads[i].error = cancelled ? nil : error.localizedDescription
                repoTasks[id] = nil
            }
        }
        return id
    }

    /// Fetch an MLX repo from Hugging Face. Returns the download id so the
    /// HTTP caller can poll it.
    @discardableResult
    @MainActor
    func downloadRepo(repoId: String, name: String? = nil, allowExpensive: Bool = false) -> UUID {
        let dirName = name ?? MLXRepo.directoryName(for: repoId)

        // Re-requesting something already running is a resume in the user's
        // head, not a second copy — and two writers in one staging directory
        // would interleave into a corrupt model.
        if let existing = repoDownloads.first(where: {
            $0.name == dirName && ($0.state == .downloading || $0.state == .pending)
        }) {
            return existing.id
        }

        var dl = RepoDownload(repoId: repoId, name: dirName)
        dl.state = .downloading
        dl.startTime = Date()
        repoDownloads.append(dl)
        let id = dl.id

        // ⚠️ This Task inherits @MainActor from the enclosing method, so the
        // state mutations below need no hop — only the progress callback does,
        // since MLXRepo calls it from whatever context the transfer is on.
        repoTasks[id] = Task { [weak self] in
            do {
                try await MLXRepo.download(
                    repoId: repoId, name: dirName, allowExpensive: allowExpensive
                ) { done, total in
                    Task { @MainActor in self?.updateRepo(id, done: done, total: total) }
                }
                guard let self, let i = repoDownloads.firstIndex(where: { $0.id == id }) else { return }
                repoDownloads[i].state = .completed
                repoDownloads[i].progress = 1.0
                repoTasks[id] = nil
                onModelsChanged?()
            } catch {
                let cancelled = error is CancellationError
                    || (error as NSError).code == NSURLErrorCancelled
                // Staging is left in place on a plain failure so a retry resumes
                // from it; an explicit cancel means the user wants the space back.
                if cancelled { MLXRepo.discardStaging(name: dirName) }
                guard let self, let i = repoDownloads.firstIndex(where: { $0.id == id }) else { return }
                repoDownloads[i].state = cancelled ? .cancelled : .failed
                repoDownloads[i].error = cancelled ? nil : error.localizedDescription
                repoTasks[id] = nil
            }
        }
        return id
    }

    @MainActor
    private func updateRepo(_ id: UUID, done: Int64, total: Int64) {
        guard let i = repoDownloads.firstIndex(where: { $0.id == id }) else { return }
        repoDownloads[i].bytesDownloaded = done
        repoDownloads[i].totalBytes = total
        repoDownloads[i].progress = total > 0 ? Double(done) / Double(total) : 0
        let s = Self.sampleRate(
            previous: repoDownloads[i].bytesPerSecond,
            lastBytes: repoDownloads[i].lastSampleBytes,
            lastAt: repoDownloads[i].lastSampleAt,
            now: done)
        repoDownloads[i].bytesPerSecond = s.rate
        repoDownloads[i].lastSampleBytes = s.bytes
        repoDownloads[i].lastSampleAt = s.at
    }

    @MainActor
    func cancelRepo(id: UUID) {
        repoTasks[id]?.cancel()
        repoTasks[id] = nil
        if let i = repoDownloads.firstIndex(where: { $0.id == id }) {
            repoDownloads[i].state = .cancelled
            MLXRepo.discardStaging(name: repoDownloads[i].name)
        }
    }

    @MainActor
    func removeRepoDownload(id: UUID) {
        repoDownloads.removeAll { $0.id == id }
    }

    /// Fetch a model from an arbitrary URL, verified against a caller-supplied
    /// digest. For models that aren't on Hugging Face — an internal mirror, a
    /// private build — coordinated by whoever holds the node's management key.
    /// Returns the download's id so the caller can abort it. A file download
    /// that cannot be addressed cannot be cancelled — see `cancelDownload`.
    @discardableResult
    func download(url urlString: String, filename: String, sha256: String,
                  allowExpensive: Bool = false) -> UUID? {
        guard let url = URL(string: urlString) else { return nil }

        var dl = Download(repoId: url.host ?? "url", filename: filename)
        dl.origin = .url(urlString, sha256: sha256.lowercased())
        dl.state = .downloading
        dl.startTime = Date()

        let task = session.downloadTask(
            with: DownloadPolicy.request(for: url, override: allowExpensive))
        dl.task = task
        tasks[task.taskIdentifier] = dl.id
        activeDownloads.append(dl)
        task.resume()
        return dl.id
    }

    /// Start downloading a GGUF file from HuggingFace.
    ///
    /// `allowExpensive` is the caller's one-shot opt-in to a metered path; the
    /// standing preference is consulted by `DownloadPolicy` either way. The
    /// request carries the decision so URLSession enforces it even if a caller
    /// skipped the pre-check.
    @discardableResult
    func download(repoId: String, filename: String, allowExpensive: Bool = false) -> UUID? {
        let urlString = "https://huggingface.co/\(repoId)/resolve/main/\(filename)"
        guard let url = URL(string: urlString) else { return nil }

        var dl = Download(repoId: repoId, filename: filename)
        dl.state = .downloading
        dl.startTime = Date()

        let task = session.downloadTask(
            with: DownloadPolicy.request(for: url, override: allowExpensive))
        dl.task = task
        tasks[task.taskIdentifier] = dl.id
        activeDownloads.append(dl)

        task.resume()
        return dl.id
    }

    /// The name a download is allowed to write, or nil if it isn't safe.
    ///
    /// ⚠️ THIS IS THE LAST LINE, NOT THE FIRST. The destination is built as
    /// `modelsDirectory.appendingPathComponent(filename)` and the publish step
    /// does `removeItem` before `moveItem` — so a `filename` that walks out of
    /// the models directory does not merely write in the wrong place, it
    /// *deletes* whatever it lands on first. The routes validate too, for a
    /// clean 400, but the check has to exist here or a future caller that skips
    /// the route reintroduces it.
    ///
    /// A Hugging Face `filename` may legitimately name a file inside a repo
    /// subdirectory, so the fetch keeps the full path and only the destination
    /// is reduced to its last component.
    static func safeDestinationName(_ filename: String) -> String? {
        let base = (filename as NSString).lastPathComponent
        guard !base.isEmpty, base != ".", base != "..",
              !base.contains("/"), !base.contains(".."), !base.hasPrefix(".")
        else { return nil }
        return base
    }

    func cancelDownload(id: UUID) {
        guard let idx = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        activeDownloads[idx].task?.cancel()
        activeDownloads[idx].state = .cancelled
    }

    func removeDownload(id: UUID) {
        activeDownloads.removeAll { $0.id == id }
    }

    /// Current transfer rate from successive samples, lightly smoothed.
    ///
    /// ⚠️ THE OLD RATE WAS `bytesDownloaded / elapsedSinceStart`, WHICH IS AN
    /// AVERAGE, NOT A RATE. Three ways that misleads:
    ///   - it can only crawl toward the true rate, so the figure shown early in
    ///     a download is always far too low;
    ///   - it never recovers from a stall — a transfer that pauses and resumes
    ///     reports a permanently depressed speed, and the ETA inherits it;
    ///   - on a RESUMED model the byte count starts high while elapsed starts
    ///     at ~0, so the first sample reports an absurd speed.
    /// An EMA over deltas tracks the real rate and settles after a stall.
    /// Returns the new (rate, sampleBytes, sampleAt) — by value, not `inout`.
    /// `@Observable` turns the arrays into computed properties, and Swift
    /// refuses two `inout` writebacks into one of those in a single call.
    static func sampleRate(
        previous: Int64, lastBytes: Int64, lastAt: Date, now bytes: Int64
    ) -> (rate: Int64, bytes: Int64, at: Date) {
        let at = Date()
        let dt = at.timeIntervalSince(lastAt)
        // Too short a window makes the figure jump around; wait for a real one.
        guard dt >= 0.5 else { return (previous, lastBytes, lastAt) }
        let delta = bytes - lastBytes
        // A resumed or restarted transfer can move the counter backwards.
        guard delta > 0 else { return (previous, bytes, at) }
        let instant = Double(delta) / dt
        let smoothed = previous > 0 ? 0.7 * Double(previous) + 0.3 * instant : instant
        return (Int64(smoothed), bytes, at)
    }

    // MARK: - URLSessionDownloadDelegate (runs on background delegateQueue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Throttle UI updates to ~4 Hz to avoid hammering @Observable
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) > 0.25 else { return }
        lastProgressUpdate = now

        guard let dlId = tasks[downloadTask.taskIdentifier],
              let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }

        let sample = Self.sampleRate(
            previous: activeDownloads[idx].bytesPerSecond,
            lastBytes: activeDownloads[idx].lastSampleBytes,
            lastAt: activeDownloads[idx].lastSampleAt,
            now: totalBytesWritten)
        let speed = sample.rate

        DispatchQueue.main.async { [self] in
            guard let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }
            activeDownloads[idx].bytesDownloaded = totalBytesWritten
            activeDownloads[idx].totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
            activeDownloads[idx].progress = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                : 0
            activeDownloads[idx].bytesPerSecond = speed
            activeDownloads[idx].lastSampleBytes = sample.bytes
            activeDownloads[idx].lastSampleAt = sample.at
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dlId = tasks[downloadTask.taskIdentifier],
              let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }

        // Check HTTP status
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            DispatchQueue.main.async { [self] in
                guard let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }
                activeDownloads[idx].state = .failed
            }
            tasks.removeValue(forKey: downloadTask.taskIdentifier)
            return
        }

        let filename = activeDownloads[idx].filename
        guard let safeName = Self.safeDestinationName(filename) else {
            DispatchQueue.main.async { [self] in
                guard let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }
                activeDownloads[idx].state = .failed
            }
            tasks.removeValue(forKey: downloadTask.taskIdentifier)
            return
        }
        let destination = ModelManager.modelsDirectory.appendingPathComponent(safeName)

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)

            // Verify GGUF magic
            if let fh = FileHandle(forReadingAtPath: destination.path) {
                let magic = fh.readData(ofLength: 4)
                fh.closeFile()
                guard magic == Data([0x47, 0x47, 0x55, 0x46]) else {
                    try? FileManager.default.removeItem(at: destination)
                    DispatchQueue.main.async { [self] in
                        guard let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }
                        activeDownloads[idx].state = .failed
                    }
                    tasks.removeValue(forKey: downloadTask.taskIdentifier)
                    return
                }
            }

            // Exclude from iCloud backup
            var destURL = destination
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try destURL.setResourceValues(resourceValues)

            // Verify against HF's published content hash before declaring
            // success (mirror of the Python node's download verification).
            // Unreachable tree API → unverified but accepted (offline-safe);
            // a hash mismatch deletes the file and fails the download.
            let repoId = activeDownloads[idx].repoId
            let origin = activeDownloads[idx].origin
            DispatchQueue.main.async { [self] in
                guard let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }
                activeDownloads[idx].state = .verifying
                activeDownloads[idx].progress = 1.0
            }
            Task { [weak self] in
                let expected: HFVerify.Expected?
                switch origin {
                case .huggingFace:
                    // Advisory: an unreachable tree API must not stop an
                    // otherwise-good download, since the node has to work
                    // offline-ish. A mismatch is still fatal.
                    expected = await HFVerify.fetchExpectedHash(repoId: repoId, filename: filename)
                case .url(_, let sha256):
                    // ⚠️ NOT ADVISORY. There is no second source to fall back
                    // on, so an unverifiable URL download is a failed one.
                    expected = HFVerify.Expected(algo: "sha256", hex: sha256)
                }
                let ok = (try? HFVerify.verify(file: destination, expected: expected, filename: filename)) != nil
                await MainActor.run { [weak self] in
                    guard let self, let idx = self.activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }
                    self.activeDownloads[idx].state = ok ? .completed : .failed
                    if ok { self.onModelsChanged?() }
                }
            }
        } catch {
            DispatchQueue.main.async { [self] in
                guard let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }
                activeDownloads[idx].state = .failed
            }
        }

        tasks.removeValue(forKey: downloadTask.taskIdentifier)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error,
              let dlId = tasks[task.taskIdentifier] else { return }

        let isCancelled = (error as NSError).code == NSURLErrorCancelled
        DispatchQueue.main.async { [self] in
            guard let idx = activeDownloads.firstIndex(where: { $0.id == dlId }) else { return }
            activeDownloads[idx].state = isCancelled ? .cancelled : .failed
        }
        tasks.removeValue(forKey: task.taskIdentifier)
    }
}

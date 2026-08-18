import Foundation

/// Fetching an MLX model, which is a DIRECTORY and not a single file.
///
/// ⚠️ THIS IS WHY THE MLX PATH HAS BEEN UNREACHABLE. MLXBackend shipped in
/// builds 13-15 and `ModelManager.scanLocalModels` has understood MLX
/// directories the whole time, but nothing in the app could put one on the
/// device: `ModelDownloader.download` fetches exactly one file to exactly one
/// path, and an MLX model is a config, a tokenizer, and one or more safetensors
/// shards that only mean anything together. Side-loading through the Files app
/// was the only way in. This closes that.
///
/// Four things this has to get right, each of which has a specific failure it
/// prevents:
///
///  1. **Publish atomically.** `scanLocalModels` calls a directory a loadable
///     model when it holds `config.json` and *any* `.safetensors`
///     (ModelManager.swift:113-117). A download that writes in place would
///     satisfy that test the moment the first shard lands, so an interrupted
///     fetch leaves behind something the picker offers and the engine then
///     fails to load — with a confusing error, on a model the user believes
///     they downloaded. So assemble under `.staging/` and move into place only
///     once every file is present.
///
///  2. **Stage on the same volume.** `.staging` lives *inside* the models
///     directory, which looks odd next to the models but is deliberate: a move
///     within a volume is a rename — atomic and instant. Staging in `tmp/` or
///     Caches would make publishing a multi-gigabyte copy, needing the model's
///     size *twice* on a device that likely hasn't got it. (Those directories
///     are also purgeable under space pressure, which is precisely when a large
///     download is in flight.) `.staging` is invisible to the scanner for free:
///     it holds no `config.json` of its own, so it fails the directory test.
///
///  3. **Check free space first.** iOS surfaces exhaustion as a write error
///     partway through, i.e. after twenty minutes of cellular data.
///
///  4. **Resume by byte, not by file.** Shards run to several GB; restarting one
///     from zero because Wi-Fi dropped at 90% is the difference between a
///     feature and a thing users stop trusting.
enum MLXRepo {

    struct Asset: Sendable {
        let path: String
        let size: Int64
        /// Where to fetch this file from. nil → derive the Hugging Face URL
        /// from the repo id, which is the original behaviour.
        var url: String? = nil
        /// Expected sha256. Set for manifest installs, where there is no
        /// published hash to look up; nil for Hugging Face, which is verified
        /// against the tree API instead.
        var sha256: String? = nil
    }

    enum Failure: LocalizedError {
        case treeUnavailable(String)
        case notAnMLXRepo(String)
        case insufficientSpace(needed: Int64, free: Int64)
        case httpStatus(Int, String)
        case digestMismatch(file: String, expected: String, got: String)
        case manifestIncomplete(String)

        var errorDescription: String? {
            switch self {
            case .treeUnavailable(let repo):
                return "Couldn't read the file list for \(repo). Check the connection and the repo name."
            case .notAnMLXRepo(let repo):
                return "\(repo) has no .safetensors weights — it isn't an MLX repo. "
                     + "MLX repos are usually named \"…-4bit\" or \"…-8bit\" (try the mlx-community org)."
            case .insufficientSpace(let needed, let free):
                let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                return "Needs \(n) but only \(f) is free."
            case .httpStatus(let code, let file):
                return code == 401 || code == 403
                    ? "\(file) needs authentication — this repo is gated on Hugging Face."
                    : "Download failed for \(file) (HTTP \(code))."
            case .digestMismatch(let file, let expected, let got):
                return "\(file) does not match the digest supplied for it "
                     + "(expected \(expected.prefix(12))…, got \(got.prefix(12))…). The file was discarded."
            case .manifestIncomplete(let why):
                return "Manifest rejected: \(why)"
            }
        }
    }

    // MARK: - What belongs to an MLX model

    /// ⚠️ AN ALLOWLIST, NOT A DENYLIST. Repos routinely also carry the original
    /// fp16 weights, ONNX exports, or a full set of GGUF quants — pulling a repo
    /// wholesale can mean tens of gigabytes to obtain a 4GB model. Anything not
    /// recognised is skipped, so an unfamiliar extra file costs nothing.
    ///
    /// Subdirectory entries are skipped: MLX repos are flat, and the ones that
    /// aren't keep *other* formats in those folders (`onnx/`, `original/`).
    static func isMLXAsset(_ path: String) -> Bool {
        guard !path.contains("/") else { return false }
        let name = path.lowercased()
        if name.hasSuffix(".gguf") { return false }
        if name.hasSuffix(".safetensors") { return true }
        // Covers config / tokenizer / generation_config / the shard index.
        if name.hasSuffix(".json") { return true }
        return ["tokenizer.model", "merges.txt", "vocab.txt", "chat_template.jinja"].contains(name)
    }

    /// Ask HF what is in the repo. `size` is the LFS size when present — the
    /// plain `size` of an LFS entry is the size of the *pointer file*, a few
    /// hundred bytes, which would make the space check pass for anything.
    static func plan(repoId: String) async throws -> [Asset] {
        guard let url = URL(string:
            "https://huggingface.co/api/models/\(repoId)/tree/main?recursive=true") else {
            throw Failure.treeUnavailable(repoId)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure.treeUnavailable(repoId)
        }

        var assets: [Asset] = []
        for e in entries {
            guard (e["type"] as? String) == "file",
                  let path = e["path"] as? String, isMLXAsset(path) else { continue }
            let lfsSize = (e["lfs"] as? [String: Any])?["size"] as? Int64
            assets.append(Asset(path: path, size: lfsSize ?? (e["size"] as? Int64 ?? 0)))
        }

        guard assets.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw Failure.notAnMLXRepo(repoId)
        }
        return assets
    }

    // MARK: - Paths

    static var stagingRoot: URL {
        ModelManager.modelsDirectory.appendingPathComponent(".staging", isDirectory: true)
    }

    /// `mlx-community/Qwen2.5-7B-Instruct-4bit` → `Qwen2.5-7B-Instruct-4bit`.
    static func directoryName(for repoId: String) -> String {
        repoId.split(separator: "/").last.map(String.init) ?? repoId
    }

    /// Space the volume will actually give us. `volumeAvailableCapacity` alone
    /// overstates it — it counts purgeable space the system may decline to
    /// release. ForImportantUsage is the honest number for a user-initiated
    /// download that must survive.
    static func freeBytes() -> Int64 {
        let values = try? ModelManager.modelsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Fetch

    /// Install an MLX model from a caller-supplied manifest.
    ///
    /// ⚠️ MLX IS THE NATIVE FORMAT ON THIS FLEET, SO IT GETS THE SAME
    /// TREATMENT AS GGUF. Every node here is Apple Silicon, and an
    /// admin-install path that only handled single-file GGUF would have missed
    /// exactly the models these devices run best. An MLX model is a directory,
    /// so the manifest is per-file — each entry names its own URL and digest,
    /// and the existing staging/publish/resume machinery is reused unchanged.
    ///
    /// Every file must carry a sha256 for the same reason the single-URL form
    /// does: there is no tree API to ask, so the caller commits to the hashes
    /// up front or the install is refused.
    @discardableResult
    static func download(
        manifest assets: [Asset],
        name: String,
        allowExpensive: Bool = false,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try await install(assets: assets, repoId: "", dirName: name,
                          allowExpensive: allowExpensive, onProgress: onProgress)
    }

    /// Download every asset into staging, then publish the directory in one move.
    ///
    /// `onProgress` receives (bytes done across the whole model, total bytes) and
    /// is called from a background context.
    @discardableResult
    static func download(
        repoId: String,
        name: String? = nil,
        allowExpensive: Bool = false,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let assets = try await plan(repoId: repoId)
        return try await install(
            assets: assets, repoId: repoId,
            dirName: name ?? directoryName(for: repoId),
            allowExpensive: allowExpensive, onProgress: onProgress)
    }

    /// The shared installer: staging, space check, resume, publish. Identical
    /// whether the file list came from Hugging Face or from a manifest — only
    /// where each file is fetched from, and how it is verified, differs.
    private static func install(
        assets: [Asset],
        repoId: String,
        dirName: String,
        allowExpensive: Bool,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let staging = stagingRoot.appendingPathComponent(dirName, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // Bytes already on disk from an earlier attempt don't need fetching, and
        // must not be counted as missing when checking free space.
        let onDisk: [String: Int64] = assets.reduce(into: [:]) { acc, a in
            let p = staging.appendingPathComponent(a.path).path
            acc[a.path] = (try? fm.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0
        }
        let total = assets.reduce(Int64(0)) { $0 + $1.size }
        let remaining = assets.reduce(Int64(0)) { $0 + max(0, $1.size - (onDisk[$1.path] ?? 0)) }

        // Margin so completing the download doesn't leave the device wedged;
        // iOS starts evicting and misbehaving well before literal zero.
        let margin: Int64 = 500 * 1024 * 1024
        let free = freeBytes()
        guard free > remaining + margin else {
            throw Failure.insufficientSpace(needed: remaining + margin, free: free)
        }

        var completedBytes = assets.reduce(Int64(0)) { $0 + min($1.size, onDisk[$1.path] ?? 0) }
        onProgress(completedBytes, total)

        for asset in assets {
            try Task.checkCancellation()
            let dest = staging.appendingPathComponent(asset.path)
            let have = onDisk[asset.path] ?? 0
            if have > 0, have == asset.size { continue }   // already complete

            let base = completedBytes - min(have, asset.size)
            try await fetchFile(
                repoId: repoId, asset: asset, to: dest, resumeFrom: have,
                allowExpensive: allowExpensive,
                onBytes: { done in onProgress(base + done, total) }
            )
            // ⚠️ VERIFIED PER FILE, NOT AT THE END. A manifest install has no
            // tree API to fall back on, so the digest is the only evidence the
            // bytes are right — and checking each shard as it lands means a bad
            // one fails before the next multi-gigabyte fetch starts, instead of
            // after all of them.
            if let want = asset.sha256?.lowercased() {
                let got = try HFVerify.fileHash(url: dest, algo: "sha256")
                guard got == want else {
                    try? FileManager.default.removeItem(at: dest)
                    throw Failure.digestMismatch(file: asset.path, expected: want, got: got)
                }
            }

            completedBytes = base + asset.size
            onProgress(completedBytes, total)
        }

        // Publish. Same volume, so this is a rename.
        let dest = ModelManager.modelsDirectory.appendingPathComponent(dirName, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: staging, to: dest)

        var excluded = dest
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? excluded.setResourceValues(rv)

        return dest
    }

    /// One asset, resuming mid-file when there is something to resume from.
    private static func fetchFile(
        repoId: String, asset: Asset, to dest: URL, resumeFrom have: Int64,
        allowExpensive: Bool = false,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        // A manifest asset carries its own URL; a Hugging Face one derives it.
        let source = asset.url ?? "https://huggingface.co/\(repoId)/resolve/main/\(asset.path)"
        guard let url = URL(string: source) else {
            throw Failure.httpStatus(0, asset.path)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        // Weight-sized transfers: the metered-network policy applies here, not
        // to the small JSON `plan()` fetch that sizes them.
        DownloadPolicy.apply(to: &request, override: allowExpensive)
        // A partial file from a previous attempt: ask only for the rest.
        if have > 0, have < asset.size {
            request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range")
        }

        let (tmp, response) = try await downloadTask(request, onBytes: { onBytes(have + $0) })
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.httpStatus(0, asset.path)
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw Failure.httpStatus(http.statusCode, asset.path)
        }

        let fm = FileManager.default
        if http.statusCode == 206 {
            // Server honoured the range — append to what we already had.
            let handle = try FileHandle(forWritingTo: dest)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(contentsOf: tmp, options: .mappedIfSafe))
        } else {
            // ⚠️ 200 to a Range request means the server IGNORED it and is
            // sending the whole file. Appending here would silently produce a
            // corrupt shard that is the right size on a retry and fails to load
            // with an opaque error. Replace instead.
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
        }
    }

    /// `URLSession.download(for:)` gives no progress, and a download *delegate*
    /// conflicts with the async variant's own file handling — so drive the
    /// completion-handler task and read progress off its `Progress`.
    private static func downloadTask(
        _ request: URLRequest, onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        final class Box: @unchecked Sendable {
            var observation: NSKeyValueObservation?
            var task: URLSessionDownloadTask?
        }
        let box = Box()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: request) { url, response, error in
                    box.observation?.invalidate()
                    if let error { continuation.resume(throwing: error); return }
                    guard let url, let response else {
                        continuation.resume(throwing: Failure.httpStatus(0, request.url?.lastPathComponent ?? ""))
                        return
                    }
                    // The temp file is deleted when this handler returns, so it
                    // has to be moved somewhere durable before we hand it back.
                    let keep = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: url, to: keep)
                        continuation.resume(returning: (keep, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                // ⚠️ OBSERVE `fractionCompleted`, NOT `completedUnitCount`.
                // KVO notifications for `completedUnitCount` on a URLSession
                // task's Progress do not fire reliably; `fractionCompleted` is
                // the property Foundation actually publishes. Observing the
                // wrong one meant the callback never ran DURING a transfer, so
                // a multi-gigabyte shard reported nothing at all — the byte
                // count only moved when a whole file finished and `install`
                // pushed an aggregate. On a model that is one 2.8 GB
                // safetensors plus a handful of small JSONs, that is a progress
                // bar pinned near zero for the entire download and then a jump
                // to 100%. Reading `completedUnitCount` inside the handler is
                // fine — it is the notification that was unreliable, not the
                // value.
                box.observation = task.progress.observe(\.fractionCompleted) { p, _ in
                    let done = p.completedUnitCount
                    if done > 0 {
                        onBytes(done)
                    } else if p.totalUnitCount > 0 {
                        // Belt and braces: derive bytes from the fraction if the
                        // counter itself has not been populated yet.
                        onBytes(Int64(p.fractionCompleted * Double(p.totalUnitCount)))
                    }
                }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// Remove a half-finished staging directory (user cancelled, or a failure
    /// they don't intend to retry). Reclaims the space immediately.
    static func discardStaging(name: String) {
        try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(name))
    }
}

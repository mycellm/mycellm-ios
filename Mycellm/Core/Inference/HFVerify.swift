import CryptoKit
import Foundation

/// Download content verification against Hugging Face's published hashes —
/// Swift mirror of the Python node's `inference/hf_verify.py`.
///
/// The tree API (`/api/models/{repo}/tree/main?recursive=true`) publishes a
/// per-file hash: LFS files (all model weights) carry the raw sha256 in
/// `lfs.oid`; small non-LFS files only have the git blob sha1 in `oid`
/// (sha1 of "blob <size>\0" + content). Verification is advisory when the
/// tree API is unreachable (downloads must work offline); a mismatch is
/// fatal and the caller deletes the file.
enum HFVerify {
    struct Expected: Sendable, Equatable {
        let algo: String  // "sha256" | "git-sha1"
        let hex: String
    }

    /// Look up the published hash for one file. nil → verification skipped.
    static func fetchExpectedHash(repoId: String, filename: String) async -> Expected? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoId)/tree/main?recursive=true") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return expected(fromTree: entries, filename: filename)
    }

    /// Pure lookup half of fetchExpectedHash (testable without network).
    static func expected(fromTree entries: [[String: Any]], filename: String) -> Expected? {
        for e in entries where (e["type"] as? String) == "file" && (e["path"] as? String) == filename {
            if let lfs = e["lfs"] as? [String: Any], let oid = lfs["oid"] as? String {
                return Expected(algo: "sha256", hex: oid.lowercased())
            }
            if let oid = e["oid"] as? String {
                return Expected(algo: "git-sha1", hex: oid.lowercased())
            }
        }
        return nil
    }

    /// Streamed content hash of a finished download, HF-style.
    static func fileHash(url: URL, algo: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0

        func digestHex<H: HashFunction>(_ hasher: inout H) throws -> String {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        switch algo {
        case "sha256":
            var h = SHA256()
            return try digestHex(&h)
        case "git-sha1":
            var h = Insecure.SHA1()
            h.update(data: Data("blob \(size)\u{0}".utf8))
            return try digestHex(&h)
        default:
            throw MycellmError.inferenceError("unknown hash algo \(algo)")
        }
    }

    /// Verify a completed download. Returns "sha256"/"git-sha1"/"unverified";
    /// throws (after deleting the file) on mismatch.
    static func verify(file: URL, expected: Expected?, filename: String) throws -> String {
        guard let expected else { return "unverified" }
        let got = try fileHash(url: file, algo: expected.algo)
        guard got == expected.hex else {
            try? FileManager.default.removeItem(at: file)
            throw MycellmError.inferenceError(
                "\(filename): \(expected.algo) mismatch — expected \(expected.hex.prefix(16))…, got \(got.prefix(16))…"
            )
        }
        return expected.algo
    }
}

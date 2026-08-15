import XCTest
@testable import Mycellm

/// ⚠️ REGRESSION SUITE. Both behaviours below shipped in build 29 and were
/// found by running the API against real devices, not by these tests — the
/// unit suite was green the whole time because nothing asserted on either one.
final class DownloadSafetyTests: XCTestCase {

    // MARK: - Destination name safety

    /// The destination is `modelsDirectory.appendingPathComponent(filename)`
    /// and publishing does `removeItem` *before* `moveItem`. So a name that
    /// walks out of the models directory does not just write in the wrong
    /// place — it deletes whatever it lands on first.
    ///
    /// The guarantee is *containment*, not rejection: a traversal is reduced to
    /// its last component (`../evil.gguf` → `evil.gguf`, which lands inside the
    /// models directory) and only names that cannot be reduced to a usable file
    /// are refused. Outright refusal happens a layer up, at the URL route,
    /// which rejects any `/` — a Hugging Face repo path legitimately has them.
    func testNoInputEverEscapesTheModelsDirectory() {
        for name in ["..", ".", "../evil.gguf", "../../evil.gguf",
                     "sub/../../evil.gguf", "a/../../b.gguf", "/etc/passwd",
                     "../.staging", "....//evil.gguf", "/"] {
            guard let safe = ModelDownloader.safeDestinationName(name) else { continue }
            XCTAssertFalse(safe.contains("/"), "\(name) → \(safe) still has a separator")
            XCTAssertFalse(safe.contains(".."), "\(name) → \(safe) still walks up")
            XCTAssertFalse(safe.hasPrefix("."), "\(name) → \(safe) is hidden")
            XCTAssertFalse(safe.isEmpty, "\(name) → empty name")
        }
    }

    /// Spelled out for the two that matter most: they reduce to a plain file
    /// inside the models directory rather than to a parent path.
    func testTraversalReducesToAContainedName() {
        XCTAssertEqual(ModelDownloader.safeDestinationName("../evil.gguf"), "evil.gguf")
        XCTAssertEqual(ModelDownloader.safeDestinationName("../../a/b/evil.gguf"), "evil.gguf")
    }

    /// "." and ".." contain no slash. The original check was
    /// `!filename.contains("/")` alone, so both passed it — which is exactly
    /// how they reached a live device.
    func testDotNamesContainNoSlashAndMustStillBeRefused() {
        for name in [".", ".."] {
            XCTAssertFalse(name.contains("/"), "precondition: \(name) has no slash")
            XCTAssertNil(ModelDownloader.safeDestinationName(name))
        }
    }

    /// `.staging/` is where in-flight downloads live; a caller must not be
    /// able to write over it, and hidden files are not models.
    func testHiddenNamesAreRefused() {
        for name in [".staging", ".hidden.gguf", ".DS_Store"] {
            XCTAssertNil(ModelDownloader.safeDestinationName(name), name)
        }
    }

    func testEmptyNameIsRefused() {
        XCTAssertNil(ModelDownloader.safeDestinationName(""))
        XCTAssertNil(ModelDownloader.safeDestinationName("/"))
    }

    func testOrdinaryModelNamesAreAccepted() {
        for name in ["model.gguf", "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
                     "all-MiniLM-L6-v2-Q4_K_M.gguf", "my-finetune.v2.gguf"] {
            XCTAssertEqual(ModelDownloader.safeDestinationName(name), name, name)
        }
    }

    /// A Hugging Face repo may legitimately hold the file in a subdirectory.
    /// The fetch keeps the full path; only the destination is reduced, so
    /// these must resolve rather than be rejected outright.
    func testRepoSubdirectoryPathsReduceToTheirLastComponent() {
        XCTAssertEqual(ModelDownloader.safeDestinationName("subdir/model.gguf"), "model.gguf")
        XCTAssertEqual(
            ModelDownloader.safeDestinationName("Q4_K_M/Qwen2.5-3B.gguf"), "Qwen2.5-3B.gguf")
    }

    /// Percent-encoding is not path separation — the filesystem never decodes
    /// it, so this is an oddly-named file, not a traversal. Refusing it would
    /// be a false positive, and the earlier test run flagged it as one.
    func testPercentEncodedSlashIsNotTraversal() {
        XCTAssertEqual(ModelDownloader.safeDestinationName("a%2Fb.gguf"), "a%2Fb.gguf")
    }

    // MARK: - Downloads are addressable

    /// Every download must carry an id from the moment it starts. A download
    /// the API can begin but cannot name is one the API cannot abort — which
    /// is what shipped: the listing omitted `download_id` for file downloads
    /// and `downloads/abort` takes nothing else.
    @MainActor
    func testFileDownloadsGetAnIdAtStart() {
        let downloader = ModelDownloader()
        let id = downloader.download(
            url: "https://example.org/m.gguf", filename: "m.gguf", sha256: String(repeating: "a", count: 64))
        XCTAssertNotNil(id, "a started download must be addressable")
        XCTAssertTrue(downloader.activeDownloads.contains { $0.id == id },
                      "the id must match an entry the listing can report")
        downloader.cancelDownload(id: id!)
    }

    @MainActor
    func testHuggingFaceDownloadsGetAnIdAtStart() {
        let downloader = ModelDownloader()
        let id = downloader.download(repoId: "org/repo", filename: "m.gguf")
        XCTAssertNotNil(id)
        XCTAssertTrue(downloader.activeDownloads.contains { $0.id == id })
        downloader.cancelDownload(id: id!)
    }

    /// The abort route resolves an id against both collections. A file
    /// download must be cancellable by the same id the listing hands out.
    @MainActor
    func testFileDownloadCanBeCancelledById() {
        let downloader = ModelDownloader()
        guard let id = downloader.download(
            url: "https://example.org/m.gguf", filename: "m.gguf",
            sha256: String(repeating: "a", count: 64)) else {
            return XCTFail("download did not start")
        }
        downloader.cancelDownload(id: id)
        let entry = downloader.activeDownloads.first { $0.id == id }
        XCTAssertEqual(entry?.state, .cancelled, "cancel must reach the file download")
    }

    @MainActor
    func testAnInvalidURLYieldsNoId() {
        let downloader = ModelDownloader()
        XCTAssertNil(downloader.download(
            url: "", filename: "m.gguf", sha256: String(repeating: "a", count: 64)))
    }
}

import XCTest
@testable import Mycellm

final class HFVerifyTests: XCTestCase {
    private let tree: [[String: Any]] = [
        ["type": "directory", "path": "sub"],
        ["type": "file", "path": "model.gguf",
         "oid": "0123456789abcdef0123456789abcdef01234567",
         "lfs": ["oid": String(repeating: "a", count: 64), "size": 5]],
        ["type": "file", "path": "config.json",
         "oid": "ce013625030ba8dba906f756967f9e9ca394464a"],
    ]

    func testLFSFileUsesSha256() {
        let e = HFVerify.expected(fromTree: tree, filename: "model.gguf")
        XCTAssertEqual(e, HFVerify.Expected(algo: "sha256", hex: String(repeating: "a", count: 64)))
    }

    func testNonLFSUsesGitBlobSha1() {
        let e = HFVerify.expected(fromTree: tree, filename: "config.json")
        XCTAssertEqual(e?.algo, "git-sha1")
    }

    func testMissingFileIsNil() {
        XCTAssertNil(HFVerify.expected(fromTree: tree, filename: "nope.bin"))
    }

    func testGitBlobSha1MatchesGitHashObject() throws {
        // `echo hello | git hash-object --stdin` — canonical known value.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hfverify-\(UUID().uuidString).txt")
        try Data("hello\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let got = try HFVerify.fileHash(url: url, algo: "git-sha1")
        XCTAssertEqual(got, "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    func testMismatchDeletesFileAndThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hfverify-\(UUID().uuidString).bin")
        try Data("tampered".utf8).write(to: url)
        let expected = HFVerify.Expected(algo: "sha256", hex: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try HFVerify.verify(file: url, expected: expected, filename: "f.bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNoExpectedHashIsUnverified() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hfverify-\(UUID().uuidString).bin")
        try Data("payload".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try HFVerify.verify(file: url, expected: nil, filename: "f.bin"), "unverified")
    }
}

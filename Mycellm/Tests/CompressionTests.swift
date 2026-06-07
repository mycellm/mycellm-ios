import XCTest
@testable import Mycellm

/// Regression coverage for the zlib decompress buffer-growth bug: highly
/// compressible payloads decompressed to a truncated prefix because the output
/// buffer was sized from the compressed length with only a single retry.
final class CompressionTests: XCTestCase {

    private func roundTrip(_ original: Data, file: StaticString = #filePath, line: UInt = #line) {
        guard let compressed = ZlibCompression.compress(original) else {
            XCTFail("compress returned nil", file: file, line: line); return
        }
        guard let restored = ZlibCompression.decompress(compressed) else {
            XCTFail("decompress returned nil", file: file, line: line); return
        }
        XCTAssertEqual(restored, original, "round-trip mismatch (\(original.count) bytes)", file: file, line: line)
    }

    /// The original failure: 2048 identical bytes (~80:1 ratio) truncated to 272.
    func testHighlyCompressible2KB() {
        roundTrip(Data(repeating: 42, count: 2048))
    }

    /// Ratio far beyond the old 16x buffer ceiling — 1 MB of one byte value.
    func testHighlyCompressible1MB() {
        roundTrip(Data(repeating: 0x5A, count: 1_000_000))
    }

    /// A spread of sizes straddling the compress threshold and buffer growth.
    func testVariedSizesRoundTrip() {
        for size in [1, 100, 1024, 2048, 8192, 100_000, 500_000] {
            roundTrip(Data(repeating: 0x42, count: size))
        }
    }

    /// Low-compressibility (pseudo-random) data — exercises the path where the
    /// initial buffer is already large enough (no growth) and round-trips intact.
    func testIncompressibleRoundTrip() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        var bytes = [UInt8]()
        bytes.reserveCapacity(50_000)
        for _ in 0..<50_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        roundTrip(Data(bytes))
    }

    /// Mixed: a compressible run followed by varied bytes (realistic CBOR-ish).
    func testMixedRoundTrip() {
        var data = Data(repeating: 0x20, count: 4000)
        data.append(contentsOf: (0..<4000).map { UInt8($0 % 251) })
        roundTrip(data)
    }

    /// Wire format sanity: output is RFC 1950 (zlib) framed — 0x78 0x01 header.
    func testZlibHeaderPrefix() {
        let compressed = ZlibCompression.compress(Data(repeating: 1, count: 2048))
        XCTAssertEqual(compressed?.prefix(2).map { $0 }, [0x78, 0x01])
    }
}

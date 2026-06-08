import Foundation
import Compression

/// zlib compression/decompression helpers.
/// Wire-compatible with Python `zlib.compress(data, level=1)` / `zlib.decompress(data)`.
enum ZlibCompression {
    /// Compress data using zlib (RFC 1950) at the specified level.
    /// Level 1 = fast, matching Python's `zlib.compress(data, level=1)`.
    static func compress(_ data: Data, level: Int = 1) -> Data? {
        // zlib header (RFC 1950): CMF=0x78 (deflate, window=32KB), FLG depends on level
        // Level 1 → FLG=0x01 (no dict, FCHECK for CMF=0x78)
        let header: [UInt8] = [0x78, 0x01]

        guard !data.isEmpty else { return nil }

        let sourceSize = data.count
        // Worst case: source + 12 bytes overhead + zlib header/trailer
        let destinationSize = sourceSize + sourceSize / 10 + 64
        var destinationBuffer = [UInt8](repeating: 0, count: destinationSize)

        let compressedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_encode_buffer(
                &destinationBuffer, destinationSize,
                baseAddress.assumingMemoryBound(to: UInt8.self), sourceSize,
                nil, COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else { return nil }

        // Build zlib frame: header + raw deflate + Adler-32 checksum
        var result = Data(header)
        result.append(contentsOf: destinationBuffer[..<compressedSize])
        result.append(adler32Checksum(data))
        return result
    }

    /// Decompress zlib-compressed data (RFC 1950).
    static func decompress(_ data: Data) -> Data? {
        guard data.count >= 6 else { return nil } // minimum: 2-byte header + 0 bytes + 4-byte checksum

        // Strip zlib header (2 bytes) and Adler-32 trailer (4 bytes)
        let deflateData = data[data.startIndex + 2 ..< data.endIndex - 4]
        guard !deflateData.isEmpty else { return Data() }

        // compression_decode_buffer is one-shot: if the destination is too
        // small it fills it completely and returns exactly destinationSize.
        // The decompressed size is unbounded relative to the compressed size
        // (a long run of equal bytes compresses ~100:1), so we can't size the
        // buffer from deflateData.count alone — grow and retry until the result
        // no longer exactly fills the buffer (i.e. it wasn't truncated).
        //
        // (Previously this used a single 4x retry — only ~16x the compressed
        // size — which silently truncated highly-compressible payloads.)
        var destinationSize = max(deflateData.count * 4, 4096)
        let cap = 64 * 1024 * 1024  // guard against corrupt input → runaway alloc
        while true {
            var destinationBuffer = [UInt8](repeating: 0, count: destinationSize)
            let decompressedSize = deflateData.withUnsafeBytes { sourcePtr -> Int in
                guard let baseAddress = sourcePtr.baseAddress else { return 0 }
                return compression_decode_buffer(
                    &destinationBuffer, destinationSize,
                    baseAddress.assumingMemoryBound(to: UInt8.self), deflateData.count,
                    nil, COMPRESSION_ZLIB
                )
            }
            guard decompressedSize > 0 else { return nil }

            // Result filled the buffer exactly → output may be truncated. Grow
            // and retry. (Worst case one extra decode when the size matches the
            // buffer exactly; the retry then returns the same, smaller value.)
            if decompressedSize == destinationSize {
                guard destinationSize < cap else { return nil }
                destinationSize = min(destinationSize * 2, cap)
                continue
            }
            return Data(destinationBuffer[..<decompressedSize])
        }
    }

    /// Compute Adler-32 checksum (big-endian, 4 bytes).
    private static func adler32Checksum(_ data: Data) -> Data {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let mod: UInt32 = 65521

        for byte in data {
            a = (a + UInt32(byte)) % mod
            b = (b + a) % mod
        }

        let checksum = (b << 16) | a
        var bigEndian = checksum.bigEndian
        return Data(bytes: &bigEndian, count: 4)
    }
}

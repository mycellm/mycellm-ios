import XCTest
@testable import Mycellm

/// Transfer-rate sampling for downloads.
///
/// ⚠️ THE OLD RATE WAS `bytesDownloaded / elapsedSinceStart` — an average since
/// the transfer began, presented as a current speed. It reads far too low early
/// on, never recovers from a stall, and on a RESUMED download reports an absurd
/// figure because the byte count starts high while elapsed starts near zero.
/// The ETA is derived from it, so every one of those is visible to the user.
///
/// The companion defect is not testable here: `MLXRepo` observed
/// `Progress.completedUnitCount`, whose KVO notifications do not fire reliably,
/// so during a multi-gigabyte shard the callback never ran at all and the bar
/// sat near zero until the file finished. That fix is a one-line change of
/// observed key path, verified on device.
final class DownloadProgressTests: XCTestCase {

    private func sample(previous: Int64, lastBytes: Int64, secondsAgo: TimeInterval,
                        now bytes: Int64) -> (rate: Int64, bytes: Int64, at: Date) {
        ModelDownloader.sampleRate(
            previous: previous,
            lastBytes: lastBytes,
            lastAt: Date().addingTimeInterval(-secondsAgo),
            now: bytes)
    }

    func testFirstRealSampleReportsTheObservedRate() {
        // 10 MB in 1s, no prior estimate → ~10 MB/s, not a fraction of it.
        let s = sample(previous: 0, lastBytes: 0, secondsAgo: 1.0, now: 10_000_000)
        XCTAssertEqual(Double(s.rate), 10_000_000, accuracy: 1_000_000)
    }

    func testRateIsMeasuredOverTheWINDOWNotSinceTheStart() {
        // 100 MB already downloaded, 10 MB more in the last second. An average
        // since start would depend on total elapsed; a windowed rate is 10 MB/s.
        let s = sample(previous: 0, lastBytes: 100_000_000, secondsAgo: 1.0,
                       now: 110_000_000)
        XCTAssertEqual(Double(s.rate), 10_000_000, accuracy: 1_000_000)
    }

    func testSamplesShorterThanTheWindowAreIgnored() {
        // Sub-window deltas make the number jump around; hold the last estimate
        // and do not consume the sample.
        let s = sample(previous: 5_000_000, lastBytes: 1_000, secondsAgo: 0.1,
                       now: 2_000)
        XCTAssertEqual(s.rate, 5_000_000)
        XCTAssertEqual(s.bytes, 1_000, "an ignored sample must not advance the mark")
    }

    func testSmoothingMovesTowardTheNewRateWithoutJumpingToIt() {
        // Previous 10 MB/s, now observing 20 MB/s over 1s.
        let s = sample(previous: 10_000_000, lastBytes: 0, secondsAgo: 1.0,
                       now: 20_000_000)
        XCTAssertGreaterThan(s.rate, 10_000_000)
        XCTAssertLessThan(s.rate, 20_000_000)
    }

    func testAResumedDownloadDoesNotReportAnAbsurdRate() {
        // THE RESUME CASE. 2 GB already on disk from a previous attempt, and the
        // very first sample arrives 1s in. Dividing 2 GB by 1s — which the old
        // average did — claims 2 GB/s. The windowed delta is 0, so the rate is
        // held rather than invented.
        let s = sample(previous: 0, lastBytes: 2_000_000_000, secondsAgo: 1.0,
                       now: 2_000_000_000)
        XCTAssertEqual(s.rate, 0, "no bytes moved in the window — claim nothing")
    }

    func testACounterGoingBACKWARDSDoesNotProduceANegativeRate() {
        // A restarted transfer can reset the byte count. Int64 arithmetic would
        // happily yield a negative "speed", and the ETA divides by it.
        let s = sample(previous: 5_000_000, lastBytes: 900_000_000, secondsAgo: 1.0,
                       now: 100_000_000)
        XCTAssertGreaterThanOrEqual(s.rate, 0)
        XCTAssertEqual(s.bytes, 100_000_000, "the mark must follow the reset")
    }

    func testAStalledTransferRecoversOnceBytesMoveAgain() {
        // Stall: no bytes over a long window → the previous estimate stands
        // rather than decaying toward zero the way an average would.
        let stalled = sample(previous: 8_000_000, lastBytes: 500_000_000,
                             secondsAgo: 30.0, now: 500_000_000)
        XCTAssertEqual(stalled.rate, 8_000_000)

        // Resumed: a real delta immediately pulls the estimate back up.
        let resumed = sample(previous: 8_000_000, lastBytes: 500_000_000,
                             secondsAgo: 1.0, now: 512_000_000)
        XCTAssertGreaterThan(resumed.rate, 8_000_000)
    }

    // MARK: - What the user actually reads

    func testProgressDescriptionShowsAPercentageNotAFraction() {
        // `progress` is a 0…1 fraction; the label must render it as a percent.
        // A manifest install of one big shard sat at 0.0000036 for minutes,
        // which is 0% however it is rounded — the underlying bug was the
        // missing callback, but this pins the presentation.
        var d = ModelDownloader.RepoDownload(repoId: "r", name: "n")
        d.bytesDownloaded = 1_500_000_000
        d.totalBytes = 3_000_000_000
        d.progress = 0.5
        XCTAssertTrue(d.progressDescription.contains("50%"), d.progressDescription)
    }

    func testEtaIsAbsentRatherThanWrongWhenTheRateIsUnknown() {
        var d = ModelDownloader.RepoDownload(repoId: "r", name: "n")
        d.totalBytes = 3_000_000_000
        d.bytesDownloaded = 1_000_000_000
        d.bytesPerSecond = 0
        XCTAssertEqual(d.etaDescription, "", "no rate means no ETA, not a fake one")

        d.bytesPerSecond = 10_000_000        // 2 GB remaining ≈ 200s
        XCTAssertTrue(d.etaDescription.contains("3m"), d.etaDescription)
    }

    // MARK: - Bytes from fraction

    /// ⚠️ MEASURED ON DEVICE: `URLSessionDownloadTask.progress` reports
    /// `completedUnitCount = 5`, `totalUnitCount = 100`, `fractionCompleted =
    /// 0.795` mid-transfer. The counts are an abstract unit scale and do not
    /// even agree with the fraction (5/100 ≠ 0.795). Only the fraction moves
    /// with the transfer, so bytes come from it and the size we already know.
    func testBytesComeFromTheFractionAndTheKnownSize() {
        XCTAssertEqual(MLXRepo.bytesFromFraction(0.5, expected: 1_000_000), 500_000)
        XCTAssertEqual(MLXRepo.bytesFromFraction(0.7954, expected: 2_800_000_000), 2_227_120_000)
    }

    func testAnUnknownSizeReportsNothingRatherThanGarbage() {
        // Better a still bar than a number invented from a unit scale that
        // has nothing to do with bytes — which is precisely the old bug.
        XCTAssertEqual(MLXRepo.bytesFromFraction(0.5, expected: 0), 0)
    }

    func testProgressIsClampedToTheExpectedSize() {
        // A fraction slightly over 1 must not report more bytes than the file
        // has; `install` sums these into a total the UI renders as a percent.
        XCTAssertEqual(MLXRepo.bytesFromFraction(1.02, expected: 1_000), 1_000)
        XCTAssertEqual(MLXRepo.bytesFromFraction(1.0, expected: 1_000), 1_000)
    }

    func testNonsenseFractionsReportZero() {
        XCTAssertEqual(MLXRepo.bytesFromFraction(-0.3, expected: 1_000), 0)
        XCTAssertEqual(MLXRepo.bytesFromFraction(.nan, expected: 1_000), 0)
        // Infinity is not "complete", it is a broken reading — report nothing
        // rather than claiming the file finished.
        XCTAssertEqual(MLXRepo.bytesFromFraction(.infinity, expected: 1_000), 0)
    }
}

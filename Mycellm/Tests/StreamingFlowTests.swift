import XCTest
@testable import Mycellm

/// Streaming correlation, driven directly — no device, no network, no sockets.
///
/// Every previous round of this bug was diagnosed by installing a build on a
/// phone, sending a chat by hand, and reading logs. That proves one path per
/// attempt and cannot show an ordering race at all. The contract underneath is
/// ordinary Swift: register a request id, route frames to it, terminate, cancel.
/// Driven here, the defect reproduces in milliseconds and deterministically.
///
/// THE DEFECT: `QUICTransport.requestStream` stored its continuation inside a
/// detached `Task`, so registration had not necessarily happened when the
/// function returned. A bootstrap relaying an already-warm model answers fast
/// enough to lose that race, and `handleStreamMessage` then found nothing,
/// returned false, and discarded the tokens. No error was raised, so the reply
/// simply never appeared and the idle watchdog eventually reported a timeout.
final class StreamingFlowTests: XCTestCase {

    private func chunk(_ id: String, _ text: String) -> MessageEnvelope {
        MessageEnvelope(type: .inferenceStream, payload: ["text": .string(text)],
                        fromPeer: "peer", id: id, ts: 0)
    }

    private func done(_ id: String) -> MessageEnvelope {
        MessageEnvelope(type: .inferenceDone, payload: [:], fromPeer: "peer", id: id, ts: 0)
    }

    private func failure(_ id: String, _ text: String) -> MessageEnvelope {
        MessageEnvelope(type: .error, payload: ["error_message": .string(text)],
                        fromPeer: "peer", id: id, ts: 0)
    }

    private func drain(_ s: AsyncThrowingStream<MessageEnvelope, Error>) async throws -> String {
        var out = ""
        for try await e in s { out += e.payload["text"]?.stringValue ?? "" }
        return out
    }

    // MARK: - Registration is complete on return

    func testAFrameDeliveredImmediatelyAfterRegisteringIsRouted() async throws {
        // THE REGRESSION TEST. Nothing awaits between register and deliver —
        // exactly the window the old detached-Task registration could lose.
        let r = StreamRegistry()
        let stream = r.register("r1")
        XCTAssertTrue(r.deliver(chunk("r1", "Hello")), "the first frame must route")
        XCTAssertTrue(r.deliver(chunk("r1", " world")))
        XCTAssertTrue(r.deliver(done("r1")))
        let text = try await drain(stream)
        XCTAssertEqual(text, "Hello world")
    }

    func testFramesBufferUntilTheCallerStartsIterating() async throws {
        // `requestStream` hands the stream back and the caller reaches its
        // `for await` some time later. Everything in between must buffer.
        let r = StreamRegistry()
        let stream = r.register("r2")
        for word in ["a", "b", "c", "d", "e"] { _ = r.deliver(chunk("r2", word)) }
        _ = r.deliver(done("r2"))
        let text = try await drain(stream)
        XCTAssertEqual(text, "abcde", "order and completeness")
    }

    func testALongStreamIsNotTruncatedByBuffering() async throws {
        // A real answer is hundreds of frames; a bounded buffer would silently
        // drop the middle of a reply.
        let r = StreamRegistry()
        let stream = r.register("long")
        for i in 0..<500 { _ = r.deliver(chunk("long", "\(i),")) }
        _ = r.deliver(done("long"))
        let text = try await drain(stream)
        XCTAssertEqual(text.split(separator: ",").count, 500)
    }

    // MARK: - Correlation

    func testAFrameForAnUnknownRequestIsReportedNotSwallowed() {
        let r = StreamRegistry()
        XCTAssertFalse(r.deliver(chunk("nobody", "x")),
                       "an unroutable frame must be visible to the caller")
    }

    func testConcurrentStreamsDoNotCrossTalk() async throws {
        let r = StreamRegistry()
        let a = r.register("A")
        let b = r.register("B")
        _ = r.deliver(chunk("A", "a1"))
        _ = r.deliver(chunk("B", "b1"))
        _ = r.deliver(chunk("A", "a2"))
        _ = r.deliver(done("A"))
        _ = r.deliver(chunk("B", "b2"))
        _ = r.deliver(done("B"))
        let textA = try await drain(a)
        let textB = try await drain(b)
        XCTAssertEqual(textA, "a1a2")
        XCTAssertEqual(textB, "b1b2")
    }

    // MARK: - Termination

    func testDoneEndsTheStreamAndReleasesTheRegistration() async throws {
        let r = StreamRegistry()
        let stream = r.register("r3")
        _ = r.deliver(chunk("r3", "x"))
        _ = r.deliver(done("r3"))
        _ = try await drain(stream)
        XCTAssertEqual(r.activeCount, 0, "a finished stream must not leak")
        XCTAssertFalse(r.deliver(chunk("r3", "late")), "late frames have nowhere to go")
    }

    func testAnErrorFrameThrows() async {
        let r = StreamRegistry()
        let stream = r.register("r4")
        _ = r.deliver(failure("r4", "peer exploded"))
        do {
            _ = try await drain(stream)
            XCTFail("an error frame must throw, not finish silently")
        } catch {
            XCTAssertTrue("\(error)".contains("peer exploded"), "\(error)")
        }
    }

    func testPartialTextBeforeAnErrorIsStillDelivered() async {
        // Throwing away tokens already shown is worse than an incomplete reply.
        let r = StreamRegistry()
        let stream = r.register("r5")
        _ = r.deliver(chunk("r5", "partial"))
        _ = r.deliver(failure("r5", "boom"))
        var text = ""
        do {
            for try await e in stream { text += e.payload["text"]?.stringValue ?? "" }
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(text, "partial")
        }
    }

    func testASendFailureEndsTheStreamWithThatError() async {
        // `requestStream` registers first and sends after; a send that fails
        // must terminate the stream it already handed back, or the caller waits
        // out the idle timeout for a request that never left.
        let r = StreamRegistry()
        let stream = r.register("r6")
        r.fail("r6", MycellmError.transportError("Not connected"))
        do {
            _ = try await drain(stream)
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue("\(error)".contains("Not connected"), "\(error)")
        }
        XCTAssertEqual(r.activeCount, 0)
    }

    func testCancellationFinishesWithoutThrowing() async throws {
        let r = StreamRegistry()
        let stream = r.register("r7")
        _ = r.deliver(chunk("r7", "half"))
        r.cancel("r7")
        let kept = try await drain(stream)
        XCTAssertEqual(kept, "half", "cancel keeps what arrived")
        XCTAssertEqual(r.activeCount, 0)
    }

    func testADroppedConnectionFailsEveryOpenStream() async {
        // Otherwise each in-flight chat hangs until its own idle timeout.
        let r = StreamRegistry()
        let a = r.register("A"), b = r.register("B")
        r.failAll(MycellmError.transportError("connection lost"))
        for s in [a, b] {
            do { _ = try await drain(s); XCTFail("expected a throw") }
            catch { XCTAssertTrue("\(error)".contains("connection lost")) }
        }
        XCTAssertEqual(r.activeCount, 0)
    }

    // MARK: - Idle timeout arithmetic

    /// ⚠️ THE ORIGINAL TIMER WAS A DEADLINE, NOT AN IDLE TIMEOUT — one
    /// `sleep(chunkTimeout)` then an unconditional cancel. Tokens could be
    /// flowing perfectly and the stream still died at 20s.
    func testActivityResetsTheIdleClock() {
        let box = TimestampBox()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(box.idleFor(), 0.5, "idle time must accumulate")
        box.touch()
        XCTAssertLessThan(box.idleFor(), 0.5, "a chunk must reset the clock")
    }

    func testIdleClockKeepsAccumulatingWithoutActivity() {
        let box = TimestampBox()
        Thread.sleep(forTimeInterval: 0.3)
        let first = box.idleFor()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertGreaterThan(box.idleFor(), first, "a silent peer must eventually trip it")
    }
}

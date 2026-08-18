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

    // MARK: - Out-of-order reassembly

    private func seqChunk(_ id: String, _ seq: Int, _ text: String) -> MessageEnvelope {
        MessageEnvelope(type: .inferenceStream,
                        payload: ["text": .string(text), "seq": .int(Int64(seq))],
                        fromPeer: "peer", id: id, ts: 0)
    }

    /// ⚠️ THE SCRAMBLED-TEXT BUG, REPRODUCED. Each frame is sent with
    /// `send_message`, which opens a NEW QUIC stream, and QUIC orders only
    /// WITHIN a stream. On a real device this produced
    /// "End-to encryption (-endE2" instead of "End-to-end encryption (E2EE)".
    /// Every token arrived; the order did not survive.
    func testFramesAreReassembledIntoSequenceOrder() async throws {
        let r = StreamRegistry()
        let stream = r.register("s1")
        // Delivered shuffled, exactly as the transport can present them.
        _ = r.deliver(seqChunk("s1", 2, "-end"))
        _ = r.deliver(seqChunk("s1", 0, "End"))
        _ = r.deliver(seqChunk("s1", 3, " encryption"))
        _ = r.deliver(seqChunk("s1", 1, "-to"))
        _ = r.deliver(done("s1"))
        let text = try await drain(stream)
        XCTAssertEqual(text, "End-to-end encryption")
    }

    func testAFrameIsHeldUntilItsPredecessorArrives() async throws {
        // Emitting eagerly is what scrambles the text; a gap must block.
        let r = StreamRegistry()
        let stream = r.register("s2")
        _ = r.deliver(seqChunk("s2", 1, "second"))
        _ = r.deliver(seqChunk("s2", 2, "third"))
        _ = r.deliver(seqChunk("s2", 0, "first"))
        _ = r.deliver(done("s2"))
        let text = try await drain(stream)
        XCTAssertEqual(text, "firstsecondthird")
    }

    func testTheTailIsNotLostWhenDONEOvertakesAFrame() async throws {
        // DONE travels on its own stream too, so it can arrive before a frame
        // sent earlier. Finishing immediately would truncate the reply.
        let r = StreamRegistry()
        let stream = r.register("s3")
        _ = r.deliver(seqChunk("s3", 0, "alpha"))
        _ = r.deliver(seqChunk("s3", 2, "gamma"))   // 1 still in flight
        _ = r.deliver(done("s3"))
        let text = try await drain(stream)
        XCTAssertEqual(text, "alphagamma", "held frames must be emitted before finishing")
    }

    func testAGapAtTerminationEmitsWhatArrivedInOrder() async throws {
        // A frame that never comes must not cost us the ones that did.
        let r = StreamRegistry()
        let stream = r.register("s4")
        _ = r.deliver(seqChunk("s4", 0, "a"))
        _ = r.deliver(seqChunk("s4", 3, "d"))
        _ = r.deliver(seqChunk("s4", 2, "c"))
        _ = r.deliver(done("s4"))
        let text = try await drain(stream)
        XCTAssertEqual(text, "acd", "sequence order preserved across the gap")
    }

    func testADuplicateFrameIsNotEmittedTwice() async throws {
        let r = StreamRegistry()
        let stream = r.register("s5")
        _ = r.deliver(seqChunk("s5", 0, "x"))
        _ = r.deliver(seqChunk("s5", 0, "x"))
        _ = r.deliver(seqChunk("s5", 1, "y"))
        _ = r.deliver(done("s5"))
        let text = try await drain(stream)
        XCTAssertEqual(text, "xy")
    }

    func testAPeerWithoutSequenceNumbersStillWorks() async throws {
        // A 0.7.x node sends no `seq`. It must reassemble in arrival order
        // rather than stalling forever waiting for frame 0.
        let r = StreamRegistry()
        let stream = r.register("s6")
        _ = r.deliver(chunk("s6", "one "))
        _ = r.deliver(chunk("s6", "two"))
        _ = r.deliver(done("s6"))
        let text = try await drain(stream)
        XCTAssertEqual(text, "one two")
    }

    func testAnErrorMidStreamStillDeliversWhatWasOrdered() async {
        let r = StreamRegistry()
        let stream = r.register("s7")
        _ = r.deliver(seqChunk("s7", 0, "kept"))
        _ = r.deliver(seqChunk("s7", 2, "also"))
        _ = r.deliver(failure("s7", "boom"))
        var text = ""
        do {
            for try await e in stream { text += e.payload["text"]?.stringValue ?? "" }
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(text, "keptalso")
        }
    }

    // MARK: - Framed multi-message streams

    private func framed(_ env: MessageEnvelope) -> Data {
        let cbor = env.toCBOR()
        var out = Data()
        let n = UInt32(cbor.count).bigEndian
        withUnsafeBytes(of: n) { out.append(contentsOf: $0) }
        out.append(cbor)
        return out
    }

    /// ⚠️ THE DELIVERY BUG. A streamed reply used to be one QUIC stream PER
    /// frame: prime sent 40, NWMultiplexGroup delivered 7, and QUIC orders only
    /// within a stream so those 7 were shuffled. One stream carrying
    /// length-prefixed frames makes ordering and delivery QUIC's problem
    /// instead of luck's — but only if the reader can find frame boundaries.
    func testSeveralFramesAreReadFromOneBuffer() throws {
        var buffer = Data()
        for i in 0..<3 { buffer.append(framed(seqChunk("f1", i, "t\(i)"))) }

        var texts: [String] = []
        var rest = buffer
        while let (msg, remainder) = QUICTransport.readFrame(rest) {
            texts.append(msg.payload["text"]?.stringValue ?? "")
            rest = remainder
        }
        XCTAssertEqual(texts, ["t0", "t1", "t2"])
        XCTAssertTrue(rest.isEmpty, "a fully-consumed buffer must leave nothing")
    }

    func testAPartialFrameIsLeftInTheBufferUntilComplete() throws {
        // TCP/QUIC hand over arbitrary byte counts; a frame split across two
        // receives must not be parsed early or dropped.
        let whole = framed(seqChunk("f2", 0, "hello"))
        let firstHalf = whole.prefix(whole.count - 3)
        XCTAssertNil(QUICTransport.readFrame(Data(firstHalf)),
                     "an incomplete frame must not parse")

        let (msg, rest) = try XCTUnwrap(QUICTransport.readFrame(whole))
        XCTAssertEqual(msg.payload["text"]?.stringValue, "hello")
        XCTAssertTrue(rest.isEmpty)
    }

    func testATruncatedLengthPrefixIsNotAFrame() {
        XCTAssertNil(QUICTransport.readFrame(Data([0x00, 0x01])))
        XCTAssertNil(QUICTransport.readFrame(Data()))
    }

    func testAnAbsurdLengthIsRejectedRatherThanBufferedForever() {
        // An unframed CBOR message read as a frame yields a nonsense length.
        // Rejecting it lets the reader fall back to the legacy single-message
        // path instead of waiting for bytes that will never come.
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF])
        buffer.append(Data(repeating: 0, count: 16))
        XCTAssertNil(QUICTransport.readFrame(buffer))
    }

    func testFramesAndTheTerminalFrameShareOneStream() throws {
        // The whole reply — chunks then DONE — arrives as one buffer.
        var buffer = Data()
        buffer.append(framed(seqChunk("f3", 0, "part1")))
        buffer.append(framed(seqChunk("f3", 1, "part2")))
        buffer.append(framed(done("f3")))

        var types: [MessageType] = []
        var rest = buffer
        while let (msg, remainder) = QUICTransport.readFrame(rest) {
            types.append(msg.type)
            rest = remainder
        }
        XCTAssertEqual(types, [.inferenceStream, .inferenceStream, .inferenceDone])
    }
}

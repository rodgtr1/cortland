import XCTest
@testable import Cortland

/// Cursor-scoped delta reads over the recent-output rolling buffer
/// (`TerminalText.recentDelta`), the pure core behind `pane_read --since`.
final class RecentOutputDeltaTests: XCTestCase {
    private let gen = 4321

    /// Mirrors `appendAutomationOutput`: a rolling buffer plus the monotonic
    /// total and evicted-byte counters, so tests exercise the same invariant the
    /// view controller maintains (`dropped + buffer.utf8.count == total`).
    private struct RollingBuffer {
        private(set) var buffer = ""
        private(set) var total = 0
        private(set) var dropped = 0
        let cap: Int

        mutating func append(_ chunk: String) {
            let before = buffer.utf8.count
            TerminalText.appendBounded(chunk, to: &buffer, cap: cap)
            let appended = chunk.utf8.count
            total += appended
            dropped += before + appended - buffer.utf8.count
        }
    }

    private func delta(_ b: RollingBuffer, since: String?, lineLimit: Int? = nil) -> TerminalText.RecentDelta {
        TerminalText.recentDelta(
            buffer: b.buffer, total: b.total, dropped: b.dropped,
            generation: gen, since: since, lineLimit: lineLimit)
    }

    func testNoSinceReturnsFullBufferUntruncatedWithCursor() {
        var b = RollingBuffer(cap: 64_000)
        b.append("hello world\n")
        let result = delta(b, since: nil)
        XCTAssertEqual(result.text, "hello world\n")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.cursor, "\(gen):\(b.total)")
    }

    func testSinceReturnsOnlyOutputAppendedAfterCursor() {
        var b = RollingBuffer(cap: 64_000)
        b.append("first chunk\n")
        let cursor = delta(b, since: nil).cursor
        b.append("second chunk\n")
        let result = delta(b, since: cursor)
        XCTAssertEqual(result.text, "second chunk\n")
        XCTAssertFalse(result.truncated)
    }

    func testSinceAtCurrentCursorReturnsEmptyDelta() {
        var b = RollingBuffer(cap: 64_000)
        b.append("all of it\n")
        let cursor = delta(b, since: nil).cursor
        let result = delta(b, since: cursor)
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.cursor, cursor, "cursor is stable when nothing new arrived")
    }

    func testStripsANSIFromTheDeltaSlice() {
        var b = RollingBuffer(cap: 64_000)
        b.append("plain\n")
        let cursor = delta(b, since: nil).cursor
        b.append("\u{001B}[31mred\u{001B}[0m text\n")
        XCTAssertEqual(delta(b, since: cursor).text, "red text\n")
    }

    func testCursorFromAnotherShellGenerationIsTruncated() {
        var b = RollingBuffer(cap: 64_000)
        b.append("output\n")
        let staleGeneration = "\(gen + 1):3"
        let result = delta(b, since: staleGeneration)
        XCTAssertTrue(result.truncated, "a cursor minted by a previous shell must re-sync")
        XCTAssertEqual(result.text, "output\n")
        XCTAssertEqual(result.cursor, "\(gen):\(b.total)")
    }

    func testCursorBeforeEvictedWindowIsTruncated() {
        // A small cap forces the rolling trim, evicting the front of the stream.
        var b = RollingBuffer(cap: 16)
        b.append("aaaaaaaa")
        let earlyCursor = delta(b, since: nil).cursor  // offset 8
        b.append("bbbbbbbbbbbbbbbbbbbb")               // trims past offset 8
        XCTAssertGreaterThan(b.dropped, 8, "precondition: the early cursor's bytes were evicted")
        let result = delta(b, since: earlyCursor)
        XCTAssertTrue(result.truncated, "a cursor before the retained window must re-sync")
        XCTAssertEqual(result.text, b.buffer, "truncated read returns the full retained buffer")
    }

    func testCursorStillInWindowAfterTrimReturnsDelta() {
        var b = RollingBuffer(cap: 16)
        b.append("aaaa")
        b.append("bbbb")
        let cursor = delta(b, since: nil).cursor  // offset 8, still retained
        b.append("cccc")                          // total 12, under the trim slack
        XCTAssertEqual(b.dropped, 0, "precondition: nothing evicted yet")
        XCTAssertEqual(delta(b, since: cursor).text, "cccc")
    }

    func testMalformedCursorIsTruncatedNotAnError() {
        var b = RollingBuffer(cap: 64_000)
        b.append("output\n")
        for bad in ["", "not-a-cursor", "\(gen):", ":5", "\(gen):-1", "\(gen):5:5"] {
            let result = delta(b, since: bad)
            XCTAssertTrue(result.truncated, "malformed cursor '\(bad)' should re-sync, not throw")
            XCTAssertEqual(result.text, "output\n")
        }
    }

    func testLineLimitCapsTheDelta() {
        var b = RollingBuffer(cap: 64_000)
        b.append("keep-before\n")
        let cursor = delta(b, since: nil).cursor
        b.append("line1\nline2\nline3\n")
        let result = delta(b, since: cursor, lineLimit: 2)
        // The trailing newline yields an empty final element; the last two
        // non-empty lines survive alongside it.
        XCTAssertEqual(result.text, "line3\n")
    }

    func testCounterInvariantHoldsAcrossTrims() {
        var b = RollingBuffer(cap: 32)
        for _ in 0..<50 { b.append("0123456789") }
        XCTAssertEqual(b.dropped + b.buffer.utf8.count, b.total,
                       "dropped + retained bytes must equal the monotonic total")
    }
}

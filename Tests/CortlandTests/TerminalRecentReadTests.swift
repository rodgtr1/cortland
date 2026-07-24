import XCTest
@testable import Cortland

/// `TerminalText.recentRead`'s cursor branching once a full read served from the
/// interpreted screen stopped going through `recentDelta`.
///
/// The two paths now decide staleness separately — `recentRead` from the cursor
/// alone (so it never normalizes a raw buffer it is about to throw away), and
/// `recentDelta` while slicing — so these pin the rule they must agree on:
/// a cursor is usable only when it parses, names this generation, and still points
/// inside the retained window `[dropped, total]`. TerminalTranscriptTests covers
/// the fresh-buffer cases; this one covers a buffer whose front has been evicted,
/// which is where the two could silently drift apart.
final class TerminalRecentReadTests: XCTestCase {
    private let gen = 7

    /// A buffer that has rolled: 40 bytes evicted off the front, so the retained
    /// window is [40, 40 + buffer].
    private func rolledSnapshot(screen: String?) -> TerminalText.RecentReadSnapshot {
        let buffer = "kept one\nkept two\nkept three\n"
        return TerminalText.RecentReadSnapshot(
            screen: screen, buffer: buffer, total: 40 + buffer.utf8.count,
            dropped: 40, generation: gen)
    }

    func testCursorPointingBeforeTheRetainedWindowResyncsAsATruncatedFullRead() {
        // The reader fell behind and its bytes were trimmed away. That is a
        // re-sync, never an error: full read, truncated: true — and served from
        // the screen, which still has the history the raw buffer lost.
        let snapshot = rolledSnapshot(screen: "$ run\nkept three\n\n\n")
        let read = TerminalText.recentRead(snapshot, since: "\(gen):39", lineLimit: 20)
        XCTAssertTrue(read.truncated)
        XCTAssertEqual(read.text, "$ run\nkept three")
        XCTAssertEqual(read.cursor, "\(gen):\(snapshot.total)")
    }

    func testCursorAtTheEdgeOfTheRetainedWindowStillDeltas() {
        // `offset == dropped` is the oldest byte still held, and must resolve —
        // an off-by-one here would silently re-sync every read of a rolled buffer.
        let snapshot = rolledSnapshot(screen: "the screen\n")
        let read = TerminalText.recentRead(snapshot, since: "\(gen):40", lineLimit: 20)
        XCTAssertFalse(read.truncated)
        XCTAssertEqual(read.text, "kept one\nkept two\nkept three\n",
                       "a delta comes from the raw stream, not the screen")
    }

    func testCursorAtTheHeadOfTheStreamReturnsNothingNew() {
        let snapshot = rolledSnapshot(screen: "the screen\n")
        let read = TerminalText.recentRead(snapshot, since: "\(gen):\(snapshot.total)", lineLimit: 20)
        XCTAssertFalse(read.truncated)
        XCTAssertEqual(read.text, "", "caught up: no output since the cursor")
        XCTAssertEqual(read.cursor, "\(gen):\(snapshot.total)")
    }

    func testCursorBeyondTheStreamResyncs() {
        // A cursor from a longer-lived buffer (or a corrupted one) points past
        // everything we have.
        let snapshot = rolledSnapshot(screen: "$ run\nkept three\n")
        let read = TerminalText.recentRead(snapshot, since: "\(gen):\(snapshot.total + 1)", lineLimit: 20)
        XCTAssertTrue(read.truncated)
        XCTAssertEqual(read.text, "$ run\nkept three")
    }

    /// The screen-served full read must agree, byte for byte, with what the old
    /// route produced — `recentDelta` for the cursor and `truncated`, the screen
    /// for the text. Only the discarded raw normalization is gone.
    func testScreenServedReadMatchesTheDeltaRouteOnCursorAndTruncation() {
        let snapshot = rolledSnapshot(screen: "$ run\nkept three\n")
        for since in [nil, "\(gen):39", "\(gen + 1):40", "junk", "\(gen):\(snapshot.total + 1)"] {
            let read = TerminalText.recentRead(snapshot, since: since, lineLimit: 20)
            let delta = TerminalText.recentDelta(
                buffer: snapshot.buffer, total: snapshot.total, dropped: snapshot.dropped,
                generation: snapshot.generation, since: since, lineLimit: 20)
            XCTAssertEqual(read.cursor, delta.cursor, "cursor drifted for since: \(since ?? "nil")")
            XCTAssertEqual(read.truncated, delta.truncated,
                           "truncation drifted for since: \(since ?? "nil")")
            XCTAssertEqual(read.text, "$ run\nkept three",
                           "every one of these is a full read, served from the screen")
        }
    }
}

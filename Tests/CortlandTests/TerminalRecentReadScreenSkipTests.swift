import XCTest
import SwiftTerm
@testable import Cortland

/// A live delta read resolves against the raw rolling buffer and never uses the
/// main-screen dump, so `recentReadSnapshot` skips building it. These pin the
/// predicate both sites share and check that a skipped screen never changes a
/// read's output.
final class TerminalRecentReadScreenSkipTests: XCTestCase {
    private let gen = 7
    // A rolled buffer: retained window is [40, 100].
    private let total = 100
    private let dropped = 40

    private func needsScreen(_ since: String?) -> Bool {
        TerminalText.isFullRecentRead(since: since, total: total, dropped: dropped, generation: gen)
    }

    func testLiveCursorDoesNotNeedTheScreen() {
        XCTAssertFalse(needsScreen("\(gen):40"))
        XCTAssertFalse(needsScreen("\(gen):70"))
        XCTAssertFalse(needsScreen("\(gen):100"))
    }

    func testNoCursorNeedsTheScreen() {
        XCTAssertTrue(needsScreen(nil))
    }

    func testStaleGenerationNeedsTheScreen() {
        XCTAssertTrue(needsScreen("\(gen + 1):70"))
        XCTAssertTrue(needsScreen("garbage"))
    }

    func testCursorThatFellOffTheFrontNeedsTheScreen() {
        XCTAssertTrue(needsScreen("\(gen):39"))
        // Past the end is stale too.
        XCTAssertTrue(needsScreen("\(gen):101"))
    }

    private func terminal(feeding raw: String) -> Terminal {
        let headless = HeadlessTerminal(onEnd: { _ in })
        let terminal = headless.terminal!
        terminal.feed(text: raw)
        return terminal
    }

    func testSnapshotSkipsTheScreenOnlyForALiveCursorAndReadsMatch() {
        let raw = "$ swift build\r\nCompiling\r\nBuild complete!\r\n"
        let term = terminal(feeding: raw)
        let count = raw.utf8.count
        func snap(_ since: String?) -> TerminalText.RecentReadSnapshot {
            TerminalText.recentReadSnapshot(terminal: term, buffer: raw, total: count,
                                            dropped: 0, generation: gen, since: since)
        }
        let full = TerminalText.recentReadSnapshot(terminal: term, buffer: raw, total: count,
                                                   dropped: 0, generation: gen)
        XCTAssertNotNil(full.screen)
        for since in [nil, "\(gen):0", "\(gen):15", "\(gen):\(count)", "\(gen + 1):3", "\(gen):\(count + 1)"] {
            let skipped = snap(since)
            let live = since.map { !TerminalText.isStaleRecentCursor($0, total: count, dropped: 0, generation: gen) } ?? false
            XCTAssertEqual(skipped.screen == nil, live, "since: \(String(describing: since))")
            XCTAssertEqual(TerminalText.recentRead(skipped, since: since, lineLimit: 20),
                           TerminalText.recentRead(full, since: since, lineLimit: 20),
                           "since: \(String(describing: since))")
        }
    }

    func testAlternateScreenSnapshotKeepsTheFrameForALiveCursor() {
        let raw = "$ claude\r\n\u{1B}[?1049h\u{1B}[2J\u{1B}[1;1Hworking"
        let term = terminal(feeding: raw)
        let count = raw.utf8.count
        let live = TerminalText.recentReadSnapshot(terminal: term, buffer: raw, total: count,
                                                   dropped: 0, generation: gen, since: "\(gen):0")
        let full = TerminalText.recentReadSnapshot(terminal: term, buffer: raw, total: count,
                                                   dropped: 0, generation: gen)
        XCTAssertNil(live.screen)
        XCTAssertNotNil(live.alternateFrame)
        XCTAssertEqual(TerminalText.recentRead(live, since: "\(gen):0", lineLimit: 20),
                       TerminalText.recentRead(full, since: "\(gen):0", lineLimit: 20))
    }
}

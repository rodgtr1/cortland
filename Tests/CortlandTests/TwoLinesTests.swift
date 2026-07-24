import XCTest
@testable import Cortland

@MainActor
final class TwoLinesJournalTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("two-lines-tests-\(UUID().uuidString)")
            .appendingPathComponent("two-lines.md")
    }

    func testFirstAppendCreatesFileWithHeaderAndEntry() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let date = Date(timeIntervalSince1970: 1_750_000_000)
        TwoLinesJournal.append(prompt: "something round", entry: "the mug's ring stain", date: date, to: fileURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Two Lines"), "first write should lay down the header")
        XCTAssertTrue(content.contains("**something round** — the mug's ring stain"))
        XCTAssertTrue(content.contains(TwoLinesJournal.dayStamp(for: date)))
    }

    func testAppendsAccumulateAndRecentEntriesReadsThemBack() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let date = Date(timeIntervalSince1970: 1_750_000_000)
        TwoLinesJournal.append(prompt: "a", entry: "first", date: date, to: fileURL)
        TwoLinesJournal.append(prompt: "b", entry: "second", date: date, to: fileURL)
        TwoLinesJournal.append(prompt: "c", entry: "third", date: date, to: fileURL)

        let all = TwoLinesJournal.recentEntries(limit: 10, from: fileURL)
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all[0].contains("first"))
        XCTAssertTrue(all[2].contains("third"), "entries stay chronological, newest last")

        let limited = TwoLinesJournal.recentEntries(limit: 2, from: fileURL)
        XCTAssertEqual(limited.count, 2)
        XCTAssertTrue(limited[0].contains("second"), "limit keeps the newest entries")
    }

    func testMultilineEntriesCollapseToOneListLine() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        TwoLinesJournal.append(
            prompt: "the sky",
            entry: "grey wool\n  pulled thin at the edges  \n",
            date: Date(timeIntervalSince1970: 1_750_000_000),
            to: fileURL
        )
        let entries = TwoLinesJournal.recentEntries(limit: 5, from: fileURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].hasSuffix("grey wool pulled thin at the edges"))
    }

    func testEmptyEntryIsNotWritten() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        TwoLinesJournal.append(prompt: "anything", entry: "   \n  ", date: Date(timeIntervalSince1970: 0), to: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRecentEntriesOnMissingFileIsEmpty() {
        XCTAssertEqual(TwoLinesJournal.recentEntries(limit: 5, from: temporaryFileURL()), [])
    }

    func testTraceSeedsAreStableAndFollowJournalEntries() {
        let content = """
        # Two Lines

        - 2026-07-15 · **something round** — a cup
        - 2026-07-15 · **the sky, right now** — high cloud
        """
        let seeds = TwoLinesJournal.traceSeeds(in: content)
        XCTAssertEqual(seeds.count, 2)
        XCTAssertEqual(seeds, TwoLinesJournal.traceSeeds(in: content))
        XCTAssertNotEqual(seeds[0], seeds[1])
    }
}

@MainActor
final class TwoLinesPromptTests: XCTestCase {
    func testPickAvoidsRecentPrompts() {
        var rng = SplitMix64(seed: 7)
        let recent = Array(0..<100)
        for _ in 0..<50 {
            let choice = TwoLinesPromptPicker.pick(promptCount: 110, avoiding: recent, using: &rng)
            XCTAssertTrue((100..<110).contains(choice), "must pick outside the recent window")
        }
    }

    func testPickFallsBackWhenEverythingIsRecent() {
        var rng = SplitMix64(seed: 7)
        let choice = TwoLinesPromptPicker.pick(promptCount: 10, avoiding: Array(0..<10), using: &rng)
        XCTAssertTrue((0..<10).contains(choice))
    }

    func testRecentCapacityLeavesRoomForFreshPicks() {
        let capacity = TwoLinesPromptPicker.recentCapacity(promptCount: TwoLinesPrompts.all.count)
        XCTAssertGreaterThan(capacity, 0)
        XCTAssertLessThan(capacity, TwoLinesPrompts.all.count, "capacity must never cover the whole library")
    }

    func testPromptLibraryIsCleanAndDeduplicated() {
        let prompts = TwoLinesPrompts.all
        XCTAssertGreaterThanOrEqual(prompts.count, 100, "library should stay big enough to avoid repeats")
        XCTAssertEqual(Set(prompts).count, prompts.count, "no duplicate prompts")
        for prompt in prompts {
            XCTAssertFalse(prompt.isEmpty)
            XCTAssertEqual(prompt, prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

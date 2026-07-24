import XCTest
@testable import Cortland

@MainActor
final class JournalPromptTests: XCTestCase {
    func testEveryPoolHasEnoughPromptsToAvoidRepeats() {
        for pool in JournalPool.allCases {
            let prompts = JournalPrompts.pool(pool)
            XCTAssertGreaterThanOrEqual(
                prompts.count, 12,
                "\(pool.rawValue) needs at least 12 prompts to outrun the no-repeat window"
            )
            XCTAssertGreaterThan(
                prompts.count, JournalModel.recentCapacity,
                "\(pool.rawValue) must stay larger than the recent window"
            )
        }
        XCTAssertGreaterThanOrEqual(JournalPrompts.all.count, 48)
    }

    func testPromptLibraryIsCleanAndDeduplicated() {
        let all = JournalPrompts.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "no duplicate ids")
        XCTAssertEqual(Set(all.map(\.text)).count, all.count, "no duplicate prompts")
        for prompt in all {
            XCTAssertFalse(prompt.text.isEmpty)
            XCTAssertEqual(prompt.text, prompt.text.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertGreaterThan(prompt.limit, 0)
        }
    }

    func testSizesStayInTheirPoolsRanges() {
        for prompt in JournalPrompts.pool(.recenter) + JournalPrompts.pool(.unload) {
            switch prompt.unit {
            case .characters: XCTAssertTrue((100...250).contains(prompt.limit), prompt.id)
            case .words: XCTAssertTrue((20...40).contains(prompt.limit), prompt.id)
            }
        }
        for prompt in JournalPrompts.pool(.create) {
            switch prompt.unit {
            case .characters: XCTAssertTrue((350...800).contains(prompt.limit), prompt.id)
            case .words: XCTAssertTrue((75...150).contains(prompt.limit), prompt.id)
            }
        }
        for prompt in JournalPrompts.pool(.reflect) {
            XCTAssertEqual(prompt.unit, .words, "the deep pool is sized in words")
            XCTAssertTrue((200...400).contains(prompt.limit), prompt.id)
        }
    }

    func testSpecifiedPromptsArePresentInTheRightPools() {
        let expected: [(String, JournalPool)] = [
            ("What are you hoping this agent run accomplishes?", .recenter),
            ("Name one thing that has gone well today.", .recenter),
            ("What are you avoiding thinking about?", .unload),
            ("Describe your mood as weather.", .unload),
            ("Describe an imaginary shop you would visit but never work in.", .create),
            ("Write one sentence you wish someone had told you at 25.", .create),
            ("What does your career look like at 52?", .reflect),
            ("Imagine yourself at 70 looking back at this period. What mattered?", .reflect)
        ]
        for (text, pool) in expected {
            let match = JournalPrompts.all.first { $0.text == text }
            XCTAssertEqual(match?.pool, pool, "\"\(text)\" belongs to \(pool.rawValue)")
        }
    }

    func testPoolsAreTaggedConsistently() {
        for pool in JournalPool.allCases {
            XCTAssertTrue(JournalPrompts.pool(pool).allSatisfy { $0.pool == pool })
        }
    }
}

@MainActor
final class JournalSelectionTests: XCTestCase {
    private func model() -> JournalModel {
        JournalModel(feelSeed: 99)
    }

    func testPickIsDeterministicForASeed() {
        let first = JournalModel.pick(from: .create, avoiding: [], seed: 12_345)
        let second = JournalModel.pick(from: .create, avoiding: [], seed: 12_345)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pool, .create)
    }

    func testPickAvoidsTheRecentWindow() {
        let prompts = JournalPrompts.pool(.reflect)
        let recent = prompts.prefix(JournalModel.recentCapacity).map(\.id)
        for seed in UInt64(0)..<40 {
            let choice = JournalModel.pick(from: .reflect, avoiding: recent, seed: seed)
            XCTAssertFalse(recent.contains(choice.id), "seed \(seed) served a recent prompt")
        }
    }

    func testPickFallsBackWhenEverythingIsRecent() {
        let all = JournalPrompts.pool(.unload).map(\.id)
        let choice = JournalModel.pick(from: .unload, avoiding: all, seed: 7)
        XCTAssertTrue(all.contains(choice.id), "an exhausted window still serves something")
    }

    func testServingRemembersPromptsPerPoolAndCapsTheRing() {
        let model = model()
        for seed in UInt64(0)..<20 {
            _ = model.serve(door: .reflect, seed: seed)
        }
        let recent = model.recentIDs(for: .reflect)
        XCTAssertEqual(recent.count, JournalModel.recentCapacity, "the ring holds the last 8, no more")
        XCTAssertEqual(Set(recent).count, recent.count, "the window never repeats within itself")
        XCTAssertTrue(model.recentIDs(for: .create).isEmpty, "pools remember separately")
    }

    func testServedPromptsDoNotRepeatWithinTheWindow() {
        let model = model()
        var served: [String] = []
        for seed in UInt64(0)..<30 {
            served.append(model.serve(door: .make, seed: seed).id)
        }
        for index in JournalModel.recentCapacity..<served.count {
            let window = served[(index - JournalModel.recentCapacity)..<index]
            XCTAssertFalse(window.contains(served[index]), "prompt at \(index) repeated inside the window")
        }
    }

    func testDoorOneAlternatesBetweenItsTwoPools() {
        let model = model()
        let pools = (UInt64(0)..<6).map { model.serve(door: .clear, seed: $0).pool }
        XCTAssertEqual(pools, [.recenter, .unload, .recenter, .unload, .recenter, .unload])
    }

    func testDoorsTwoAndThreeAreFixedAndReflectIsNeverServedByDefault() {
        let make = model()
        for seed in UInt64(0)..<12 {
            XCTAssertEqual(make.serve(door: .make, seed: seed).pool, .create)
        }
        let clear = model()
        for seed in UInt64(0)..<12 {
            XCTAssertNotEqual(
                clear.serve(door: .clear, seed: seed).pool, .reflect,
                "the deep pool is only ever reached through door 3"
            )
        }
        XCTAssertEqual(model().serve(door: .reflect, seed: 1).pool, .reflect)
    }

    func testRerollSwapsThePromptOnceAndStaysInThePool() {
        let model = model()
        let first = model.serve(door: .make, seed: 3)
        model.beginDraft(prompt: first, startDate: Date(timeIntervalSince1970: 0))

        let second = model.reroll(seed: 4)
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.pool, .create)
        XCTAssertNotEqual(second?.id, first.id, "a reroll cannot hand back what it just showed")
        XCTAssertEqual(model.snapshot().draft?.promptID, second?.id)

        XCTAssertNil(model.reroll(seed: 5), "only one reroll per entry")
        XCTAssertEqual(model.snapshot().draft?.promptID, second?.id, "the refused reroll changed nothing")
    }

    func testRerollWithoutADraftDoesNothing() {
        XCTAssertNil(model().reroll(seed: 1))
    }
}

@MainActor
final class JournalCountingTests: XCTestCase {
    func testCharacterCountingIsUnicodeSafe() {
        XCTAssertEqual(JournalModel.count("hello", unit: .characters), 5)
        XCTAssertEqual(JournalModel.count("café", unit: .characters), 4, "an accented letter is one character")
        XCTAssertEqual(JournalModel.count("🌧", unit: .characters), 1, "an emoji is one character, not four bytes")
        XCTAssertEqual(JournalModel.count("👩‍👩‍👧", unit: .characters), 1, "one grapheme, however many scalars")
        XCTAssertEqual(JournalModel.count("", unit: .characters), 0)
    }

    func testCharacterCountingKeepsWhitespaceAndNewlines() {
        XCTAssertEqual(JournalModel.count("a b", unit: .characters), 3)
        XCTAssertEqual(JournalModel.count("a\nb", unit: .characters), 3)
    }

    func testWordCountingSplitsOnWhitespace() {
        XCTAssertEqual(JournalModel.count("one two three", unit: .words), 3)
        XCTAssertEqual(JournalModel.count("  spaced   out  ", unit: .words), 2, "runs of whitespace are one break")
        XCTAssertEqual(JournalModel.count("across\nlines\there", unit: .words), 3, "newlines and tabs break words")
        XCTAssertEqual(JournalModel.count("", unit: .words), 0)
        XCTAssertEqual(JournalModel.count("   \n  ", unit: .words), 0)
        XCTAssertEqual(JournalModel.count("hyphenated-word counts once", unit: .words), 3)
    }
}

@MainActor
final class JournalMeterTests: XCTestCase {
    func testBandThresholds() {
        XCTAssertEqual(JournalModel.band(used: 0, limit: 100), .neutral)
        XCTAssertEqual(JournalModel.band(used: 69, limit: 100), .neutral, "69% is still neutral")
        XCTAssertEqual(JournalModel.band(used: 70, limit: 100), .near, "amber starts at 70%")
        XCTAssertEqual(JournalModel.band(used: 89, limit: 100), .near)
        XCTAssertEqual(JournalModel.band(used: 90, limit: 100), .close, "soft red starts at 90%")
        XCTAssertEqual(JournalModel.band(used: 99, limit: 100), .close)
        XCTAssertEqual(JournalModel.band(used: 100, limit: 100), .over, "at the limit the meter is full")
        XCTAssertEqual(JournalModel.band(used: 402, limit: 350), .over)
    }

    func testBandThresholdsOnARealLimit() {
        XCTAssertEqual(JournalModel.band(used: 244, limit: 350), .neutral, "69.7%")
        XCTAssertEqual(JournalModel.band(used: 245, limit: 350), .near, "70.0%")
        XCTAssertEqual(JournalModel.band(used: 314, limit: 350), .near, "89.7%")
        XCTAssertEqual(JournalModel.band(used: 315, limit: 350), .close, "90.0%")
    }

    func testFillStopsAtTheLimitAndNeverGoesNegative() {
        XCTAssertEqual(JournalModel.fill(used: 0, limit: 350), 0, accuracy: 0.0001)
        XCTAssertEqual(JournalModel.fill(used: 175, limit: 350), 0.5, accuracy: 0.0001)
        XCTAssertEqual(JournalModel.fill(used: 350, limit: 350), 1, accuracy: 0.0001)
        XCTAssertEqual(JournalModel.fill(used: 900, limit: 350), 1, accuracy: 0.0001, "past the limit it stops filling")
    }

    func testDegenerateLimitIsNotACrash() {
        XCTAssertEqual(JournalModel.band(used: 5, limit: 0), .neutral)
        XCTAssertEqual(JournalModel.fill(used: 5, limit: 0), 0, accuracy: 0.0001)
    }
}

@MainActor
final class JournalFeelCheckTests: XCTestCase {
    func testRollIsDeterministic() {
        for counter in 0..<20 {
            XCTAssertEqual(
                JournalModel.showsFeelCheck(seed: 42, counter: counter),
                JournalModel.showsFeelCheck(seed: 42, counter: counter)
            )
        }
    }

    func testRollLandsRoughlyOneTimeInFive() {
        let entries = 4_000
        let hits = (0..<entries).filter { JournalModel.showsFeelCheck(seed: 2_026, counter: $0) }.count
        let rate = Double(hits) / Double(entries)
        XCTAssertEqual(rate, 0.2, accuracy: 0.03, "the check should be sparse, not absent or constant")
    }

    func testDifferentSeedsGiveDifferentSequences() {
        let first = (0..<40).map { JournalModel.showsFeelCheck(seed: 1, counter: $0) }
        let second = (0..<40).map { JournalModel.showsFeelCheck(seed: 2, counter: $0) }
        XCTAssertNotEqual(first, second, "one install's checks are its own")
    }

    func testFinishingAnEntryAdvancesTheRollAndTheQuietMarker() {
        let model = JournalModel(feelSeed: 2_026)
        let expected = (0..<12).map { JournalModel.showsFeelCheck(seed: 2_026, counter: $0) }
        let actual = (0..<12).map { _ in model.finishEntry() }
        XCTAssertEqual(actual, expected, "each entry gets the roll for its own counter")
        XCTAssertEqual(model.snapshot().entriesWritten, 12)
        XCTAssertEqual(model.snapshot().feelCounter, 12)
    }
}

@MainActor
final class JournalStateTests: XCTestCase {
    func testDraftRoundTripsThroughEncoding() throws {
        let model = JournalModel(feelSeed: 7)
        let prompt = model.serve(door: .make, seed: 11)
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        model.beginDraft(prompt: prompt, startDate: started)
        model.updateDraft(text: "half a thought\n\nand a second paragraph")

        let data = try JSONEncoder().encode(model.snapshot())
        let restored = try JSONDecoder().decode(JournalState.self, from: data)

        XCTAssertEqual(restored, model.snapshot())
        XCTAssertEqual(restored.draft?.promptID, prompt.id)
        XCTAssertEqual(restored.draft?.pool, .create)
        XCTAssertEqual(restored.draft?.text, "half a thought\n\nand a second paragraph")
        XCTAssertEqual(
            try XCTUnwrap(restored.draft).startDate.timeIntervalSince1970,
            started.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertNotNil(JournalModel.prompt(id: restored.draft!.promptID), "a restored draft finds its prompt again")
    }

    func testFullStateSurvivesARoundTrip() throws {
        let model = JournalModel(feelSeed: 123)
        _ = model.serve(door: .clear, seed: 1)
        _ = model.serve(door: .clear, seed: 2)
        _ = model.serve(door: .reflect, seed: 3)
        model.finishEntry()

        let data = try JSONEncoder().encode(model.snapshot())
        let restored = JournalModel(state: try JSONDecoder().decode(JournalState.self, from: data))

        XCTAssertEqual(restored.snapshot(), model.snapshot())
        XCTAssertEqual(restored.recentIDs(for: .recenter).count, 1)
        XCTAssertEqual(restored.recentIDs(for: .unload).count, 1)
        XCTAssertEqual(restored.recentIDs(for: .reflect).count, 1)
        XCTAssertEqual(restored.snapshot().nextClearPool, .recenter, "door 1 picks up its alternation where it left off")
        XCTAssertEqual(restored.snapshot().entriesWritten, 1)
    }

    func testFreshStateIsEmptyAndVersioned() {
        let state = JournalModel(feelSeed: 1).snapshot()
        XCTAssertEqual(state.version, 1)
        XCTAssertNil(state.draft)
        XCTAssertEqual(state.entriesWritten, 0)
        XCTAssertTrue(state.recentPromptIDs.isEmpty)
    }

    func testDiscardingLeavesNoTrace() {
        let model = JournalModel(feelSeed: 1)
        let prompt = model.serve(door: .make, seed: 1)
        model.beginDraft(prompt: prompt, startDate: Date(timeIntervalSince1970: 0))
        model.updateDraft(text: "never mind")
        model.discardDraft()
        XCTAssertNil(model.snapshot().draft)
        XCTAssertEqual(model.snapshot().entriesWritten, 0, "a discarded draft was never an entry")
    }
}

@MainActor
final class JournalFileTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-tests-\(UUID().uuidString)")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 14, _ minute: Int = 32) -> Date {
        Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private let shopPrompt = JournalPrompt(
        id: "create-03",
        pool: .create,
        text: "Describe an imaginary shop you would visit but never work in.",
        limit: 350,
        unit: .characters
    )

    // MARK: - Naming

    func testMonthlyFileNaming() {
        XCTAssertEqual(JournalFile.fileName(for: date(2026, 7, 16)), "2026-07.md")
        XCTAssertEqual(JournalFile.fileName(for: date(2026, 12, 31, 23, 59)), "2026-12.md")
        XCTAssertEqual(JournalFile.fileName(for: date(2027, 1, 1, 0, 1)), "2027-01.md", "the year rolls over cleanly")
        XCTAssertEqual(JournalFile.fileName(for: date(2026, 1, 5)), "2026-01.md", "single-digit months are padded")
    }

    func testEntriesInTheSameMonthShareAFileAndDifferentMonthsDoNot() {
        let directory = temporaryDirectory()
        let july = JournalFile.fileURL(for: date(2026, 7, 1), in: directory)
        let august = JournalFile.fileURL(for: date(2026, 8, 1), in: directory)
        XCTAssertEqual(july, JournalFile.fileURL(for: date(2026, 7, 28), in: directory))
        XCTAssertNotEqual(july, august)
    }

    func testStampIsLocaleIndependentTwelveHourTime() {
        XCTAssertTrue(JournalFile.stamp(for: date(2026, 7, 16, 14, 32)).hasSuffix("2:32 PM"))
        XCTAssertTrue(JournalFile.stamp(for: date(2026, 7, 16, 0, 5)).hasSuffix("12:05 AM"), "midnight reads as 12 AM")
        XCTAssertTrue(JournalFile.stamp(for: date(2026, 7, 16, 12, 0)).hasSuffix("12:00 PM"), "noon reads as 12 PM")
        XCTAssertTrue(JournalFile.stamp(for: date(2026, 7, 16, 9, 7)).hasPrefix("2026-07-16 9:07 AM"))
    }

    // MARK: - Block format

    func testBlockMatchesTheSpecifiedShape() {
        let block = JournalFile.block(
            prompt: shopPrompt,
            entry: String(repeating: "a", count: 287),
            date: date(2026, 7, 16, 14, 32)
        )
        let lines = block.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "## 2026-07-16 2:32 PM · create")
        XCTAssertEqual(lines[1], "> Describe an imaginary shop you would visit but never work in.")
        XCTAssertEqual(lines[2], "> (350 characters, used 287)")
        XCTAssertEqual(lines[3], "", "a blank line separates the header from the entry")
        XCTAssertEqual(lines[4], String(repeating: "a", count: 287))
        XCTAssertTrue(block.hasPrefix("## "), "every block starts with ## so a month can be split on it")
    }

    func testBlockNotesOverageWithoutComment() {
        let block = JournalFile.block(
            prompt: shopPrompt,
            entry: String(repeating: "b", count: 402),
            date: date(2026, 7, 16)
        )
        XCTAssertTrue(block.contains("> (350 characters, used 402)"))
        XCTAssertFalse(block.lowercased().contains("over"), "overage is a fact, not a verdict")
        XCTAssertFalse(block.contains("!"))
    }

    func testBlockCountsWordsForWordPrompts() {
        let prompt = JournalPrompt(id: "t", pool: .reflect, text: "Why?", limit: 300, unit: .words)
        let block = JournalFile.block(prompt: prompt, entry: "one two three four", date: date(2026, 7, 16))
        XCTAssertTrue(block.contains("> (300 words, used 4)"))
    }

    func testBlockPreservesParagraphs() {
        let entry = "First paragraph.\n\nSecond paragraph, after a blank line.\nA third line."
        let block = JournalFile.block(prompt: shopPrompt, entry: entry, date: date(2026, 7, 16))
        XCTAssertTrue(block.contains(entry), "paragraphs survive exactly as written")
    }

    func testBlockUsesThePoolNameInTheHeader() {
        for pool in JournalPool.allCases {
            let prompt = JournalPrompt(id: "t", pool: pool, text: "?", limit: 100, unit: .characters)
            let block = JournalFile.block(prompt: prompt, entry: "x", date: date(2026, 7, 16))
            XCTAssertTrue(block.hasPrefix("## 2026-07-16 2:32 PM · \(pool.rawValue)"), pool.rawValue)
        }
    }

    // MARK: - Appending

    func testFirstAppendCreatesTheDirectoryFileAndHeader() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let when = date(2026, 7, 16)
        let url = JournalFile.fileURL(for: when, in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "the directory is created lazily")

        let written = JournalFile.append(prompt: shopPrompt, entry: "a small shop", date: when, to: url)
        XCTAssertEqual(written, url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Journal · 2026-07"), "the first write lays down the month's title")
        XCTAssertTrue(content.contains("## 2026-07-16 2:32 PM · create"))
        XCTAssertTrue(content.contains("a small shop"))
    }

    func testAppendsAccumulateInOrderAndReadBackNewestFirst() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = JournalFile.fileURL(for: date(2026, 7, 1), in: directory)

        JournalFile.append(prompt: shopPrompt, entry: "first", date: date(2026, 7, 1, 9, 0), to: url)
        JournalFile.append(prompt: shopPrompt, entry: "second", date: date(2026, 7, 2, 10, 0), to: url)
        JournalFile.append(prompt: shopPrompt, entry: "third", date: date(2026, 7, 3, 11, 0), to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(JournalFile.blocks(in: content).count, 3, "the month holds three entries")
        XCTAssertTrue(content.range(of: "first")!.lowerBound < content.range(of: "third")!.lowerBound,
                      "the file reads chronologically, like a journal")

        let recent = JournalFile.recentBlocks(limit: 10, from: url)
        XCTAssertEqual(recent.count, 3)
        XCTAssertTrue(recent[0].contains("third"), "browse shows newest first")
        XCTAssertTrue(recent[2].contains("first"))

        let limited = JournalFile.recentBlocks(limit: 2, from: url)
        XCTAssertEqual(limited.count, 2)
        XCTAssertTrue(limited[0].contains("third"))
        XCTAssertFalse(limited.contains { $0.contains("first") }, "the limit keeps the newest")
    }

    func testAppendToAUserEditedFileWithoutATrailingNewline() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = JournalFile.fileURL(for: date(2026, 7, 1), in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "# My own heading\n\n## 2026-07-01 8:00 AM · unload\n> mine\n\nhand written".write(
            to: url, atomically: true, encoding: .utf8
        )

        JournalFile.append(prompt: shopPrompt, entry: "appended", date: date(2026, 7, 5), to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# My own heading"), "the user's edits are left exactly alone")
        XCTAssertTrue(content.contains("hand written"))
        XCTAssertTrue(content.contains("appended"))
        XCTAssertEqual(JournalFile.blocks(in: content).count, 2, "the new entry is its own block")
        XCTAssertFalse(content.contains("hand writtenappended"), "the entry does not run into the last line")
    }

    func testAppendToAnEmptyFileStillWritesTheHeader() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = JournalFile.fileURL(for: date(2026, 7, 1), in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "\n  \n".write(to: url, atomically: true, encoding: .utf8)

        JournalFile.append(prompt: shopPrompt, entry: "something", date: date(2026, 7, 1), to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Journal · 2026-07"))
    }

    func testEmptyEntryIsNeverWritten() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = JournalFile.fileURL(for: date(2026, 7, 1), in: directory)

        XCTAssertNil(JournalFile.append(prompt: shopPrompt, entry: "   \n  ", date: date(2026, 7, 1), to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing typed leaves no file behind")
    }

    func testDeletingTheFileIsNotAProblem() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = JournalFile.fileURL(for: date(2026, 7, 1), in: directory)

        JournalFile.append(prompt: shopPrompt, entry: "first", date: date(2026, 7, 1), to: url)
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(JournalFile.recentBlocks(limit: 5, from: url), [], "a missing month reads as nothing")

        JournalFile.append(prompt: shopPrompt, entry: "after", date: date(2026, 7, 2), to: url)
        XCTAssertEqual(JournalFile.recentBlocks(limit: 5, from: url).count, 1, "and writing simply starts it again")
    }

    func testRecentBlocksOnAMissingFileIsEmpty() {
        let url = temporaryDirectory().appendingPathComponent("2026-07.md")
        XCTAssertEqual(JournalFile.recentBlocks(limit: 5, from: url), [])
    }

    func testBlocksIgnoresAnythingAboveTheFirstEntry() {
        let content = """
        # Journal · 2026-07

        Bounded writing, one small finished thing at a time, between agent runs.

        ## 2026-07-16 2:32 PM · create
        > A prompt.
        > (350 characters, used 3)

        one

        ## 2026-07-17 9:00 AM · unload
        > Another.
        > (100 characters, used 3)

        two
        """
        let blocks = JournalFile.blocks(in: content)
        XCTAssertEqual(blocks.count, 2, "the title is not an entry")
        XCTAssertTrue(blocks[0].hasPrefix("## 2026-07-16"))
        XCTAssertTrue(blocks[1].hasSuffix("two"))
    }

    // MARK: - The feel line

    func testFeelLineJoinsTheEntryJustWritten() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = JournalFile.fileURL(for: date(2026, 7, 1), in: directory)

        JournalFile.append(prompt: shopPrompt, entry: "the shop", date: date(2026, 7, 1), to: url)
        JournalFile.appendFeeling("calmer", to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("the shop\nfelt: calmer\n"), "the line sits under the entry it belongs to")
        XCTAssertEqual(JournalFile.blocks(in: content).count, 1, "it joins the block rather than starting one")
    }

    func testTheNextEntryStillSeparatesCleanlyAfterAFeelLine() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = JournalFile.fileURL(for: date(2026, 7, 1), in: directory)

        JournalFile.append(prompt: shopPrompt, entry: "first", date: date(2026, 7, 1), to: url)
        JournalFile.appendFeeling("wired", to: url)
        JournalFile.append(prompt: shopPrompt, entry: "second", date: date(2026, 7, 2), to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("felt: wired\n\n## 2026-07-02"))
        let blocks = JournalFile.blocks(in: content)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[0].hasSuffix("felt: wired"))
    }

    func testFeelLineOnAMissingFileIsIgnored() {
        let url = temporaryDirectory().appendingPathComponent("2026-07.md")
        JournalFile.appendFeeling("same", to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testJournalLivesInItsOwnDirectory() {
        XCTAssertTrue(JournalFile.directoryURL.path.hasSuffix(".config/cortland/journal"))
    }
}

@MainActor
final class JournalCatalogTests: XCTestCase {
    func testJournalIsRegisteredExactlyOnce() {
        let entries = ArcadeGameCatalog.games.filter { $0.id == JournalView.gameID }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "Journal")
    }

    func testJournalViewMatchesThePanelsContentSize() {
        let game = JournalView(savedState: nil)
        XCTAssertEqual(game.view.frame.size, BlocksGameView.contentSize, "the panel must not resize between games")
    }

    func testFreshGameEncodesRestorableState() throws {
        let game = JournalView(savedState: nil)
        let data = try XCTUnwrap(game.encodeState())
        XCTAssertNoThrow(try JSONDecoder().decode(JournalState.self, from: data))
    }

    func testUndecodableBlobStartsFresh() throws {
        let game = JournalView(savedState: Data("not a journal".utf8))
        let restored = try JSONDecoder().decode(JournalState.self, from: try XCTUnwrap(game.encodeState()))
        XCTAssertNil(restored.draft)
        XCTAssertEqual(restored.entriesWritten, 0)
    }

    func testADraftForAnUnknownPromptDoesNotStrandTheGame() throws {
        // A prompt id can vanish between versions; landing on the picker is the
        // right answer, never a broken writing screen.
        var state = JournalState(feelSeed: 5)
        state.draft = JournalDraft(pool: .create, promptID: "create-does-not-exist", text: "orphan",
                                   startDate: Date(timeIntervalSince1970: 0))
        let game = JournalView(savedState: try JSONEncoder().encode(state))
        let restored = try JSONDecoder().decode(JournalState.self, from: try XCTUnwrap(game.encodeState()))
        XCTAssertNil(restored.draft)
    }

    func testASavedDraftIsRestoredIntact() throws {
        let model = JournalModel(feelSeed: 5)
        let prompt = model.serve(door: .make, seed: 1)
        model.beginDraft(prompt: prompt, startDate: Date(timeIntervalSince1970: 1_750_000_000))
        model.updateDraft(text: "half a thought")

        let game = JournalView(savedState: try JSONEncoder().encode(model.snapshot()))
        let restored = try JSONDecoder().decode(JournalState.self, from: try XCTUnwrap(game.encodeState()))
        XCTAssertEqual(restored.draft?.text, "half a thought", "Esc mid-thought is never destructive")
        XCTAssertEqual(restored.draft?.promptID, prompt.id, "and lands back on the same prompt")
    }
}

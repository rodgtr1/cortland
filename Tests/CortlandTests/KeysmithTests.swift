import XCTest
@testable import Cortland

@MainActor
final class KeysmithGameTests: XCTestCase {
    private func startedGame(seed: UInt64 = 1) -> KeysmithGame {
        let game = KeysmithGame()
        game.beginLine(seed: seed)
        return game
    }

    /// A character guaranteed to differ from `expected`, for forcing a miss.
    private func wrong(for expected: Character) -> Character {
        expected == "x" ? "y" : "x"
    }

    // MARK: - Stop-on-error input

    func testCorrectKeyAdvancesTheCursor() {
        let game = startedGame()
        XCTAssertTrue(game.line.count > 1, "generated line should hold several characters")
        let first = game.line[0]
        let result = game.type(first, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result, .advanced)
        XCTAssertEqual(game.cursor, 1)
    }

    func testWrongKeyRecordsErrorAgainstExpectedAndDoesNotAdvance() {
        let game = startedGame()
        let expected = game.line[0]
        let result = game.type(wrong(for: expected), at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result, .mistake(expected: expected))
        XCTAssertEqual(game.cursor, 0, "a miss must not advance the cursor")

        // Finish the line so its tallies commit, then the miss is on the books.
        typeRestCorrectly(game, from: Date(timeIntervalSince1970: 0.1), step: 0.1)
        let key = String(expected)
        XCTAssertGreaterThanOrEqual(game.keyErrors[key] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(game.keyAttempts[key] ?? 0, 2, "the miss and the correct retry both count")
    }

    func testAbandonedLineContributesNothingToStats() {
        let game = startedGame()
        let expected = game.line[0]
        _ = game.type(wrong(for: expected), at: Date(timeIntervalSince1970: 0))
        _ = game.type(expected, at: Date(timeIntervalSince1970: 0.1))
        XCTAssertEqual(game.cursor, 1)

        game.abandonLine()
        XCTAssertEqual(game.cursor, 0, "the abandoned line restarts fresh")
        XCTAssertTrue(game.keyAttempts.isEmpty, "no stats from an unfinished line")
        XCTAssertTrue(game.keyErrors.isEmpty)
    }

    // MARK: - Scoring math

    func testLineWPMAndAccuracyWithInjectedTimestamps() {
        let game = startedGame()
        let count = game.line.count
        let start = Date(timeIntervalSince1970: 1_000)
        let elapsed: TimeInterval = 6

        typeLineCorrectly(game, characterCount: count, start: start, elapsed: elapsed)

        guard let line = game.completedLines.first else {
            return XCTFail("line should have completed")
        }
        XCTAssertEqual(line.characters, count)
        XCTAssertEqual(line.keystrokes, count)
        XCTAssertEqual(line.correct, count)
        XCTAssertEqual(line.accuracy, 1, accuracy: 0.0001)
        XCTAssertEqual(line.wpm, (Double(count) / 5) / (elapsed / 60), accuracy: 0.0001)
    }

    func testAccuracyCountsEveryKeystrokeIncludingMisses() {
        let game = startedGame()
        let count = game.line.count
        let start = Date(timeIntervalSince1970: 0)

        // One miss on the first character, then the whole line correctly.
        let expected = game.line[0]
        _ = game.type(wrong(for: expected), at: start)
        typeLineCorrectly(game, characterCount: count, start: start.addingTimeInterval(0.1), elapsed: 5)

        guard let line = game.completedLines.first else {
            return XCTFail("line should have completed")
        }
        XCTAssertEqual(line.keystrokes, count + 1, "the miss adds a keystroke")
        XCTAssertEqual(line.correct, count)
        XCTAssertEqual(line.accuracy, Double(count) / Double(count + 1), accuracy: 0.0001)
    }

    // MARK: - Run rollup and bests

    func testFiveLinesRollUpIntoARunAndSetBests() {
        let game = startedGame()
        let result = playRun(game, elapsedPerLine: 6, startSeed: 100)

        guard case .runCompleted(let summary) = result else {
            return XCTFail("the fifth line should complete the run")
        }
        XCTAssertEqual(game.completedLines.count, KeysmithGame.linesPerRun)
        XCTAssertEqual(game.totalLinesCompleted, KeysmithGame.linesPerRun)

        let totalChars = game.completedLines.reduce(0) { $0 + $1.characters }
        let totalElapsed = game.completedLines.reduce(0) { $0 + $1.elapsed }
        XCTAssertEqual(summary.wpm, (Double(totalChars) / 5) / (totalElapsed / 60), accuracy: 0.001)
        XCTAssertEqual(summary.accuracy, 1, accuracy: 0.0001)
        XCTAssertTrue(summary.setWPMRecord)
        XCTAssertTrue(summary.setAccuracyRecord)
        XCTAssertEqual(game.bestWPM["letters"], summary.wpm)
        XCTAssertEqual(game.bestAccuracy["letters"], summary.accuracy)
    }

    func testBestsUpdateOnlyWhenBeaten() {
        let game = startedGame()
        _ = playRun(game, elapsedPerLine: 6, startSeed: 200)
        let firstBest = game.bestWPM["letters"] ?? 0
        XCTAssertGreaterThan(firstBest, 0)

        // A slower run (more elapsed per line) cannot beat the WPM best, and its
        // accuracy only ties, so neither best moves.
        game.beginRun(seed: 300)
        let slow = playRun(game, elapsedPerLine: 20, startSeed: 300)
        if case .runCompleted(let summary) = slow {
            XCTAssertFalse(summary.setWPMRecord)
            XCTAssertFalse(summary.setAccuracyRecord)
        } else {
            XCTFail("expected a completed run")
        }
        XCTAssertEqual(game.bestWPM["letters"], firstBest, "a slower run must not lower the best")

        // A faster run beats it.
        game.beginRun(seed: 400)
        let fast = playRun(game, elapsedPerLine: 2, startSeed: 400)
        if case .runCompleted(let summary) = fast {
            XCTAssertTrue(summary.setWPMRecord)
        } else {
            XCTFail("expected a completed run")
        }
        XCTAssertGreaterThan(game.bestWPM["letters"] ?? 0, firstBest)
        XCTAssertEqual(game.totalLinesCompleted, KeysmithGame.linesPerRun * 3)
    }

    func testSelectingATierClearsTheRunButKeepsStats() {
        let game = startedGame()
        typeLineCorrectly(game, characterCount: game.line.count, start: Date(timeIntervalSince1970: 0), elapsed: 4)
        XCTAssertEqual(game.completedLines.count, 1)
        let attempts = game.keyAttempts
        XCTAssertFalse(attempts.isEmpty)

        game.selectTier(.code)
        XCTAssertEqual(game.tier, .code)
        XCTAssertTrue(game.completedLines.isEmpty, "a tier switch drops the run in progress")
        XCTAssertFalse(game.hasLineUnderway)
        XCTAssertEqual(game.keyAttempts, attempts, "per-key stats survive a tier switch")
    }

    // MARK: - Persistence

    func testStateRoundTripsThroughCodable() throws {
        let game = startedGame()
        // Populate stats and a completed line, then leave a fresh line pending.
        let expected = game.line[0]
        _ = game.type(wrong(for: expected), at: Date(timeIntervalSince1970: 0))
        typeLineCorrectly(game, characterCount: game.line.count, start: Date(timeIntervalSince1970: 0.1), elapsed: 4)
        game.beginLine(seed: 7)

        let snapshot = game.snapshot()
        let decoded = try JSONDecoder().decode(KeysmithState.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(KeysmithGame(state: decoded).snapshot(), snapshot)
    }

    // MARK: - Helpers

    /// Types the remaining characters of the current line correctly.
    private func typeRestCorrectly(_ game: KeysmithGame, from start: Date, step: TimeInterval) {
        var time = start
        while game.cursor < game.line.count {
            let expected = game.line[game.cursor]
            _ = game.type(expected, at: time)
            time = time.addingTimeInterval(step)
        }
    }

    /// Types a whole line correctly so its first keystroke lands at `start` and
    /// its last at `start + elapsed`.
    private func typeLineCorrectly(_ game: KeysmithGame, characterCount count: Int, start: Date, elapsed: TimeInterval) {
        let chars = game.line
        for (index, character) in chars.enumerated() {
            let fraction = count <= 1 ? 0 : Double(index) / Double(count - 1)
            _ = game.type(character, at: start.addingTimeInterval(elapsed * fraction))
        }
    }

    /// Plays a full five-line run, all keys correct, each line taking
    /// `elapsedPerLine`. Regenerates each next line the way the view does.
    @discardableResult
    private func playRun(
        _ game: KeysmithGame,
        elapsedPerLine: TimeInterval,
        startSeed: UInt64
    ) -> KeysmithGame.TypeResult {
        var last: KeysmithGame.TypeResult = .ignored
        for lineIndex in 0..<KeysmithGame.linesPerRun {
            XCTAssertTrue(game.hasLineUnderway, "line \(lineIndex) should be ready")
            let chars = game.line
            let lineStart = Date(timeIntervalSince1970: Double(lineIndex) * 1_000)
            for (index, character) in chars.enumerated() {
                let fraction = chars.count <= 1 ? 0 : Double(index) / Double(chars.count - 1)
                last = game.type(character, at: lineStart.addingTimeInterval(elapsedPerLine * fraction))
            }
            if case .lineCompleted = last {
                game.beginLine(seed: startSeed &+ UInt64(lineIndex) &+ 1)
            }
        }
        return last
    }
}

final class KeysmithDrillsTests: XCTestCase {
    func testGeneratorIsDeterministicForFixedSeedAndStats() {
        let attempts = ["z": 10]
        let errors = ["z": 8]
        let first = KeysmithDrills.makeLine(tier: .letters, seed: 42, attempts: attempts, errors: errors, minAttempts: 4)
        let second = KeysmithDrills.makeLine(tier: .letters, seed: 42, attempts: attempts, errors: errors, minAttempts: 4)
        XCTAssertEqual(first, second)
    }

    func testGeneratorSkewsTowardHighErrorKeys() {
        func occurrences(attempts: [String: Int], errors: [String: Int]) -> Int {
            (0..<200).reduce(0) { total, seed in
                let line = KeysmithDrills.makeLine(
                    tier: .letters,
                    seed: UInt64(seed),
                    attempts: attempts,
                    errors: errors,
                    minAttempts: 4
                )
                return total + line.filter { $0 == "z" }.count
            }
        }

        let uniform = occurrences(attempts: [:], errors: [:])
        let weighted = occurrences(attempts: ["z": 10], errors: ["z": 8])
        XCTAssertGreaterThan(uniform, 0, "the letters corpus should contain the test key")
        XCTAssertGreaterThan(weighted, uniform, "weighting toward a weak key should surface it more")
    }

    /// The 1/2/3 keys switch tiers before typing input is considered, so no
    /// corpus may ever ask the typist to press one as a line character.
    func testCorporaCarryNoTierSwitchDigits() {
        for tier in KeysmithTier.allCases {
            for word in KeysmithDrills.corpus(for: tier) {
                XCTAssertFalse(
                    word.contains(where: { "123".contains($0) }),
                    "\(tier) corpus word \"\(word)\" collides with the tier-switch keys"
                )
            }
        }
    }

    func testGeneratorRespectsLineLengthBounds() {
        for tier in KeysmithTier.allCases {
            for seed in 0..<300 {
                let line = KeysmithDrills.makeLine(
                    tier: tier,
                    seed: UInt64(seed),
                    attempts: [:],
                    errors: [:],
                    minAttempts: 4
                )
                XCTAssertGreaterThanOrEqual(line.count, KeysmithDrills.minLineLength, "\(tier) seed \(seed) too short")
                XCTAssertLessThanOrEqual(line.count, KeysmithDrills.maxLineLength, "\(tier) seed \(seed) too long")
            }
        }
    }
}

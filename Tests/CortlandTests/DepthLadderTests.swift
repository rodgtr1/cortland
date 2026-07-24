import XCTest
@testable import Cortland

@MainActor
final class NonogramTests: XCTestCase {
    func testCluesDeriveRunLengths() {
        XCTAssertEqual(NonogramGenerator.clues(for: [true, true, false, true, false]), [2, 1])
        XCTAssertEqual(NonogramGenerator.clues(for: [false, false, false]), [])
        XCTAssertEqual(NonogramGenerator.clues(for: [true, true, true]), [3])
    }

    func testDeduceLineFullAndEmptyClues() {
        XCTAssertEqual(NonogramSolver.deduceLine([-1, -1, -1, -1, -1], clues: [5]), [1, 1, 1, 1, 1])
        XCTAssertEqual(NonogramSolver.deduceLine([-1, -1, -1, -1, -1], clues: []), [0, 0, 0, 0, 0])
        XCTAssertEqual(NonogramSolver.deduceLine([-1, -1, -1, -1, -1], clues: [2, 2]), [1, 1, 0, 1, 1])
    }

    func testDeduceLinePartialOverlap() {
        // A 3-run in 5 cells: all placements share the center cell.
        XCTAssertEqual(NonogramSolver.deduceLine([-1, -1, -1, -1, -1], clues: [3]), [-1, -1, 1, -1, -1])
    }

    func testDeduceLineUsesKnownCells() {
        // With the first cell known filled, a 3-run must start there.
        XCTAssertEqual(NonogramSolver.deduceLine([1, -1, -1, -1, -1], clues: [3]), [1, 1, 1, 0, 0])
    }

    func testDeduceLineContradictionReturnsNil() {
        XCTAssertNil(NonogramSolver.deduceLine([1, -1, -1], clues: []))
    }

    func testGeneratorProducesLineSolvablePuzzlesAtEverySize() {
        for size in [5, 7, 8, 10, 12, 15] {
            for seed in [UInt64(1), 42, 999] {
                let puzzle = NonogramGenerator.generate(size: size, seed: seed)
                XCTAssertEqual(puzzle.size, size)
                XCTAssertEqual(puzzle.solution.count, size * size)
                XCTAssertTrue(
                    NonogramSolver.isLineSolvable(puzzle),
                    "size \(size) seed \(seed) should be solvable without guessing"
                )
            }
        }
    }

    func testGeneratorIsDeterministicPerSeed() {
        XCTAssertEqual(
            NonogramGenerator.generate(size: 8, seed: 7),
            NonogramGenerator.generate(size: 8, seed: 7)
        )
    }
}

@MainActor
final class DepthLadderGameTests: XCTestCase {
    private func startedGame(seed: UInt64 = 1) -> DepthLadderGame {
        let game = DepthLadderGame()
        game.refreshDay(now: Date(timeIntervalSince1970: 1_000_000))
        game.beginFloorIfNeeded(seed: seed)
        return game
    }

    private func solve(_ game: DepthLadderGame) -> DepthLadderGame.FillResult {
        guard let puzzle = game.puzzle else {
            XCTFail("no puzzle underway")
            return .ignored
        }
        var last = DepthLadderGame.FillResult.ignored
        for index in puzzle.solution.indices where puzzle.solution[index] {
            last = game.fill(at: index)
        }
        return last
    }

    func testFreshGameStartsOnFloorOneWithFullLanterns() {
        let game = startedGame()
        XCTAssertEqual(game.floor, 1)
        XCTAssertEqual(game.lanterns, DepthLadderGame.lanternsPerDay)
        XCTAssertEqual(game.puzzle?.size, 5)
        XCTAssertFalse(game.isDark)
    }

    func testFloorSizesGrowWithDepth() {
        XCTAssertEqual(DepthLadderGame.size(forFloor: 1), 5)
        XCTAssertEqual(DepthLadderGame.size(forFloor: 4), 7)
        XCTAssertEqual(DepthLadderGame.size(forFloor: 8), 8)
        XCTAssertEqual(DepthLadderGame.size(forFloor: 13), 10)
        XCTAssertEqual(DepthLadderGame.size(forFloor: 26), 12)
        XCTAssertEqual(DepthLadderGame.size(forFloor: 51), 15)
        XCTAssertEqual(DepthLadderGame.size(forFloor: 500), 15)
    }

    func testClearingAFloorAdvancesDepthWithoutCostingALantern() {
        let game = startedGame()
        XCTAssertEqual(solve(game), .floorCleared)
        XCTAssertEqual(game.depth, 1)
        XCTAssertEqual(game.floor, 2)
        XCTAssertEqual(game.totalCleared, 1)
        XCTAssertEqual(game.lanterns, DepthLadderGame.lanternsPerDay)
        XCTAssertNil(game.puzzle, "next floor generates on the next check-in")

        game.beginFloorIfNeeded(seed: 2)
        XCTAssertNotNil(game.puzzle)
        XCTAssertEqual(game.mistakes, 0)
    }

    func testWrongFillAutoCrossesAndCounts() {
        let game = startedGame()
        guard let puzzle = game.puzzle,
              let wrongIndex = puzzle.solution.firstIndex(of: false) else {
            return XCTFail("expected an empty cell")
        }
        XCTAssertEqual(game.fill(at: wrongIndex), .mistake)
        XCTAssertEqual(game.marks[wrongIndex], 0, "wrong fill auto-crosses")
        XCTAssertEqual(game.mistakes, 1)
        XCTAssertEqual(game.fill(at: wrongIndex), .uncrossed, "filling a crossed cell clears the cross")
        XCTAssertEqual(game.marks[wrongIndex], -1)
        XCTAssertEqual(game.mistakes, 1, "clearing a cross is free")
    }

    func testFillOnCrossedCellUncrossesThenFills() {
        let game = startedGame()
        guard let puzzle = game.puzzle,
              let filledIndex = puzzle.solution.firstIndex(of: true) else {
            return XCTFail("expected a filled cell")
        }
        // A stray cross on a cell the solution fills must not dead-end the
        // floor: the first fill lifts the cross, the second lands.
        game.toggleCross(at: filledIndex)
        XCTAssertEqual(game.fill(at: filledIndex), .uncrossed)
        XCTAssertEqual(game.marks[filledIndex], -1)
        XCTAssertEqual(game.fill(at: filledIndex), .filled)
        XCTAssertEqual(game.marks[filledIndex], 1)
        XCTAssertEqual(game.mistakes, 0)
    }

    func testThreeMistakesFailTheFloorAndBurnALantern() {
        let game = startedGame()
        guard let puzzle = game.puzzle else { return XCTFail("no puzzle") }
        let wrong = puzzle.solution.indices.filter { !puzzle.solution[$0] }.prefix(3)
        XCTAssertEqual(game.fill(at: wrong[wrong.startIndex]), .mistake)
        XCTAssertEqual(game.fill(at: wrong[wrong.index(after: wrong.startIndex)]), .mistake)
        XCTAssertEqual(game.fill(at: wrong[wrong.index(wrong.startIndex, offsetBy: 2)]), .floorFailed)

        XCTAssertEqual(game.lanterns, DepthLadderGame.lanternsPerDay - 1)
        XCTAssertEqual(game.depth, 0, "failing never loses depth")
        XCTAssertNil(game.puzzle)

        // Retrying the same floor is allowed while lanterns remain.
        game.beginFloorIfNeeded(seed: 9)
        XCTAssertEqual(game.floor, 1)
        XCTAssertNotNil(game.puzzle)
    }

    func testBurningAllLanternsGoesDarkUntilTheNextDay() {
        let game = startedGame()
        for attempt in 0..<DepthLadderGame.lanternsPerDay {
            game.beginFloorIfNeeded(seed: UInt64(attempt + 10))
            guard let puzzle = game.puzzle else { return XCTFail("no puzzle") }
            for wrongIndex in puzzle.solution.indices.filter({ !puzzle.solution[$0] }).prefix(3) {
                _ = game.fill(at: wrongIndex)
            }
        }
        XCTAssertTrue(game.isDark)
        game.beginFloorIfNeeded(seed: 99)
        XCTAssertNil(game.puzzle, "no lanterns, no new floor")

        // Midnight passes: lanterns refill and play resumes.
        game.refreshDay(now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(game.lanterns, DepthLadderGame.lanternsPerDay)
        XCTAssertFalse(game.isDark)
        game.beginFloorIfNeeded(seed: 99)
        XCTAssertNotNil(game.puzzle)
    }

    func testRefreshOnSameDayKeepsLanterns() {
        let game = startedGame()
        guard let puzzle = game.puzzle else { return XCTFail("no puzzle") }
        for wrongIndex in puzzle.solution.indices.filter({ !puzzle.solution[$0] }).prefix(3) {
            _ = game.fill(at: wrongIndex)
        }
        XCTAssertEqual(game.lanterns, DepthLadderGame.lanternsPerDay - 1)
        game.refreshDay(now: Date(timeIntervalSince1970: 1_000_500))
        XCTAssertEqual(game.lanterns, DepthLadderGame.lanternsPerDay - 1, "same-day refresh must not refill")
    }

    func testCrossesAreFreeNotes() {
        let game = startedGame()
        guard let puzzle = game.puzzle,
              let filledIndex = puzzle.solution.firstIndex(of: true),
              let emptyIndex = puzzle.solution.firstIndex(of: false) else {
            return XCTFail("expected both cell kinds")
        }
        game.toggleCross(at: emptyIndex)
        XCTAssertEqual(game.marks[emptyIndex], 0)
        XCTAssertEqual(game.mistakes, 0, "crosses are never validated")
        game.toggleCross(at: emptyIndex)
        XCTAssertEqual(game.marks[emptyIndex], -1)

        XCTAssertEqual(game.fill(at: filledIndex), .filled)
        game.toggleCross(at: filledIndex)
        XCTAssertEqual(game.marks[filledIndex], 1, "filled cells can't be crossed")
    }

    func testStateRoundTripsThroughCodable() throws {
        let game = startedGame()
        guard let puzzle = game.puzzle,
              let filledIndex = puzzle.solution.firstIndex(of: true),
              let emptyIndex = puzzle.solution.firstIndex(of: false) else {
            return XCTFail("expected both cell kinds")
        }
        _ = game.fill(at: filledIndex)
        _ = game.fill(at: emptyIndex)

        let snapshot = game.snapshot()
        let decoded = try JSONDecoder().decode(DepthLadderState.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(DepthLadderGame(state: decoded).snapshot(), snapshot)
    }
}

import XCTest
@testable import Cortland

/// A fixed calendar so month stamps never depend on where the test machine is
/// standing.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(year: Int = 2026, month: Int = 7, day: Int = 16) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    return utc.date(from: components)!
}

/// The seeds every generation property is held over. Wide enough that a rule
/// which only usually holds shows up here.
private let seeds: [UInt64] = (0..<400).map { UInt64($0) &* 2_654_435_761 &+ 17 }

// MARK: - Tiles

@MainActor
final class LoomTileTests: XCTestCase {
    func testRotationCyclesEdgesClockwise() {
        XCTAssertEqual(LoomTile.rotate(LoomEdge.north.bit, by: 1), LoomEdge.east.bit)
        XCTAssertEqual(LoomTile.rotate(LoomEdge.east.bit, by: 1), LoomEdge.south.bit)
        XCTAssertEqual(LoomTile.rotate(LoomEdge.south.bit, by: 1), LoomEdge.west.bit)
        XCTAssertEqual(LoomTile.rotate(LoomEdge.west.bit, by: 1), LoomEdge.north.bit)
    }

    func testFourQuarterTurnsIsIdentityForEveryPiece() {
        for stubs in UInt8(0)...UInt8(15) {
            XCTAssertEqual(LoomTile.rotate(stubs, by: 4), stubs)
            XCTAssertEqual(LoomTile.rotate(stubs, by: 0), stubs)
            XCTAssertEqual(LoomTile.rotate(LoomTile.rotate(stubs, by: 1), by: 3), stubs)
        }
    }

    func testRotationNeverGainsOrLosesStubs() {
        for stubs in UInt8(0)...UInt8(15) {
            for turns in 0..<4 {
                XCTAssertEqual(LoomTile.rotate(stubs, by: turns).nonzeroBitCount, stubs.nonzeroBitCount)
            }
        }
    }

    func testOnlyBlankAndCrossReadTheSameAtEveryAngle() {
        for stubs in UInt8(0)...UInt8(15) {
            let fixed = LoomTile.rotate(stubs, by: 1) == stubs
            XCTAssertEqual(fixed, stubs == 0 || stubs == 0b1111, "stub set \(stubs) turned wrong")
            XCTAssertEqual(LoomTile(stubs: stubs, rotation: 0).isRotatable, !fixed)
        }
    }

    /// The scrambler and the settle-nudge both lean on this: any turnable tile
    /// is genuinely changed by one quarter turn, at any starting angle.
    func testAQuarterTurnAlwaysChangesARotatableTilesMask() {
        for stubs in UInt8(0)...UInt8(15) {
            let tile = LoomTile(stubs: stubs, rotation: 0)
            guard tile.isRotatable else { continue }
            for rotation in 0..<4 {
                let here = LoomTile(stubs: stubs, rotation: rotation)
                let turned = LoomTile(stubs: stubs, rotation: rotation + 1)
                XCTAssertNotEqual(here.mask, turned.mask, "stub set \(stubs) at \(rotation) turned into itself")
            }
        }
    }

    func testMaskFollowsRotationAndNegativeTurnsWrap() {
        let elbow = LoomTile(stubs: LoomEdge.north.bit | LoomEdge.east.bit, rotation: 1)
        XCTAssertEqual(elbow.mask, LoomEdge.east.bit | LoomEdge.south.bit)
        XCTAssertTrue(elbow.has(.east))
        XCTAssertFalse(elbow.has(.north))
        XCTAssertEqual(LoomTile.rotate(LoomEdge.north.bit, by: -1), LoomEdge.west.bit)
    }

    func testOppositeEdges() {
        XCTAssertEqual(LoomEdge.north.opposite, .south)
        XCTAssertEqual(LoomEdge.east.opposite, .west)
        for edge in LoomEdge.allCases {
            XCTAssertEqual(edge.opposite.opposite, edge)
        }
    }
}

// MARK: - The settled predicate

@MainActor
final class LoomBoardTests: XCTestCase {
    /// A 2x2 with one thread running along the top row: east cap, west cap,
    /// two blanks below.
    private func pair() -> LoomPanel {
        LoomPanel(seed: 1, side: 2, tiles: [
            LoomTile(stubs: LoomEdge.east.bit, rotation: 0),
            LoomTile(stubs: LoomEdge.west.bit, rotation: 0),
            LoomTile(stubs: 0, rotation: 0),
            LoomTile(stubs: 0, rotation: 0)
        ])
    }

    func testAnEmptyBoardIsSettled() {
        let blank = LoomPanel(seed: 1, side: 2, tiles: Array(repeating: LoomTile(stubs: 0, rotation: 0), count: 4))
        XCTAssertTrue(LoomBoard.isSettled(blank))
    }

    func testFacingStubsSettle() {
        XCTAssertTrue(LoomBoard.isSettled(pair()))
    }

    func testAStubMeetingNothingIsNotSettled() {
        var panel = pair()
        panel.tiles[1] = LoomTile(stubs: LoomEdge.west.bit, rotation: 2) // now points east, into the void
        XCTAssertFalse(LoomBoard.isSettled(panel))
    }

    func testAStubPointingOffTheBoardIsNotSettled() {
        var panel = pair()
        panel.tiles[0] = LoomTile(stubs: LoomEdge.east.bit, rotation: 2) // points west, off the edge
        XCTAssertFalse(LoomBoard.isSettled(panel))
    }

    func testEveryEdgeOfTheBoardIsChecked() {
        // One cap in the middle of a 3x3, turned to each of the four edges: its
        // neighbor is blank every time, so nothing settles at any angle.
        for rotation in 0..<4 {
            var tiles = Array(repeating: LoomTile(stubs: 0, rotation: 0), count: 9)
            tiles[4] = LoomTile(stubs: LoomEdge.north.bit, rotation: rotation)
            XCTAssertFalse(LoomBoard.isSettled(LoomPanel(seed: 1, side: 3, tiles: tiles)))
        }
    }

    /// Any closed arrangement is settled, not only the one dealt: two elbows
    /// facing each other settle exactly as a pair of caps would.
    func testAnyClosedArrangementCountsNotJustTheGeneratedOne() {
        let loop = LoomPanel(seed: 1, side: 2, tiles: [
            LoomTile(stubs: LoomEdge.east.bit | LoomEdge.south.bit, rotation: 0),
            LoomTile(stubs: LoomEdge.south.bit | LoomEdge.west.bit, rotation: 0),
            LoomTile(stubs: LoomEdge.north.bit | LoomEdge.east.bit, rotation: 0),
            LoomTile(stubs: LoomEdge.north.bit | LoomEdge.west.bit, rotation: 0)
        ])
        XCTAssertTrue(LoomBoard.isSettled(loop), "a closed ring of elbows is a finished panel")
    }
}

// MARK: - Generation: the two invariants

@MainActor
final class LoomGeneratorTests: XCTestCase {
    /// Restores every tile to the angle its stub set was derived at, which is
    /// the pattern the panel was woven from.
    private func unscrambled(_ panel: LoomPanel) -> LoomPanel {
        var panel = panel
        for index in panel.tiles.indices {
            panel.tiles[index].rotation = 0
        }
        return panel
    }

    // The first invariant.
    func testEveryPanelDealtIsSolvable() {
        for seed in seeds {
            let panel = LoomGenerator.panel(seed: seed)
            XCTAssertTrue(LoomBoard.isSettled(unscrambled(panel)),
                          "seed \(seed) dealt a panel with no arrangement that closes")
        }
    }

    // The second invariant.
    func testNoPanelIsEverDealtAlreadySettled() {
        for seed in seeds {
            let panel = LoomGenerator.panel(seed: seed)
            XCTAssertFalse(LoomBoard.isSettled(panel), "seed \(seed) dealt a panel with nothing to do")
        }
    }

    func testScramblingOnlyEverTurnsTilesAndNeverReplacesThem() {
        for seed in seeds.prefix(80) {
            let panel = LoomGenerator.panel(seed: seed)
            XCTAssertTrue(panel.tiles.allSatisfy { (0..<4).contains($0.rotation) })
            // Identity is preserved by construction: the settled pattern read
            // back off the panel is still a valid weave, which the invariant
            // above already holds. Here we hold that scrambling changed nothing
            // but angles, by checking the stub multiset survives a re-scramble.
            var rng = SplitMix64(seed: seed)
            let rescrambled = LoomGenerator.scramble(side: panel.side, tiles: panel.tiles, seed: seed, rng: &rng)
            XCTAssertEqual(rescrambled.tiles.map(\.stubs), panel.tiles.map(\.stubs))
        }
    }

    func testSidesStayInRangeAndAllOfThemComeUp() {
        var seen = Set<Int>()
        for seed in seeds {
            let side = LoomGenerator.panel(seed: seed).side
            XCTAssertTrue(LoomGenerator.sides.contains(side), "seed \(seed) dealt a \(side)x\(side) panel")
            seen.insert(side)
        }
        XCTAssertEqual(seen, Set(LoomGenerator.sides), "every size should turn up; there is no ramp")
    }

    func testPanelsAreNeitherBareNorAllOneNote() {
        for seed in seeds {
            let panel = LoomGenerator.panel(seed: seed)
            let threaded = panel.tiles.filter { $0.stubs != 0 }.count
            XCTAssertGreaterThanOrEqual(threaded * 2, panel.tiles.count,
                                        "seed \(seed) dealt a mostly bare panel")
            XCTAssertTrue(panel.tiles.contains { $0.isRotatable },
                          "seed \(seed) dealt a panel with nothing that turns")
        }
    }

    func testNoStubEverPointsOffTheBoardInTheWovenPattern() {
        for seed in seeds.prefix(80) {
            let panel = unscrambled(LoomGenerator.panel(seed: seed))
            for row in 0..<panel.side {
                XCTAssertFalse(panel.tile(row: row, col: 0).has(.west))
                XCTAssertFalse(panel.tile(row: row, col: panel.side - 1).has(.east))
            }
            for col in 0..<panel.side {
                XCTAssertFalse(panel.tile(row: 0, col: col).has(.north))
                XCTAssertFalse(panel.tile(row: panel.side - 1, col: col).has(.south))
            }
        }
    }

    func testTheSameSeedDealsTheSamePanel() {
        for seed in seeds.prefix(40) {
            XCTAssertEqual(LoomGenerator.panel(seed: seed), LoomGenerator.panel(seed: seed))
        }
    }

    func testDifferentSeedsDiverge() {
        let panels = seeds.prefix(60).map { LoomGenerator.panel(seed: $0) }
        XCTAssertGreaterThan(Set(panels.map { $0.tiles.map(\.stubs) }).count, 1)
    }

    /// The generator's floor: even a pattern of plain corridors is a settled,
    /// non-degenerate weave, so the reroll always has something to land on.
    func testTheFallbackPatternIsItselfAValidWeave() {
        for side in LoomGenerator.sides {
            var rng = SplitMix64(seed: 1)
            let tiles = LoomGenerator.settledPattern(side: side, rng: &rng)
            let panel = LoomPanel(seed: 1, side: side, tiles: tiles)
            XCTAssertTrue(LoomBoard.isSettled(panel))
            XCTAssertTrue(tiles.contains { $0.isRotatable })
        }
    }

    /// Gives the reroll teeth. On a full-sized panel a random shuffle is so
    /// unlikely to land settled that a scrambler which never checked would
    /// still look correct; on two facing caps it lands settled one time in
    /// sixteen, so skipping the check deals a finished panel within a few
    /// seeds.
    func testAShuffleThatLandsSettledIsRolledAgain() {
        let facingCaps = [
            LoomTile(stubs: LoomEdge.east.bit, rotation: 0),
            LoomTile(stubs: LoomEdge.west.bit, rotation: 0),
            LoomTile(stubs: 0, rotation: 0),
            LoomTile(stubs: 0, rotation: 0)
        ]
        for seed in seeds {
            var rng = SplitMix64(seed: seed)
            let panel = LoomGenerator.scramble(side: 2, tiles: facingCaps, seed: seed, rng: &rng)
            XCTAssertFalse(LoomBoard.isSettled(panel), "seed \(seed) dealt a panel that was already finished")
            XCTAssertEqual(panel.tiles.map(\.stubs), facingCaps.map(\.stubs), "rerolling turns tiles, it does not swap them")
        }
    }

    /// Scrambling a board with a settled pattern must never hand back a settled
    /// board, even when the rerolls are unlucky enough to fall through to the
    /// nudge.
    func testScrambleNeverReturnsASettledBoard() {
        for seed in seeds.prefix(120) {
            var rng = SplitMix64(seed: seed)
            let side = 5
            let tiles = LoomGenerator.settledPattern(side: side, rng: &rng)
            let panel = LoomGenerator.scramble(side: side, tiles: tiles, seed: seed, rng: &rng)
            XCTAssertFalse(LoomBoard.isSettled(panel), "seed \(seed) scrambled to a finished board")
        }
    }
}

// MARK: - The model

@MainActor
final class LoomModelTests: XCTestCase {
    /// Turns tiles until the panel settles, by walking every tile back to the
    /// angle its stub set was read from. Finite: at most three turns per tile,
    /// and it stops the moment the board closes, which may be before the last
    /// tile is home if the player found another closed arrangement on the way.
    private func settle(_ model: LoomModel, file: StaticString = #filePath, line: UInt = #line) {
        for index in model.panel.tiles.indices {
            while !model.isSettled, model.panel.tiles[index].rotation != 0 {
                model.turn(at: index)
            }
        }
        XCTAssertTrue(model.isSettled, "the pattern the panel was woven from must close it", file: file, line: line)
    }

    func testAFreshLoomHasAnUnsettledPanelAndNothingWoven() {
        let model = LoomModel(seed: 7)
        XCTAssertFalse(model.isSettled)
        XCTAssertEqual(model.panelsWoven, 0)
        XCTAssertEqual(model.panelOrdinal, 1, "the first panel is panel 1")
        XCTAssertEqual(model.cursor, 0)
        XCTAssertFalse(LoomBoard.isSettled(model.panel))
    }

    func testTurningAdvancesOneQuarterClockwise() {
        let model = LoomModel(seed: 7)
        let before = model.panel.tiles[3].rotation
        model.turn(at: 3)
        XCTAssertEqual(model.panel.tiles[3].rotation, (before + 1) % 4)
    }

    func testFourTurnsPutATileBackWhereItWas() {
        let model = LoomModel(seed: 7)
        let before = model.panel.tiles[2]
        for _ in 0..<4 { model.turn(at: 2) }
        XCTAssertEqual(model.panel.tiles[2], before, "there is nothing to undo; a turn always comes round")
    }

    func testTurningOffTheBoardIsIgnored() {
        let model = LoomModel(seed: 7)
        XCTAssertEqual(model.turn(at: -1), .ignored)
        XCTAssertEqual(model.turn(at: model.panel.tiles.count), .ignored)
    }

    func testSettlingIsReportedOnceAndCountsThePanel() {
        let model = LoomModel(seed: 7)
        settle(model)
        XCTAssertTrue(model.isSettled)
        XCTAssertEqual(model.panelsWoven, 1)
        XCTAssertEqual(model.panelOrdinal, 1, "the panel on screen is still the one just settled")
    }

    /// The whole point of the resolved flag: a settled panel left on screen is
    /// inert, so it can never be woven into the tapestry twice.
    func testASettledPanelCannotBeTurnedOrCountedAgain() {
        let model = LoomModel(seed: 7)
        settle(model)
        let panel = model.panel
        for index in panel.tiles.indices {
            XCTAssertEqual(model.turn(at: index), .ignored)
        }
        XCTAssertEqual(model.panel, panel, "a settled panel does not move")
        XCTAssertEqual(model.panelsWoven, 1)
    }

    func testEveryTurnBeforeTheLastOneIsJustATurn() {
        let model = LoomModel(seed: 11)
        var settled = 0
        var turns = 0
        for index in model.panel.tiles.indices {
            while !model.isSettled && model.panel.tiles[index].rotation != 0 {
                switch model.turn(at: index) {
                case .settled: settled += 1
                case .turned: turns += 1
                case .ignored: XCTFail("a turn on an unsettled panel is never ignored")
                }
            }
        }
        XCTAssertEqual(settled, 1, "settling is reported exactly once")
        XCTAssertGreaterThan(turns, 0, "there was something to do")
    }

    func testANewPanelOnlyComesWhenAskedForAndOnlyOnceSettled() {
        let model = LoomModel(seed: 7)
        let first = model.panel
        XCTAssertFalse(model.nextPanel(), "an unsettled panel is never taken away")
        XCTAssertEqual(model.panel, first)

        settle(model)
        XCTAssertTrue(model.nextPanel())
        XCTAssertFalse(model.isSettled)
        XCTAssertEqual(model.cursor, 0)
        XCTAssertEqual(model.panelsWoven, 1, "weaving a new panel does not weave a row")
        XCTAssertEqual(model.panelOrdinal, 2)
        XCTAssertNotEqual(model.panel.seed, first.seed)
        XCTAssertFalse(LoomBoard.isSettled(model.panel), "a fresh panel always has something left to do")
    }

    func testALoomDealsTheSameSequenceOfPanelsEveryTime() {
        func sequence() -> [UInt64] {
            let model = LoomModel(seed: 4242)
            var seeds: [UInt64] = [model.panel.seed]
            for _ in 0..<5 {
                settle(model)
                model.nextPanel()
                seeds.append(model.panel.seed)
            }
            return seeds
        }
        XCTAssertEqual(sequence(), sequence())
        XCTAssertEqual(Set(sequence()).count, 6, "the loom does not deal the same panel twice in a row")
    }

    func testDifferentLoomSeedsDealDifferentPanels() {
        XCTAssertNotEqual(LoomModel(seed: 1).panel.seed, LoomModel(seed: 2).panel.seed)
    }

    // MARK: - The cursor

    func testTheCursorMovesAndStopsAtTheEdges() {
        let model = LoomModel(seed: 7)
        let side = model.side
        model.moveCursor(rowDelta: -1, colDelta: -1)
        XCTAssertEqual(model.cursor, 0, "the cursor stops rather than wrapping")

        model.moveCursor(rowDelta: 1, colDelta: 2)
        XCTAssertEqual(model.cursor, side + 2)

        for _ in 0..<(side * 2) { model.moveCursor(rowDelta: 1, colDelta: 1) }
        XCTAssertEqual(model.cursor, side * side - 1)
    }

    func testTheCursorCanBePlacedDirectlyAndIgnoresNonsense() {
        let model = LoomModel(seed: 7)
        model.setCursor(4)
        XCTAssertEqual(model.cursor, 4)
        model.setCursor(-1)
        model.setCursor(model.panel.tiles.count)
        XCTAssertEqual(model.cursor, 4, "an off-board click leaves the cursor where it was")
    }

    func testTurnAtCursorTurnsTheTileUnderIt() {
        let model = LoomModel(seed: 7)
        model.setCursor(6)
        let before = model.panel.tiles[6].rotation
        model.turnAtCursor()
        XCTAssertEqual(model.panel.tiles[6].rotation, (before + 1) % 4)
    }

    // MARK: - Persistence

    func testStateRoundTrips() throws {
        let model = LoomModel(seed: 8080)
        model.setCursor(3)
        model.turn(at: 3)
        model.turn(at: 5)

        let snapshot = model.snapshot()
        let decoded = try JSONDecoder().decode(LoomState.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testAHalfTurnedPanelComesBackExactlyAsItWasLeft() throws {
        let original = LoomModel(seed: 8080)
        original.setCursor(7)
        original.turn(at: 1)
        original.turn(at: 1)
        original.turn(at: 4)

        let decoded = try JSONDecoder().decode(LoomState.self, from: JSONEncoder().encode(original.snapshot()))
        let restored = LoomModel(state: decoded)

        XCTAssertEqual(restored.panel, original.panel, "every angle survives the trip")
        XCTAssertEqual(restored.cursor, 7)
        XCTAssertFalse(restored.isSettled)
        XCTAssertEqual(restored.panelsWoven, 0)
    }

    func testASettledPanelStaysSettledAcrossARelaunchAndIsNotRewoven() throws {
        let original = LoomModel(seed: 99)
        settle(original)

        let decoded = try JSONDecoder().decode(LoomState.self, from: JSONEncoder().encode(original.snapshot()))
        let restored = LoomModel(state: decoded)

        XCTAssertTrue(restored.isSettled)
        XCTAssertEqual(restored.panelsWoven, 1, "coming back to a settled panel weaves nothing new")
        XCTAssertEqual(restored.turn(at: 0), .ignored)
    }
}

// MARK: - The weave

@MainActor
final class LoomWeaveTests: XCTestCase {
    private func panel(side: Int, stubs: UInt8) -> LoomPanel {
        LoomPanel(seed: 1, side: side,
                  tiles: Array(repeating: LoomTile(stubs: stubs, rotation: 0), count: side * side))
    }

    func testGlyphThresholds() {
        XCTAssertEqual(LoomWeave.glyph(forAverageStubs: 0), "░")
        XCTAssertEqual(LoomWeave.glyph(forAverageStubs: 1.49), "░")
        XCTAssertEqual(LoomWeave.glyph(forAverageStubs: 1.5), "▒")
        XCTAssertEqual(LoomWeave.glyph(forAverageStubs: 1.99), "▒")
        XCTAssertEqual(LoomWeave.glyph(forAverageStubs: 2.0), "▓")
        XCTAssertEqual(LoomWeave.glyph(forAverageStubs: 2.49), "▓")
        XCTAssertEqual(LoomWeave.glyph(forAverageStubs: 2.5), "█")
        XCTAssertEqual(LoomWeave.glyph(forAverageStubs: 4), "█")
    }

    func testDenserColumnsWeaveHeavierGlyphs() {
        XCTAssertEqual(LoomWeave.row(for: panel(side: 8, stubs: 0)), "░░░░░░░░")
        XCTAssertEqual(LoomWeave.row(for: panel(side: 8, stubs: 0b1111)), "████████")
    }

    func testEveryRowIsTheSameWidthSoTheClothHangsStraight() {
        for side in LoomGenerator.sides {
            let row = LoomWeave.row(for: panel(side: side, stubs: 0b0101))
            XCTAssertEqual(row.count, LoomWeave.width, "a \(side)-wide panel wove a ragged row")
        }
    }

    func testNarrowPanelsSitCenteredInTheirRow() {
        XCTAssertEqual(LoomWeave.row(for: panel(side: 5, stubs: 0b1111)), " █████  ")
        XCTAssertEqual(LoomWeave.row(for: panel(side: 6, stubs: 0b1111)), " ██████ ")
    }

    func testARowReadsColumnByColumn() {
        // One column of crosses on the left, the rest bare.
        var tiles = Array(repeating: LoomTile(stubs: 0, rotation: 0), count: 25)
        for row in 0..<5 {
            tiles[row * 5] = LoomTile(stubs: 0b1111, rotation: 0)
        }
        XCTAssertEqual(LoomWeave.row(for: LoomPanel(seed: 1, side: 5, tiles: tiles)), " █░░░░  ")
    }

    /// A panel's row is fixed the moment it is dealt: turning tiles rearranges
    /// thread but never adds or removes any, so the cloth records the panel
    /// rather than the route the player took through it.
    func testTurningTilesDoesNotChangeTheRowAPanelWillWeave() {
        for seed in seeds.prefix(60) {
            let panel = LoomGenerator.panel(seed: seed)
            var turned = panel
            for index in turned.tiles.indices {
                turned.tiles[index].rotation = (turned.tiles[index].rotation + 1) % 4
            }
            XCTAssertEqual(LoomWeave.row(for: turned), LoomWeave.row(for: panel))
        }
    }

    func testEveryRowAGeneratedPanelWeavesIsRecognisableAsCloth() {
        for seed in seeds.prefix(120) {
            let row = LoomWeave.row(for: LoomGenerator.panel(seed: seed))
            XCTAssertTrue(LoomTapestry.isRow(row), "\(row) does not read back as a row of cloth")
        }
    }
}

// MARK: - The tapestry file

@MainActor
final class LoomTapestryTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-tests-\(UUID().uuidString)")
            .appendingPathComponent("loom-tapestry.md")
    }

    func testMonthStamp() {
        XCTAssertEqual(LoomTapestry.monthStamp(for: date(year: 2026, month: 7)), "2026-07")
        XCTAssertEqual(LoomTapestry.monthStamp(for: date(year: 2026, month: 12)), "2026-12")
    }

    func testFirstRowLaysDownTheHeaderTheMonthAndAnOpenBolt() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        LoomTapestry.record(row: "░▒▓█░▒▓█", date: date(), to: url)
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.hasPrefix("# Loom"), "the first row lays down the header")
        XCTAssertTrue(content.contains("## 2026-07"))
        XCTAssertTrue(content.contains("```\n░▒▓█░▒▓█\n```"))
    }

    func testRowsInTheSameMonthJoinTheRunningBolt() {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        LoomTapestry.record(row: "░░░░░░░░", date: date(day: 2), to: url)
        LoomTapestry.record(row: "▒▒▒▒▒▒▒▒", date: date(day: 9), to: url)
        LoomTapestry.record(row: "████████", date: date(day: 30), to: url)

        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertEqual(content.components(separatedBy: "## ").count - 1, 1, "one month, one bolt")
        XCTAssertEqual(content.components(separatedBy: "```").count - 1, 2, "one month, one fence")
        XCTAssertEqual(LoomTapestry.recentRows(limit: 10, from: url), ["░░░░░░░░", "▒▒▒▒▒▒▒▒", "████████"])
    }

    func testANewMonthOpensANewBolt() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        LoomTapestry.record(row: "░░░░░░░░", date: date(month: 7), to: url)
        LoomTapestry.record(row: "▒▒▒▒▒▒▒▒", date: date(month: 8), to: url)
        LoomTapestry.record(row: "▓▓▓▓▓▓▓▓", date: date(month: 8), to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("## 2026-07"))
        XCTAssertTrue(content.contains("## 2026-08"))
        XCTAssertEqual(content.components(separatedBy: "```").count - 1, 4, "two months, two fences")
        XCTAssertEqual(LoomTapestry.rowCount(forMonth: "2026-07", from: url), 1)
        XCTAssertEqual(LoomTapestry.rowCount(forMonth: "2026-08", from: url), 2)
    }

    func testRecordingAPanelWritesItsWovenRow() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let panel = LoomGenerator.panel(seed: 12_345)
        LoomTapestry.record(panel, date: date(), to: url)
        XCTAssertEqual(LoomTapestry.recentRows(limit: 1, from: url), [LoomWeave.row(for: panel)])
    }

    func testRecentRowsKeepsTheNewestAndRespectsTheLimit() {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for day in 1...6 {
            LoomTapestry.record(row: String(repeating: "░", count: day) + String(repeating: " ", count: 8 - day),
                                date: date(day: day), to: url)
        }
        let rows = LoomTapestry.recentRows(limit: 2, from: url)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last, "░░░░░░  ")
    }

    func testRecentRowsOnAMissingFileIsEmpty() {
        XCTAssertEqual(LoomTapestry.recentRows(limit: 5, from: temporaryFileURL()), [])
        XCTAssertEqual(LoomTapestry.rowCount(forMonth: "2026-07", from: temporaryFileURL()), 0)
    }

    /// Rows are found by their shape, so the user's own prose in the file is
    /// never mistaken for cloth.
    func testOnlyGlyphLinesCountAsRows() {
        XCTAssertTrue(LoomTapestry.isRow("░▒▓█░▒▓█"))
        XCTAssertTrue(LoomTapestry.isRow(" ▒▒▒▒▒  "))
        XCTAssertFalse(LoomTapestry.isRow(""), "an empty line is not a row")
        XCTAssertFalse(LoomTapestry.isRow("        "), "padding alone is not a row")
        XCTAssertFalse(LoomTapestry.isRow("# Loom"))
        XCTAssertFalse(LoomTapestry.isRow("## 2026-07"))
        XCTAssertFalse(LoomTapestry.isRow("```"))
        XCTAssertFalse(LoomTapestry.isRow("░▒▓█ a note I left myself"))
    }

    func testATapestryTheUserRewroteIsNotTheGamesBusiness() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        LoomTapestry.record(row: "░░░░░░░░", date: date(), to: url)
        try "# my own cloth\n\nI threw the rest out.\n".write(to: url, atomically: true, encoding: .utf8)
        LoomTapestry.record(row: "▒▒▒▒▒▒▒▒", date: date(), to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# my own cloth"), "the player's edits survive untouched")
        XCTAssertTrue(content.contains("I threw the rest out."))
        XCTAssertEqual(LoomTapestry.recentRows(limit: 10, from: url), ["▒▒▒▒▒▒▒▒"],
                       "the loom keeps appending below whatever is there")
    }

    func testABrokenBoltIsNotRepairedItIsJustLeftAlone() {
        // The user deleted a closing fence. The loom opens a fresh bolt rather
        // than trying to reason about the damage.
        let opened = LoomTapestry.appending(row: "░░░░░░░░", month: "2026-07", to: "# Loom\n\n## 2026-07\n\n```\n▒▒▒▒▒▒▒▒\n")
        XCTAssertTrue(opened.contains("▒▒▒▒▒▒▒▒"), "nothing that was there is lost")
        XCTAssertTrue(opened.hasSuffix("```\n░░░░░░░░\n```\n"))
    }

    func testAppendingIsPureAndOnlyEverAddsARow() {
        let first = LoomTapestry.appending(row: "░░░░░░░░", month: "2026-07", to: "")
        let second = LoomTapestry.appending(row: "▒▒▒▒▒▒▒▒", month: "2026-07", to: first)

        XCTAssertEqual(LoomTapestry.appending(row: "░░░░░░░░", month: "2026-07", to: ""), first,
                       "appending reads nothing but its arguments")
        XCTAssertEqual(LoomTapestry.rows(in: first).map(\.row), ["░░░░░░░░"])
        XCTAssertEqual(LoomTapestry.rows(in: second).map(\.row), ["░░░░░░░░", "▒▒▒▒▒▒▒▒"])
        XCTAssertEqual(LoomTapestry.rows(in: second).map(\.month), ["2026-07", "2026-07"])
    }

    func testAFileWithoutATrailingNewlineStillTakesARow() {
        let content = LoomTapestry.appending(row: "░░░░░░░░", month: "2026-07", to: "# Loom\n\n## 2026-07\n\n```\n▒▒▒▒▒▒▒▒\n```")
        XCTAssertEqual(LoomTapestry.rows(in: content).count, 2)
    }
}

// MARK: - Registration

@MainActor
final class LoomCatalogRegistrationTests: XCTestCase {
    func testLoomIsInTheArcadeCatalog() {
        let entry = ArcadeGameCatalog.games.first { $0.id == LoomView.gameID }
        XCTAssertNotNil(entry, "Loom must be registered in the arcade")
        XCTAssertEqual(entry?.title, "Loom")
    }

    func testAFreshViewSizesToThePanelAndHasSomethingToDo() {
        let view = LoomView(savedState: nil)
        XCTAssertEqual(view.view.frame.size, BlocksGameView.contentSize)
        XCTAssertNotNil(view.encodeState())
    }

    func testAnUndecodableBlobIsAFreshLoomRatherThanACrash() {
        let view = LoomView(savedState: Data("not json".utf8))
        XCTAssertEqual(view.view.frame.size, BlocksGameView.contentSize)
        XCTAssertNotNil(view.encodeState())
    }

    func testStateSurvivesAnEncodeDecodeThroughTheView() throws {
        let first = LoomView(savedState: nil)
        let blob = try XCTUnwrap(first.encodeState())
        let second = LoomView(savedState: blob)
        let restored = try XCTUnwrap(second.encodeState())

        // Compare the decoded state, not the bytes: JSONEncoder does not
        // promise a stable key order between two encodes of the same value.
        XCTAssertEqual(try JSONDecoder().decode(LoomState.self, from: restored),
                       try JSONDecoder().decode(LoomState.self, from: blob),
                       "a hidden panel comes back exactly as it was")
    }

    func testTheHowToPlayKeepsTheRegister() {
        XCTAssertFalse(LoomView.howToPlay.contains("—"), "no em dashes in the directions")
        XCTAssertFalse(LoomView.howToPlay.contains("!"))
        XCTAssertTrue(LoomView.howToPlay.contains("Esc"), "every game says how to get out")
    }
}

import XCTest
@testable import Cortland

/// A fixed calendar so day stamps never depend on where the test machine is
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
    components.hour = 21
    return utc.date(from: components)!
}

/// The seeds every generation property is held over. Wide enough that a rule
/// which only usually holds shows up here.
private let seeds: [UInt64] = (0..<300).map { UInt64($0) &* 2_654_435_761 &+ 17 }

private let stamps = ["2026-07-16", "2026-07-17", "2026-01-01", "2025-12-31", "2026-02-28"]

// MARK: - The sky

@MainActor
final class NightSkyFieldTests: XCTestCase {
    func testTheSameSeedAndDateDealTheSameSky() {
        for seed in seeds.prefix(60) {
            XCTAssertEqual(
                NightSkyField.stars(seed: seed, dateStamp: "2026-07-16"),
                NightSkyField.stars(seed: seed, dateStamp: "2026-07-16"),
                "reopening tonight must show tonight's sky"
            )
        }
    }

    func testADifferentNightIsADifferentSky() {
        for seed in seeds.prefix(60) {
            let tonight = NightSkyField.stars(seed: seed, dateStamp: "2026-07-16")
            let tomorrow = NightSkyField.stars(seed: seed, dateStamp: "2026-07-17")
            XCTAssertNotEqual(tonight, tomorrow, "seed \(seed) dealt the same sky two nights running")
        }
    }

    func testDifferentInstallsSeeSkiesOfTheirOwn() {
        let skies = seeds.prefix(40).map { NightSkyField.stars(seed: $0, dateStamp: "2026-07-16") }
        let distinct = Set(skies.map { sky in sky.map { "\($0.x),\($0.y)" }.joined() })
        XCTAssertEqual(distinct.count, skies.count, "two installs should not be looking at the same sky")
    }

    /// The one rule the scatter has: nothing clumps.
    func testNoStarIsDealtTooCloseToAnother() {
        for seed in seeds {
            for stamp in stamps.prefix(2) {
                let sky = NightSkyField.stars(seed: seed, dateStamp: stamp)
                for (index, star) in sky.enumerated() {
                    for other in sky[(index + 1)...] {
                        XCTAssertGreaterThanOrEqual(
                            hypot(star.x - other.x, star.y - other.y),
                            NightSkyField.minimumSpacing,
                            "seed \(seed) dealt two stars on top of each other"
                        )
                    }
                }
            }
        }
    }

    func testEverySkyIsAHandfulOfStarsNeverBareAndNeverACrowd() {
        for seed in seeds {
            for stamp in stamps {
                let count = NightSkyField.stars(seed: seed, dateStamp: stamp).count
                XCTAssertTrue(NightSkyField.countRange.contains(count),
                              "seed \(seed) on \(stamp) dealt \(count) stars")
            }
        }
    }

    func testStarsKeepOffTheEdgeOfTheSky() {
        for seed in seeds.prefix(60) {
            for star in NightSkyField.stars(seed: seed, dateStamp: "2026-07-16") {
                XCTAssertTrue((NightSkyField.inset...(1 - NightSkyField.inset)).contains(star.x))
                XCTAssertTrue((NightSkyField.inset...(1 - NightSkyField.inset)).contains(star.y))
            }
        }
    }

    func testBrightnessIsOneOfThreeClassesAndAllOfThemTurnUp() {
        var seen = Set<Int>()
        for seed in seeds.prefix(40) {
            for star in NightSkyField.stars(seed: seed, dateStamp: "2026-07-16") {
                XCTAssertTrue((0...2).contains(star.brightness))
                seen.insert(star.brightness)
            }
        }
        XCTAssertEqual(seen, [0, 1, 2])
    }

    /// The date has to be hashed by something stable across processes, or
    /// tonight's sky would be a different sky after a relaunch.
    func testTheSkySeedIsStableAndDependsOnBothHalves() {
        XCTAssertEqual(NightSkyField.skySeed(seed: 9, dateStamp: "2026-07-16"),
                       NightSkyField.skySeed(seed: 9, dateStamp: "2026-07-16"))
        XCTAssertNotEqual(NightSkyField.skySeed(seed: 9, dateStamp: "2026-07-16"),
                          NightSkyField.skySeed(seed: 9, dateStamp: "2026-07-17"))
        XCTAssertNotEqual(NightSkyField.skySeed(seed: 9, dateStamp: "2026-07-16"),
                          NightSkyField.skySeed(seed: 10, dateStamp: "2026-07-16"))
    }
}

// MARK: - Streaks

@MainActor
final class NightSkyStreakTests: XCTestCase {
    func testAStreakIsSeededSoTheRollIsReproducible() {
        var first = SplitMix64(seed: 42)
        var second = SplitMix64(seed: 42)
        XCTAssertEqual(NightSkyStreaks.streak(using: &first), NightSkyStreaks.streak(using: &second))
        XCTAssertEqual(NightSkyStreaks.rolls(using: &first), NightSkyStreaks.rolls(using: &second))
    }

    func testAStreakFallsFromTheUpperSkyAndGoesDown() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let streak = NightSkyStreaks.streak(using: &rng)
            XCTAssertLessThanOrEqual(streak.startY, 0.55)
            XCTAssertGreaterThan(streak.endY, streak.startY, "a shooting star falls")
        }
    }

    /// Rare, not never: a watched sky gets one now and then, and never on a
    /// schedule anyone could sit and wait for.
    func testStreaksAreRareButDoHappen() {
        var rng = SplitMix64(seed: 3)
        let rolls = (0..<4000).filter { _ in NightSkyStreaks.rolls(using: &rng) }.count
        XCTAssertGreaterThan(rolls, 0)
        XCTAssertLessThan(Double(rolls) / 4000, 0.1)
    }
}

// MARK: - The model

@MainActor
final class NightSkyModelTests: XCTestCase {
    private func model(seed: UInt64 = 7, stamp: String = "2026-07-16") -> NightSkyModel {
        NightSkyModel(seed: seed, dateStamp: stamp)
    }

    func testAFreshNightHasAStarfieldAndNothingDrawnOnIt() {
        let sky = model()
        XCTAssertTrue(NightSkyField.countRange.contains(sky.stars.count))
        XCTAssertEqual(sky.path, [])
        XCTAssertEqual(sky.named, [])
        XCTAssertFalse(sky.canName, "an empty sky asks for nothing")
    }

    func testLinkingBuildsTheShapeStarToStar() {
        let sky = model()
        XCTAssertTrue(sky.link(3))
        XCTAssertTrue(sky.link(8))
        XCTAssertEqual(sky.path, [3, 8])
        XCTAssertEqual(sky.segments, [NightSkySegment(from: 3, to: 8)])
        XCTAssertEqual(sky.lastLinked, 8)
    }

    /// Closing a loop is drawing, not a mistake.
    func testAStarAlreadyInTheShapeCanBeLinkedAgain() {
        let sky = model()
        sky.link(1)
        sky.link(2)
        sky.link(3)
        XCTAssertTrue(sky.link(1), "coming back round to the first star closes the loop")
        XCTAssertEqual(sky.path, [1, 2, 3, 1])
        XCTAssertEqual(sky.segments.count, 3)
    }

    func testAStarDoesNotLinkToItself() {
        let sky = model()
        sky.link(4)
        XCTAssertFalse(sky.link(4), "a segment of no length is not a link")
        XCTAssertEqual(sky.path, [4])
    }

    func testLinkingAStarThatIsNotThereIsNothing() {
        let sky = model()
        XCTAssertFalse(sky.link(-1))
        XCTAssertFalse(sky.link(sky.stars.count))
        XCTAssertEqual(sky.path, [])
    }

    func testBackspaceTakesBackOneLinkAndIsTheOnlyUndo() {
        let sky = model()
        sky.link(1)
        sky.link(2)
        sky.link(3)
        XCTAssertTrue(sky.unlink())
        XCTAssertEqual(sky.path, [1, 2])
        XCTAssertTrue(sky.unlink())
        XCTAssertTrue(sky.unlink())
        XCTAssertEqual(sky.path, [])
        XCTAssertFalse(sky.unlink(), "there is nothing to take back, and that is not an error")
    }

    func testAShapeIsNameableOnceSomethingIsLinked() {
        let sky = model()
        XCTAssertFalse(sky.canName)
        sky.link(1)
        XCTAssertFalse(sky.canName, "one star is not a shape yet")
        sky.link(2)
        XCTAssertTrue(sky.canName)
    }

    func testNamingSettlesTheShapeOntoTonightsSkyAndClearsTheDrawing() {
        let sky = model()
        sky.link(1)
        sky.link(2)
        sky.link(5)

        let constellation = sky.name("the kettle")
        XCTAssertEqual(constellation?.name, "the kettle")
        XCTAssertEqual(constellation?.path, [1, 2, 5])
        XCTAssertEqual(sky.named.map(\.name), ["the kettle"])
        XCTAssertEqual(sky.path, [], "naming leaves the sky ready to start again")
    }

    func testSeveralConstellationsANightAreFine() {
        let sky = model()
        sky.link(1); sky.link(2)
        sky.name("one")
        sky.link(3); sky.link(4)
        sky.name("two")
        XCTAssertEqual(sky.named.map(\.name), ["one", "two"])
    }

    func testAnEmptyNameIsAQuietNoAndTheShapeSurvives() {
        let sky = model()
        sky.link(1)
        sky.link(2)

        XCTAssertNil(sky.name(""))
        XCTAssertNil(sky.name("   \n  "))
        XCTAssertEqual(sky.path, [1, 2], "cancelling naming leaves the shape exactly as it was")
        XCTAssertEqual(sky.named, [])
    }

    func testNamingNothingIsNothing() {
        let sky = model()
        XCTAssertNil(sky.name("the empty sky"))
        sky.link(1)
        XCTAssertNil(sky.name("one star"), "a single star is not a shape")
        XCTAssertEqual(sky.named, [])
    }

    /// The name becomes a markdown heading in a file the user reads.
    func testANameIsTidiedToOneLine() {
        XCTAssertEqual(NightSkyModel.cleanName("  the   kettle \n"), "the kettle")
        XCTAssertEqual(NightSkyModel.cleanName("two\nlines"), "two lines")
        XCTAssertEqual(NightSkyModel.cleanName(""), "")
        XCTAssertEqual(NightSkyModel.cleanName(String(repeating: "a", count: 200)).count, 48)
        XCTAssertEqual(NightSkyModel.cleanName("The Kettle"), "The Kettle", "the name is the user's, capitals included")
    }

    // MARK: - The night turning over

    func testTheSameNightIsNeverRolledOver() {
        let sky = model(stamp: "2026-07-16")
        sky.link(1)
        sky.link(2)
        let stars = sky.stars

        XCTAssertFalse(sky.rollOver(to: "2026-07-16"))
        XCTAssertEqual(sky.path, [1, 2], "reopening the same night carries on")
        XCTAssertEqual(sky.stars, stars)
    }

    /// The invariant that makes skipping days free: an unfinished shape belonged
    /// to a sky that is gone, so it goes with it, and nothing says a word.
    func testANewNightLetsAnOldUnnamedShapeGo() {
        let sky = model(stamp: "2026-07-16")
        sky.link(1)
        sky.link(2)
        sky.link(3)

        XCTAssertTrue(sky.rollOver(to: "2026-07-17"))
        XCTAssertEqual(sky.path, [], "the shape belonged to last night's sky")
        XCTAssertEqual(sky.dateStamp, "2026-07-17")
        XCTAssertEqual(sky.stars, NightSkyField.stars(seed: 7, dateStamp: "2026-07-17"))
    }

    func testANewNightTakesLastNightsNamedShapesOffTheSky() {
        let sky = model(stamp: "2026-07-16")
        sky.link(1)
        sky.link(2)
        sky.name("the kettle")

        sky.rollOver(to: "2026-07-17")
        XCTAssertEqual(sky.named, [], "named shapes live in the almanac now, not on the new sky")
    }

    /// Skipping a week is not a thing that happened, it is just a different sky.
    func testSkippingNightsCostsNothingAndIsNotRecorded() {
        let sky = model(stamp: "2026-07-16")
        sky.rollOver(to: "2026-07-30")
        XCTAssertEqual(sky.dateStamp, "2026-07-30")
        XCTAssertEqual(sky.stars, NightSkyField.stars(seed: 7, dateStamp: "2026-07-30"))
        XCTAssertEqual(sky.path, [])
    }

    // MARK: - Finding a star

    func testTheMouseFindsTheNearestStarAndOnlyIfItIsClose() {
        let sky = model()
        let star = sky.stars[5]
        XCTAssertEqual(sky.star(nearX: star.x + 0.005, y: star.y, within: 0.04), 5)
        XCTAssertNil(sky.star(nearX: -5, y: -5, within: 0.04), "a click at nothing links nothing")
    }

    /// A hand-placed field, because the generated scatter would only make the
    /// directions ambiguous. y grows downward, as it does on the panel.
    func testAnArrowFindsTheNearestStarThatWay() {
        let field = [
            NightSkyStar(x: 0.5, y: 0.5, brightness: 0),
            NightSkyStar(x: 0.7, y: 0.5, brightness: 0),
            NightSkyStar(x: 0.9, y: 0.5, brightness: 0),
            NightSkyStar(x: 0.5, y: 0.2, brightness: 0)
        ]
        XCTAssertEqual(NightSkyModel.star(from: 0, towardX: 1, y: 0, in: field), 1, "nearest to the right, not furthest")
        XCTAssertEqual(NightSkyModel.star(from: 0, towardX: 0, y: -1, in: field), 3, "up the panel")
        XCTAssertNil(NightSkyModel.star(from: 0, towardX: -1, y: 0, in: field), "nothing that way is nothing")
        XCTAssertNil(NightSkyModel.star(from: 9, towardX: 1, y: 0, in: field))
    }

    /// Nothing behind the arrow, and nothing far off to the side of it.
    func testAnArrowIgnoresStarsThatAreNotRoughlyThatWay() {
        let field = [
            NightSkyStar(x: 0.5, y: 0.5, brightness: 0),
            NightSkyStar(x: 0.52, y: 0.1, brightness: 0),  // barely right, mostly up
            NightSkyStar(x: 0.8, y: 0.5, brightness: 0)    // squarely right, further off
        ]
        XCTAssertEqual(NightSkyModel.star(from: 0, towardX: 1, y: 0, in: field), 2)
        XCTAssertEqual(NightSkyModel.star(from: 0, towardX: 0, y: -1, in: field), 1)
    }

    func testTheHighlightStartsAtTheStarNearestTheMiddle() throws {
        let sky = model()
        let index = try XCTUnwrap(sky.centermostStar)
        let best = sky.stars.indices.min { first, second in
            hypot(sky.stars[first].x - 0.5, sky.stars[first].y - 0.5)
                < hypot(sky.stars[second].x - 0.5, sky.stars[second].y - 0.5)
        }
        XCTAssertEqual(index, best)
    }

    // MARK: - Persistence

    func testStateRoundTrips() throws {
        let sky = model()
        sky.link(1); sky.link(2); sky.link(7)
        sky.name("the kettle")
        sky.link(3); sky.link(9)

        let snapshot = sky.snapshot()
        let decoded = try JSONDecoder().decode(NightSkyState.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    /// The one that matters for hide plus relaunch: a half-drawn shape simply
    /// carries on.
    func testAShapeInProgressComesBackExactlyAsItWasLeft() throws {
        let original = model(seed: 4242)
        original.link(2); original.link(6); original.link(11)

        let decoded = try JSONDecoder().decode(NightSkyState.self, from: JSONEncoder().encode(original.snapshot()))
        let restored = NightSkyModel(state: decoded)

        XCTAssertEqual(restored.path, [2, 6, 11])
        XCTAssertEqual(restored.stars, original.stars, "the same night is the same sky")
        XCTAssertTrue(restored.canName)
        XCTAssertTrue(restored.link(4), "and drawing carries straight on")
    }

    func testTonightsNamedShapesComeBackSettledOnTonightsSky() throws {
        let original = model()
        original.link(1); original.link(2)
        original.name("the kettle")

        let decoded = try JSONDecoder().decode(NightSkyState.self, from: JSONEncoder().encode(original.snapshot()))
        let restored = NightSkyModel(state: decoded)
        XCTAssertEqual(restored.named.map(\.name), ["the kettle"])
        XCTAssertEqual(restored.named.first?.path, [1, 2])
    }

    /// A blob written against another sky cannot leave a link pointing at a
    /// star that is not there.
    func testLinksIntoNothingAreDroppedRatherThanCarried() {
        let sky = NightSkyModel(state: NightSkyState(
            skySeed: 7,
            dateStamp: "2026-07-16",
            drawing: [1, 9_999, 2],
            named: [NightSkyConstellation(name: "gone", path: [4, 10_000])]
        ))
        XCTAssertEqual(sky.path, [1, 2])
        XCTAssertEqual(sky.named, [], "a shape that points at nothing is not drawn")
    }
}

// MARK: - The sketch

@MainActor
final class NightSkySketchTests: XCTestCase {
    /// A short chain through a real sky: each link runs to the nearest star not
    /// yet in the shape, which is roughly what a person's eye does.
    private func chain(in sky: [NightSkyStar], from start: Int, length: Int) -> [Int] {
        var path = [start]
        while path.count < length {
            let last = sky[path[path.count - 1]]
            let next = sky.indices
                .filter { !path.contains($0) }
                .min { hypot(sky[$0].x - last.x, sky[$0].y - last.y) < hypot(sky[$1].x - last.x, sky[$1].y - last.y) }
            guard let next else { break }
            path.append(next)
        }
        return path
    }

    /// The invariant the almanac rests on: the sketch shows the shape's stars,
    /// all of them, and never quietly loses one to a neighbouring cell.
    func testASketchHoldsExactlyTheConstellationsStars() {
        for seed in seeds.prefix(120) {
            let sky = NightSkyField.stars(seed: seed, dateStamp: "2026-07-16")
            for length in [2, 3, 5, 8, 12] {
                let path = chain(in: sky, from: Int(seed % UInt64(sky.count)), length: length)
                let rows = NightSkySketch.rows(path: path, sky: sky)
                let drawn = rows.joined().filter { $0 == NightSkySketch.star }.count
                XCTAssertEqual(drawn, Set(path).count,
                               "seed \(seed), \(length) stars: the sketch drew \(drawn) of them")
            }
        }
    }

    func testAClosedLoopDrawsEachStarOnceNotTwice() {
        let sky = NightSkyField.stars(seed: 11, dateStamp: "2026-07-16")
        let path = chain(in: sky, from: 0, length: 4) + [0]
        let rows = NightSkySketch.rows(path: path, sky: sky)
        XCTAssertEqual(rows.joined().filter { $0 == NightSkySketch.star }.count, 4)
    }

    func testASketchIsRectangularEnoughAndNeverRunsAway() {
        for seed in seeds.prefix(60) {
            let sky = NightSkyField.stars(seed: seed, dateStamp: "2026-07-16")
            let rows = NightSkySketch.rows(path: chain(in: sky, from: 0, length: 6), sky: sky)
            let widest = NightSkySketch.resolutions.map(\.cols).max() ?? 0
            let tallest = NightSkySketch.resolutions.map(\.rows).max() ?? 0
            XCTAssertLessThanOrEqual(rows.count, tallest)
            XCTAssertTrue(rows.allSatisfy { $0.count <= widest })
            XCTAssertFalse(rows.isEmpty)
        }
    }

    func testASketchIsTrimmedButNeverIntoTheShape() {
        let sky = NightSkyField.stars(seed: 5, dateStamp: "2026-07-16")
        let rows = NightSkySketch.rows(path: chain(in: sky, from: 0, length: 5), sky: sky)
        XCTAssertFalse(rows.first?.isEmpty ?? true, "no blank band above the shape")
        XCTAssertFalse(rows.last?.isEmpty ?? true, "or below it")
        XCTAssertTrue(rows.allSatisfy { !$0.hasSuffix(" ") }, "no trailing whitespace to leave in a file")
    }

    func testAnEmptyPathSketchesNothing() {
        XCTAssertEqual(NightSkySketch.rows(path: [], sky: NightSkyField.stars(seed: 1, dateStamp: "2026-07-16")), [])
    }

    /// Context, not a second sky.
    func testASketchShowsOnlyAFewNeighbours() {
        for seed in seeds.prefix(60) {
            let sky = NightSkyField.stars(seed: seed, dateStamp: "2026-07-16")
            let rows = NightSkySketch.rows(path: chain(in: sky, from: 0, length: 5), sky: sky)
            let dots = rows.joined().filter { $0 == NightSkySketch.neighbor }.count
            XCTAssertLessThanOrEqual(dots, NightSkySketch.neighborLimit)
        }
    }

    func testTheSameShapeSketchesTheSameWayEveryTime() {
        let sky = NightSkyField.stars(seed: 21, dateStamp: "2026-07-16")
        let path = chain(in: sky, from: 3, length: 6)
        XCTAssertEqual(NightSkySketch.rows(path: path, sky: sky), NightSkySketch.rows(path: path, sky: sky))
    }

    func testTheMembersOfAShapeAreItsStarsEachOnceInLinkOrder() {
        let sky = NightSkyField.stars(seed: 1, dateStamp: "2026-07-16")
        XCTAssertEqual(NightSkySketch.orderedMembers(of: [4, 2, 4, 9, 2], in: sky), [4, 2, 9])
        XCTAssertEqual(NightSkySketch.orderedMembers(of: [4, 99_999], in: sky), [4])
    }

    // MARK: - Glyphs

    func testALinkIsWalkedWithTheGlyphEachStepEarns() {
        let across = NightSkySketch.walk(from: .init(col: 0, row: 0), to: .init(col: 4, row: 0))
        XCTAssertEqual(across.map(\.glyph), ["─", "─", "─"])
        XCTAssertEqual(across.map(\.cell), [.init(col: 1, row: 0), .init(col: 2, row: 0), .init(col: 3, row: 0)])

        let down = NightSkySketch.walk(from: .init(col: 0, row: 0), to: .init(col: 0, row: 3))
        XCTAssertEqual(down.map(\.glyph), ["│", "│"])

        let fallingRight = NightSkySketch.walk(from: .init(col: 0, row: 0), to: .init(col: 3, row: 3))
        XCTAssertEqual(fallingRight.map(\.glyph), ["╲", "╲"])

        let fallingLeft = NightSkySketch.walk(from: .init(col: 3, row: 0), to: .init(col: 0, row: 3))
        XCTAssertEqual(fallingLeft.map(\.glyph), ["╱", "╱"])
    }

    func testAWalkLeavesTheEndpointsForTheStars() {
        let steps = NightSkySketch.walk(from: .init(col: 0, row: 0), to: .init(col: 5, row: 2))
        XCTAssertFalse(steps.contains { $0.cell == .init(col: 0, row: 0) })
        XCTAssertFalse(steps.contains { $0.cell == .init(col: 5, row: 2) })
        XCTAssertTrue(NightSkySketch.walk(from: .init(col: 1, row: 1), to: .init(col: 1, row: 1)).isEmpty)
    }

    func testAWalkIsAConnectedLineOfSingleSteps() {
        let steps = NightSkySketch.walk(from: .init(col: 0, row: 0), to: .init(col: 9, row: 4))
        let cells = [NightSkySketch.Cell(col: 0, row: 0)] + steps.map(\.cell) + [.init(col: 9, row: 4)]
        for (from, to) in zip(cells, cells.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(to.col - from.col), 1)
            XCTAssertLessThanOrEqual(abs(to.row - from.row), 1)
            XCTAssertNotEqual(from, to)
        }
    }

    func testAShallowLinkReadsAsALineThatDropsRatherThanAStair() {
        let steps = NightSkySketch.walk(from: .init(col: 0, row: 0), to: .init(col: 8, row: 2))
        XCTAssertTrue(steps.contains { $0.glyph == "─" })
        XCTAssertTrue(steps.contains { $0.glyph == "╲" })
        XCTAssertFalse(steps.contains { $0.glyph == "│" }, "a shallow link never drops straight down")
    }
}

// MARK: - The prose

@MainActor
final class NightSkyProseTests: XCTestCase {
    private func sky(_ points: [(Double, Double)]) -> [NightSkyStar] {
        points.map { NightSkyStar(x: $0.0, y: $0.1, brightness: 0) }
    }

    func testCountsAreWordsNotFigures() {
        XCTAssertEqual(NightSkyProse.word(for: 1), "one")
        XCTAssertEqual(NightSkyProse.word(for: 7), "seven")
        XCTAssertEqual(NightSkyProse.word(for: 12), "twelve")
        XCTAssertEqual(NightSkyProse.word(for: 20), "twenty")
        XCTAssertEqual(NightSkyProse.word(for: 21), "twenty-one")
        XCTAssertEqual(NightSkyProse.word(for: 40), "forty")
        XCTAssertEqual(NightSkyProse.word(for: 99), "ninety-nine")
        XCTAssertEqual(NightSkyProse.word(for: 120), "120", "past counting, a figure is honest enough")
    }

    func testTheLineSaysWhatIsThereAndWhereItSits() {
        // Low in the west: the panel's bottom right, facing south.
        let field = sky([(0.8, 0.8), (0.85, 0.85), (0.9, 0.9)])
        XCTAssertEqual(NightSkyProse.line(path: [0, 1, 2], sky: field), "three stars, low in the west")
    }

    func testPlacementReadsAsAStargazerFacingSouth() {
        XCTAssertEqual(NightSkyProse.placement(of: [0], in: sky([(0.1, 0.1)])), "high in the east")
        XCTAssertEqual(NightSkyProse.placement(of: [0], in: sky([(0.5, 0.5)])), "midway up in the south")
        XCTAssertEqual(NightSkyProse.placement(of: [0], in: sky([(0.9, 0.9)])), "low in the west")
        XCTAssertEqual(NightSkyProse.placement(of: [0], in: sky([(0.9, 0.1)])), "high in the west")
    }

    func testPlacementIsTheShapesMiddleNotItsFirstStar() {
        let field = sky([(0.05, 0.05), (0.95, 0.95)])
        XCTAssertEqual(NightSkyProse.placement(of: [0, 1], in: field), "midway up in the south")
    }

    func testAStarIsCountedOnceHoweverManyTimesItIsLinked() {
        let field = sky([(0.5, 0.5), (0.6, 0.5), (0.55, 0.6)])
        XCTAssertTrue(NightSkyProse.line(path: [0, 1, 2, 0], sky: field).hasPrefix("three stars,"))
    }

    func testTheLineIsQuietAndFactualWithNoAdjectiveForHowGoodItIs() {
        let field = sky([(0.5, 0.5), (0.6, 0.5)])
        let line = NightSkyProse.line(path: [0, 1], sky: field)
        XCTAssertEqual(line, "two stars, midway up in the south")
        XCTAssertFalse(line.contains("!"))
    }

    func testOneStarIsSingular() {
        XCTAssertEqual(NightSkyProse.line(path: [0], sky: sky([(0.5, 0.5)])), "one star, midway up in the south")
    }
}

// MARK: - The almanac file

@MainActor
final class NightSkyAlmanacTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("night-sky-tests-\(UUID().uuidString)")
            .appendingPathComponent("star-almanac.md")
    }

    private func constellation(seed: UInt64 = 12_345) -> (NightSkyConstellation, [NightSkyStar]) {
        let sky = NightSkyField.stars(seed: seed, dateStamp: "2026-07-16")
        var path = [0]
        while path.count < 6 {
            let last = sky[path[path.count - 1]]
            guard let next = sky.indices
                .filter({ !path.contains($0) })
                .min(by: { hypot(sky[$0].x - last.x, sky[$0].y - last.y) < hypot(sky[$1].x - last.x, sky[$1].y - last.y) })
            else { break }
            path.append(next)
        }
        return (NightSkyConstellation(name: "the kettle", path: path), sky)
    }

    func testDayStamp() {
        XCTAssertEqual(NightSkyAlmanac.dayStamp(for: date(), calendar: utc), "2026-07-16")
        XCTAssertEqual(NightSkyAlmanac.dayStamp(for: date(year: 2026, month: 1, day: 1), calendar: utc), "2026-01-01")
    }

    func testASectionIsANameANightASketchAndALine() {
        let (shape, sky) = constellation()
        let section = NightSkyAlmanac.section(for: shape, sky: sky, dateStamp: "2026-07-16")

        XCTAssertTrue(section.hasPrefix("## the kettle · 2026-07-16"))
        XCTAssertTrue(section.contains(NightSkyProse.line(path: shape.path, sky: sky)))
        XCTAssertTrue(section.hasSuffix("\n"))
    }

    /// The other half of the sketch invariant: it is inside the fence, all of
    /// it, and the fence closes.
    func testTheSketchStaysInsideItsFenceAndHoldsTheShapesStars() {
        for seed in seeds.prefix(40) {
            let (shape, sky) = constellation(seed: seed)
            let section = NightSkyAlmanac.section(for: shape, sky: sky, dateStamp: "2026-07-16")
            let lines = section.components(separatedBy: "\n")

            let fences = lines.indices.filter { lines[$0] == "```" }
            XCTAssertEqual(fences.count, 2, "seed \(seed): a sketch has an opening and a closing fence")
            guard fences.count == 2 else { continue }

            let sketch = Array(lines[(fences[0] + 1)..<fences[1]])
            XCTAssertEqual(sketch, NightSkySketch.rows(path: shape.path, sky: sky))
            XCTAssertEqual(sketch.joined().filter { $0 == NightSkySketch.star }.count, Set(shape.path).count,
                           "seed \(seed): the fenced sketch is the constellation")
            XCTAssertFalse(sketch.contains { $0.contains("```") }, "nothing inside the fence can break out of it")
            XCTAssertFalse(sketch.contains { $0.hasPrefix("## ") })
        }
    }

    func testTheFirstConstellationLaysDownTheHeader() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (shape, sky) = constellation()
        NightSkyAlmanac.record(shape, sky: sky, dateStamp: "2026-07-16", to: url)
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.hasPrefix("# Night Sky"))
        XCTAssertTrue(content.contains("## the kettle · 2026-07-16"))
        XCTAssertTrue(content.contains("```"))
    }

    func testEachConstellationIsItsOwnSectionAppendedInOrder() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (shape, sky) = constellation()
        NightSkyAlmanac.record(shape, sky: sky, dateStamp: "2026-07-16", to: url)
        NightSkyAlmanac.record(
            NightSkyConstellation(name: "the spoon", path: shape.path),
            sky: sky, dateStamp: "2026-07-17", to: url
        )

        let content = try String(contentsOf: url, encoding: .utf8)
        let kettle = try XCTUnwrap(content.range(of: "## the kettle"))
        let spoon = try XCTUnwrap(content.range(of: "## the spoon"))
        XCTAssertTrue(kettle.lowerBound < spoon.lowerBound, "the almanac only ever grows at the end")
        XCTAssertEqual(content.components(separatedBy: "# Night Sky").count - 1, 1, "one header, ever")
        XCTAssertEqual(content.components(separatedBy: "```").count - 1, 4, "two shapes, two fences")
    }

    func testAppendingIsPureAndOnlyEverAddsASection() {
        let first = NightSkyAlmanac.appending(section: "## a · 2026-07-16\n", to: "")
        let second = NightSkyAlmanac.appending(section: "## b · 2026-07-16\n", to: first)

        XCTAssertEqual(NightSkyAlmanac.appending(section: "## a · 2026-07-16\n", to: ""), first,
                       "appending reads nothing but its arguments")
        XCTAssertTrue(second.hasPrefix(first))
        XCTAssertTrue(second.hasSuffix("## b · 2026-07-16\n"))
    }

    func testAFileWithoutATrailingNewlineStillTakesASection() {
        let content = NightSkyAlmanac.appending(section: "## b · 2026-07-16\n", to: "# Night Sky\n\n## a · 2026-07-15")
        XCTAssertTrue(content.contains("## a · 2026-07-15\n"))
        XCTAssertTrue(content.hasSuffix("## b · 2026-07-16\n"))
    }

    /// The file is the user's. If they rewrite it, the game writes below
    /// whatever is there and never repairs, recounts, or reads it back.
    func testAnAlmanacTheUserRewroteIsNotTheGamesBusiness() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (shape, sky) = constellation()
        NightSkyAlmanac.record(shape, sky: sky, dateStamp: "2026-07-16", to: url)
        try "# my own sky\n\nI renamed them all.\n".write(to: url, atomically: true, encoding: .utf8)
        NightSkyAlmanac.record(shape, sky: sky, dateStamp: "2026-07-17", to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# my own sky"), "the user's edits survive untouched")
        XCTAssertTrue(content.contains("I renamed them all."))
        XCTAssertTrue(content.contains("## the kettle · 2026-07-17"))
    }
}

// MARK: - Registration

@MainActor
final class NightSkyCatalogRegistrationTests: XCTestCase {
    func testNightSkyIsInTheArcadeCatalog() {
        let entry = ArcadeGameCatalog.games.first { $0.id == NightSkyView.gameID }
        XCTAssertNotNil(entry, "Night Sky must be registered in the arcade")
        XCTAssertEqual(entry?.title, "Night Sky")
    }

    func testAFreshViewSizesToThePanel() {
        let view = NightSkyView(savedState: nil)
        XCTAssertEqual(view.view.frame.size, BlocksGameView.contentSize)
        XCTAssertNotNil(view.encodeState())
    }

    func testAnUndecodableBlobIsAFreshSkyRatherThanACrash() {
        let view = NightSkyView(savedState: Data("not json".utf8))
        XCTAssertEqual(view.view.frame.size, BlocksGameView.contentSize)
        XCTAssertNotNil(view.encodeState())
    }

    func testStateSurvivesAnEncodeDecodeThroughTheView() throws {
        let first = NightSkyView(savedState: nil)
        let blob = try XCTUnwrap(first.encodeState())
        let second = NightSkyView(savedState: blob)
        let restored = try XCTUnwrap(second.encodeState())

        // Compare the decoded state, not the bytes: JSONEncoder does not
        // promise a stable key order between two encodes of the same value.
        XCTAssertEqual(try JSONDecoder().decode(NightSkyState.self, from: restored),
                       try JSONDecoder().decode(NightSkyState.self, from: blob),
                       "a hidden sky comes back as it was")
    }

    /// A sky saved on another night is not carried over: the panel opens on
    /// tonight, with nothing said about the nights in between.
    func testAViewRestoredFromAnOlderNightOpensOnTonight() throws {
        let stale = NightSkyState(skySeed: 99, dateStamp: "2020-01-01", drawing: [1, 2, 3])
        let view = NightSkyView(savedState: try JSONEncoder().encode(stale))
        let state = try JSONDecoder().decode(NightSkyState.self, from: try XCTUnwrap(view.encodeState()))

        XCTAssertEqual(state.dateStamp, NightSkyAlmanac.dayStamp(for: Date()))
        XCTAssertEqual(state.drawing, [], "last night's unfinished shape is let go")
        XCTAssertEqual(state.skySeed, 99, "the install's own seed stays put")
    }

    func testTheHowToPlayKeepsTheRegister() {
        XCTAssertFalse(NightSkyView.howToPlay.contains("—"), "no em dashes in the directions")
        XCTAssertFalse(NightSkyView.howToPlay.contains("!"))
        XCTAssertTrue(NightSkyView.howToPlay.contains("Esc"), "every game says how to get out")
    }
}

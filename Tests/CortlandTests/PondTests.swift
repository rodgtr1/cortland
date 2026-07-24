import XCTest
@testable import Cortland

/// A fixed calendar so the time-of-day bands never depend on where the test
/// machine is standing.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(hour: Int, day: Int = 16) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 7
    components.day = day
    components.hour = hour
    components.minute = 30
    return utc.date(from: components)!
}

private let noon = date(hour: 12)      // day
private let midnight = date(hour: 1)   // night
private let dawn = date(hour: 7)       // morning
private let dusk = date(hour: 19)      // evening

private let minute: TimeInterval = 60
private let hour: TimeInterval = 3600

@MainActor
final class PondCatalogTests: XCTestCase {
    func testCatalogIsTheRightSizeAndHasNoDuplicates() {
        let count = PondCatalog.species.count
        XCTAssertGreaterThanOrEqual(count, 35)
        XCTAssertLessThanOrEqual(count, 50)
        XCTAssertEqual(Set(PondCatalog.species.map(\.id)).count, count, "no duplicate ids")
        XCTAssertEqual(Set(PondCatalog.species.map(\.name)).count, count, "no duplicate names")
    }

    func testEveryTierIsPopulatedAndReachableAtAnyHour() {
        for tier in PondTier.allCases {
            let inTier = PondCatalog.species(in: tier)
            XCTAssertGreaterThanOrEqual(inTier.count, 4, "tier \(tier) is too thin")
            for time in PondTimeOfDay.allCases {
                XCTAssertFalse(inTier.filter { $0.fits(time) }.isEmpty,
                               "tier \(tier) is gated out entirely at \(time.name)")
            }
        }
    }

    func testEverySpeciesHasSizesAndFlavor() {
        for species in PondCatalog.species {
            XCTAssertFalse(species.sizes.isEmpty, "\(species.id) needs at least one size phrase")
            XCTAssertFalse(species.flavor.isEmpty, "\(species.id) needs a flavor line")
            XCTAssertNotEqual(species.gate, [], "\(species.id) has an empty gate, which can never be met")
        }
    }

    func testProseKeepsTheRegister() {
        for species in PondCatalog.species {
            let lines = [species.flavor] + species.sizes
            for line in lines {
                XCTAssertFalse(line.contains("!"), "no exclamation marks: \(line)")
                XCTAssertFalse(line.contains("—"), "no em dashes in the prose: \(line)")
            }
        }
    }

    func testLookupByID() {
        XCTAssertEqual(PondCatalog.species(id: "minnow")?.name, "minnow")
        XCTAssertNil(PondCatalog.species(id: "kraken"))
    }
}

@MainActor
final class PondBandTests: XCTestCase {
    func testBandBoundaries() {
        XCTAssertEqual(PondBand.forElapsed(0), .brief)
        XCTAssertEqual(PondBand.forElapsed(10), .brief)
        XCTAssertEqual(PondBand.forElapsed(2 * minute - 1), .brief)
        XCTAssertEqual(PondBand.forElapsed(2 * minute), .short)
        XCTAssertEqual(PondBand.forElapsed(15 * minute - 1), .short)
        XCTAssertEqual(PondBand.forElapsed(15 * minute), .medium)
        XCTAssertEqual(PondBand.forElapsed(90 * minute - 1), .medium)
        XCTAssertEqual(PondBand.forElapsed(90 * minute), .long)
        XCTAssertEqual(PondBand.forElapsed(12 * hour - 1), .long)
        XCTAssertEqual(PondBand.forElapsed(12 * hour), .vigil)
        XCTAssertEqual(PondBand.forElapsed(72 * hour), .vigil)
    }

    func testNegativeElapsedIsTreatedAsNoTimeAtAll() {
        XCTAssertEqual(PondBand.forElapsed(-500), .brief)
        XCTAssertEqual(PondBobberStage.forElapsed(-500), .high)
    }

    func testEachBandOpensExactlyOneMoreTier() {
        for band in PondBand.allCases {
            XCTAssertEqual(band.tierWeights.count, band.deepestTier.rawValue + 1)
            XCTAssertFalse(band.tierWeights.contains { $0 <= 0 }, "\(band) has a tier it can never draw")
        }
        XCTAssertEqual(PondBand.brief.deepestTier, .common)
        XCTAssertEqual(PondBand.vigil.deepestTier, .strange)
    }

    func testBobberStageBoundaries() {
        XCTAssertEqual(PondBobberStage.forElapsed(0), .high)
        XCTAssertEqual(PondBobberStage.forElapsed(2 * minute), .settled)
        XCTAssertEqual(PondBobberStage.forElapsed(15 * minute), .low)
        XCTAssertEqual(PondBobberStage.forElapsed(90 * minute), .deep)
        XCTAssertEqual(PondBobberStage.forElapsed(200 * hour), .deep, "the deepest stage is a floor, not a countdown")
    }
}

@MainActor
final class PondTimeOfDayTests: XCTestCase {
    func testHourBands() {
        XCTAssertEqual(PondTimeOfDay.at(date(hour: 6), calendar: utc), .morning)
        XCTAssertEqual(PondTimeOfDay.at(date(hour: 9), calendar: utc), .morning)
        XCTAssertEqual(PondTimeOfDay.at(date(hour: 10), calendar: utc), .day)
        XCTAssertEqual(PondTimeOfDay.at(date(hour: 16), calendar: utc), .day)
        XCTAssertEqual(PondTimeOfDay.at(date(hour: 17), calendar: utc), .evening)
        XCTAssertEqual(PondTimeOfDay.at(date(hour: 20), calendar: utc), .evening)
        XCTAssertEqual(PondTimeOfDay.at(date(hour: 21), calendar: utc), .night)
        XCTAssertEqual(PondTimeOfDay.at(date(hour: 3), calendar: utc), .night)
    }
}

@MainActor
final class PondRollTests: XCTestCase {
    private func sample(elapsed: TimeInterval, now: Date, count: Int = 400) -> [PondSpecies] {
        (0..<count).map { PondModel.roll(castSeed: UInt64($0) &* 2_654_435_761, elapsed: elapsed, now: now, calendar: utc) }
    }

    // MARK: - Determinism

    func testSameInputsProduceTheSameCatch() {
        for seed: UInt64 in [1, 42, 7777, 0xDEADBEEF] {
            for elapsed: TimeInterval in [10, 5 * minute, 40 * minute, 4 * hour, 30 * hour] {
                let a = PondModel.roll(castSeed: seed, elapsed: elapsed, now: noon, calendar: utc)
                let b = PondModel.roll(castSeed: seed, elapsed: elapsed, now: noon, calendar: utc)
                XCTAssertEqual(a.id, b.id, "seed \(seed) at \(elapsed)s must roll identically")
            }
        }
    }

    func testDifferentCastSeedsDiverge() {
        let a = sample(elapsed: 30 * hour, now: noon).map(\.id)
        let b = (0..<400).map {
            PondModel.roll(castSeed: UInt64($0) &* 11_400_714_819_323_198_485, elapsed: 30 * hour, now: noon, calendar: utc).id
        }
        XCTAssertNotEqual(a, b)
    }

    func testTheReelInMomentIsPartOfTheSeed() {
        let atNoon = PondModel.roll(castSeed: 99, elapsed: hour, now: noon, calendar: utc)
        let aMinuteLater = PondModel.roll(castSeed: 99, elapsed: hour, now: noon.addingTimeInterval(60), calendar: utc)
        // Not a hard guarantee for a single pair, but across a spread the rolls
        // must not be identical: the moment of reel-in is a real input.
        let spread = (0..<50).map {
            PondModel.roll(castSeed: 99, elapsed: hour, now: noon.addingTimeInterval(Double($0) * 60), calendar: utc).id
        }
        XCTAssertGreaterThan(Set(spread).count, 1)
        _ = (atNoon, aMinuteLater)
    }

    // MARK: - The pool only ever widens

    func testShortWaitsLandCommonThingsAndNeverNothing() {
        for species in sample(elapsed: 10, now: noon) {
            XCTAssertEqual(species.tier, .common, "\(species.id) is too deep for a ten-second cast")
        }
    }

    func testEachBandNeverExceedsItsDeepestTier() {
        let cases: [(TimeInterval, PondTier)] = [
            (10, .common), (5 * minute, .uncommon), (40 * minute, .notable),
            (4 * hour, .rare), (30 * hour, .strange)
        ]
        for (elapsed, deepest) in cases {
            for species in sample(elapsed: elapsed, now: midnight) {
                XCTAssertLessThanOrEqual(species.tier.rawValue, deepest.rawValue,
                                         "\(species.id) surfaced at \(elapsed)s, deeper than \(deepest)")
            }
        }
    }

    func testEachBandActuallyReachesItsNewTier() {
        let cases: [(TimeInterval, PondTier)] = [
            (5 * minute, .uncommon), (40 * minute, .notable), (4 * hour, .rare), (30 * hour, .strange)
        ]
        for (elapsed, tier) in cases {
            let hits = sample(elapsed: elapsed, now: midnight).filter { $0.tier == tier }
            XCTAssertFalse(hits.isEmpty, "\(tier) is unreachable at \(elapsed)s")
        }
    }

    func testALongWaitCanStillLandSomethingSmall() {
        let tiers = Set(sample(elapsed: 72 * hour, now: noon).map(\.tier))
        XCTAssertTrue(tiers.contains(.common), "a three-day wait must still be able to land a minnow")
        XCTAssertTrue(tiers.contains(.strange), "a three-day wait must be able to reach the strange tier")
    }

    func testDeepTiersGetMoreLikelyAsTheLineStaysOut() {
        let shallow = sample(elapsed: 5 * minute, now: midnight).filter { $0.tier != .common }.count
        let deep = sample(elapsed: 30 * hour, now: midnight).filter { $0.tier != .common }.count
        XCTAssertGreaterThan(deep, shallow, "waiting should widen the pool, not narrow it")
    }

    // MARK: - Time of day

    func testGatedSpeciesNeverSurfaceAtTheWrongHour() {
        for now in [noon, midnight, dawn, dusk] {
            let time = PondTimeOfDay.at(now, calendar: utc)
            for elapsed: TimeInterval in [10, 5 * minute, 40 * minute, 4 * hour, 30 * hour] {
                for species in sample(elapsed: elapsed, now: now) {
                    XCTAssertTrue(species.fits(time), "\(species.id) surfaced at \(time.name), where it is gated out")
                }
            }
        }
    }

    func testNightOnlySpeciesAreReachableAtNight() {
        let nightIDs = Set(sample(elapsed: 30 * hour, now: midnight, count: 800).map(\.id))
        XCTAssertTrue(nightIDs.contains("moonlight fish"), "the night tier should be reachable on a long night cast")
    }
}

@MainActor
final class PondModelTests: XCTestCase {
    func testFreshPondHasNoLineOutAndNothingFound() {
        let model = PondModel(seed: 7)
        XCTAssertFalse(model.isLineOut)
        XCTAssertEqual(model.distinctSpecies, 0)
        XCTAssertEqual(model.totalCatches, 0)
        XCTAssertNil(model.elapsed(now: noon))
        XCTAssertNil(model.bobberStage(now: noon))
        XCTAssertNil(model.reelIn(now: noon, calendar: utc), "there is nothing to reel in yet")
    }

    func testCastRecordsTheMomentAndTheSeed() {
        let model = PondModel(seed: 7)
        XCTAssertTrue(model.cast(now: noon, seed: 555))
        XCTAssertTrue(model.isLineOut)
        XCTAssertEqual(model.snapshot().castDate, noon)
        XCTAssertEqual(model.snapshot().castSeed, 555)
        XCTAssertEqual(model.elapsed(now: noon.addingTimeInterval(90)), 90)
    }

    func testCastingAgainWithALineOutChangesNothing() {
        let model = PondModel(seed: 7)
        model.cast(now: noon, seed: 555)
        XCTAssertFalse(model.cast(now: noon.addingTimeInterval(600), seed: 999),
                       "a second cast is refused, not silently restarted")
        XCTAssertEqual(model.snapshot().castDate, noon, "the original cast is never disturbed")
        XCTAssertEqual(model.snapshot().castSeed, 555)
    }

    func testEveryReelInLandsSomethingEvenAfterTenSeconds() {
        for seed: UInt64 in 0..<200 {
            let model = PondModel(seed: seed)
            model.cast(now: noon, seed: seed &* 2_654_435_761)
            let landed = model.reelIn(now: noon.addingTimeInterval(10), calendar: utc)
            XCTAssertNotNil(landed, "seed \(seed): a short cast still lands something")
            XCTAssertFalse(landed?.name.isEmpty ?? true)
            XCTAssertFalse(landed?.size.isEmpty ?? true)
        }
    }

    func testReelInClearsTheLineAndRecordsTheCatch() {
        let model = PondModel(seed: 7)
        model.cast(now: noon, seed: 555)
        let landed = model.reelIn(now: noon.addingTimeInterval(3 * hour), calendar: utc)

        XCTAssertNotNil(landed)
        XCTAssertFalse(model.isLineOut, "reeling in takes the line out of the water")
        XCTAssertNil(model.snapshot().castDate)
        XCTAssertNil(model.snapshot().castSeed)
        XCTAssertEqual(model.totalCatches, 1)
        XCTAssertEqual(model.distinctSpecies, 1)
        XCTAssertEqual(landed?.elapsed, 3 * hour)
        XCTAssertEqual(model.snapshot().speciesFound, [landed!.speciesID])
    }

    func testFirstOfASpeciesIsFlaggedOnceAndOnlyOnce() {
        let model = PondModel(seed: 7)
        var firsts = 0
        var seen = Set<String>()
        for index in 0..<60 {
            model.cast(now: noon, seed: UInt64(index) &* 6_364_136_223_846_793_005)
            guard let landed = model.reelIn(now: noon.addingTimeInterval(30 * hour), calendar: utc) else {
                return XCTFail("every reel-in lands something")
            }
            XCTAssertEqual(landed.isFirst, !seen.contains(landed.speciesID),
                           "\(landed.speciesID) reported the wrong first-ever flag")
            if landed.isFirst { firsts += 1 }
            seen.insert(landed.speciesID)
        }
        XCTAssertEqual(firsts, seen.count)
        XCTAssertEqual(model.distinctSpecies, seen.count)
        XCTAssertEqual(model.totalCatches, 60)
    }

    func testCatchMatchesItsCatalogEntry() {
        let model = PondModel(seed: 7)
        model.cast(now: midnight, seed: 4242)
        let landed = model.reelIn(now: midnight.addingTimeInterval(20 * hour), calendar: utc)!
        let species = PondCatalog.species(id: landed.speciesID)
        XCTAssertNotNil(species)
        XCTAssertEqual(landed.name, species?.name)
        XCTAssertEqual(landed.flavor, species?.flavor)
        XCTAssertEqual(landed.tier, species?.tier)
        XCTAssertTrue(species?.sizes.contains(landed.size) ?? false, "the size must come from the species' own range")
    }

    func testAClockThatMovedBackwardsCostsNothing() {
        let model = PondModel(seed: 7)
        model.cast(now: noon, seed: 555)
        XCTAssertEqual(model.elapsed(now: noon.addingTimeInterval(-3600)), 0)
        XCTAssertEqual(model.bobberStage(now: noon.addingTimeInterval(-3600)), .high)
        let landed = model.reelIn(now: noon.addingTimeInterval(-3600), calendar: utc)
        XCTAssertNotNil(landed, "a backwards clock still lands something")
        XCTAssertEqual(landed?.elapsed, 0)
    }

    func testBobberSinksAsTheLineStaysOut() {
        let model = PondModel(seed: 7)
        model.cast(now: noon, seed: 555)
        XCTAssertEqual(model.bobberStage(now: noon.addingTimeInterval(30)), .high)
        XCTAssertEqual(model.bobberStage(now: noon.addingTimeInterval(5 * minute)), .settled)
        XCTAssertEqual(model.bobberStage(now: noon.addingTimeInterval(40 * minute)), .low)
        XCTAssertEqual(model.bobberStage(now: noon.addingTimeInterval(5 * hour)), .deep)
    }

    func testDurationPhrasesAreQuietMarkers() {
        XCTAssertEqual(PondModel.durationPhrase(0), "0 s")
        XCTAssertEqual(PondModel.durationPhrase(42), "42 s")
        XCTAssertEqual(PondModel.durationPhrase(12 * minute), "12 min")
        XCTAssertEqual(PondModel.durationPhrase(4 * hour), "4 h")
        XCTAssertEqual(PondModel.durationPhrase(47 * hour), "47 h")
        XCTAssertEqual(PondModel.durationPhrase(72 * hour), "3 d")
        XCTAssertEqual(PondModel.durationPhrase(-10), "0 s")
    }

    // MARK: - Persistence

    func testStateRoundTrips() throws {
        let model = PondModel(seed: 8080)
        model.cast(now: noon, seed: 1234)
        _ = model.reelIn(now: noon.addingTimeInterval(hour), calendar: utc)
        model.cast(now: dusk, seed: 5678)

        let snapshot = model.snapshot()
        let decoded = try JSONDecoder().decode(PondState.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testAPondRestoredMidCastReelsOnTheTrueElapsedTime() throws {
        let original = PondModel(seed: 8080)
        original.cast(now: noon, seed: 1234)

        let decoded = try JSONDecoder().decode(PondState.self, from: JSONEncoder().encode(original.snapshot()))
        let restored = PondModel(state: decoded)

        XCTAssertTrue(restored.isLineOut, "hiding the panel does not pull the line in")
        let later = noon.addingTimeInterval(26 * hour)
        XCTAssertEqual(restored.elapsed(now: later), 26 * hour)
        XCTAssertEqual(restored.bobberStage(now: later), .deep)

        let fromOriginal = original.reelIn(now: later, calendar: utc)
        let fromRestored = restored.reelIn(now: later, calendar: utc)
        XCTAssertEqual(fromOriginal?.speciesID, fromRestored?.speciesID,
                       "a restored pond lands exactly what the original would have")
        XCTAssertEqual(fromOriginal?.elapsed, 26 * hour)
    }

    func testUndecodableBlobsAreNotDecodable() {
        // The view treats nil here as a fresh pond; this pins the decode side.
        XCTAssertNil(try? JSONDecoder().decode(PondState.self, from: Data("{ nonsense".utf8)))
    }
}

@MainActor
final class PondAlmanacTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pond-tests-\(UUID().uuidString)")
            .appendingPathComponent("pond-almanac.md")
    }

    private func sampleCatch(isFirst: Bool = false) -> PondCatch {
        PondCatch(speciesID: "largemouth", name: "largemouth bass",
                  flavor: "It came up slow, then all at once.",
                  size: "a forearm's length, unhurried", tier: .notable,
                  elapsed: 4 * hour, isFirst: isFirst)
    }

    func testLineFormat() {
        XCTAssertEqual(
            PondAlmanac.line(for: sampleCatch(), date: noon),
            "- 2026-07-16 · **largemouth bass** — a forearm's length, unhurried · line out 4 h"
        )
    }

    func testFirstEverCatchIsMarked() {
        XCTAssertTrue(PondAlmanac.line(for: sampleCatch(isFirst: true), date: noon).hasSuffix(" · first"))
        XCTAssertFalse(PondAlmanac.line(for: sampleCatch(isFirst: false), date: noon).hasSuffix(" · first"))
    }

    func testFirstWriteLaysDownHeaderAndEntry() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        PondAlmanac.record(sampleCatch(isFirst: true), date: noon, to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# The Pond"), "the first catch lays down the header")
        XCTAssertTrue(content.contains("**largemouth bass**"))
    }

    func testEntriesAppendInOrderAndTheFileIsOnlyEverAddedTo() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        PondAlmanac.record(sampleCatch(isFirst: true), date: noon, to: url)
        PondAlmanac.record(sampleCatch(), date: date(hour: 12, day: 17), to: url)

        let entries = PondAlmanac.recentEntries(limit: 10, from: url)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].contains("2026-07-16"))
        XCTAssertTrue(entries[1].contains("2026-07-17"))
    }

    func testRecentEntriesRespectsTheLimitAndKeepsTheNewest() {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for day in 1...6 {
            PondAlmanac.record(sampleCatch(), date: date(hour: 12, day: day), to: url)
        }
        let entries = PondAlmanac.recentEntries(limit: 2, from: url)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[1].contains("2026-07-06"))
    }

    func testAUserRewrittenAlmanacIsNotTheGamesBusiness() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // The player deletes everything and leaves a note of their own. The
        // pond keeps appending and the species count, which lives in state,
        // is untouched by any of it.
        PondAlmanac.record(sampleCatch(), date: noon, to: url)
        try "# my own file\n\nnot a list\n".write(to: url, atomically: true, encoding: .utf8)
        PondAlmanac.record(sampleCatch(), date: noon, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# my own file"), "the player's edits survive")
        XCTAssertEqual(PondAlmanac.recentEntries(limit: 10, from: url).count, 1)
    }

    func testRecentEntriesOnAMissingFileIsEmpty() {
        XCTAssertEqual(PondAlmanac.recentEntries(limit: 5, from: temporaryFileURL()), [])
    }
}

@MainActor
final class PondCatalogRegistrationTests: XCTestCase {
    func testThePondIsInTheArcadeCatalog() {
        let entry = ArcadeGameCatalog.games.first { $0.id == PondView.gameID }
        XCTAssertNotNil(entry, "The Pond must be registered in the arcade")
        XCTAssertEqual(entry?.title, "The Pond")
    }

    func testAFreshViewSizesToThePanelAndStartsWithNoLineOut() {
        let view = PondView(savedState: nil)
        XCTAssertEqual(view.view.frame.size, BlocksGameView.contentSize)
        XCTAssertNotNil(view.encodeState())
    }

    func testAnUndecodableBlobIsAFreshPondRatherThanACrash() {
        let view = PondView(savedState: Data("not json".utf8))
        XCTAssertEqual(view.view.frame.size, BlocksGameView.contentSize)
    }

    func testStateSurvivesAnEncodeDecodeThroughTheView() throws {
        let first = PondView(savedState: nil)
        let blob = try XCTUnwrap(first.encodeState())
        let second = PondView(savedState: blob)
        let restored = try XCTUnwrap(second.encodeState())

        // Compare the decoded state, not the bytes: JSONEncoder does not
        // promise a stable key order, even between two encodes of the same
        // value in one process.
        XCTAssertEqual(try JSONDecoder().decode(PondState.self, from: restored),
                       try JSONDecoder().decode(PondState.self, from: blob),
                       "a hidden pond comes back exactly as it was")
    }
}

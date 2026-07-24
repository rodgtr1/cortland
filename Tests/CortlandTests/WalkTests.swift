import XCTest
@testable import Cortland

@MainActor
final class WalkModelTests: XCTestCase {
    private func walked(seed: UInt64, steps: Int) -> [WalkStep] {
        let model = WalkModel(seed: seed)
        return (0..<steps).map { _ in model.step() }
    }

    // MARK: - Determinism

    func testSameSeedProducesIdenticalWalkOver200Steps() {
        for seed: UInt64 in [1, 42, 7777, 0xDEADBEEF] {
            let a = walked(seed: seed, steps: 200)
            let b = walked(seed: seed, steps: 200)
            XCTAssertEqual(a.map(\.text), b.map(\.text), "seed \(seed) text must match exactly")
            XCTAssertEqual(a.map { $0.finding ?? "" }, b.map { $0.finding ?? "" })
            XCTAssertEqual(a.map(\.biome), b.map(\.biome))
            XCTAssertEqual(a.map(\.weather), b.map(\.weather))
        }
    }

    func testDifferentSeedsDiverge() {
        let a = walked(seed: 1, steps: 200).map(\.text)
        let b = walked(seed: 2, steps: 200).map(\.text)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Findings

    func testFindingRateAndGapOver2000Steps() {
        for seed: UInt64 in [3, 500, 123456] {
            let model = WalkModel(seed: seed)
            var findingSteps: [Int] = []
            for _ in 0..<2000 {
                let result = model.step()
                if result.finding != nil { findingSteps.append(result.step) }
            }
            let rate = Double(findingSteps.count) / 2000.0
            XCTAssertGreaterThanOrEqual(rate, 0.05, "seed \(seed): finding rate too low (\(rate))")
            XCTAssertLessThanOrEqual(rate, 0.12, "seed \(seed): finding rate too high (\(rate))")

            for pair in zip(findingSteps, findingSteps.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.1 - pair.0, WalkModel.minFindingGap,
                                            "seed \(seed): findings closer than the minimum gap")
            }
        }
    }

    func testFindingsAreBiomeAppropriate() {
        let model = WalkModel(seed: 99)
        for _ in 0..<3000 {
            let result = model.step()
            guard let finding = result.finding else { continue }
            let match = WalkContent.findings.first { $0.text == finding }
            XCTAssertNotNil(match)
            XCTAssertTrue(match?.fits(result.biome) ?? false,
                          "\(finding) surfaced in the \(result.biome.name), where it does not belong")
        }
    }

    func testFindingPoolIsLargeAndVaried() {
        XCTAssertGreaterThanOrEqual(WalkContent.findings.count, 60)
        XCTAssertEqual(Set(WalkContent.findings.map(\.text)).count, WalkContent.findings.count,
                       "no duplicate findings")
    }

    // MARK: - Biome and weather transitions

    func testBiomeTransitionsFollowAdjacencyAndDurationsInBounds() {
        let model = WalkModel(seed: 2024)
        var runs: [(WalkBiome, Int)] = []
        var current = model.biome
        var run = 0
        for _ in 0..<2000 {
            let result = model.step()
            if result.biome == current {
                run += 1
            } else {
                XCTAssertTrue(current.neighbors.contains(result.biome),
                              "\(current.name) jumped to non-neighbor \(result.biome.name)")
                runs.append((current, run))
                current = result.biome
                run = 1
            }
        }
        // Every completed run (all but the trailing in-progress one) must be a
        // valid, in-bounds biome duration.
        for (biome, length) in runs.dropLast() {
            XCTAssertTrue(WalkModel.biomeDurationRange.contains(length),
                          "\(biome.name) lasted \(length) steps, out of bounds")
        }
        XCTAssertGreaterThan(runs.count, 5, "a long walk should cross several biomes")
    }

    func testWeatherTransitionsFollowAdjacencyAndDurationsInBounds() {
        let model = WalkModel(seed: 55)
        var current = model.weather
        var run = 0
        var completedRuns: [Int] = []
        for _ in 0..<2000 {
            let result = model.step()
            if result.weather == current {
                run += 1
            } else {
                XCTAssertTrue(current.neighbors.contains(result.weather),
                              "\(current.name) jumped to non-neighbor \(result.weather.name)")
                completedRuns.append(run)
                current = result.weather
                run = 1
            }
        }
        for length in completedRuns.dropFirst() {
            XCTAssertTrue(WalkModel.weatherDurationRange.contains(length),
                          "weather run of \(length) steps is out of bounds")
        }
    }

    // MARK: - Anti-repetition

    func testNoTemplateRepeatsWithinItsFeasibleWindow() {
        let model = WalkModel(seed: 314)
        var history: [(WalkBiome, Int)] = []
        for _ in 0..<400 {
            let result = model.step()
            let poolSize = result.biome.templates.count
            // Mirror the model's memory: within the remembered window of the
            // last ~25 ids, a template never reuses any of the most recent
            // (poolSize - 1) same-biome picks. A biome lasts at most 20 steps,
            // so a whole continuous stay fits inside that window: no near
            // repeat is ever visible. (Reusing a line after leaving and
            // returning many steps later is fine and expected.)
            let window = history.suffix(WalkModel.templateWindow)
            var sameBiome: [Int] = []
            for past in window.reversed() where past.0 == result.biome {
                if sameBiome.count >= poolSize - 1 { break }
                sameBiome.append(past.1)
            }
            XCTAssertFalse(sameBiome.contains(result.templateID),
                           "template \(result.templateID) repeated within its window in \(result.biome.name)")
            history.append((result.biome, result.templateID))
        }
    }

    func testEveryBiomeHasAtLeastFiveTemplates() {
        for biome in WalkBiome.allCases {
            XCTAssertGreaterThanOrEqual(biome.templates.count, 5, "\(biome.name) needs at least five templates")
        }
    }

    func testAdjacencyIsSymmetricAndConnected() {
        // Symmetric: if A borders B, B borders A. Keeps the landscape coherent.
        for biome in WalkBiome.allCases {
            for neighbor in biome.neighbors {
                XCTAssertTrue(neighbor.neighbors.contains(biome),
                              "\(biome.name) borders \(neighbor.name) but not the reverse")
            }
        }
        // Connected: every biome reachable from the first by walking neighbors.
        var seen: Set<WalkBiome> = [WalkBiome.allCases[0]]
        var frontier = [WalkBiome.allCases[0]]
        while let next = frontier.popLast() {
            for neighbor in next.neighbors where !seen.contains(neighbor) {
                seen.insert(neighbor)
                frontier.append(neighbor)
            }
        }
        XCTAssertEqual(seen.count, WalkBiome.allCases.count, "the landscape graph must be fully connected")
    }

    // MARK: - Register (no forbidden punctuation in the prose)

    func testProseKeepsTheFieldNotebookRegister() {
        var allProse = WalkContent.timeWords + WalkContent.connectives + WalkContent.findings.map(\.text)
        for biome in WalkBiome.allCases { allProse += biome.templates }
        for weather in WalkWeather.allCases { allProse += weather.inflections }
        for line in allProse {
            XCTAssertFalse(line.contains("!"), "no exclamation marks: \(line)")
            XCTAssertFalse(line.contains("—"), "no em dashes in the prose: \(line)")
        }
    }

    // MARK: - Persistence

    func testStateRoundTripAndResumeProducesIdenticalWalk() throws {
        let original = WalkModel(seed: 8080)
        for _ in 0..<50 { original.step() }

        let snapshot = original.snapshot()
        let decoded = try JSONDecoder().decode(WalkState.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)

        let resumed = WalkModel(state: decoded)
        let continuedOriginal = (0..<10).map { _ in original.step().text }
        let continuedResumed = (0..<10).map { _ in resumed.step().text }
        XCTAssertEqual(continuedOriginal, continuedResumed,
                       "a restored walk continues identically to the original")
    }

    func testFreshWalkTakesNoStepsAndShowsNothingUntilAsked() {
        let model = WalkModel(seed: 7)
        XCTAssertEqual(model.currentStep, 0)
        XCTAssertFalse(model.hasStarted)
        XCTAssertTrue(model.lines.isEmpty)
    }

    func testFirstStepEntersTheStartingBiome() {
        let model = WalkModel(seed: 7)
        let first = model.step()
        XCTAssertEqual(first.step, 1)
        XCTAssertTrue(first.enteredBiome, "the first step logs the starting place")
        XCTAssertTrue(model.hasStarted)
    }
}

@MainActor
final class WalkJournalTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("walk-tests-\(UUID().uuidString)")
            .appendingPathComponent("the-walk.md")
    }

    func testFirstWriteLaysDownHeaderAndEntry() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        WalkJournal.recordBiomeEntry(step: 460, biome: .birchWood, weather: .lightRain, to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# The Walk"), "first write lays down the header")
        XCTAssertTrue(content.contains("- step 460 · entered the birch wood, light rain"))
    }

    func testFindingLineFormat() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        WalkJournal.recordBiomeEntry(step: 1, biome: .meadow, weather: .clear, to: url)
        WalkJournal.recordFinding(step: 482, biome: .birchWood, finding: "a stone with a perfect white ring", to: url)

        let entries = WalkJournal.recentEntries(limit: 10, from: url)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1], "- step 482 · birch wood · a stone with a perfect white ring")
    }

    func testRecentEntriesOnMissingFileIsEmpty() {
        XCTAssertEqual(WalkJournal.recentEntries(limit: 5, from: temporaryFileURL()), [])
    }
}


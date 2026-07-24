import XCTest
@testable import Cortland

@MainActor
final class GroveTreeTests: XCTestCase {
    private func planted(_ species: GroveSpecies = .maple, seed: UInt64 = 42) -> GroveTree {
        let tree = GroveTree(state: .empty)
        tree.plant(species: species, seed: seed, now: Date(timeIntervalSince1970: 1_000_000))
        return tree
    }

    // MARK: - Determinism

    func testSameSeedAndTicksProduceIdenticalTree() {
        for species in GroveSpecies.allCases {
            let a = planted(species, seed: 7)
            let b = planted(species, seed: 7)
            a.grow(ticks: 40)
            b.grow(ticks: 40)
            XCTAssertEqual(a.snapshot().segments, b.snapshot().segments,
                           "\(species) with the same seed and tick count must match exactly")
        }
    }

    func testChunkedGrowthMatchesOneLongGrow() {
        let whole = planted(.pine, seed: 99)
        let chunked = planted(.pine, seed: 99)
        whole.grow(ticks: 30)
        for _ in 0..<10 { chunked.grow(ticks: 3) }
        XCTAssertEqual(whole.snapshot().segments, chunked.snapshot().segments,
                       "growth must not depend on how ticks are chunked")
        XCTAssertEqual(whole.snapshot().growthTicks, chunked.snapshot().growthTicks)
    }

    func testDifferentSeedsDiverge() {
        let a = planted(.maple, seed: 1)
        let b = planted(.maple, seed: 2)
        a.grow(ticks: 40)
        b.grow(ticks: 40)
        XCTAssertNotEqual(a.snapshot().segments, b.snapshot().segments)
    }

    // MARK: - Elapsed-time math

    func testElapsedGrowthTickMath() {
        let start = Date(timeIntervalSince1970: 1_000_000)

        // Zero elapsed: nothing grows, clock untouched.
        let idle = planted(.maple, seed: 5)
        let before = idle.snapshot()
        idle.applyElapsedGrowth(now: start)
        XCTAssertEqual(idle.snapshot(), before, "no time passed means no growth")

        // Seven hours -> two ticks (3h each), remainder carried forward.
        let short = planted(.maple, seed: 5)
        short.applyElapsedGrowth(now: start.addingTimeInterval(7 * 3600))
        XCTAssertEqual(short.snapshot().growthTicks, 2)
        XCTAssertEqual(short.snapshot().lastGrowthAt, start.addingTimeInterval(6 * 3600),
                       "the leftover hour carries; only whole ticks advance the clock")

        // A week -> capped at eight ticks, surplus discarded (clock jumps to now).
        let week = planted(.maple, seed: 5)
        let now = start.addingTimeInterval(7 * 24 * 3600)
        week.applyElapsedGrowth(now: now)
        XCTAssertEqual(week.snapshot().growthTicks, GroveTree.maxCatchUpTicks)
        XCTAssertEqual(week.snapshot().lastGrowthAt, now, "surplus beyond the cap is not banked")
    }

    func testGrowthNeverRunsOnAnEmptyPlot() {
        let bare = GroveTree(state: .empty)
        bare.applyElapsedGrowth(now: Date(timeIntervalSince1970: 9_000_000))
        bare.grow(ticks: 20)
        XCTAssertTrue(bare.isEmpty)
        XCTAssertEqual(bare.snapshot().segments.count, 0)
    }

    // MARK: - Composure bounds

    func testGrowthRespectsSegmentDepthAndFrameBoundsOver200Ticks() {
        for species in GroveSpecies.allCases {
            let tree = planted(species, seed: 3)
            tree.grow(ticks: 200)
            let segments = tree.snapshot().segments
            XCTAssertLessThanOrEqual(segments.count, GroveTree.maxSegments,
                                     "\(species) must stay under the segment cap")
            let maxDepth = species.traits.maxDepth
            XCTAssertTrue(segments.allSatisfy { $0.depth <= maxDepth },
                          "\(species) must respect its max depth")
            for layout in tree.layout() {
                XCTAssertGreaterThanOrEqual(layout.end.col, GroveGeometry.minCol - 0.001)
                XCTAssertLessThanOrEqual(layout.end.col, GroveGeometry.maxCol + 0.001)
                XCTAssertGreaterThanOrEqual(layout.end.row, GroveGeometry.minRow - 0.001)
                XCTAssertLessThanOrEqual(layout.end.row, GroveGeometry.maxRow + 0.001)
            }
        }
    }

    func testGrowthActuallyProducesATree() {
        let tree = planted(.maple, seed: 11)
        tree.grow(ticks: 40)
        let segments = tree.snapshot().segments
        XCTAssertGreaterThan(segments.count, 8, "40 ticks should be a recognizable little tree")
        XCTAssertTrue(segments.contains { $0.depth >= 3 }, "it should have grown some height")
    }

    // MARK: - Shaping

    func testPruneRemovesExactlyTheSubtree() {
        let tree = planted(.maple, seed: 8)
        tree.grow(ticks: 40)

        // Find an interior segment with descendants and prune it.
        let segments = tree.snapshot().segments
        let parents = Set(segments.compactMap(\.parentID))
        guard let target = segments.first(where: { parents.contains($0.id) && $0.parentID != nil }) else {
            return XCTFail("expected an interior branch to prune")
        }

        // Compute the true descendant set independently.
        var expected: Set<Int> = [target.id]
        var changed = true
        while changed {
            changed = false
            for seg in segments where seg.parentID.map(expected.contains) == true && !expected.contains(seg.id) {
                expected.insert(seg.id)
                changed = true
            }
        }

        let removed = tree.prune(segmentID: target.id)
        XCTAssertEqual(removed, expected, "prune must remove exactly the subtree")

        let remaining = Set(tree.snapshot().segments.map(\.id))
        XCTAssertTrue(remaining.isDisjoint(with: expected))
        XCTAssertTrue(tree.snapshot().segments.contains { $0.id == target.parentID },
                      "the parent stub survives the cut")
    }

    func testPruningBackToTheTrunkLetsItRegrow() {
        let tree = planted(.pine, seed: 4)
        tree.grow(ticks: 30)
        // Prune everything above the trunk root.
        for seg in tree.snapshot().segments where seg.parentID == 0 {
            tree.prune(segmentID: seg.id)
        }
        let countAfterPrune = tree.snapshot().segments.count
        tree.grow(ticks: 20)
        XCTAssertGreaterThan(tree.snapshot().segments.count, countAfterPrune,
                             "the trunk stub is alive and grows around the cut")
    }

    func testTrainingClampsAtItsLimits() {
        let tree = planted(.willow, seed: 6)
        tree.grow(ticks: 20)
        guard let id = tree.selectableSegmentIDs().first else { return XCTFail("nothing to train") }

        for _ in 0..<20 { tree.train(segmentID: id, direction: 1) }
        let high = tree.snapshot().segments.first { $0.id == id }?.trainOffset
        XCTAssertEqual(high, GroveTree.trainLimit, "training clamps at the positive limit")

        for _ in 0..<40 { tree.train(segmentID: id, direction: -1) }
        let low = tree.snapshot().segments.first { $0.id == id }?.trainOffset
        XCTAssertEqual(low, -GroveTree.trainLimit, "training clamps at the negative limit")
    }

    func testTrainingRotatesTheWholeSubtree() {
        let tree = planted(.maple, seed: 8)
        tree.grow(ticks: 40)
        // Pick an interior joint that carries a subtree.
        let parents = Set(tree.snapshot().segments.compactMap(\.parentID))
        guard let joint = tree.snapshot().segments.first(where: { parents.contains($0.id) }) else {
            return XCTFail("expected a joint")
        }
        let childID = tree.snapshot().segments.first { $0.parentID == joint.id }!.id
        let before = tree.layout().first { $0.id == childID }!.end
        tree.train(segmentID: joint.id, direction: 1)
        tree.train(segmentID: joint.id, direction: 1)
        let after = tree.layout().first { $0.id == childID }!.end
        XCTAssertNotEqual(before, after, "bending a joint swings the branches hanging off it")
    }

    // MARK: - Selection

    func testSelectionCyclesOverLivingTipsAndTheirParents() {
        let tree = planted(.maple, seed: 8)
        tree.grow(ticks: 40)
        let ids = tree.selectableSegmentIDs()
        XCTAssertFalse(ids.isEmpty)

        let childCount = Dictionary(grouping: tree.snapshot().segments.compactMap(\.parentID)) { $0 }
            .mapValues(\.count)
        let livingTips = tree.snapshot().segments.filter { $0.alive && (childCount[$0.id] ?? 0) == 0 }
        for tip in livingTips {
            XCTAssertTrue(ids.contains(tip.id), "living tips are selectable")
            if let parent = tip.parentID {
                XCTAssertTrue(ids.contains(parent), "their parent joints are selectable")
            }
        }
    }

    // MARK: - Persistence

    func testStateRoundTripsThroughCodable() throws {
        let tree = planted(.willow, seed: 21)
        tree.grow(ticks: 55)
        if let id = tree.selectableSegmentIDs().first {
            tree.selectedSegmentID = id
            tree.train(segmentID: id, direction: 1)
        }
        let snapshot = tree.snapshot()
        let decoded = try JSONDecoder().decode(GroveState.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(GroveTree(state: decoded).snapshot(), snapshot,
                       "restoring and re-snapshotting is lossless")
    }
}

@MainActor
final class GroveRasterizerTests: XCTestCase {
    private func grown(_ species: GroveSpecies, seed: UInt64, ticks: Int) -> GroveTree {
        let tree = GroveTree(state: .empty)
        tree.plant(species: species, seed: seed, now: Date(timeIntervalSince1970: 1_000_000))
        tree.grow(ticks: ticks)
        return tree
    }

    func testRenderedCellsStayInsideTheGridAtEveryAge() {
        for species in GroveSpecies.allCases {
            for ticks in [0, 1, 5, 20, 40, 80, 200] {
                let tree = grown(species, seed: 13, ticks: ticks)
                let grid = GroveRasterizer.rasterize(tree, highlightedID: tree.selectedSegmentID)
                XCTAssertEqual(grid.droppedOutOfBounds, 0,
                               "\(species) at \(ticks) ticks placed a cell off-grid")
                XCTAssertEqual(grid.cols, GroveGeometry.cols)
                XCTAssertEqual(grid.rows, GroveGeometry.rows)
            }
        }
    }

    func testEmptyGroveStillRastersEarthOnly() {
        let grid = GroveRasterizer.rasterize(GroveTree(state: .empty))
        XCTAssertEqual(grid.droppedOutOfBounds, 0)
        // No wood, but the ground line is present.
        let hasGround = (0..<grid.cols).contains { grid[$0, Int(GroveGeometry.groundRow.rounded())]?.kind == .ground }
        XCTAssertTrue(hasGround)
    }

    func testSelectionHighlightMarksTheSelectedBranch() {
        let tree = grown(.maple, seed: 8, ticks: 40)
        guard let id = tree.selectableSegmentIDs().first else { return XCTFail("nothing selectable") }
        tree.selectedSegmentID = id
        let grid = GroveRasterizer.rasterize(tree, highlightedID: id)
        let anyHighlighted = grid.cells.compactMap { $0 }.contains { $0.highlighted }
        XCTAssertTrue(anyHighlighted, "the selected branch should light up")
    }

    /// Debug helper kept for eyeballing the silhouette during tuning. Not an
    /// assertion; run with `-Xswiftc -DGROVE_EYEBALL` visible via the log.
    func testPrintSampleTrees() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_EYEBALL"] != nil,
                          "set GROVE_EYEBALL=1 to print sample groves")
        for species in GroveSpecies.allCases {
            let tree = grown(species, seed: 13, ticks: 40)
            print("\n=== \(species.displayName) · 40 ticks · \(tree.snapshot().segments.count) segments ===")
            print(GroveRasterizer.rasterize(tree).text())
        }
    }
}

@MainActor
final class GroveLogTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-tests-\(UUID().uuidString)")
            .appendingPathComponent("grove.md")
    }

    func testPlantingWritesHeaderAndLine() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        GroveLog.recordPlanting(species: .pine, date: date, to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# The Grove"))
        XCTAssertTrue(content.contains("planted a pine"))
        XCTAssertTrue(content.contains(GroveLog.dayStamp(for: date)))
    }

    func testClearingRecordsWhatWasLetGo() {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        GroveLog.recordPlanting(species: .maple, date: date, to: url)
        GroveLog.recordClearing(species: .maple, date: date, to: url)
        let entries = GroveLog.recentEntries(limit: 10, from: url)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].contains("planted a maple"))
        XCTAssertTrue(entries[1].contains("let the maple go"))
    }

    func testRecentEntriesOnMissingFileIsEmpty() {
        XCTAssertEqual(GroveLog.recentEntries(limit: 5, from: temporaryFileURL()), [])
    }
}

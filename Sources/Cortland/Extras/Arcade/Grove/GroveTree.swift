import Foundation

/// Fixed geometry shared by the model (bounds during growth) and the
/// rasterizer (grid size). Angles are degrees measured clockwise from
/// straight up; a segment's direction is `(sin, -cos)` in grid coordinates
/// where row 0 is the top (the view draws flipped).
nonisolated enum GroveGeometry {
    static let cols = 52
    static let rows = 30
    /// Where the trunk emerges from the earth (bottom-center of the grid).
    static let baseCol = 26.0
    static let groundRow = 27.0
    /// Inner box every branch tip must stay inside, leaving a one-cell margin
    /// for foliage so nothing a tip carries ever lands off-grid.
    static let minCol = 4.0
    static let maxCol = 47.0
    static let minRow = 3.0
    static let maxRow = 26.0
}

/// The three moods a grove can be planted in. No species is better than
/// another; they differ only in how they carry themselves as they grow.
nonisolated enum GroveSpecies: String, Codable, CaseIterable, Sendable {
    case pine, maple, willow

    var displayName: String {
        switch self {
        case .pine: return "pine"
        case .maple: return "maple"
        case .willow: return "willow"
        }
    }

    var traits: GroveTraits {
        switch self {
        case .pine:
            // Narrow and layered: a modest trunk, then tight forks that fan
            // just enough to build conical foliage pads instead of a bare pole.
            return GroveTraits(
                forkHalfAngle: 17, jitter: 6, lengthRange: 1.4...1.9,
                maxDepth: 9, trunkDepth: 3,
                forkProb: 0.22, extendProb: 0.62, sproutProb: 0.06,
                driftFactor: -0.10, droop: 0, blossomProb: 0.015
            )
        case .maple:
            // Wide, rounded, generous: broad forks and a gentle outward lean.
            return GroveTraits(
                forkHalfAngle: 29, jitter: 7, lengthRange: 1.7...2.4,
                maxDepth: 9, trunkDepth: 2,
                forkProb: 0.23, extendProb: 0.63, sproutProb: 0.06,
                driftFactor: 0.12, droop: 0, blossomProb: 0.03
            )
        case .willow:
            // A taller trunk that rises before the crown fans out and the tips
            // curl over and hang.
            return GroveTraits(
                forkHalfAngle: 22, jitter: 7, lengthRange: 2.0...2.6,
                maxDepth: 11, trunkDepth: 4,
                forkProb: 0.16, extendProb: 0.70, sproutProb: 0.05,
                driftFactor: 0.22, droop: 8, blossomProb: 0.02
            )
        }
    }
}

/// The knobs that give each species its growth personality. Probabilities are
/// per living tip per tick; `driftFactor` bends each new extension relative to
/// its parent's absolute angle (negative pulls toward vertical, positive fans
/// outward), and `droop` adds a downward pull once a branch has left center.
nonisolated struct GroveTraits: Sendable {
    let forkHalfAngle: Double
    let jitter: Double
    let lengthRange: ClosedRange<Double>
    let maxDepth: Int
    /// Depth below which the trunk only extends (never forks), so every grove
    /// keeps a clean, single trunk before the canopy opens up.
    let trunkDepth: Int
    let forkProb: Double
    let extendProb: Double
    let sproutProb: Double
    let driftFactor: Double
    let droop: Double
    let blossomProb: Double
}

/// One branch segment. Angles are stored *relative to the parent*; the tree's
/// absolute geometry falls out of walking the graph from the trunk. `baseAngle`
/// is what growth chose; `trainOffset` is what the gardener nudged (and it
/// rotates the whole subtree hanging off this joint).
nonisolated struct GroveSegment: Codable, Equatable, Sendable {
    var id: Int
    var parentID: Int?
    var baseAngle: Double
    var trainOffset: Double
    var length: Double
    var depth: Int
    var age: Int
    /// A tip is `alive && childless`. Alive-with-children means an interior
    /// joint that can regrow if the branch above it is pruned away.
    var alive: Bool
    var hasBlossom: Bool
}

/// Everything a grove is, start to finish. A nil `species` is an empty plot
/// waiting for a seed. Serialized verbatim into the arcade state blob.
nonisolated struct GroveState: Codable, Equatable, Sendable {
    var species: GroveSpecies?
    var seed: UInt64
    var plantedAt: Date?
    var lastGrowthAt: Date?
    var growthTicks: Int
    var segments: [GroveSegment]
    var nextSegmentID: Int
    var selectedSegmentID: Int?

    static let empty = GroveState(
        species: nil, seed: 0, plantedAt: nil, lastGrowthAt: nil,
        growthTicks: 0, segments: [], nextSegmentID: 0, selectedSegmentID: nil
    )
}

/// A point on the character grid, in fractional cells.
nonisolated struct GrovePoint: Equatable, Sendable {
    var col: Double
    var row: Double
}

/// A segment resolved into absolute grid geometry, ready to rasterize.
nonisolated struct GroveSegmentLayout: Sendable {
    let id: Int
    let parentID: Int?
    let start: GrovePoint
    let end: GrovePoint
    let absAngle: Double
    let depth: Int
    let isTip: Bool
    let isLivingTip: Bool
    let hasBlossom: Bool
}

/// The bonsai model: a set of branch segments grown by an L-system-flavored
/// rule set driven entirely by `seed`, so the same seed and tick count always
/// reproduce the identical tree. Pure and `nonisolated` so it is directly
/// testable; the view owns all rendering and input.
nonisolated final class GroveTree {
    /// Composure bound: a grove never sprawls past this many segments.
    static let maxSegments = 90
    /// Growth cadence and catch-up policy.
    static let secondsPerTick: TimeInterval = 3 * 60 * 60
    static let maxCatchUpTicks = 8
    /// How far, and in what step, a branch may be trained from its grown angle.
    static let trainLimit = 22.0
    static let trainStep = 4.0

    private(set) var state: GroveState

    init(state: GroveState) {
        self.state = state
    }

    var species: GroveSpecies? { state.species }
    var segments: [GroveSegment] { state.segments }
    var isEmpty: Bool { state.species == nil || state.segments.isEmpty }
    var selectedSegmentID: Int? {
        get { state.selectedSegmentID }
        set { state.selectedSegmentID = newValue }
    }

    func snapshot() -> GroveState { state }

    /// Whole days since planting, for the quiet "planted N days ago" header.
    func daysSincePlanting(now: Date) -> Int {
        guard let plantedAt = state.plantedAt else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: plantedAt, to: now).day ?? 0
        return max(0, days)
    }

    // MARK: - Planting

    /// Turns an empty plot into a fresh sprout: one short trunk segment leaning
    /// a few seeded degrees off vertical for character.
    func plant(species: GroveSpecies, seed: UInt64, now: Date) {
        var rng = SplitMix64(seed: seed)
        let lean = Double.random(in: -7...7, using: &rng)
        let sprout = GroveSegment(
            id: 0, parentID: nil, baseAngle: lean, trainOffset: 0,
            length: 1.5, depth: 0, age: 0, alive: true, hasBlossom: false
        )
        state = GroveState(
            species: species, seed: seed, plantedAt: now, lastGrowthAt: now,
            growthTicks: 0, segments: [sprout], nextSegmentID: 1, selectedSegmentID: 0
        )
    }

    /// Returns the plot to bare earth. The old tree is simply let go.
    func clear() {
        state = .empty
    }

    // MARK: - Growth over real time

    /// Applies whatever growth the elapsed wall-clock has earned. One tick per
    /// three hours, capped at eight per open so a week away is a pleasant jump
    /// rather than an unrecognizable tree. Sub-tick remainders carry forward
    /// (fair to frequent visitors); surplus beyond the cap is discarded, never
    /// banked (banking would reward staying away).
    func applyElapsedGrowth(now: Date) {
        guard state.species != nil, let last = state.lastGrowthAt else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0 else { return }
        let rawTicks = Int(elapsed / Self.secondsPerTick)
        guard rawTicks > 0 else { return }
        let ticks = min(rawTicks, Self.maxCatchUpTicks)
        grow(ticks: ticks)
        if rawTicks > Self.maxCatchUpTicks {
            state.lastGrowthAt = now
        } else {
            state.lastGrowthAt = last.addingTimeInterval(Double(ticks) * Self.secondsPerTick)
        }
    }

    /// Grows exactly `ticks` discrete steps. Deterministic given the seed and
    /// the running tick count, independent of how the ticks are chunked.
    func grow(ticks: Int) {
        guard state.species != nil else { return }
        for _ in 0..<max(0, ticks) {
            growOneTick(index: state.growthTicks)
            state.growthTicks += 1
        }
    }

    private func growOneTick(index: Int) {
        guard let traits = state.species?.traits else { return }
        // A fresh, reproducible stream per tick keyed off the seed and the
        // absolute tick index, so chunked catch-up matches one long grow.
        var rng = SplitMix64(seed: state.seed &+ 0x9E3779B97F4A7C15 &* UInt64(index &+ 1))

        for i in state.segments.indices {
            state.segments[i].age += 1
            state.segments[i].hasBlossom = false
        }

        let layout = layoutByID()
        let childCount = childCounts()

        // Snapshot the living tips up front so growth added this tick doesn't
        // grow again until next tick; ascending id keeps the draw order stable.
        let tips = state.segments
            .filter { $0.alive && (childCount[$0.id] ?? 0) == 0 }
            .map(\.id)
            .sorted()

        for tipID in tips {
            guard let idx = state.segments.firstIndex(where: { $0.id == tipID }) else { continue }
            let tip = state.segments[idx]

            if tip.depth >= traits.maxDepth || state.segments.count >= Self.maxSegments {
                state.segments[idx].alive = false
                continue
            }

            let roll = Double.random(in: 0..<1, using: &rng)
            let canFork = tip.depth >= traits.trunkDepth && state.segments.count + 2 <= Self.maxSegments
            let absAngle = layout[tipID]?.absAngle ?? tip.baseAngle
            let end = layout[tipID]?.end ?? GrovePoint(col: GroveGeometry.baseCol, row: GroveGeometry.groundRow)

            if canFork && roll < traits.forkProb {
                fork(parentIndex: idx, parentEnd: end, parentAbs: absAngle, traits: traits, rng: &rng)
            } else if roll < traits.forkProb + traits.extendProb {
                extend(parentIndex: idx, parentEnd: end, parentAbs: absAngle, traits: traits, rng: &rng)
            } else {
                state.segments[idx].alive = false
            }
        }

        if Double.random(in: 0..<1, using: &rng) < traits.sproutProb {
            sproutLowBranch(traits: traits, layout: layout, childCount: childCount, rng: &rng)
        }
        if Double.random(in: 0..<1, using: &rng) < traits.blossomProb {
            blossomARandomTip(childCount: childCounts(), rng: &rng)
        }
    }

    /// Continues a tip with a single child, bent by species drift plus jitter.
    /// A tip whose next cell would leave the frame simply caps off instead.
    private func extend(parentIndex: Int, parentEnd: GrovePoint, parentAbs: Double, traits: GroveTraits, rng: inout SplitMix64) {
        let parent = state.segments[parentIndex]
        let jitter = Double.random(in: -traits.jitter...traits.jitter, using: &rng)
        let length = Double.random(in: traits.lengthRange, using: &rng)
        let relative = drift(parentAbs: parentAbs, traits: traits) + jitter
        if !addChild(of: parent, relativeAngle: relative, length: length, parentEnd: parentEnd, parentAbs: parentAbs) {
            state.segments[parentIndex].alive = false
        }
    }

    /// Splits a tip into two children at +/- the species fork angle. If neither
    /// child fits the frame, the tip caps off.
    private func fork(parentIndex: Int, parentEnd: GrovePoint, parentAbs: Double, traits: GroveTraits, rng: inout SplitMix64) {
        let parent = state.segments[parentIndex]
        let d = drift(parentAbs: parentAbs, traits: traits) * 0.5
        var placed = false
        for sign in [1.0, -1.0] {
            let jitter = Double.random(in: -traits.jitter...traits.jitter, using: &rng)
            let length = Double.random(in: traits.lengthRange, using: &rng)
            let relative = sign * traits.forkHalfAngle + d + jitter
            if addChild(of: parent, relativeAngle: relative, length: length, parentEnd: parentEnd, parentAbs: parentAbs) {
                placed = true
            }
        }
        if !placed {
            state.segments[parentIndex].alive = false
        }
    }

    /// Occasionally hangs a fresh low branch off an older interior segment, the
    /// gnarled character a bonsai picks up over time.
    private func sproutLowBranch(traits: GroveTraits, layout: [Int: GroveSegmentLayout], childCount: [Int: Int], rng: inout SplitMix64) {
        let candidates = state.segments.filter {
            $0.depth >= 1 && $0.depth <= traits.trunkDepth + 1 && $0.age >= 4
                && state.segments.count + 1 <= Self.maxSegments
        }
        guard !candidates.isEmpty else { return }
        let pick = candidates[Int.random(in: 0..<candidates.count, using: &rng)]
        let sign = Bool.random(using: &rng) ? 1.0 : -1.0
        let jitter = Double.random(in: -traits.jitter...traits.jitter, using: &rng)
        let length = Double.random(in: traits.lengthRange, using: &rng)
        let relative = sign * (traits.forkHalfAngle + 30) + jitter
        guard let geo = layout[pick.id] else { return }
        _ = addChild(of: pick, relativeAngle: relative, length: length, parentEnd: geo.end, parentAbs: geo.absAngle)
    }

    private func blossomARandomTip(childCount: [Int: Int], rng: inout SplitMix64) {
        let tips = state.segments.indices.filter { (childCount[state.segments[$0].id] ?? 0) == 0 }
        guard !tips.isEmpty else { return }
        let idx = tips[Int.random(in: 0..<tips.count, using: &rng)]
        state.segments[idx].hasBlossom = true
    }

    /// Appends a child if its endpoint lands inside the frame; returns whether
    /// it did. New ids only ever grow, keeping parents ordered before children.
    @discardableResult
    private func addChild(of parent: GroveSegment, relativeAngle: Double, length: Double, parentEnd: GrovePoint, parentAbs: Double) -> Bool {
        let childAbs = parentAbs + relativeAngle
        let end = advance(from: parentEnd, angle: childAbs, length: length)
        guard end.col >= GroveGeometry.minCol, end.col <= GroveGeometry.maxCol,
              end.row >= GroveGeometry.minRow, end.row <= GroveGeometry.maxRow else {
            return false
        }
        let child = GroveSegment(
            id: state.nextSegmentID, parentID: parent.id, baseAngle: relativeAngle,
            trainOffset: 0, length: length, depth: parent.depth + 1, age: 0,
            alive: true, hasBlossom: false
        )
        state.segments.append(child)
        state.nextSegmentID += 1
        return true
    }

    private func drift(parentAbs: Double, traits: GroveTraits) -> Double {
        var d = traits.driftFactor * parentAbs
        if traits.droop != 0, parentAbs != 0 {
            d += (parentAbs > 0 ? 1.0 : -1.0) * traits.droop
        }
        return d
    }

    // MARK: - Shaping

    /// Removes the selected segment and everything hanging off it. Harmless and
    /// permanent: the parent joint is left behind as a stub the tree may later
    /// grow around. Returns the ids removed.
    @discardableResult
    func prune(segmentID: Int) -> Set<Int> {
        guard state.segments.contains(where: { $0.id == segmentID }) else { return [] }
        let children = childrenByParent()
        var doomed: Set<Int> = []
        var stack = [segmentID]
        while let id = stack.popLast() {
            guard doomed.insert(id).inserted else { continue }
            stack.append(contentsOf: children[id] ?? [])
        }
        state.segments.removeAll { doomed.contains($0.id) }
        if let selected = state.selectedSegmentID, doomed.contains(selected) {
            state.selectedSegmentID = nil
        }
        return doomed
    }

    /// Nudges the selected branch's angle a few degrees, clamped to a gentle
    /// range around its grown angle. `direction` is -1 or +1.
    func train(segmentID: Int, direction: Double) {
        guard let idx = state.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let proposed = state.segments[idx].trainOffset + direction * Self.trainStep
        state.segments[idx].trainOffset = min(Self.trainLimit, max(-Self.trainLimit, proposed))
    }

    // MARK: - Selection

    /// Selectable branches are the living tips and the joints they hang from,
    /// ordered left to right so the arrow keys sweep across the canopy.
    func selectableSegmentIDs() -> [Int] {
        let layout = layoutByID()
        let childCount = childCounts()
        let tips = state.segments.filter { $0.alive && (childCount[$0.id] ?? 0) == 0 }
        var ids = Set(tips.map(\.id))
        for tip in tips {
            if let parent = tip.parentID { ids.insert(parent) }
        }
        return ids.sorted { a, b in
            let pa = layout[a]?.end ?? GrovePoint(col: 0, row: 0)
            let pb = layout[b]?.end ?? GrovePoint(col: 0, row: 0)
            if pa.col != pb.col { return pa.col < pb.col }
            return pa.row < pb.row
        }
    }

    // MARK: - Layout

    /// Resolves every segment into absolute grid geometry. Segments are walked
    /// in id order; a parent is always resolved before its children.
    func layout() -> [GroveSegmentLayout] {
        let byID = layoutByID()
        return state.segments.map { byID[$0.id]! }
    }

    private func layoutByID() -> [Int: GroveSegmentLayout] {
        let childCount = childCounts()
        var abs: [Int: Double] = [:]
        var ends: [Int: GrovePoint] = [:]
        var result: [Int: GroveSegmentLayout] = [:]
        let base = GrovePoint(col: GroveGeometry.baseCol, row: GroveGeometry.groundRow)

        for seg in state.segments.sorted(by: { $0.id < $1.id }) {
            let start: GrovePoint
            let parentAbs: Double
            if let pid = seg.parentID, let pEnd = ends[pid] {
                start = pEnd
                parentAbs = abs[pid] ?? 0
            } else {
                start = base
                parentAbs = 0
            }
            let absAngle = parentAbs + seg.baseAngle + seg.trainOffset
            let end = advance(from: start, angle: absAngle, length: seg.length)
            abs[seg.id] = absAngle
            ends[seg.id] = end
            let childless = (childCount[seg.id] ?? 0) == 0
            result[seg.id] = GroveSegmentLayout(
                id: seg.id, parentID: seg.parentID, start: start, end: end,
                absAngle: absAngle, depth: seg.depth, isTip: childless,
                isLivingTip: childless && seg.alive, hasBlossom: seg.hasBlossom
            )
        }
        return result
    }

    private func advance(from point: GrovePoint, angle: Double, length: Double) -> GrovePoint {
        let radians = angle * .pi / 180
        return GrovePoint(
            col: point.col + sin(radians) * length,
            row: point.row - cos(radians) * length
        )
    }

    private func childCounts() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for seg in state.segments {
            if let pid = seg.parentID { counts[pid, default: 0] += 1 }
        }
        return counts
    }

    private func childrenByParent() -> [Int: [Int]] {
        var map: [Int: [Int]] = [:]
        for seg in state.segments {
            if let pid = seg.parentID { map[pid, default: []].append(seg.id) }
        }
        return map
    }
}

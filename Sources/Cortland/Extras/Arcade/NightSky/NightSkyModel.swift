import Foundation

/// A shape someone noticed and named. The path is star indices in the order
/// they were linked, so a repeated index closes a loop rather than breaking
/// anything, and the segments are simply the steps between them.
nonisolated struct NightSkyConstellation: Codable, Equatable, Sendable {
    var name: String
    var path: [Int]
}

/// One link between two stars.
nonisolated struct NightSkySegment: Equatable, Sendable {
    var from: Int
    var to: Int
}

/// Everything Night Sky keeps. The almanac file is the real record; this holds
/// only what tonight needs to be tonight again after a hide or a relaunch.
/// Constellations older than tonight are not in here, on purpose: they belong
/// to skies that are gone, and to the user's file.
nonisolated struct NightSkyState: Codable, Equatable, Sendable {
    var version: Int
    /// Stable per install. Every sky is drawn from it and a date, so this
    /// install's skies are its own.
    var skySeed: UInt64
    var dateStamp: String
    /// The unnamed shape in progress, star indices in link order.
    var drawing: [Int]
    /// Tonight's named shapes, so they render settled on reopening tonight.
    var named: [NightSkyConstellation]

    init(version: Int = 1, skySeed: UInt64, dateStamp: String, drawing: [Int] = [], named: [NightSkyConstellation] = []) {
        self.version = version
        self.skySeed = skySeed
        self.dateStamp = dateStamp
        self.drawing = drawing
        self.named = named
    }
}

/// The sky and what has been drawn on it: pure, `nonisolated`, deterministic
/// given a seed and a date. It owns linking and naming; the view owns the
/// stars' light and the almanac file.
nonisolated final class NightSkyModel {
    private(set) var state: NightSkyState
    private(set) var stars: [NightSkyStar]

    init(state: NightSkyState) {
        self.state = state
        stars = NightSkyField.stars(seed: state.skySeed, dateStamp: state.dateStamp)
        // A blob from another sky (or another version) could point at stars
        // that are not there. Drop those rather than carry a dangling link.
        self.state.drawing = self.state.drawing.filter { stars.indices.contains($0) }
        self.state.named = self.state.named.filter { constellation in
            constellation.path.allSatisfy { stars.indices.contains($0) }
        }
    }

    convenience init(seed: UInt64, dateStamp: String) {
        self.init(state: NightSkyModel.freshState(seed: seed, dateStamp: dateStamp))
    }

    static func freshState(seed: UInt64, dateStamp: String) -> NightSkyState {
        NightSkyState(skySeed: seed, dateStamp: dateStamp)
    }

    func snapshot() -> NightSkyState { state }

    var dateStamp: String { state.dateStamp }
    var path: [Int] { state.drawing }
    var named: [NightSkyConstellation] { state.named }
    var lastLinked: Int? { state.drawing.last }

    /// A shape is nameable once it has at least one link. A single star is not
    /// a shape yet, and naming nothing is not an error, just nothing.
    var canName: Bool { state.drawing.count >= 2 }

    static func segments(of path: [Int]) -> [NightSkySegment] {
        zip(path, path.dropFirst()).map { NightSkySegment(from: $0, to: $1) }
    }

    var segments: [NightSkySegment] { Self.segments(of: state.drawing) }

    // MARK: - The night turning over

    /// Deals a new night when the date has changed. Tonight's named shapes stay
    /// in the almanac and leave the sky; an unfinished unnamed shape is let go
    /// without comment, because the sky it was drawn on is gone. Nothing is
    /// counted and nothing is missed.
    @discardableResult
    func rollOver(to dateStamp: String) -> Bool {
        guard dateStamp != state.dateStamp else { return false }
        state.dateStamp = dateStamp
        state.drawing = []
        state.named = []
        stars = NightSkyField.stars(seed: state.skySeed, dateStamp: dateStamp)
        return true
    }

    // MARK: - Drawing

    /// Links a star onto the shape. Clicking a star already in the shape is
    /// fine and closes a loop; only linking a star to itself is nothing, since
    /// that is a segment of no length.
    @discardableResult
    func link(_ index: Int) -> Bool {
        guard stars.indices.contains(index), state.drawing.last != index else { return false }
        state.drawing.append(index)
        return true
    }

    /// Takes back the most recent link. The only undo there is, and the only
    /// one wanted.
    @discardableResult
    func unlink() -> Bool {
        guard !state.drawing.isEmpty else { return false }
        state.drawing.removeLast()
        return true
    }

    /// Names the shape and settles it onto tonight's sky, handing back what to
    /// write into the almanac. An empty name or a shape with nothing linked is
    /// a quiet no: nothing is written and the shape stays exactly as it was.
    func name(_ raw: String) -> NightSkyConstellation? {
        let name = Self.cleanName(raw)
        guard !name.isEmpty, canName else { return nil }
        let constellation = NightSkyConstellation(name: name, path: state.drawing)
        state.named.append(constellation)
        state.drawing = []
        return constellation
    }

    /// One line, whatever was typed: the name becomes a markdown heading in a
    /// file the user reads, so it cannot carry newlines or run off the page.
    static func cleanName(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(48))
    }

    // MARK: - Finding a star

    /// The mouse's whole hit test: the nearest star to a point, if one is close
    /// enough to have been meant.
    func star(nearX x: Double, y: Double, within radius: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, star) in stars.enumerated() {
            let distance = hypot(star.x - x, star.y - y)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    func star(from origin: Int, towardX dx: Double, y dy: Double) -> Int? {
        Self.star(from: origin, towardX: dx, y: dy, in: stars)
    }

    /// The keyboard's whole navigation: the nearest star lying roughly the way
    /// the arrow points. A quarter of the sky is plenty of cone, and closest
    /// wins inside it.
    static func star(from origin: Int, towardX dx: Double, y dy: Double, in stars: [NightSkyStar]) -> Int? {
        guard stars.indices.contains(origin) else { return nil }
        let from = stars[origin]

        var best: (index: Int, distance: Double)?
        for (index, star) in stars.enumerated() where index != origin {
            let vx = star.x - from.x
            let vy = star.y - from.y
            let distance = hypot(vx, vy)
            guard distance > 0, (vx * dx + vy * dy) / distance > 0.7071 else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Where a soft highlight starts: the star nearest the middle of the sky.
    var centermostStar: Int? {
        stars.indices.min { hypot(stars[$0].x - 0.5, stars[$0].y - 0.5) < hypot(stars[$1].x - 0.5, stars[$1].y - 0.5) }
    }
}

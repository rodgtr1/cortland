import Foundation

/// The hidden world under one map sheet: a fixed grid of land and sea with a
/// coarse elevation over the land, generated from a seed via layered value
/// noise. Pure and `nonisolated`, so the same seed always yields the same
/// coastline (tests depend on it). The world exists whole from the first
/// moment; the model only decides how much of it has been drawn.
nonisolated struct CartographyWorld: Equatable, Sendable {
    static let width = 64
    static let height = 36
    static let cellCount = width * height

    /// Elevation bands over land. Sea cells carry `.sea`.
    enum Ground: Int, Codable, Sendable {
        case sea = -1
        case lowland = 0
        case upland = 1
        case hill = 2
    }

    /// The seed the sheet was opened with. The actual noise runs on a derived
    /// seed chosen so the sheet is interesting, but this identifies the world.
    let seed: UInt64
    let land: [Bool]
    let ground: [Ground]

    init(seed: UInt64) {
        self.seed = seed
        // Try derived seeds until the roll is interesting: a real mix of land
        // and sea, neither a dull all-water nor an all-earth sheet. A base
        // seed always produces the same sequence, so the search is deterministic.
        var picker = SplitMix64(seed: seed)
        var resolved: UInt64 = seed
        var resolvedLand = Self.generateLand(seed: seed)
        for _ in 0..<128 {
            let candidate = picker.next()
            let candidateLand = Self.generateLand(seed: candidate)
            resolved = candidate
            resolvedLand = candidateLand
            if Self.isInteresting(candidateLand) { break }
        }
        land = resolvedLand
        ground = Self.generateGround(seed: resolved, land: resolvedLand)
    }

    static func index(_ x: Int, _ y: Int) -> Int { y * width + x }
    static func inBounds(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < width && y >= 0 && y < height }

    func isLand(_ x: Int, _ y: Int) -> Bool { land[Self.index(x, y)] }
    func groundAt(_ x: Int, _ y: Int) -> Ground { ground[Self.index(x, y)] }

    var landFraction: Double {
        Double(land.lazy.filter { $0 }.count) / Double(Self.cellCount)
    }

    // MARK: - Interestingness

    /// A sheet is worth keeping when a solid quarter-to-half of it is land and
    /// both land and sea reach into the interior (not just clip a border), so
    /// there is a real coastline to uncover.
    static func isInteresting(_ land: [Bool]) -> Bool {
        let landCount = land.lazy.filter { $0 }.count
        let fraction = Double(landCount) / Double(cellCount)
        guard fraction >= 0.25, fraction <= 0.55 else { return false }

        var interiorLand = false
        var interiorSea = false
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                if land[index(x, y)] { interiorLand = true } else { interiorSea = true }
                if interiorLand && interiorSea { return true }
            }
        }
        return interiorLand && interiorSea
    }

    // MARK: - Noise

    private static let landThreshold = 0.5

    private static func generateLand(seed: UInt64) -> [Bool] {
        var grid = [Bool](repeating: false, count: cellCount)
        for y in 0..<height {
            for x in 0..<width {
                let n = fractalNoise(seed: seed, x: Double(x), y: Double(y),
                                     periods: [18, 9, 4.5], amplitudes: [1.0, 0.5, 0.25])
                grid[index(x, y)] = n > landThreshold
            }
        }
        return grid
    }

    private static func generateGround(seed: UInt64, land: [Bool]) -> [Ground] {
        var grid = [Ground](repeating: .sea, count: cellCount)
        let elevationSeed = seed ^ 0x5DEECE66D
        for y in 0..<height {
            for x in 0..<width {
                let i = index(x, y)
                guard land[i] else { continue }
                let e = fractalNoise(seed: elevationSeed, x: Double(x), y: Double(y),
                                     periods: [12, 6], amplitudes: [1.0, 0.5])
                grid[i] = e < 0.52 ? .lowland : (e < 0.8 ? .upland : .hill)
            }
        }
        return grid
    }

    /// Sum of a few octaves of value noise, normalized to roughly [0, 1].
    private static func fractalNoise(seed: UInt64, x: Double, y: Double, periods: [Double], amplitudes: [Double]) -> Double {
        var total = 0.0
        var norm = 0.0
        for octave in periods.indices {
            let octaveSeed = seed &+ 0x9E3779B97F4A7C15 &* UInt64(octave + 1)
            total += amplitudes[octave] * valueNoise(seed: octaveSeed, x: x / periods[octave], y: y / periods[octave])
            norm += amplitudes[octave]
        }
        return total / norm
    }

    /// Smoothly interpolated lattice noise: random values at integer lattice
    /// points, blended with a smoothstep so the field undulates instead of
    /// jumping.
    private static func valueNoise(seed: UInt64, x: Double, y: Double) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let tx = smoothstep(x - Double(x0))
        let ty = smoothstep(y - Double(y0))
        let v00 = lattice(seed, x0, y0)
        let v10 = lattice(seed, x0 + 1, y0)
        let v01 = lattice(seed, x0, y0 + 1)
        let v11 = lattice(seed, x0 + 1, y0 + 1)
        let top = v00 + (v10 - v00) * tx
        let bottom = v01 + (v11 - v01) * tx
        return top + (bottom - top) * ty
    }

    private static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    private static func lattice(_ seed: UInt64, _ ix: Int, _ iy: Int) -> Double {
        var h = seed
        h ^= UInt64(bitPattern: Int64(ix)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(iy)) &* 0xC2B2AE3D27D4EB4F
        var rng = SplitMix64(seed: h)
        // Top 53 bits to a double in [0, 1).
        return Double(rng.next() >> 11) * (1.0 / 9007199254740992.0)
    }
}

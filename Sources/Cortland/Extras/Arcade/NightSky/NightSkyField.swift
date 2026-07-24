import Foundation

/// One invented star. Coordinates live in a unit square with y increasing
/// downward, so the view maps them straight into its flipped sky rect and the
/// almanac maps them straight into character cells, with no axis to flip in
/// between.
nonisolated struct NightSkyStar: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    /// 0 faint, 1 middling, 2 bright. Cosmetic only: a bright star is not
    /// worth more than a faint one and links exactly the same, it is just
    /// easier to see.
    var brightness: Int
}

/// Tonight's sky. Invented rather than surveyed: there are no real stars here
/// and no right constellation to find in them.
nonisolated enum NightSkyField {
    /// No star is dealt closer than this to one already placed, so the sky
    /// scatters instead of clumping and every star stays its own thing to
    /// click. Also the floor the almanac's sketch leans on to keep two stars
    /// off the same character cell.
    static let minimumSpacing: Double = 0.062
    static let countRange = 45...70
    /// Stars keep off the very edge, where the sky meets its frame.
    static let inset: Double = 0.04
    /// Dart throwing saturates far above 70 stars at this spacing; the budget
    /// is a backstop for a pathological seed, not a working limit.
    private static let maximumAttempts = 20_000

    /// The sky for one evening, seeded from the install seed and the date
    /// stamp together: reopening tonight deals the same stars, and tomorrow
    /// deals a different sky. Nothing about it is stored, so it costs nothing
    /// to let a night go.
    static func stars(seed: UInt64, dateStamp: String) -> [NightSkyStar] {
        var rng = SplitMix64(seed: skySeed(seed: seed, dateStamp: dateStamp))
        let target = Int.random(in: countRange, using: &rng)

        var stars: [NightSkyStar] = []
        var attempts = 0
        while stars.count < target, attempts < maximumAttempts {
            attempts += 1
            let x = Double.random(in: inset...(1 - inset), using: &rng)
            let y = Double.random(in: inset...(1 - inset), using: &rng)
            guard stars.allSatisfy({ hypot($0.x - x, $0.y - y) >= minimumSpacing }) else { continue }
            stars.append(NightSkyStar(x: x, y: y, brightness: brightness(using: &rng)))
        }
        return stars
    }

    /// FNV-1a over the date stamp rather than `Hasher`: Swift's hashing is
    /// seeded per process, and tonight's sky has to be the same sky after a
    /// relaunch.
    static func skySeed(seed: UInt64, dateStamp: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in dateStamp.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        var rng = SplitMix64(seed: seed ^ hash)
        return rng.next()
    }

    /// Most stars are faint, a few carry the eye, and a bright one is a small
    /// event. Purely how it looks.
    private static func brightness(using rng: inout SplitMix64) -> Int {
        switch Double.random(in: 0..<1, using: &rng) {
        case ..<0.55: return 0
        case ..<0.87: return 1
        default: return 2
        }
    }
}

/// A streak across the sky, now and then. Never stored and never announced: a
/// shooting star missed is nothing at all, which is the point of it.
nonisolated struct NightSkyStreak: Equatable, Sendable {
    var startX: Double
    var startY: Double
    var endX: Double
    var endY: Double
}

nonisolated enum NightSkyStreaks {
    /// Rolled every few seconds while the panel is open, so one turns up every
    /// minute or so of watching and never on a schedule anyone could wait for.
    static let chance = 0.05

    static func rolls(using rng: inout SplitMix64) -> Bool {
        Double.random(in: 0..<1, using: &rng) < chance
    }

    /// Falls from somewhere in the upper sky, down and across.
    static func streak(using rng: inout SplitMix64) -> NightSkyStreak {
        let startX = Double.random(in: 0.05...0.95, using: &rng)
        let startY = Double.random(in: 0.05...0.55, using: &rng)
        let angle = Double.random(in: 0.35...1.2, using: &rng)
        let length = Double.random(in: 0.18...0.34, using: &rng)
        let direction: Double = Bool.random(using: &rng) ? 1 : -1
        return NightSkyStreak(
            startX: startX,
            startY: startY,
            endX: startX + cos(angle) * length * direction,
            endY: startY + sin(angle) * length
        )
    }
}

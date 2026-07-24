import Foundation

/// How long the line has been out, in bands. The pool only widens: every band
/// still contains every shallower tier, so a three-day wait can land a minnow.
/// There is no band you can miss and none that closes behind you.
nonisolated enum PondBand: Int, CaseIterable, Sendable {
    case brief   // under 2 minutes
    case short   // 2 to 15 minutes
    case medium  // 15 to 90 minutes
    case long    // 90 minutes to 12 hours
    case vigil   // over 12 hours

    static func forElapsed(_ elapsed: TimeInterval) -> PondBand {
        switch max(0, elapsed) {
        case ..<120: return .brief
        case ..<900: return .short
        case ..<5400: return .medium
        case ..<43200: return .long
        default: return .vigil
        }
    }

    var deepestTier: PondTier {
        PondTier(rawValue: rawValue) ?? .strange
    }

    /// Relative likelihood per tier, shallowest first. The deep tiers never
    /// crowd the common ones out entirely; they just stop being surprising.
    var tierWeights: [Double] {
        switch self {
        case .brief: return [1.0]
        case .short: return [0.72, 0.28]
        case .medium: return [0.45, 0.33, 0.22]
        case .long: return [0.28, 0.27, 0.27, 0.18]
        case .vigil: return [0.15, 0.20, 0.25, 0.25, 0.15]
        }
    }
}

/// Where the bobber rides. The only hint the pond ever gives that time has
/// passed: no numbers, no bar, no "ready at".
nonisolated enum PondBobberStage: Int, CaseIterable, Sendable {
    case high, settled, low, deep

    static func forElapsed(_ elapsed: TimeInterval) -> PondBobberStage {
        switch max(0, elapsed) {
        case ..<120: return .high
        case ..<900: return .settled
        case ..<5400: return .low
        default: return .deep
        }
    }
}

/// One thing brought up, decided entirely at reel-in. Nothing about it existed
/// while the line was out, so nothing about it could have been missed.
nonisolated struct PondCatch: Codable, Equatable, Sendable {
    let speciesID: String
    let name: String
    let flavor: String
    let size: String
    let tier: PondTier
    let elapsed: TimeInterval
    /// True the first time this species has ever been caught on this pond.
    let isFirst: Bool
}

/// Everything the pond remembers. The almanac file is the real record; this
/// only holds what the pond itself needs to be the same pond tomorrow.
nonisolated struct PondState: Codable, Equatable, Sendable {
    var version: Int
    /// Stable per install: shapes the shoreline silhouette, nothing else.
    var pondSeed: UInt64
    var castDate: Date?
    var castSeed: UInt64?
    var speciesFound: Set<String>
    var catches: Int

    init(version: Int = 1, pondSeed: UInt64, castDate: Date? = nil, castSeed: UInt64? = nil,
         speciesFound: Set<String> = [], catches: Int = 0) {
        self.version = version
        self.pondSeed = pondSeed
        self.castDate = castDate
        self.castSeed = castSeed
        self.speciesFound = speciesFound
        self.catches = catches
    }
}

/// The pond: pure, `nonisolated`, and deterministic given its inputs. It owns
/// casting, reeling, and the catch roll; the view owns the water and the
/// almanac file.
///
/// Future hook: an agent run finishing elsewhere in Cortland could nudge the
/// bobber here. Deliberately not wired in v1; it needs code outside this
/// directory, and the pond must never become something you have to check on.
nonisolated final class PondModel {
    private(set) var state: PondState

    init(state: PondState) {
        self.state = state
    }

    convenience init(seed: UInt64) {
        self.init(state: PondModel.freshState(seed: seed))
    }

    static func freshState(seed: UInt64) -> PondState {
        PondState(pondSeed: seed)
    }

    func snapshot() -> PondState { state }

    var isLineOut: Bool { state.castDate != nil }
    var distinctSpecies: Int { state.speciesFound.count }
    var totalCatches: Int { state.catches }
    var pondSeed: UInt64 { state.pondSeed }

    /// Elapsed never goes negative: a clock that moved backwards while the
    /// line was out costs the player nothing.
    func elapsed(now: Date) -> TimeInterval? {
        state.castDate.map { max(0, now.timeIntervalSince($0)) }
    }

    func bobberStage(now: Date) -> PondBobberStage? {
        elapsed(now: now).map(PondBobberStage.forElapsed)
    }

    // MARK: - The two actions

    /// Casts, if there is no line out already. Only the seed and the moment
    /// are kept; nothing is decided here.
    @discardableResult
    func cast(now: Date, seed: UInt64) -> Bool {
        guard !isLineOut else { return false }
        state.castDate = now
        state.castSeed = seed
        return true
    }

    /// Reels in. Always lands something. Returns nil only when there was no
    /// line out to begin with.
    func reelIn(now: Date, calendar: Calendar = .current) -> PondCatch? {
        guard let castDate = state.castDate else { return nil }
        let seed = state.castSeed ?? state.pondSeed
        let elapsed = max(0, now.timeIntervalSince(castDate))

        let species = Self.roll(castSeed: seed, elapsed: elapsed, now: now, calendar: calendar)
        var rng = SplitMix64(seed: Self.rollSeed(castSeed: seed, elapsed: elapsed, now: now) &+ 1)
        let size = species.sizes[Int.random(in: 0..<species.sizes.count, using: &rng)]

        let isFirst = !state.speciesFound.contains(species.id)
        state.speciesFound.insert(species.id)
        state.catches += 1
        state.castDate = nil
        state.castSeed = nil

        return PondCatch(speciesID: species.id, name: species.name, flavor: species.flavor,
                         size: size, tier: species.tier, elapsed: elapsed, isFirst: isFirst)
    }

    // MARK: - The catch roll

    /// Seeded from the cast seed, the elapsed duration, and the moment of
    /// reel-in, all injectable. Nothing was rolled while the line sat out.
    static func rollSeed(castSeed: UInt64, elapsed: TimeInterval, now: Date) -> UInt64 {
        let seconds = UInt64(max(0, elapsed.rounded(.down)))
        let stamp = UInt64(bitPattern: Int64(now.timeIntervalSince1970.rounded(.down)))
        let bucket = (seconds &* 0x9E3779B97F4A7C15) ^ (stamp &* 0xBF58476D1CE4E5B9)
        return castSeed ^ bucket
    }

    static func roll(castSeed: UInt64, elapsed: TimeInterval, now: Date, calendar: Calendar = .current) -> PondSpecies {
        var rng = SplitMix64(seed: rollSeed(castSeed: castSeed, elapsed: elapsed, now: now))
        let band = PondBand.forElapsed(elapsed)
        let time = PondTimeOfDay.at(now, calendar: calendar)
        let tier = rollTier(band: band, rng: &rng)
        return pick(tier: tier, time: time, rng: &rng)
    }

    private static func rollTier(band: PondBand, rng: inout SplitMix64) -> PondTier {
        let weights = band.tierWeights
        var roll = Double.random(in: 0..<weights.reduce(0, +), using: &rng)
        for (index, weight) in weights.enumerated() {
            roll -= weight
            if roll < 0 { return PondTier(rawValue: index) ?? .common }
        }
        return band.deepestTier
    }

    /// Picks within a tier, honoring the hour. If an hour happens to gate a
    /// whole tier out (it cannot today, and a test holds that), fall back to
    /// shallower water rather than to nothing: every reel-in lands something.
    private static func pick(tier: PondTier, time: PondTimeOfDay, rng: inout SplitMix64) -> PondSpecies {
        for rawValue in stride(from: tier.rawValue, through: 0, by: -1) {
            guard let candidateTier = PondTier(rawValue: rawValue) else { continue }
            let candidates = PondCatalog.species(in: candidateTier).filter { $0.fits(time) }
            guard !candidates.isEmpty else { continue }
            return candidates[Int.random(in: 0..<candidates.count, using: &rng)]
        }
        return PondCatalog.species[0]
    }

    // MARK: - Place-markers

    /// A quiet marker for how long the line was out, for the almanac line.
    /// Never a target, never compared to anything.
    static func durationPhrase(_ elapsed: TimeInterval) -> String {
        let seconds = Int(max(0, elapsed).rounded())
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 172_800 { return "\(seconds / 3600) h" }
        return "\(seconds / 86_400) d"
    }
}

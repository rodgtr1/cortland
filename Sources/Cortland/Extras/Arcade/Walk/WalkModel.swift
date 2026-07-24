import Foundation

/// One rendered step, kept in the state blob so reopening shows the walk
/// exactly as it was left. `finding` is nil on most steps.
nonisolated struct WalkLine: Codable, Equatable, Sendable {
    var step: Int
    var text: String
    var finding: String?
}

/// Everything a walk is. All of it is derived deterministically from `seed`
/// and the step index, but the evolving Markov state and memory windows live
/// here too so a walk can be paused and resumed to the exact same footfall.
nonisolated struct WalkState: Codable, Equatable, Sendable {
    var seed: UInt64
    var step: Int
    var biome: WalkBiome
    var biomeStepsRemaining: Int
    var weather: WalkWeather
    var weatherStepsRemaining: Int
    /// Whether the current biome's "entered" line has already been journaled.
    var journaledBiomeEntry: Bool
    /// Globally-unique template ids recently used (biomeIndex * 100 + local),
    /// newest last. Bounds anti-repetition.
    var recentTemplateIDs: [Int]
    /// Indices into `WalkContent.findings` recently seen, newest last.
    var recentFindingIDs: [Int]
    var lastFindingStep: Int
    /// The last weather or connective sentence appended, so it is never used
    /// twice in a row.
    var lastExtra: String
    /// The last several rendered lines, newest last.
    var lines: [WalkLine]
}

/// What a single step produced, handed back to the view: the text to show, the
/// finding to log (if any), whether this step crossed into a new biome (so the
/// view can write the journal's "entered" line), and the place-markers.
nonisolated struct WalkStep: Sendable {
    let step: Int
    let biome: WalkBiome
    let weather: WalkWeather
    let text: String
    let finding: String?
    let enteredBiome: Bool
    /// The chosen template's global id, exposed for the anti-repetition test.
    let templateID: Int
}

/// The walk itself: a pure, `nonisolated`, deterministic generator. The view
/// owns rendering, input, and the journal file; this owns only the words and
/// the state that produces them.
nonisolated final class WalkModel {
    static let biomeDurationRange = 8...20
    static let weatherDurationRange = 10...25
    static let findingProbability = 0.11
    static let minFindingGap = 4
    static let templateWindow = 25
    static let findingMemory = 24
    static let maxVisibleLines = 8

    private(set) var state: WalkState

    init(state: WalkState) {
        self.state = state
    }

    /// A fresh walk: a starting place and sky chosen from the seed, no steps
    /// taken yet. Opening the panel on this shows an invitation, not a demand.
    convenience init(seed: UInt64) {
        self.init(state: WalkModel.freshState(seed: seed))
    }

    static func freshState(seed: UInt64) -> WalkState {
        var rng = SplitMix64(seed: seed)
        let biomes = WalkBiome.allCases
        let weathers = WalkWeather.allCases
        let biome = biomes[Int.random(in: 0..<biomes.count, using: &rng)]
        let weather = weathers[Int.random(in: 0..<weathers.count, using: &rng)]
        return WalkState(
            seed: seed,
            step: 0,
            biome: biome,
            biomeStepsRemaining: Int.random(in: biomeDurationRange, using: &rng),
            weather: weather,
            weatherStepsRemaining: Int.random(in: weatherDurationRange, using: &rng),
            journaledBiomeEntry: false,
            recentTemplateIDs: [],
            recentFindingIDs: [],
            lastFindingStep: 0,
            lastExtra: "",
            lines: []
        )
    }

    func snapshot() -> WalkState { state }

    var biome: WalkBiome { state.biome }
    var weather: WalkWeather { state.weather }
    var currentStep: Int { state.step }
    var lines: [WalkLine] { state.lines }
    var hasStarted: Bool { !state.lines.isEmpty }

    // MARK: - Stepping

    /// Takes one step: advances biome and weather along their Markov chains,
    /// perhaps turns up a finding, assembles the description, and records it.
    /// Every draw comes from a per-step RNG keyed off the seed and step index,
    /// so the whole walk replays identically from any snapshot.
    @discardableResult
    func step() -> WalkStep {
        state.step += 1
        var rng = Self.stepRNG(seed: state.seed, step: state.step)

        advanceBiome(&rng)
        advanceWeather(&rng)

        let entered = !state.journaledBiomeEntry
        state.journaledBiomeEntry = true

        let finding = resolveFinding(&rng)
        let (text, templateID) = renderDescription(&rng)

        let line = WalkLine(step: state.step, text: text, finding: finding?.text)
        state.lines.append(line)
        if state.lines.count > Self.maxVisibleLines {
            state.lines.removeFirst(state.lines.count - Self.maxVisibleLines)
        }

        return WalkStep(
            step: state.step, biome: state.biome, weather: state.weather,
            text: text, finding: finding?.text, enteredBiome: entered, templateID: templateID
        )
    }

    private static func stepRNG(seed: UInt64, step: Int) -> SplitMix64 {
        SplitMix64(seed: seed &+ 0x9E3779B97F4A7C15 &* UInt64(bitPattern: Int64(step)))
    }

    // MARK: - Markov transitions

    private func advanceBiome(_ rng: inout SplitMix64) {
        state.biomeStepsRemaining -= 1
        guard state.biomeStepsRemaining <= 0 else { return }
        let neighbors = state.biome.neighbors
        state.biome = neighbors[Int.random(in: 0..<neighbors.count, using: &rng)]
        state.biomeStepsRemaining = Int.random(in: Self.biomeDurationRange, using: &rng)
        state.journaledBiomeEntry = false
    }

    private func advanceWeather(_ rng: inout SplitMix64) {
        state.weatherStepsRemaining -= 1
        guard state.weatherStepsRemaining <= 0 else { return }
        let neighbors = state.weather.neighbors
        state.weather = neighbors[Int.random(in: 0..<neighbors.count, using: &rng)]
        state.weatherStepsRemaining = Int.random(in: Self.weatherDurationRange, using: &rng)
    }

    // MARK: - Findings

    private func resolveFinding(_ rng: inout SplitMix64) -> WalkFinding? {
        guard state.step - state.lastFindingStep >= Self.minFindingGap else { return nil }
        guard Double.random(in: 0..<1, using: &rng) < Self.findingProbability else { return nil }

        let recent = Set(state.recentFindingIDs)
        var eligible = WalkContent.findings.indices.filter {
            WalkContent.findings[$0].fits(state.biome) && !recent.contains($0)
        }
        if eligible.isEmpty {
            // Everything that fits here is recently seen; loosen rather than
            // skip, so a long stay in one biome still turns things up.
            eligible = WalkContent.findings.indices.filter { WalkContent.findings[$0].fits(state.biome) }
        }
        guard !eligible.isEmpty else { return nil }

        let chosen = weightedChoice(eligible, &rng)
        state.lastFindingStep = state.step
        state.recentFindingIDs.append(chosen)
        if state.recentFindingIDs.count > Self.findingMemory {
            state.recentFindingIDs.removeFirst(state.recentFindingIDs.count - Self.findingMemory)
        }
        return WalkContent.findings[chosen]
    }

    private func weightedChoice(_ indices: [Int], _ rng: inout SplitMix64) -> Int {
        let total = indices.reduce(0) { $0 + WalkContent.findings[$1].weight }
        var roll = Int.random(in: 0..<total, using: &rng)
        for index in indices {
            roll -= WalkContent.findings[index].weight
            if roll < 0 { return index }
        }
        return indices[indices.count - 1]
    }

    // MARK: - Description assembly

    /// Picks a biome template that avoids the recent window, fills its time
    /// slot, and occasionally adds a weather inflection or a connective as a
    /// spare second sentence. Returns the text and the template's global id.
    private func renderDescription(_ rng: inout SplitMix64) -> (String, Int) {
        let templates = state.biome.templates
        let base = biomeBase()
        let poolIDs = Array(base..<(base + templates.count))

        // Exclude the most recent same-biome picks (up to pool size minus one,
        // so a candidate always remains). This guarantees no template repeats
        // within its feasible window even when a pool is small.
        var excluded = Set<Int>()
        for id in state.recentTemplateIDs.reversed() where poolIDs.contains(id) {
            if excluded.count >= templates.count - 1 { break }
            excluded.insert(id)
        }
        let candidates = poolIDs.filter { !excluded.contains($0) }
        let chosenID = candidates[Int.random(in: 0..<candidates.count, using: &rng)]

        state.recentTemplateIDs.append(chosenID)
        if state.recentTemplateIDs.count > Self.templateWindow {
            state.recentTemplateIDs.removeFirst(state.recentTemplateIDs.count - Self.templateWindow)
        }

        var sentence = templates[chosenID - base]
        if sentence.contains("{time}") {
            let time = WalkContent.timeWords[Int.random(in: 0..<WalkContent.timeWords.count, using: &rng)]
            sentence = sentence.replacingOccurrences(of: "{time}", with: time)
        }

        // At most one extra sentence, weighted toward weather so the sky stays
        // present without every line carrying a tail. It never repeats the last
        // extra used, so back-to-back tails never read the same.
        let roll = Double.random(in: 0..<1, using: &rng)
        if roll < 0.4 {
            let extra = pick(state.weather.inflections, avoiding: state.lastExtra, &rng)
            sentence += " " + extra
            state.lastExtra = extra
        } else if roll < 0.5 {
            let extra = pick(WalkContent.connectives, avoiding: state.lastExtra, &rng)
            sentence += " " + extra
            state.lastExtra = extra
        }

        return (sentence, chosenID)
    }

    private func pick(_ pool: [String], avoiding avoid: String, _ rng: inout SplitMix64) -> String {
        let candidates = pool.filter { $0 != avoid }
        let choices = candidates.isEmpty ? pool : candidates
        return choices[Int.random(in: 0..<choices.count, using: &rng)]
    }

    private func biomeBase() -> Int {
        (WalkBiome.allCases.firstIndex(of: state.biome) ?? 0) * 100
    }
}

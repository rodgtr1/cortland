import Foundation

/// A half-written entry. It exists for exactly one reason: so that Esc is
/// never destructive. Closing the panel mid-thought and reopening lands back
/// in the same prompt with the same words. This is the one exception to
/// "every entry dies complete", and it is not a resumable project: the game
/// never suggests continuing or expanding anything it has already saved.
nonisolated struct JournalDraft: Codable, Equatable, Sendable {
    var pool: JournalPool
    var promptID: String
    var text: String
    var startDate: Date
    /// The one reroll per entry, spent or not.
    var rerolled: Bool

    init(pool: JournalPool, promptID: String, text: String = "", startDate: Date, rerolled: Bool = false) {
        self.pool = pool
        self.promptID = promptID
        self.text = text
        self.startDate = startDate
        self.rerolled = rerolled
    }
}

/// Everything the journal keeps between opens. Deliberately thin: the monthly
/// markdown files are the real record, and nothing here is ever re-derived
/// from them. `entriesWritten` is a place-marker, not a target, and is shown
/// nowhere prominent.
nonisolated struct JournalState: Codable, Equatable, Sendable {
    var version: Int
    /// Per pool, the ids most recently served, oldest first. Capped at
    /// `JournalModel.recentCapacity`.
    var recentPromptIDs: [String: [String]]
    var draft: JournalDraft?
    var entriesWritten: Int
    /// Stable per install, so one person's feel checks are their own.
    var feelSeed: UInt64
    /// Advanced once per finished entry; the roll is a pure function of the
    /// pair, which is what makes "1 in 5" testable without a clock.
    var feelCounter: Int
    /// Door 1 alternates between its two pools; this is whose turn it is.
    var nextClearPool: JournalPool

    init(
        version: Int = 1,
        recentPromptIDs: [String: [String]] = [:],
        draft: JournalDraft? = nil,
        entriesWritten: Int = 0,
        feelSeed: UInt64,
        feelCounter: Int = 0,
        nextClearPool: JournalPool = .recenter
    ) {
        self.version = version
        self.recentPromptIDs = recentPromptIDs
        self.draft = draft
        self.entriesWritten = entriesWritten
        self.feelSeed = feelSeed
        self.feelCounter = feelCounter
        self.nextClearPool = nextClearPool
    }
}

/// How full the meter is, as shape rather than pressure. There is no band for
/// "too little": under the limit is not a state worth naming.
nonisolated enum JournalMeterBand: Equatable, Sendable {
    case neutral
    case near
    case close
    /// Past the limit. The meter stops filling and the words keep landing.
    case over
}

/// The journal's rules, with no AppKit and no clock of its own: prompt
/// selection, counting, the meter, and the feel-check roll. Every source of
/// entropy and every date arrives as a parameter, so all of this is directly
/// testable and reproducible.
///
/// Future hook, deliberately not built (see the spec's out-of-scope list): an
/// "agent finished, finish your thought when ready" notice would want agent
/// status, which lives outside this directory. If that ever becomes reachable
/// from a game module, it belongs here as an input, never as an interruption.
nonisolated final class JournalModel {
    /// The no-repeat window: the last 8 prompts served from a pool are off the
    /// table. Every pool is comfortably larger than this, so there is always
    /// something fresh to draw.
    static let recentCapacity = 8

    private(set) var state: JournalState

    init(state: JournalState) {
        self.state = state
    }

    convenience init(feelSeed: UInt64) {
        self.init(state: JournalState(feelSeed: feelSeed))
    }

    func snapshot() -> JournalState { state }

    // MARK: - Prompts

    /// Which pool a door opens. Door 1 alternates; doors 2 and 3 are fixed.
    /// Reflect is only ever reached through door 3, by explicit choice.
    func pool(for door: JournalDoor) -> JournalPool {
        switch door {
        case .clear: return state.nextClearPool
        case .make: return .create
        case .reflect: return .reflect
        }
    }

    /// Rolls a prompt from `pool`, avoiding the ones most recently served from
    /// it, and records it as the pool's newest. Door 1's alternation advances
    /// here so consecutive visits move recenter, unload, recenter.
    func serve(door: JournalDoor, seed: UInt64) -> JournalPrompt {
        let chosen = pool(for: door)
        let prompt = Self.pick(from: chosen, avoiding: recentIDs(for: chosen), seed: seed)
        remember(prompt)
        if door == .clear {
            state.nextClearPool = chosen == .recenter ? .unload : .recenter
        }
        return prompt
    }

    /// Swaps the current prompt for another from the same pool. The old one is
    /// already remembered, so a reroll cannot hand back what it just showed.
    func reroll(seed: UInt64) -> JournalPrompt? {
        guard let draft = state.draft, !draft.rerolled else { return nil }
        let prompt = Self.pick(from: draft.pool, avoiding: recentIDs(for: draft.pool), seed: seed)
        remember(prompt)
        state.draft?.promptID = prompt.id
        state.draft?.rerolled = true
        return prompt
    }

    func recentIDs(for pool: JournalPool) -> [String] {
        state.recentPromptIDs[pool.rawValue] ?? []
    }

    private func remember(_ prompt: JournalPrompt) {
        var recent = recentIDs(for: prompt.pool)
        recent.append(prompt.id)
        if recent.count > Self.recentCapacity {
            recent.removeFirst(recent.count - Self.recentCapacity)
        }
        state.recentPromptIDs[prompt.pool.rawValue] = recent
    }

    /// Deterministic given the seed. Recent prompts are excluded; if a pool
    /// were ever small enough for the window to swallow it whole, the roll
    /// falls back to the full pool rather than returning nothing.
    static func pick(from pool: JournalPool, avoiding recent: [String], seed: UInt64) -> JournalPrompt {
        let prompts = JournalPrompts.pool(pool)
        var rng = SplitMix64(seed: seed)
        let recentSet = Set(recent)
        let fresh = prompts.filter { !recentSet.contains($0.id) }
        return (fresh.isEmpty ? prompts : fresh).randomElement(using: &rng)!
    }

    static func prompt(id: String) -> JournalPrompt? {
        JournalPrompts.all.first { $0.id == id }
    }

    // MARK: - Drafts

    func beginDraft(prompt: JournalPrompt, startDate: Date) {
        state.draft = JournalDraft(pool: prompt.pool, promptID: prompt.id, startDate: startDate)
    }

    func updateDraft(text: String) {
        state.draft?.text = text
    }

    func discardDraft() {
        state.draft = nil
    }

    /// Records a finished entry: clears the draft, advances the two quiet
    /// counters, and answers whether this entry is one of the roughly one in
    /// five that gets the feel check. The text itself has already gone to the
    /// user's file; nothing about it is kept here.
    @discardableResult
    func finishEntry() -> Bool {
        let feel = showsFeelCheck
        state.draft = nil
        state.entriesWritten += 1
        state.feelCounter += 1
        return feel
    }

    /// Whether the next finished entry gets the feel check. Pure in its
    /// inputs, so tests can walk the sequence without a clock.
    var showsFeelCheck: Bool {
        Self.showsFeelCheck(seed: state.feelSeed, counter: state.feelCounter)
    }

    static func showsFeelCheck(seed: UInt64, counter: Int) -> Bool {
        var rng = SplitMix64(seed: seed &+ UInt64(bitPattern: Int64(counter)))
        return rng.next() % 5 == 0
    }

    // MARK: - Counting and the meter

    /// Characters count graphemes, so an emoji or an accented letter is one
    /// character and not four bytes. Words are whitespace-separated tokens.
    static func count(_ text: String, unit: JournalLimitUnit) -> Int {
        switch unit {
        case .characters:
            return text.count
        case .words:
            return text.split(whereSeparator: { $0.isWhitespace }).count
        }
    }

    /// How full the meter draws: capped at 1, because past the limit it simply
    /// stops filling. Nothing turns red and starts blinking; the words keep
    /// landing either way.
    static func fill(used: Int, limit: Int) -> Double {
        guard limit > 0 else { return 0 }
        return min(1, Double(used) / Double(limit))
    }

    static func band(used: Int, limit: Int) -> JournalMeterBand {
        guard limit > 0 else { return .neutral }
        let fraction = Double(used) / Double(limit)
        if fraction >= 1 { return .over }
        if fraction >= 0.9 { return .close }
        if fraction >= 0.7 { return .near }
        return .neutral
    }
}

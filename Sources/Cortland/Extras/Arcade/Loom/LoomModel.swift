import Foundation

/// Everything the loom keeps. The tapestry file is the real record; this holds
/// only what the loom needs to be the same loom tomorrow, half-turned panel
/// included.
nonisolated struct LoomState: Codable, Equatable, Sendable {
    var version: Int
    /// Stable per install: every panel's seed is drawn from it, so the sequence
    /// of panels is this loom's own.
    var loomSeed: UInt64
    var panelsWoven: Int
    var panel: LoomPanel
    /// Whether the panel on screen is already settled and already woven in.
    /// Stored rather than derived so a resolved panel left overnight is not
    /// woven into the tapestry a second time on the way back.
    var resolved: Bool
    var cursor: Int

    init(version: Int = 1, loomSeed: UInt64, panelsWoven: Int = 0, panel: LoomPanel,
         resolved: Bool = false, cursor: Int = 0) {
        self.version = version
        self.loomSeed = loomSeed
        self.panelsWoven = panelsWoven
        self.panel = panel
        self.resolved = resolved
        self.cursor = cursor
    }
}

/// The loom: pure, `nonisolated`, deterministic given its seed. It owns turning
/// tiles and dealing panels; the view owns the thread and the tapestry file.
nonisolated final class LoomModel {
    /// What a turn came to. Nothing here is a failure; `settled` just means the
    /// panel has nothing left to ask for.
    enum Turn: Equatable {
        case turned
        case settled
        case ignored
    }

    private(set) var state: LoomState

    init(state: LoomState) {
        self.state = state
    }

    convenience init(seed: UInt64) {
        self.init(state: LoomModel.freshState(seed: seed))
    }

    static func freshState(seed: UInt64) -> LoomState {
        LoomState(loomSeed: seed, panel: LoomGenerator.panel(seed: panelSeed(loomSeed: seed, index: 0)))
    }

    /// Panel seeds are drawn off the loom seed and the panel's ordinal, so a
    /// restored loom deals exactly the panels it was going to deal.
    static func panelSeed(loomSeed: UInt64, index: Int) -> UInt64 {
        var rng = SplitMix64(seed: loomSeed &+ UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15)
        return rng.next()
    }

    func snapshot() -> LoomState { state }

    var panel: LoomPanel { state.panel }
    var side: Int { state.panel.side }
    var isSettled: Bool { state.resolved }
    var panelsWoven: Int { state.panelsWoven }
    var cursor: Int { state.cursor }

    /// A quiet place-marker, never a target: which panel this is, counting from
    /// the first one this loom ever dealt.
    var panelOrdinal: Int { state.resolved ? state.panelsWoven : state.panelsWoven + 1 }

    // MARK: - The whole verb set

    func setCursor(_ index: Int) {
        guard state.panel.tiles.indices.contains(index) else { return }
        state.cursor = index
    }

    func moveCursor(rowDelta: Int, colDelta: Int) {
        let side = state.panel.side
        let row = min(max(0, state.cursor / side + rowDelta), side - 1)
        let col = min(max(0, state.cursor % side + colDelta), side - 1)
        state.cursor = row * side + col
    }

    /// Turns a tile a quarter clockwise. Turning a settled panel is ignored:
    /// there is nothing there to disturb.
    @discardableResult
    func turn(at index: Int) -> Turn {
        guard !state.resolved, state.panel.tiles.indices.contains(index) else { return .ignored }
        state.panel.tiles[index].rotation = (state.panel.tiles[index].rotation + 1) % 4
        guard LoomBoard.isSettled(state.panel) else { return .turned }
        state.resolved = true
        state.panelsWoven += 1
        return .settled
    }

    @discardableResult
    func turnAtCursor() -> Turn { turn(at: state.cursor) }

    /// Deals the next panel. Only ever at the player's asking, and only once
    /// the one on screen is settled: nothing auto-advances out from under a
    /// panel someone is still looking at.
    @discardableResult
    func nextPanel() -> Bool {
        guard state.resolved else { return false }
        state.panel = LoomGenerator.panel(seed: Self.panelSeed(loomSeed: state.loomSeed, index: state.panelsWoven))
        state.resolved = false
        state.cursor = 0
        return true
    }
}

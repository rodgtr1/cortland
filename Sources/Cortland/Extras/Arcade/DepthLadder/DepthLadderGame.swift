import Foundation

/// Everything Depth Ladder persists. `marks` mirrors the puzzle grid:
/// -1 untouched, 0 crossed (player note / auto-cross after a mistake),
/// 1 correctly filled.
nonisolated struct DepthLadderState: Codable, Equatable, Sendable {
    var depth: Int
    var totalCleared: Int
    var lanterns: Int
    var lanternDay: String
    var puzzle: NonogramPuzzle?
    var marks: [Int]
    var mistakes: Int
}

/// The check-in meta-game around the nonogram floors: an endless descent
/// where `depth` (deepest floor cleared) is the permanent stat. Descending is
/// free; *failing* a floor (three wrong fills) burns one of the day's three
/// lanterns, and at zero lanterns the tower goes dark until midnight. Pure
/// model, no AppKit — DepthLadderView owns rendering and input.
final class DepthLadderGame {
    static let lanternsPerDay = 3
    static let mistakesAllowed = 3

    enum FillResult {
        case filled
        case uncrossed
        case mistake
        case floorCleared
        case floorFailed
        case ignored
    }

    private(set) var depth: Int
    private(set) var totalCleared: Int
    private(set) var lanterns: Int
    private(set) var lanternDay: String
    private(set) var puzzle: NonogramPuzzle?
    private(set) var marks: [Int]
    private(set) var mistakes: Int

    /// The floor currently being attempted (depth counts *cleared* floors).
    var floor: Int { depth + 1 }

    /// Out of lanterns with no puzzle underway: nothing to do until the
    /// daily refill.
    var isDark: Bool { lanterns <= 0 && puzzle == nil }

    init() {
        depth = 0
        totalCleared = 0
        lanterns = Self.lanternsPerDay
        lanternDay = ""
        puzzle = nil
        marks = []
        mistakes = 0
    }

    init(state: DepthLadderState) {
        depth = state.depth
        totalCleared = state.totalCleared
        lanterns = state.lanterns
        lanternDay = state.lanternDay
        puzzle = state.puzzle
        marks = state.marks
        mistakes = state.mistakes
    }

    func snapshot() -> DepthLadderState {
        DepthLadderState(
            depth: depth,
            totalCleared: totalCleared,
            lanterns: lanterns,
            lanternDay: lanternDay,
            puzzle: puzzle,
            marks: marks,
            mistakes: mistakes
        )
    }

    /// Floors start small and grow with depth; the endless tail is 15x15.
    static func size(forFloor floor: Int) -> Int {
        switch floor {
        case ..<4: return 5
        case ..<8: return 7
        case ..<13: return 8
        case ..<26: return 10
        case ..<51: return 12
        default: return 15
        }
    }

    /// Refills the lanterns when the local day has rolled over since the
    /// last check-in.
    func refreshDay(now: Date) {
        let today = Self.dayStamp(for: now)
        if today != lanternDay {
            lanternDay = today
            lanterns = Self.lanternsPerDay
        }
    }

    /// Generates the current floor's puzzle when none is underway. No-op
    /// while a puzzle is in progress or the tower is dark.
    func beginFloorIfNeeded(seed: UInt64) {
        guard puzzle == nil, lanterns > 0 else { return }
        let generated = NonogramGenerator.generate(size: Self.size(forFloor: floor), seed: seed)
        puzzle = generated
        marks = Array(repeating: -1, count: generated.size * generated.size)
        mistakes = 0
    }

    /// Attempts to fill a cell. Fills are validated against the solution
    /// immediately: a wrong fill auto-crosses the cell and counts a mistake,
    /// and the third mistake fails the floor (burning a lantern). Filling a
    /// crossed cell clears the cross instead — never a silent no-op — so the
    /// next fill lands for real.
    func fill(at index: Int) -> FillResult {
        guard let puzzle, marks.indices.contains(index), marks[index] != 1 else { return .ignored }

        if marks[index] == 0 {
            marks[index] = -1
            return .uncrossed
        }

        guard puzzle.solution[index] else {
            marks[index] = 0
            mistakes += 1
            if mistakes >= Self.mistakesAllowed {
                lanterns -= 1
                self.puzzle = nil
                marks = []
                mistakes = 0
                return .floorFailed
            }
            return .mistake
        }

        marks[index] = 1
        let solved = puzzle.solution.indices.allSatisfy { !puzzle.solution[$0] || marks[$0] == 1 }
        if solved {
            depth += 1
            totalCleared += 1
            self.puzzle = nil
            marks = []
            mistakes = 0
            return .floorCleared
        }
        return .filled
    }

    /// Crosses are free-form notes; only fills are validated. Filled cells
    /// can't be crossed.
    func toggleCross(at index: Int) {
        guard puzzle != nil, marks.indices.contains(index), marks[index] != 1 else { return }
        marks[index] = marks[index] == 0 ? -1 : 0
    }

    static func dayStamp(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

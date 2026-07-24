import Foundation

/// One picross-style deduction puzzle: a hidden bitmap plus the row/column
/// run-length clues the player deduces it from.
nonisolated struct NonogramPuzzle: Codable, Equatable, Sendable {
    let size: Int
    /// Row-major hidden bitmap; true = filled.
    let solution: [Bool]
    let rowClues: [[Int]]
    let colClues: [[Int]]
}

/// Deterministic RNG so puzzle generation is reproducible in tests (and a
/// floor could someday be re-derived from its seed).
nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

nonisolated enum NonogramGenerator {
    /// Random puzzles are only accepted when the line solver below can finish
    /// them: that guarantees the player never has to guess. Density is nudged
    /// down on retries because overly dense grids are the usual rejects.
    static func generate(size: Int, seed: UInt64) -> NonogramPuzzle {
        var rng = SplitMix64(seed: seed)
        var best: NonogramPuzzle?
        for attempt in 0..<40 {
            let density = 0.58 - Double(attempt / 10) * 0.04
            let solution = (0..<(size * size)).map { _ in Double.random(in: 0..<1, using: &rng) < density }
            let puzzle = NonogramPuzzle(
                size: size,
                solution: solution,
                rowClues: (0..<size).map { row in clues(for: (0..<size).map { solution[row * size + $0] }) },
                colClues: (0..<size).map { col in clues(for: (0..<size).map { solution[$0 * size + col] }) }
            )
            best = puzzle
            if NonogramSolver.isLineSolvable(puzzle) {
                return puzzle
            }
        }
        // Practically unreachable (acceptance is high at these sizes); the
        // last candidate is still a valid puzzle, just possibly needing a
        // lucky guess at the end.
        return best!
    }

    static func clues(for line: [Bool]) -> [Int] {
        var runs: [Int] = []
        var run = 0
        for cell in line {
            if cell {
                run += 1
            } else if run > 0 {
                runs.append(run)
                run = 0
            }
        }
        if run > 0 {
            runs.append(run)
        }
        return runs
    }
}

nonisolated enum NonogramSolver {
    /// True when repeated row/column deduction alone determines every cell —
    /// i.e. the puzzle is uniquely solvable by the same line logic a human
    /// uses, with no guessing.
    static func isLineSolvable(_ puzzle: NonogramPuzzle) -> Bool {
        let n = puzzle.size
        var cells = [Int](repeating: -1, count: n * n) // -1 unknown, 0 empty, 1 filled

        var changed = true
        while changed {
            changed = false
            for row in 0..<n {
                let line = (0..<n).map { cells[row * n + $0] }
                guard let deduced = deduceLine(line, clues: puzzle.rowClues[row]) else { return false }
                for col in 0..<n where deduced[col] != line[col] {
                    cells[row * n + col] = deduced[col]
                    changed = true
                }
            }
            for col in 0..<n {
                let line = (0..<n).map { cells[$0 * n + col] }
                guard let deduced = deduceLine(line, clues: puzzle.colClues[col]) else { return false }
                for row in 0..<n where deduced[row] != line[row] {
                    cells[row * n + col] = deduced[row]
                    changed = true
                }
            }
        }
        return !cells.contains(-1)
    }

    /// Intersects every clue placement consistent with the known cells:
    /// positions where all placements agree become determined. Returns nil
    /// when no placement fits (a contradiction — impossible for clues derived
    /// from a real solution with truthful marks).
    static func deduceLine(_ line: [Int], clues: [Int]) -> [Int]? {
        let n = line.count
        var candidate = [Int](repeating: 0, count: n)
        var intersection: [Int]?

        func compatible(_ from: Int, _ to: Int, value: Int) -> Bool {
            for index in from..<to {
                if line[index] >= 0 && line[index] != value {
                    return false
                }
            }
            return true
        }

        func merge() {
            if var merged = intersection {
                for index in 0..<n where merged[index] != candidate[index] {
                    merged[index] = -1
                }
                intersection = merged
            } else {
                intersection = candidate
            }
        }

        func place(from start: Int, clueIndex: Int) {
            if clueIndex == clues.count {
                if compatible(start, n, value: 0) {
                    for index in start..<n {
                        candidate[index] = 0
                    }
                    merge()
                }
                return
            }
            let run = clues[clueIndex]
            // Minimum room the remaining runs (and their separators) need.
            let tail = clues[(clueIndex + 1)...].reduce(0, +) + (clues.count - clueIndex - 1)
            var position = start
            while position + run + tail <= n {
                if compatible(start, position, value: 0), compatible(position, position + run, value: 1) {
                    let isLast = clueIndex == clues.count - 1
                    let separatorEnd = isLast ? position + run : position + run + 1
                    if isLast || compatible(position + run, separatorEnd, value: 0) {
                        for index in start..<position {
                            candidate[index] = 0
                        }
                        for index in position..<(position + run) {
                            candidate[index] = 1
                        }
                        if !isLast {
                            candidate[position + run] = 0
                        }
                        place(from: separatorEnd, clueIndex: clueIndex + 1)
                    }
                }
                position += 1
            }
        }

        place(from: 0, clueIndex: 0)
        return intersection
    }
}

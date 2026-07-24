import Foundation

/// Everything Keysmith persists. `keyAttempts`/`keyErrors` are keyed by
/// single-character strings (JSON has no Character keys) and drive the adaptive
/// drills; `bestWPM`/`bestAccuracy` are keyed by tier raw value. The run in
/// progress rides along too: `currentLine` is the line on screen and
/// `completedLines` the lines already cleared this run. The cursor and the
/// in-flight timing are deliberately absent — hiding the panel abandons the
/// current line, so a restored run always restarts that line from the top.
nonisolated struct KeysmithState: Codable, Equatable, Sendable {
    var tier: KeysmithTier
    var keyAttempts: [String: Int]
    var keyErrors: [String: Int]
    var bestWPM: [String: Double]
    var bestAccuracy: [String: Double]
    var totalLinesCompleted: Int
    var currentLine: String
    var completedLines: [KeysmithLineResult]
}

/// The three difficulty bands, cycled with Tab or picked with the 1/2/3 keys.
nonisolated enum KeysmithTier: String, Codable, CaseIterable, Sendable {
    case letters
    case words
    case code

    var title: String {
        switch self {
        case .letters: return "letters"
        case .words: return "words"
        case .code: return "code"
        }
    }

    /// The next tier in the cycle, wrapping back to the first.
    var next: KeysmithTier {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// One finished line's raw tally. Gross WPM treats every 5 characters as a
/// word: (characters / 5) / minutes. Accuracy is correct keystrokes over all
/// keystrokes, so a stop-on-error miss only ever inflates the denominator.
nonisolated struct KeysmithLineResult: Codable, Equatable, Sendable {
    var characters: Int
    var keystrokes: Int
    var correct: Int
    var elapsed: TimeInterval

    var wpm: Double {
        guard elapsed > 0 else { return 0 }
        return (Double(characters) / 5) / (elapsed / 60)
    }

    var accuracy: Double {
        guard keystrokes > 0 else { return 1 }
        return Double(correct) / Double(keystrokes)
    }
}

/// The rollup shown on the results overlay between runs: the run's aggregate
/// WPM and accuracy plus whether either just beat the tier's stored best.
nonisolated struct KeysmithRunSummary: Equatable, Sendable {
    var wpm: Double
    var accuracy: Double
    var bestWPM: Double
    var bestAccuracy: Double
    var setWPMRecord: Bool
    var setAccuracyRecord: Bool
}

/// The typing trainer: a run is five stop-on-error lines drawn from the active
/// tier's corpus, weighted toward the keys the typist keeps missing. Pure
/// model, no AppKit — KeysmithView owns rendering and input. Every method that
/// needs the clock takes a `Date`; the model never reads it itself.
final class KeysmithGame {
    static let linesPerRun = 5
    /// A key needs a few logged strikes before its error rate is trusted enough
    /// to steer the drill generator toward it.
    static let minAttemptsToWeight = 4

    /// What one typed character did to the run.
    enum TypeResult: Equatable {
        case advanced
        case mistake(expected: Character)
        case lineCompleted
        case runCompleted(KeysmithRunSummary)
        case ignored
    }

    private(set) var tier: KeysmithTier
    private(set) var keyAttempts: [String: Int]
    private(set) var keyErrors: [String: Int]
    private(set) var bestWPM: [String: Double]
    private(set) var bestAccuracy: [String: Double]
    private(set) var totalLinesCompleted: Int

    /// The line being typed, as characters; empty when no line is underway.
    private(set) var line: [Character]
    private(set) var cursor: Int
    private(set) var completedLines: [KeysmithLineResult]

    // Per-line tallies, committed to the persistent stats only when the line
    // completes and discarded when a line is abandoned (hidden mid-line), so
    // an unfinished line never colors the adaptive weighting.
    private var lineStartedAt: Date?
    private var lineKeystrokes: Int
    private var lineCorrect: Int
    private var lineAttempts: [String: Int]
    private var lineErrors: [String: Int]

    var lineText: String { String(line) }
    var hasLineUnderway: Bool { !line.isEmpty }
    /// 1-based index of the line being typed within the run.
    var lineNumber: Int { completedLines.count + 1 }
    var isRunComplete: Bool { completedLines.count >= Self.linesPerRun }

    var tierBestWPM: Double { bestWPM[tier.rawValue] ?? 0 }
    var tierBestAccuracy: Double { bestAccuracy[tier.rawValue] ?? 0 }

    init() {
        tier = .letters
        keyAttempts = [:]
        keyErrors = [:]
        bestWPM = [:]
        bestAccuracy = [:]
        totalLinesCompleted = 0
        line = []
        cursor = 0
        completedLines = []
        lineStartedAt = nil
        lineKeystrokes = 0
        lineCorrect = 0
        lineAttempts = [:]
        lineErrors = [:]
    }

    init(state: KeysmithState) {
        tier = state.tier
        keyAttempts = state.keyAttempts
        keyErrors = state.keyErrors
        bestWPM = state.bestWPM
        bestAccuracy = state.bestAccuracy
        totalLinesCompleted = state.totalLinesCompleted
        line = Array(state.currentLine)
        cursor = 0
        completedLines = state.completedLines
        lineStartedAt = nil
        lineKeystrokes = 0
        lineCorrect = 0
        lineAttempts = [:]
        lineErrors = [:]
    }

    func snapshot() -> KeysmithState {
        KeysmithState(
            tier: tier,
            keyAttempts: keyAttempts,
            keyErrors: keyErrors,
            bestWPM: bestWPM,
            bestAccuracy: bestAccuracy,
            totalLinesCompleted: totalLinesCompleted,
            currentLine: lineText,
            completedLines: completedLines
        )
    }

    // MARK: - Run control

    /// Switches tier and drops the run in progress; a run is scored against one
    /// tier's best, so it can't straddle two. Stats and bests are per tier and
    /// untouched. The caller generates the first line of the new tier.
    func selectTier(_ newTier: KeysmithTier) {
        guard newTier != tier else { return }
        tier = newTier
        completedLines = []
        line = []
        resetLineTally()
    }

    /// Generates the next line for the active tier from the given seed, weighted
    /// toward the typist's weakest keys. Deterministic given the seed and the
    /// current stats. No-op while a line is already underway or the run is done.
    func beginLine(seed: UInt64) {
        guard line.isEmpty, !isRunComplete else { return }
        line = Array(KeysmithDrills.makeLine(
            tier: tier,
            seed: seed,
            attempts: keyAttempts,
            errors: keyErrors,
            minAttempts: Self.minAttemptsToWeight
        ))
        resetLineTally()
    }

    /// Clears a finished run and starts a fresh one; the first line comes from
    /// the seed.
    func beginRun(seed: UInt64) {
        completedLines = []
        line = []
        resetLineTally()
        beginLine(seed: seed)
    }

    /// Drops the current line's partial progress without penalty: only completed
    /// lines feed the stats, so the in-flight tallies are discarded and the same
    /// line restarts from its first character on resume.
    func abandonLine() {
        resetLineTally()
    }

    // MARK: - Typing

    /// Registers one typed character against the expected character at the
    /// cursor. The cursor only advances on a correct strike (stop-on-error); a
    /// miss is charged to the expected character and leaves the cursor put.
    /// `now` stamps the line's first keystroke and its completion.
    func type(_ character: Character, at now: Date) -> TypeResult {
        guard cursor < line.count else { return .ignored }
        if lineStartedAt == nil { lineStartedAt = now }

        let expected = line[cursor]
        let key = String(expected)
        lineKeystrokes += 1
        lineAttempts[key, default: 0] += 1

        guard character == expected else {
            lineErrors[key, default: 0] += 1
            return .mistake(expected: expected)
        }

        lineCorrect += 1
        cursor += 1
        if cursor < line.count { return .advanced }
        return completeLine(at: now)
    }

    private func completeLine(at now: Date) -> TypeResult {
        let elapsed = lineStartedAt.map { now.timeIntervalSince($0) } ?? 0
        completedLines.append(KeysmithLineResult(
            characters: line.count,
            keystrokes: lineKeystrokes,
            correct: lineCorrect,
            elapsed: max(0, elapsed)
        ))
        totalLinesCompleted += 1

        // The line counted, so fold its per-key tallies into the durable stats.
        for (key, count) in lineAttempts { keyAttempts[key, default: 0] += count }
        for (key, count) in lineErrors { keyErrors[key, default: 0] += count }

        line = []
        resetLineTally()

        guard completedLines.count >= Self.linesPerRun else { return .lineCompleted }
        return .runCompleted(finishRun())
    }

    private func finishRun() -> KeysmithRunSummary {
        let totalChars = completedLines.reduce(0) { $0 + $1.characters }
        let totalKeys = completedLines.reduce(0) { $0 + $1.keystrokes }
        let totalCorrect = completedLines.reduce(0) { $0 + $1.correct }
        let totalElapsed = completedLines.reduce(0) { $0 + $1.elapsed }

        let wpm = totalElapsed > 0 ? (Double(totalChars) / 5) / (totalElapsed / 60) : 0
        let accuracy = totalKeys > 0 ? Double(totalCorrect) / Double(totalKeys) : 1

        let key = tier.rawValue
        let priorWPM = bestWPM[key] ?? 0
        let priorAccuracy = bestAccuracy[key] ?? 0
        let setWPM = wpm > priorWPM
        let setAccuracy = accuracy > priorAccuracy
        if setWPM { bestWPM[key] = wpm }
        if setAccuracy { bestAccuracy[key] = accuracy }

        return KeysmithRunSummary(
            wpm: wpm,
            accuracy: accuracy,
            bestWPM: bestWPM[key] ?? wpm,
            bestAccuracy: bestAccuracy[key] ?? accuracy,
            setWPMRecord: setWPM,
            setAccuracyRecord: setAccuracy
        )
    }

    // MARK: - Live figures

    /// Live gross WPM for the run so far, folding the in-progress line's elapsed
    /// time in with the completed lines. Zero until the line's clock starts.
    func liveWPM(at now: Date) -> Double {
        var chars = completedLines.reduce(0) { $0 + $1.characters }
        var elapsed = completedLines.reduce(0) { $0 + $1.elapsed }
        if let started = lineStartedAt {
            chars += cursor
            elapsed += max(0, now.timeIntervalSince(started))
        }
        guard elapsed > 0 else { return 0 }
        return (Double(chars) / 5) / (elapsed / 60)
    }

    /// Live accuracy for the run so far, including the in-progress line.
    var liveAccuracy: Double {
        let keys = completedLines.reduce(0) { $0 + $1.keystrokes } + lineKeystrokes
        let correct = completedLines.reduce(0) { $0 + $1.correct } + lineCorrect
        guard keys > 0 else { return 1 }
        return Double(correct) / Double(keys)
    }

    private func resetLineTally() {
        lineStartedAt = nil
        lineKeystrokes = 0
        lineCorrect = 0
        lineAttempts = [:]
        lineErrors = [:]
        cursor = 0
    }
}

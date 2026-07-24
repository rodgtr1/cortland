import Foundation

/// The typing corpora and the seeded line generator. Kept apart from
/// KeysmithGame so the word lists don't drown out the model; both are pure
/// Foundation, no AppKit. The generator reuses SplitMix64 (see Nonogram) so a
/// line is fully reproducible from its (seed, stats) pair. The corpora carry no
/// bare digits on purpose: the 1/2/3 keys switch tiers, and nothing on screen
/// should ever ask the typist to press one as input.
nonisolated enum KeysmithDrills {
    static let minLineLength = 40
    static let maxLineLength = 60

    /// Home-row and full-alphabet drills: lowercase words and pseudo-words, no
    /// punctuation or capitals. Kept rich in z and q so the adaptive weighting
    /// has rare keys to steer toward.
    static let letters: [String] = [
        "the", "and", "for", "are", "but", "not", "you", "all", "can", "her",
        "was", "one", "our", "out", "day", "get", "has", "him", "his", "how",
        "man", "new", "now", "old", "see", "two", "way", "who", "boy", "did",
        "its", "let", "put", "say", "she", "too", "use", "dad", "mom", "cat",
        "dog", "run", "sun", "top", "big", "red", "hot", "cup", "hat", "bed",
        "home", "hand", "word", "work", "life", "code", "keys", "type", "fast",
        "slow", "jump", "walk", "talk", "read", "look", "make", "take", "give",
        "live", "love", "find", "must", "feel", "seem", "keep", "hold", "turn",
        "move", "play", "stop", "open", "door", "wall", "roof", "road", "tree",
        "leaf", "rain", "snow", "wind", "fire", "gold", "iron", "wood", "glass",
        "field", "river", "stone", "cloud", "light", "night", "music", "story",
        "quiet", "quick", "quilt", "quote", "quest", "queen", "equal", "squad",
        "zebra", "zonal", "zesty", "azure", "hazel", "dizzy", "fuzzy", "fizzy",
        "jazz", "buzz", "zoom", "zone", "zero", "maze", "gaze", "haze", "daze",
        "size", "cozy", "lazy", "hazy", "oozy", "prize", "seize", "graze",
        "amaze", "dozen", "gauze", "waltz", "blitz", "quartz", "jinx", "onyx",
        "vexed", "fjord", "glyph", "nymph", "crypt", "lymph", "pixel", "vivid",
        "extra", "index", "mixer", "boxer", "vowel", "wharf", "brave", "clerk",
        "drive", "flame", "grasp", "hinge", "ivory", "joker", "koala", "ledge"
    ]

    /// Common English words with capitals and punctuation mixed in, so the drill
    /// exercises the shift key and the punctuation row alongside the letters.
    static let words: [String] = [
        "The", "and", "with", "that", "have", "this", "from", "they", "which",
        "would", "there", "their", "about", "could", "other", "these", "first",
        "after", "where", "those", "being", "under", "while", "found", "still",
        "world.", "people", "before", "little", "should", "always", "through",
        "between", "because", "another", "however,", "against", "nothing",
        "morning,", "already", "perhaps", "quietly", "suddenly", "together",
        "don't", "won't", "can't", "isn't", "wasn't", "didn't", "hasn't",
        "you're", "we'll", "they've", "I'm", "it's", "let's", "that's",
        "he'd", "she'll", "wouldn't", "couldn't", "shouldn't", "everyone's",
        "Yes,", "No,", "Well,", "Now,", "Then,", "So,", "But", "And", "Or",
        "Hello,", "Goodbye.", "Please.", "Thanks!", "Sorry.", "Wait!", "Stop.",
        "Monday,", "Sunday.", "April,", "August", "October,", "December.",
        "London,", "Paris,", "Tokyo.", "Rome,", "Egypt.", "France,", "Japan.",
        "Mr.", "Mrs.", "Dr.", "St.", "Ave.", "etc.", "e.g.", "i.e.",
        "quick.", "brown,", "jumps", "over", "lazy", "again.", "twice;",
        "value,", "level.", "score:", "final;", "start,", "close.", "begin,",
        "water,", "coffee.", "garden;", "window,", "letter.", "message:",
        "friend,", "family;", "system.", "problem,", "answer:", "reason;",
        "money,", "market.", "office;", "project,", "meeting.", "deadline;",
        "summer,", "winter.", "spring;", "autumn,", "sunrise.", "sunset;",
        "north,", "south.", "east;", "west,", "center.", "corner;", "edge,",
        "yes.", "maybe;", "surely,", "clearly.", "roughly;", "nearly,",
        "hardly.", "mostly;", "simply,", "kindly.", "boldly;", "loudly,"
    ]

    /// Shell commands and Swift/JS-ish fragments, heavy on brackets, operators,
    /// and camelCase. Fragments stay short (they may hold internal spaces) and
    /// carry no bare digits.
    static let code: [String] = [
        "let x = y", "var i = j", "func run()", "return nil", "guard let",
        "if let x", "print(msg)", "[weak self]", "self.value", "map { $0 }",
        "filter { $0 }", "reduce(0, +)", "async let", "try await", "throws ->",
        "-> Bool", "-> Void", "as? Int", "is String", "?? []",
        "{ $0.id }", "$0 != nil", "a && b", "x || y", "!isEmpty",
        "count > 0", "i += x", "n -= y", "arr[idx]", "dict[key]",
        "obj.prop", "a?.b?.c", "func f<T>", "where T:", "some View",
        "@State var", "@objc func", "case .foo:", "switch x {", "for x in y",
        "while true", "do { try", "catch {}", "defer {}", "init() {}",
        "git status", "git commit", "git push", "git pull", "cd ~/repo",
        "ls -la", "rm -rf tmp", "cat file", "grep -rn", "chmod +x",
        "npm install", "npm run dev", "cargo build", "swift test", "make all",
        "cd ../src", "mkdir -p x", "echo $PATH", "export KEY=", "kill -9 pid",
        "const fn =", "let obj = {}", "=> { ... }", "await fetch", "for (;;)",
        "arr.push(x)", "JSON.parse", "x ?? y", "a === b", "!!value"
    ]

    static func corpus(for tier: KeysmithTier) -> [String] {
        switch tier {
        case .letters: return letters
        case .words: return words
        case .code: return code
        }
    }

    // MARK: - Generation

    /// How hard a single weak key pulls its words up the selection odds.
    private static let weakKeyBoost = 8.0

    /// Builds one drill line of `minLineLength...maxLineLength` characters for
    /// the tier, sampling words weighted toward the typist's weakest keys. A key
    /// counts as weak once it has at least `minAttempts` logged strikes and a
    /// nonzero error rate; words holding weak keys grow proportionally more
    /// likely, so the drills drift toward what the typist keeps missing. With no
    /// weak keys the sampling is uniform. Deterministic for a fixed (seed,
    /// stats) pair.
    static func makeLine(
        tier: KeysmithTier,
        seed: UInt64,
        attempts: [String: Int],
        errors: [String: Int],
        minAttempts: Int
    ) -> String {
        let pool = corpus(for: tier)
        guard !pool.isEmpty else { return "" }
        var rng = SplitMix64(seed: seed)

        let weightByChar = weakKeyWeights(attempts: attempts, errors: errors, minAttempts: minAttempts)
        let span = UInt64(maxLineLength - minLineLength + 1)
        let target = minLineLength + Int(rng.next() % span)

        var parts: [String] = []
        var length = 0
        while length < target {
            let separator = parts.isEmpty ? 0 : 1
            let room = maxLineLength - length - separator
            let candidates = pool.filter { !$0.isEmpty && $0.count <= room }
            guard !candidates.isEmpty else { break }
            let weights = candidates.map { wordWeight($0, weightByChar: weightByChar) }
            let word = candidates[weightedIndex(weights, using: &rng)]
            parts.append(word)
            length += separator + word.count
        }
        return parts.joined(separator: " ")
    }

    /// Per-character multipliers: greater than 1 only for keys with enough
    /// history and a nonzero error rate, scaling with how badly they miss.
    private static func weakKeyWeights(
        attempts: [String: Int],
        errors: [String: Int],
        minAttempts: Int
    ) -> [Character: Double] {
        var weights: [Character: Double] = [:]
        for (key, count) in attempts where count >= minAttempts {
            guard let character = key.first else { continue }
            let missRate = Double(errors[key] ?? 0) / Double(count)
            if missRate > 0 {
                weights[character] = 1 + missRate * weakKeyBoost
            }
        }
        return weights
    }

    /// A word's selection weight: 1 plus the accumulated boost of every weak key
    /// it contains, so words dense in fumbled keys rise to the top.
    private static func wordWeight(_ word: String, weightByChar: [Character: Double]) -> Double {
        guard !weightByChar.isEmpty else { return 1 }
        var weight = 1.0
        for character in word {
            if let charWeight = weightByChar[character] {
                weight += charWeight - 1
            }
        }
        return weight
    }

    private static func weightedIndex(_ weights: [Double], using rng: inout SplitMix64) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        let target = Double.random(in: 0..<total, using: &rng)
        var running = 0.0
        for (index, weight) in weights.enumerated() {
            running += weight
            if target < running { return index }
        }
        return weights.count - 1
    }
}

import Foundation

/// Finds a needle in a stream of text chunks without re-scanning the whole
/// buffer each time. It carries the last `needle.count - 1` characters between
/// chunks, so a match that straddles a chunk boundary — or one that would scroll
/// out of a bounded buffer before the next look — is still caught.
///
/// Backs `wait output`: each output chunk is fed once as it arrives, replacing a
/// timer that re-scanned a snapshot and could miss a string appearing and
/// scrolling past between two polls.
nonisolated struct StreamingMatcher {
    let needle: String
    private var carry: String

    /// - Parameters:
    ///   - needle: the substring to wait for. An empty needle never matches.
    ///   - seed: existing buffer text whose tail might form the start of a match
    ///     with the first fed chunk; only its last `needle.count - 1` chars are kept.
    init(needle: String, seed: String = "") {
        self.needle = needle
        self.carry = needle.isEmpty ? "" : String(seed.suffix(needle.count - 1))
    }

    /// Feeds the next chunk. Returns true the first time the needle is found in
    /// the carried tail + this chunk. Once it returns true the matcher should be
    /// discarded; further feeds keep matching but the carry is no longer updated.
    mutating func feed(_ chunk: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let haystack = carry + chunk
        if haystack.contains(needle) {
            return true
        }
        carry = String(haystack.suffix(needle.count - 1))
        return false
    }
}

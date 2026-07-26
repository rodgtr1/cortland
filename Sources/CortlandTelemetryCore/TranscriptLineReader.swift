import Foundation

/// Streams a newline-delimited transcript file line by line without ever loading
/// the whole file into memory.
///
/// The transcript parsers used to `String(contentsOfFile:)` the entire file and
/// then copy each line into its own `Data` for JSON parsing. A live agent
/// transcript reaches hundreds of MB, so that meant a ≥2× memory spike on every
/// Stop hook (the full String plus the per-line copies) with no bound (P5).
/// Reading in fixed-size chunks keeps resident memory to a chunk plus the line
/// currently being assembled, regardless of file size.
public enum TranscriptLineReader {
    private static let chunkSize = 1 << 16   // 64 KiB
    private static let newline = UInt8(0x0A)

    /// Invokes `handle` with the raw bytes of each line (newline excluded), in
    /// order. `handle` is non-escaping and called synchronously, so callers can
    /// mutate captured state directly. Returns false if the file can't be opened.
    @discardableResult
    public static func forEachLine(inFileAt path: String, _ handle: (Data) -> Void) -> Bool {
        forEachLine(inFileAt: path) { line in
            handle(line)
            return true
        }
    }

    /// Same, except `handle` returns false to stop. Reading ends there: the
    /// remaining bytes are never read, so a caller with a line or byte budget
    /// (Session Recall's 2,000-line title scan) bounds its file I/O by the same
    /// number that bounds its work, instead of paying for the whole file first.
    /// Returns false only if the file can't be opened.
    @discardableResult
    public static func forEachLine(inFileAt path: String, while handle: (Data) -> Bool) -> Bool {
        forEachLine(inFileAt: path, maxLineBytes: Int.max) { line, _, _ in handle(line) }
    }

    /// Same, with a hard ceiling on the bytes one line may occupy.
    ///
    /// Chunked reading bounds a file, but not a *line*: a transcript written
    /// without newlines (or one record carrying a giant inlined payload) makes
    /// the assembly buffer grow to the size of that record, which defeats a
    /// caller's byte budget. Past `maxLineBytes` the rest of the line is read
    /// and discarded instead of accumulated, so the buffer never exceeds
    /// `maxLineBytes` and peak memory stays at that plus one 64 KiB chunk.
    ///
    /// `handle` receives:
    ///   - `line`: the line's bytes, newline excluded, truncated to
    ///     `maxLineBytes` when the line was longer;
    ///   - `bytesConsumed`: the line's *full* size on disk including its
    ///     newline, discarded bytes included, so a caller's running total stays
    ///     honest;
    ///   - `wasTruncated`: whether bytes were dropped, so a caller never treats
    ///     a cut-off record as a whole one.
    ///
    /// Return false from `handle` to stop reading.
    @discardableResult
    public static func forEachLine(
        inFileAt path: String,
        maxLineBytes: Int,
        _ handle: (_ line: Data, _ bytesConsumed: Int, _ wasTruncated: Bool) -> Bool
    ) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }

        // The current line: `buffer` holds at most `maxLineBytes` of it,
        // `consumed` counts every byte of it that came off disk.
        var buffer = Data()
        var consumed = 0
        var truncated = false

        while let chunk = try? file.read(upToCount: chunkSize), !chunk.isEmpty {
            var start = chunk.startIndex
            while start < chunk.endIndex {
                guard let newlineIndex = chunk[start...].firstIndex(of: newline) else {
                    // No line end in what's left: keep what fits, count it all.
                    append(chunk[start...], to: &buffer, limit: maxLineBytes, truncated: &truncated)
                    consumed += chunk.distance(from: start, to: chunk.endIndex)
                    break
                }
                append(chunk[start..<newlineIndex], to: &buffer, limit: maxLineBytes, truncated: &truncated)
                consumed += chunk.distance(from: start, to: newlineIndex) + 1   // + the newline
                let keepGoing = handle(buffer, consumed, truncated)
                buffer.removeAll(keepingCapacity: true)
                consumed = 0
                truncated = false
                if !keepGoing { return true }
                start = newlineIndex + 1
            }
        }

        // A trailing line with no final newline (the live transcript is being
        // appended to) is still a complete record to try to parse.
        if consumed > 0 {
            _ = handle(buffer, consumed, truncated)
        }
        return true
    }

    /// Append `bytes` to `buffer` up to `limit`, flagging the overflow. Bytes
    /// past the limit are dropped here rather than buffered, which is the whole
    /// point of the limit.
    private static func append(
        _ bytes: Data.SubSequence,
        to buffer: inout Data,
        limit: Int,
        truncated: inout Bool
    ) {
        let room = limit - buffer.count
        if bytes.count <= room {
            buffer.append(contentsOf: bytes)
            return
        }
        truncated = true
        if room > 0 {
            buffer.append(contentsOf: bytes.prefix(room))
        }
    }
}

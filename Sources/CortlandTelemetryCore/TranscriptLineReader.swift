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
enum TranscriptLineReader {
    private static let chunkSize = 1 << 16   // 64 KiB
    private static let newline = UInt8(0x0A)

    /// Invokes `handle` with the raw bytes of each line (newline excluded), in
    /// order. `handle` is non-escaping and called synchronously, so callers can
    /// mutate captured state directly. Returns false if the file can't be opened.
    static func forEachLine(inFileAt path: String, _ handle: (Data) -> Void) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }

        var buffer = Data()
        while let chunk = try? file.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)

            // Emit every complete line in the buffer, then drop them in a single
            // compaction so we never repeatedly shift the whole buffer.
            var lineStart = buffer.startIndex
            while let newlineIndex = buffer[lineStart...].firstIndex(of: newline) {
                handle(buffer.subdata(in: lineStart..<newlineIndex))
                lineStart = newlineIndex + 1
            }
            if lineStart != buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }

        // A trailing line with no final newline (the live transcript is being
        // appended to) is still a complete record to try to parse.
        if !buffer.isEmpty {
            handle(buffer)
        }
        return true
    }
}

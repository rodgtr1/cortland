import Foundation

/// The append-only file behind `Log`, with one generation of rotation.
///
/// Split out from `Log` so it can be pointed at a temp directory with a small cap
/// in tests; the app holds a single instance aimed at
/// ~/Library/Logs/Cortland/Cortland.log.
///
/// Not internally synchronised: every method must be called from one serial queue
/// (Log's), and that is what makes the handle and the byte counter safe to touch.
/// `@unchecked Sendable` records exactly that bargain — a FileHandle isn't
/// Sendable, and the counter is plain mutable state.
nonisolated final class RotatingLogFile: @unchecked Sendable {
    let fileURL: URL
    /// Rotating past this size keeps the log bounded at roughly 2x the cap on
    /// disk (the live file plus one previous generation).
    let cap: Int

    /// The previous generation. Exactly one is kept: this is a debugging aid you
    /// `tail`, not an audit trail.
    var rotatedURL: URL { fileURL.appendingPathExtension("1") }

    private var handle: FileHandle?
    /// Bytes in the open file, seeded from its size when the handle is opened, so
    /// the size cap costs no stat per record.
    private var bytesWritten = 0
    private var recordsSinceExistenceCheck = 0

    /// How often the path is re-checked for having been deleted or moved out from
    /// under the open handle. Writes to an unlinked file succeed silently and go
    /// nowhere, but checking on every record would restore the per-record stat the
    /// kept-open handle exists to avoid. So a bounded handful of records can be
    /// lost after someone clears the log by hand, and no more.
    private let existenceCheckInterval: Int

    init(fileURL: URL, cap: Int = Limits.maxLogFileSize, existenceCheckInterval: Int = 256) {
        self.fileURL = fileURL
        self.cap = cap
        self.existenceCheckInterval = existenceCheckInterval
    }

    deinit {
        try? handle?.close()
    }

    /// Whether this record would push the file past the cap. Pure so the
    /// threshold is testable without writing megabytes of logs.
    static func shouldRotate(bytesWritten: Int, incoming: Int, cap: Int) -> Bool {
        bytesWritten + incoming > cap
    }

    func append(_ data: Data) {
        recordsSinceExistenceCheck += 1
        if recordsSinceExistenceCheck >= existenceCheckInterval {
            recordsSinceExistenceCheck = 0
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                close() // Reopening below recreates the file.
            }
        }

        // Open *before* deciding to rotate: opening is what seeds the byte
        // counter from the file's current size, and a log inherited from a
        // previous launch can already be over the cap. Deciding first would read
        // a counter of zero and let that file grow by another whole cap.
        guard openHandle() != nil else { return }

        if Self.shouldRotate(bytesWritten: bytesWritten, incoming: data.count, cap: cap) {
            rotate()
        }

        guard let handle = openHandle() else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            // The descriptor went bad (the file was replaced, the volume went
            // away). Drop it so the next record reopens. There is nowhere to
            // report this — this *is* the reporting path.
            close()
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    /// Moves the log aside, replacing any previous generation. The next append
    /// reopens, which recreates the live file.
    private func rotate() {
        close()

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: rotatedURL)
        try? fileManager.moveItem(at: fileURL, to: rotatedURL)
        bytesWritten = 0
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            // The directory goes too when someone clears ~/Library/Logs/Cortland.
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        // Seed the counter from the file being appended to, so a log inherited
        // from a previous launch rotates at the cap rather than at the cap plus
        // whatever was already there.
        bytesWritten = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
        return opened
    }
}

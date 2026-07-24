import Foundation
import os

/// Lightweight app logger. Writes to the unified logging system (visible in
/// Console.app, filter by subsystem `app.cortland.terminal`) and appends to a
/// plain-text file you can `tail`:
///
///     tail -f ~/Library/Logs/Cortland/Cortland.log
///
/// Use this instead of `print()` so messages survive when the packaged `.app`
/// is launched (stdout is discarded there).
///
/// `nonisolated`: the logger is called from every thread (background git work,
/// the IPC accept loop, PTY callbacks), so it must not inherit the module's
/// default main-actor isolation. All state here is immutable and the file write
/// is funnelled through a private serial queue.
nonisolated enum Log {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case error = "ERROR"

        /// Higher is louder; `Log.level` is the quietest record still written.
        var severity: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .error: return 2
            }
        }
    }

    private static let subsystem = "app.cortland.terminal"
    private static let osLog = os.Logger(subsystem: subsystem, category: "app")

    /// The minimum level that gets recorded: `CORTLAND_LOG_LEVEL=debug|info|error`,
    /// defaulting to everything in a debug build and to info in a shipped one, so
    /// the packaged app stops writing per-callback chatter to disk forever.
    ///
    /// An environment variable rather than a `[behavior]` key in config.toml:
    /// Log is deliberately `nonisolated` (see the type comment) while Config
    /// loads on the main actor, so reading a config knob here would either drag
    /// the logger onto the main actor or need a lock around a mutable level —
    /// too much machinery for a switch that only ever gets flipped while
    /// debugging. Read once, immutable thereafter, so it stays thread-safe.
    static let level: Level = {
        let raw = ProcessInfo.processInfo.environment["CORTLAND_LOG_LEVEL"] ?? ""
        if let configured = Level(rawValue: raw.uppercased()) { return configured }
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }()

    /// ~/Library/Logs/Cortland/Cortland.log
    static let fileURL: URL = {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Cortland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Cortland.log")
    }()

    private static let queue = DispatchQueue(label: "\(subsystem).log")

    /// Touched only from `queue`, which is serial: the queue is the lock this
    /// type documents needing.
    private static let file = RotatingLogFile(fileURL: fileURL)

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ message: @autoclosure () -> String, category: String = "app") {
        guard shouldLog(.debug) else { return }
        write(.debug, message(), category: category)
    }

    static func info(_ message: @autoclosure () -> String, category: String = "app") {
        guard shouldLog(.info) else { return }
        write(.info, message(), category: category)
    }

    static func error(_ message: @autoclosure () -> String, category: String = "app") {
        guard shouldLog(.error) else { return }
        write(.error, message(), category: category)
    }

    /// Pure so the gate is testable without touching the process environment.
    static func shouldLog(_ level: Level, minimum: Level = Log.level) -> Bool {
        level.severity >= minimum.severity
    }

    private static func write(_ level: Level, _ message: String, category: String) {
        switch level {
        case .debug: osLog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info: osLog.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: osLog.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }

        let line = "\(timestampFormatter.string(from: Date())) [\(level.rawValue)] [\(category)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            file.append(data)
        }
    }
}

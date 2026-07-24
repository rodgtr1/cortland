import Foundation

/// Logging for Pro code, routed back into the app's own log file.
///
/// The app owns `Log` (levels, categories, rotation, the file under
/// ~/Library/Logs/Cortland); rather than give the Pro package a view of it,
/// the app installs a sink here at launch. Unwired — in a free build, or in a
/// unit test — every call is a no-op, so nothing is lost and nothing is
/// printed.
/// `nonisolated` because the callers aren't: the cost history is written from a
/// closing tab on the main actor, but the session parsers and file helpers run
/// off it. Set once at launch, before anything Pro exists to log — the same
/// shape as the app's own `Log`.
public nonisolated enum ProLog {
    public enum Level: String, Sendable {
        case debug, info, error
    }

    nonisolated(unsafe) public static var sink: (@Sendable (Level, String, String) -> Void)?

    public static func debug(_ message: String, category: String) {
        sink?(.debug, message, category)
    }

    public static func info(_ message: String, category: String) {
        sink?(.info, message, category)
    }

    public static func error(_ message: String, category: String) {
        sink?(.error, message, category)
    }
}

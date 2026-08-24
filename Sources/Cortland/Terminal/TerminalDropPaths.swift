import Foundation

/// Turns paths dropped onto a terminal pane into the text typed at its prompt.
///
/// Single quotes are the only shell quoting that leaves everything else in a
/// path literal (spaces, `$`, backslashes, globs), so every path is wrapped in
/// them. A single quote inside the path can't be escaped while quoted, so it's
/// spliced in the standard way: close the quote, emit `\'`, reopen.
nonisolated enum TerminalDropPaths {
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Paths in pasteboard order, one space apart, ready to send to the PTY.
    static func typedText(for paths: [String]) -> String {
        paths.map(quoted).joined(separator: " ")
    }
}

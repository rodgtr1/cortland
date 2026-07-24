import Foundation

/// Detects a dev server coming up in terminal output — either a printed
/// localhost URL or a "listening on port N" line — and dedups so the same
/// URL is only offered once. The banner UI itself stays in the view
/// controller; this is just the detection.
nonisolated struct ServerBannerDetector {
    private static let serverURLRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "https?://(?:localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0)(?::\\d{2,5})?(?:/[A-Za-z0-9_\\-./?#=&%]*)?"
    )
    private static let listeningPortRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?i)listening on (?:port )?(?:[a-z.*]*:)?(\\d{2,5})\\b"
    )

    private var lastOfferedURL: URL?

    /// Returns a newly detected server URL worth offering, or nil when the
    /// chunk has none (or repeats the last offer).
    mutating func detectServerURL(in output: String) -> URL? {
        // Cheap pre-check before the ANSI strip + two regex passes, which otherwise
        // ran on every ~10Hz flush for the life of the pane. Both matchers require
        // one of these literals (serverURLRegex needs "http", listeningPortRegex
        // needs "listening on"), so a chunk without either can't match.
        guard output.range(of: "http", options: .caseInsensitive) != nil
            || output.range(of: "listening on", options: .caseInsensitive) != nil else { return nil }

        // Strip ANSI codes but keep case (URL paths are case-sensitive).
        let text = TerminalText.stripANSIEscapes(output)

        var url: URL?
        if let regex = Self.serverURLRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let matchRange = Range(match.range, in: text) {
                url = URL(string: Self.normalizeLocalURLString(String(text[matchRange])))
            }
        }
        if url == nil, let regex = Self.listeningPortRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let portRange = Range(match.range(at: 1), in: text),
               let port = Int(text[portRange]), port >= 80 {
                url = URL(string: "http://localhost:\(port)/")
            }
        }

        guard let serverURL = url, serverURL != lastOfferedURL else { return nil }
        lastOfferedURL = serverURL
        return serverURL
    }

    static func normalizeLocalURLString(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "0.0.0.0", with: "localhost")
            .replacingOccurrences(of: "127.0.0.1", with: "localhost")
    }
}

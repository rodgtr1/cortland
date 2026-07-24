import Foundation

/// Presentation helpers for telemetry — kept in the core (not the view) so they
/// are unit-testable and reusable across surfaces (dashboard, event stream, …).
public enum TelemetryFormat {
    /// `claude-opus-4-8` → `opus-4.8`. Drops the `claude-` prefix and a trailing
    /// date snapshot, and renders version dashes between digits as dots.
    public static func shortModel(_ model: String) -> String {
        var s = model
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        s = s.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d)-(\d)"#, with: "$1.$2", options: .regularExpression)
        return s
    }

    /// `1_234` → `1k`, `1_500_000` → `1.5M`. Whole-number `k` keeps the token
    /// dashboard clean; the `M` range carries one decimal where it matters.
    public static func compactTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }

    /// USD with a `<$0.01` floor so tiny (but nonzero) spends don't render as
    /// `$0.00`. A genuinely zero/free session still shows `$0.00`.
    public static func cost(_ usd: Double) -> String {
        if usd <= 0 { return "$0.00" }
        return usd < 0.01 ? "<$0.01" : String(format: "$%.2f", usd)
    }
}

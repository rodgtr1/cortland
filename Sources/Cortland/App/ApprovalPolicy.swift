import Foundation

/// How long a user-granted "approve & remember" allowance lasts. Every scope
/// is session-only (cleared on relaunch), matching the Auto-approve Agent Edits
/// menu toggle — nothing here is persisted to disk.
nonisolated enum RememberScope: String {
    case none       // Just this once
    case file       // This exact file, rest of session
    case folder     // This folder and everything under it, rest of session
    case session    // Every edit, rest of session (same as the menu toggle)
}

/// The outcome of a diff-approval sheet: whether the edit was accepted, and
/// whether the user asked to remember the decision for similar future edits.
nonisolated struct ApprovalOutcome {
    let accepted: Bool
    let remember: RememberScope

    static let rejected = ApprovalOutcome(accepted: false, remember: .none)
}

/// Session-scoped allowances the user granted through "approve & remember".
/// In-memory only; relaunch resets it.
nonisolated struct SessionApprovals {
    var sessionWide = false
    private(set) var files: Set<String> = []
    private(set) var folders: [String] = []

    mutating func record(_ scope: RememberScope, path: String) {
        let canonicalPath = ApprovalPolicy.canonical(path)
        switch scope {
        case .none:
            break
        case .file:
            files.insert(canonicalPath)
        case .folder:
            folders.append((canonicalPath as NSString).deletingLastPathComponent)
        case .session:
            sessionWide = true
        }
    }

    func allows(_ path: String) -> Bool {
        if sessionWide { return true }
        let canonicalPath = ApprovalPolicy.canonical(path)
        if files.contains(canonicalPath) { return true }
        return folders.contains { folder in
            canonicalPath == folder || canonicalPath.hasPrefix(folder + "/")
        }
    }
}

/// Decides whether an agent edit to a given path is approved silently or needs
/// the review sheet. Precedence, highest first:
///   1. `always_ask` globs — always prompt. A security override: an entry like
///      `.env` keeps prompting even in auto mode, after a "remember" grant, or
///      inside a worktree-scoped auto-approve root.
///   2. session "approve & remember" allowances.
///   3. worktree-scoped auto-approve — when enabled and the pane sits in a
///      registered worktree, edits INSIDE that worktree root approve silently.
///   4. `auto_allow` globs — silent approve even while the global mode is "ask".
///   5. global auto toggle — the `[approval] mode` config plus the menu toggle.
nonisolated enum ApprovalPolicy {
    enum Decision { case ask, allow }

    static func decide(
        path: String,
        globalAuto: Bool,
        autoAllow: [String],
        alwaysAsk: [String],
        session: SessionApprovals,
        workingRoot: String? = nil,
        worktreeAutoApprove: Bool = false
    ) -> Decision {
        let canonicalPath = canonical(path)
        // always_ask is the security override, so it fails CLOSED: a pattern
        // that can't compile still forces a prompt rather than silently
        // dropping protection for that rule. Checked FIRST so it also wins over
        // worktree-scoped auto-approve — an `.env` rule keeps prompting inside a
        // worktree just as it does everywhere else.
        for pattern in alwaysAsk {
            switch globMatch(pattern, canonicalPath: canonicalPath) {
            case .match:
                return .ask
            case .invalid:
                Log.error("always_ask pattern failed to compile, forcing prompt: \(pattern)", category: "approval")
                return .ask
            case .noMatch:
                continue
            }
        }
        if session.allows(canonicalPath) { return .allow }
        // Worktree-scoped auto-approve: only paths that actually live inside the
        // pane's worktree root approve. An edit to an absolute path outside it
        // (the main checkout, another worktree, anything global) falls through
        // and prompts as usual. Both operands are canonicalized so symlinks and
        // `..` traversal can't smuggle a path across the boundary.
        if worktreeAutoApprove, let workingRoot,
           isPath(canonicalPath, withinRoot: canonical(workingRoot)) {
            return .allow
        }
        // auto_allow grants silent approval, so it fails the other way: an
        // over-broad pattern (matches every path) or one that can't compile is
        // ignored — a typo must never become a blanket auto-approve.
        for pattern in autoAllow {
            if isOverBroad(pattern) {
                Log.error("ignoring over-broad auto_allow pattern: \(pattern)", category: "approval")
                continue
            }
            if globMatch(pattern, canonicalPath: canonicalPath) == .match { return .allow }
        }
        return globalAuto ? .allow : .ask
    }

    /// True when an `auto_allow` glob would match essentially every path. Such a
    /// pattern is rejected so a typo can't silently auto-approve the whole tree.
    ///
    /// Inspecting the compiled regex body misses catch-alls whose body isn't
    /// literally `.*`: `*` compiles to `(^|/)[^/]*$`, `/**` to `^/.*$`, and
    /// `**/*` to `(^|/).*[^/]*$` — each matches every path. Instead, probe the
    /// matcher with a set of maximally dissimilar absolute paths; anything that
    /// matches all of them is a blanket allow, not a selective allow-list entry.
    static func isOverBroad(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        let probes = [
            "/a",
            "/z/y/x/w.txt",
            "/Users/nobody/.env",
            "/etc/hosts",
        ]
        return probes.allSatisfy { globMatch(trimmed, canonicalPath: $0) == .match }
    }

    /// True when `path` is `root` itself or lives inside it. Both arguments must
    /// already be canonical. The check is path-component-based, not a raw string
    /// prefix: `root` gets a trailing `/` before the prefix test, so a sibling
    /// whose name merely starts with `root`'s last segment — `/wt/n3-foobar`
    /// against root `/wt/n3-foo` — is correctly treated as OUTSIDE.
    static func isPath(_ path: String, withinRoot root: String) -> Bool {
        if path == root { return true }
        let boundary = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(boundary)
    }

    /// Canonicalizes a path for matching: expands `~`, resolves symlinks, and
    /// collapses `.`/`..`. Defense in depth — the IPC layer already canonicalizes
    /// diff paths, but the policy must not trust its caller to have done so.
    static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Glob match supporting `**` (spans `/`), `*` (within a single path
    /// segment), and `?`. A pattern with a leading `/` or `~` is anchored to
    /// the full path; otherwise it matches anywhere in the tree on a `/`
    /// boundary, so `Sources/**` matches `/repo/Sources/x.swift` and `.env`
    /// matches `/repo/.env`.
    static func glob(_ pattern: String, matches path: String) -> Bool {
        globMatch(pattern, canonicalPath: canonical(path)) == .match
    }

    /// Outcome of matching one glob. `.invalid` (the pattern failed to compile)
    /// is distinct from `.noMatch` so the caller can choose its fail-safe
    /// direction — `always_ask` treats it as a match, `auto_allow` ignores it.
    enum GlobResult { case match, noMatch, invalid }

    /// Matches a glob against an already-canonical path.
    static func globMatch(_ pattern: String, canonicalPath path: String) -> GlobResult {
        guard !pattern.isEmpty else { return .noMatch }
        let expandedPattern = (pattern as NSString).expandingTildeInPath
        let anchored = expandedPattern.hasPrefix("/")
        let body = regexBody(expandedPattern)
        let prefix = anchored ? "^" : "(^|/)"
        // Case-insensitive: the default macOS filesystem (APFS/HFS+) is
        // case-insensitive, so `.ENV` and `.env` are the same file. Matching
        // case-sensitively would let an agent bypass an `always_ask` rule by
        // reporting a differently-cased path for the same on-disk file.
        guard let regex = try? NSRegularExpression(pattern: prefix + body + "$", options: [.caseInsensitive]) else {
            return .invalid
        }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil ? .match : .noMatch
    }

    /// Translates a glob into a regex fragment (no anchors).
    private static func regexBody(_ pattern: String) -> String {
        var result = ""
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    // `**` only spans path separators when it's a whole segment
                    // (bounded by `/` or the string ends). A non-segment double
                    // star like `foo**bar` collapses to a single within-segment
                    // wildcard so it can't silently widen into a cross-dir `.*`.
                    let prevIsBoundary = (i == 0) || (chars[i - 1] == "/")
                    let afterIndex = i + 2
                    let nextIsBoundary = afterIndex >= chars.count || chars[afterIndex] == "/"
                    if prevIsBoundary && nextIsBoundary {
                        result += ".*"          // ** spans path separators
                        i = afterIndex
                        if i < chars.count && chars[i] == "/" { i += 1 }  // swallow the trailing slash
                        continue
                    }
                    result += "[^/]*"
                    i += 2
                    continue
                }
                result += "[^/]*"           // * stays within one segment
            case "?":
                result += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                result += "\\" + String(c)
            default:
                result += String(c)
            }
            i += 1
        }
        return result
    }
}

import Foundation

/// Produces unified-diff text for a proposed edit, for rendering through
/// `InlineDiffRenderer`. Extracted from the retired modal approval sheet; the
/// agents panel's approvals queue renders the same diff inline.
nonisolated enum UnifiedDiff {
    /// Diffs two strings with /usr/bin/diff. Falls back to a whole-file
    /// remove/add diff if that fails.
    static func text(old: String, new: String, path: String) -> String {
        let temp = FileManager.default.temporaryDirectory
        let oldURL = temp.appendingPathComponent("cortland-diff-old-\(UUID().uuidString)")
        let newURL = temp.appendingPathComponent("cortland-diff-new-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
        }

        let fileName = (path as NSString).lastPathComponent
        do {
            try old.write(to: oldURL, atomically: true, encoding: .utf8)
            try new.write(to: newURL, atomically: true, encoding: .utf8)

            let result = try ProcessRunner.shared.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/diff"),
                arguments: ["-u", oldURL.path, newURL.path]
            )

            // diff exits 1 when files differ — that's the expected case.
            if result.terminationStatus <= 1 {
                var output = result.stdout
                    .replacingOccurrences(of: oldURL.path, with: "a/\(fileName)")
                    .replacingOccurrences(of: newURL.path, with: "b/\(fileName)")
                if output.isEmpty {
                    output = "--- a/\(fileName)\n+++ b/\(fileName)\n(no changes)\n"
                }
                return output
            }
        } catch {
            Log.error("UnifiedDiff: diff failed: \(error)", category: "editor")
        }

        // Fallback: whole-file replacement view.
        var lines = ["--- a/\(fileName)", "+++ b/\(fileName)"]
        lines.append("@@ -1 +1 @@")
        lines.append(contentsOf: old.split(separator: "\n", omittingEmptySubsequences: false).map { "-\($0)" })
        lines.append(contentsOf: new.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" })
        return lines.joined(separator: "\n")
    }
}

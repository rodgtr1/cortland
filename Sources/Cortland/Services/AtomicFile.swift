import Foundation

/// Replacing a file that something else may be reading — or executing — at the
/// very moment we write it.
///
/// Used by the launch-time self-heal paths (`InstalledHelperRefresher`,
/// `InstalledSkillRefresher`), which rewrite files that a hook or an agent can
/// pick up at any instant.
nonisolated enum AtomicFile {
    /// Replaces `destination` with `data` in one step.
    ///
    /// The new bytes land in a temp file *in the same directory* (same
    /// filesystem, so the rename can't fall back to a copy), get their
    /// permissions before they are reachable under the real name, and only then
    /// take the name via `rename(2)`. A reader that opens the path during the
    /// swap sees either the whole old file or the whole new one; a half-written
    /// file is never reachable under the real name.
    static func replace(
        _ destination: URL,
        with data: Data,
        permissions: Int,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).new"
        )
        do {
            try data.write(to: temp, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            guard rename(temp.path, destination.path) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                )
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }
}

import Foundation

/// Carries a pre-rename `~/.config/sidekick` tree over to `~/.config/cortland`
/// the first time this build launches.
///
/// Everything the user owns lives in that one directory — config.toml, custom
/// themes, the arcade journals and almanacs — so the rename would otherwise read
/// as "the app forgot my settings and ate my writing". One directory copy on
/// launch is the whole migration.
///
/// It copies rather than moves, and only when the new directory is absent, so
/// running an older build afterwards still finds its own files where it left
/// them. That also makes it self-disarming: once `~/.config/cortland` exists,
/// every later launch returns before touching the disk.
///
/// `nonisolated`: file IO with no UI state.
nonisolated enum ConfigMigration {
    /// Where the app kept its files when it was called Sidekick.
    static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sidekick", isDirectory: true)
    }

    static var currentDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland", isDirectory: true)
    }

    /// Must run before anything else reads or writes under `~/.config/cortland`
    /// — the first component to create that directory (the shell-integration
    /// refresh, a config save) would make the copy look already done.
    ///
    /// Copies entry by entry rather than handing the whole directory to
    /// `copyItem`, because a single unsupported entry fails that call outright
    /// and still leaves the destination directory behind — which would disarm
    /// this on every later launch, having copied nothing. The IPC socket is
    /// exactly such an entry, and it is sitting in the directory of everyone who
    /// has ever run the app. It is skipped by file type: a socket is bound at
    /// startup, never carried over.
    ///
    /// Returns whether anything was copied. Failure is not fatal: the app falls
    /// back to defaults, which is what a fresh install gets anyway.
    @discardableResult
    static func migrateIfNeeded(
        from legacy: URL = legacyDirectory,
        to current: URL = currentDirectory
    ) -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: current.path) else { return false }
        guard isDirectory(legacy) else { return false }

        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: legacy.path)
            try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        } catch {
            Log.error(
                "Config migration: could not prepare \(current.path): \(error.localizedDescription). "
                    + "Starting from defaults.",
                category: "config"
            )
            return false
        }

        var copied = 0
        for entry in entries {
            let source = legacy.appendingPathComponent(entry)
            guard fileType(of: source) != .typeSocket else { continue }
            do {
                // Symlinks copy as symlinks (a config.toml pointing into a
                // dotfiles repo keeps pointing there, and both directories sit
                // at the same depth so a relative link still resolves).
                try fileManager.copyItem(at: source, to: current.appendingPathComponent(entry))
                copied += 1
            } catch {
                Log.error(
                    "Config migration: could not copy \(entry): \(error.localizedDescription)",
                    category: "config"
                )
            }
        }

        Log.info(
            "Config migration: copied \(copied) item(s) from \(legacy.path) to \(current.path) "
                + "(the old directory is left in place)",
            category: "config"
        )
        return copied > 0
    }

    /// `lstat`-based, so a symlink reports as one instead of as its target.
    private static func fileType(of url: URL) -> FileAttributeType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

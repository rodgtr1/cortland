import Foundation

/// Keeps the helper binaries in `~/.local/bin` in step with the app that is
/// running, refreshing them on launch.
///
/// `scripts/install-agent-status-hooks` builds `cortland-agent-status` and
/// `cortland-mcp`, copies them into `~/.local/bin`, and writes hook entries in
/// `~/.claude/settings.json` and `~/.codex/config.toml` that name those copies by
/// absolute path. It is a one-time setup: upgrading the app never touched them.
/// So a machine could run a current Cortland against helpers from weeks ago, and
/// every failure mode in that path is silent by design — a hook must never
/// disrupt the agent, so a helper that can't reach the app just exits 0 and the
/// pane sits there looking idle. That is exactly how the 316e143 fix (report over
/// the socket when the hook has no tty) would have failed to reach anyone.
///
/// This is the other half of `AgentStatusReport.protocolVersion`: the handshake
/// makes a stale helper *visible*, and this makes it *rare*.
nonisolated enum InstalledHelperRefresher {
    /// The helpers `scripts/install-agent-status-hooks` copies into `~/.local/bin`,
    /// and therefore the only files there we may touch.
    ///
    /// The bundle ships two more (`cortland-ctl`, `cortland-telemetry`), but the
    /// installer never puts them in `~/.local/bin` — `install.sh` symlinks
    /// `cortland-ctl` into `/usr/local/bin` instead, and a symlink is current by
    /// construction. A same-named file in `~/.local/bin` that our installer did
    /// not write is the user's, not ours.
    static let managedHelpers = ["cortland-agent-status", "cortland-mcp"]

    /// What happened to one helper. Reported rather than thrown so one bad file
    /// can't stop the others from being refreshed.
    enum Outcome: Equatable {
        /// Replaced with the bundled copy.
        case refreshed
        /// Byte-identical already.
        case upToDate
        /// The user never ran the installer. We do not create the file: an absent
        /// `~/.local/bin/<helper>` means they never opted into us managing that
        /// directory, and the app's own Preferences → Agents installer points its
        /// hooks straight at the bundle instead.
        case notInstalled
        /// This build doesn't ship the helper (a partial dev bundle).
        case notBundled
        /// The installed path is a symlink. `install -m 0755` writes a regular
        /// file, so a symlink is something the user set up by hand — following it
        /// would take us outside `~/.local/bin`, and replacing it would silently
        /// undo their choice.
        case skippedSymlink
        case failed(String)
    }

    // MARK: - Launch entry point

    /// Refreshes the installed helpers against this app's bundled ones. Returns
    /// immediately: the reads, the compares, and the replace all happen on a
    /// utility queue, because launch must not block on file IO (each helper is a
    /// few MB, and the comparison reads both copies).
    ///
    /// Skipped entirely unless we are running as an installed `.app` — see
    /// `isRunningFromAppBundle`.
    static func refreshOnLaunch() {
        guard isRunningFromAppBundle else {
            Log.debug("Helper refresh: skipped, not running from an app bundle", category: "app")
            return
        }
        guard let bundleDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
        let installDirectory = defaultInstallDirectory

        DispatchQueue.global(qos: .utility).async {
            let outcomes = refresh(bundleDirectory: bundleDirectory, installDirectory: installDirectory)
            for (helper, outcome) in outcomes.sorted(by: { $0.key < $1.key }) {
                switch outcome {
                case .refreshed:
                    Log.info("Helper refresh: replaced stale ~/.local/bin/\(helper) with this build's copy", category: "app")
                case .failed(let reason):
                    Log.error("Helper refresh: could not replace ~/.local/bin/\(helper): \(reason)", category: "app")
                case .upToDate, .notInstalled, .notBundled, .skippedSymlink:
                    Log.debug("Helper refresh: \(helper) — \(outcome)", category: "app")
                }
            }
        }
    }

    /// `~/.local/bin` — the directory `scripts/install-agent-status-hooks` writes to.
    static var defaultInstallDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// Whether this process is a launched `.app` rather than a `swift run` /
    /// DerivedData binary (whose `Bundle.main` is just the build directory).
    ///
    /// Dev builds deliberately do NOT self-heal. A source checkout is a moving
    /// target: `swift run` produces a debug binary, and a working tree sitting on
    /// a feature branch would overwrite the user's known-good `~/.local/bin` copy
    /// with whatever is half-finished on that branch — then flip it back on the
    /// next branch switch, with the hooks pointing at it the whole time. The
    /// from-source workflow already has an explicit, deliberate installer
    /// (`scripts/install-agent-status-hooks`) and that stays the way to update
    /// from source. An installed `.app` is something the user chose to install;
    /// its helpers are the ones its hooks should be running.
    static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - The refresh itself

    /// Brings each installed helper into line with the bundled copy of the same
    /// name. Directories are parameters so tests never go near the real
    /// `~/.local/bin`.
    @discardableResult
    static func refresh(
        bundleDirectory: URL,
        installDirectory: URL,
        helpers: [String] = managedHelpers,
        fileManager: FileManager = .default
    ) -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]
        for helper in helpers {
            outcomes[helper] = refresh(
                helper: helper,
                bundleDirectory: bundleDirectory,
                installDirectory: installDirectory,
                fileManager: fileManager
            )
        }
        return outcomes
    }

    private static func refresh(
        helper: String,
        bundleDirectory: URL,
        installDirectory: URL,
        fileManager: FileManager
    ) -> Outcome {
        let bundled = bundleDirectory.appendingPathComponent(helper)
        let installed = installDirectory.appendingPathComponent(helper)

        guard fileManager.fileExists(atPath: bundled.path) else { return .notBundled }
        // Never create it: absence is the user's answer.
        guard fileManager.fileExists(atPath: installed.path) else { return .notInstalled }
        guard !isSymbolicLink(installed, fileManager: fileManager) else { return .skippedSymlink }

        do {
            // Content, not timestamps. A helper is stale when it is not the one
            // this app ships, and *which way the clock points doesn't matter*:
            // the app that is launching is the source of truth for its own hook
            // protocol, so its bundled helper is by definition the right one to
            // be answering its socket — including when the user deliberately
            // downgrades to an older Cortland, where a "newer" installed helper
            // is precisely the thing to undo. Timestamps can't express that:
            // `install(1)` stamps a fresh mtime on a copy of an old binary, a
            // restored backup is newer than what it replaces, and a rebuild of
            // identical source moves the clock without changing a byte.
            let bundledData = try Data(contentsOf: bundled, options: .mappedIfSafe)
            let installedData = try Data(contentsOf: installed, options: .mappedIfSafe)
            guard bundledData != installedData else { return .upToDate }

            try replace(installed, with: bundledData, fileManager: fileManager)
            return .refreshed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Replaces `destination` with `data`, atomically and still executable.
    ///
    /// Atomicity is not a nicety here: a hook can fire at any moment — including
    /// while we are writing — and it execs this exact path. `AtomicFile.replace`
    /// renames the finished, 0755 file into place, so a hook that starts during
    /// the swap execs either the whole old binary or the whole new one; a
    /// half-written file is never on the path an agent might exec.
    private static func replace(_ destination: URL, with data: Data, fileManager: FileManager) throws {
        try AtomicFile.replace(destination, with: data, permissions: 0o755, fileManager: fileManager)
    }
}

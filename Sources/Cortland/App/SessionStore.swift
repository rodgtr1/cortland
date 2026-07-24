import Foundation

/// Snapshot of the open tabs/panes, persisted across launches.
nonisolated struct SessionPaneState: Codable, Equatable, Sendable {
    let type: String // "terminal"
    let cwd: String?
    let url: String?
}

nonisolated struct SessionTabState: Codable, Equatable, Sendable {
    let panes: [SessionPaneState]
    let activePaneIndex: Int
    let customTitle: String?
}

nonisolated struct SessionState: Codable, Equatable, Sendable {
    let tabs: [SessionTabState]
    let activeTabIndex: Int
}

enum SessionStore {
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/session.json")
    }

    static func save(_ state: SessionState, to fileURL: URL = defaultFileURL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("failed to save session: \(error)", category: "session")
        }
    }

    /// Nil means "nothing to restore": the file is absent, empty, or holds no
    /// tabs. A file that exists but cannot be read or decoded is a *broken*
    /// session, not a missing one — it is moved aside to session.json.bak first,
    /// so the 60s autosave can't destroy something recoverable. (Same intent as
    /// Config's config.toml.bak.)
    static func load(from fileURL: URL = defaultFileURL) -> SessionState? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Absent is the ordinary first-launch case and not worth reporting;
            // anything else is a file we can see but cannot read.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                Log.error("failed to read session: \(error)", category: "session")
                backUpBrokenFile(at: fileURL)
            }
            return nil
        }

        guard !data.isEmpty else { return nil }

        do {
            let state = try JSONDecoder().decode(SessionState.self, from: data)
            return state.tabs.isEmpty ? nil : state
        } catch {
            Log.error("failed to decode session: \(error)", category: "session")
            backUpBrokenFile(at: fileURL)
            return nil
        }
    }

    /// Renames the unusable session file aside, replacing any previous backup.
    /// Rename (not copy) so the next save writes a fresh file instead of
    /// overwriting the original.
    private static func backUpBrokenFile(at fileURL: URL) {
        let bakURL = fileURL.appendingPathExtension("bak")
        do {
            try? FileManager.default.removeItem(at: bakURL)
            try FileManager.default.moveItem(at: fileURL, to: bakURL)
            Log.error("moved unusable session to \(bakURL.path)", category: "session")
        } catch {
            Log.error("failed to back up unusable session: \(error)", category: "session")
        }
    }
}

import Foundation

/// One file an agent pane's current turn changed, as the Agents panel lists it.
nonisolated struct TurnChangedFile: Equatable, Sendable {
    let repositoryRoot: String
    /// Repository-relative.
    let path: String
    /// `.modified`, `.added`, or `.deleted`, as `changesSinceSnapshot` reports.
    let status: GitFileStatus

    var absolutePath: String {
        // Built the way the changes pane names its sections, so a click can
        // scroll to this file.
        URL(fileURLWithPath: repositoryRoot).appendingPathComponent(path).path
    }
}

/// What one pane's current turn changed, computed off the main thread.
nonisolated struct PaneTurnFiles: Equatable, Sendable {
    /// The checkout the pane is in; nil when it is not in a git repository.
    let repositoryRoot: String?
    let files: [TurnChangedFile]
    /// When the pane reached ready or done, so a file two panes changed
    /// follows the one that finished last.
    let finishedAt: Date
    /// The turn's `turnSnapshotRequestedAt` the list was computed for, so a
    /// result that lands after the next turn started is dropped.
    let turnStartedAt: Date?
}

/// The files each agent pane changed in its current turn, keyed by pane ID.
/// Plain values and pure updates; `AgentDashboardViewController` owns one,
/// fills it on `TurnSnapshotService.queue`, and reads it on reload.
nonisolated struct TurnChangedFilesStore: Equatable, Sendable {
    private(set) var entries: [UUID: PaneTurnFiles] = [:]

    /// What a pane's agent state change does to its entry.
    enum Update: Equatable {
        /// The turn paused or ended: compute the files again.
        case recompute
        /// A turn started (its files are not known until it stops), or the
        /// agent went idle: drop the entry.
        case remove
        case none
    }

    static func update(from previous: AgentState, to next: AgentState) -> Update {
        switch next {
        case .idle:
            return .remove
        case .working:
            return previous == .done || previous == .idle ? .remove : .none
        case .ready, .done:
            return .recompute
        }
    }

    mutating func remove(paneID: UUID) {
        entries[paneID] = nil
    }

    /// Stores a computed list, unless the pane moved on while it ran: it is
    /// no longer ready or done, or a later turn has started since.
    mutating func land(_ result: PaneTurnFiles, paneID: UUID, currentState: AgentState, currentTurnStartedAt: Date?) {
        guard currentState == .ready || currentState == .done,
              currentTurnStartedAt == result.turnStartedAt else { return }
        entries[paneID] = result
    }

    /// Drops entries for panes that no longer exist.
    mutating func keepOnly(paneIDs: Set<UUID>) {
        entries = entries.filter { paneIDs.contains($0.key) }
    }

    /// The files `paneID`'s current turn changed: the working tree against
    /// the snapshot that turn took (`TurnSnapshotService.currentTurnSnapshot`).
    /// No snapshot for the turn, or no repository, means no files. Runs git;
    /// call it on `TurnSnapshotService.queue`.
    static func compute(
        paneID: UUID,
        workingDirectory: String,
        turnStartedAt: Date?,
        finishedAt: Date,
        service: TurnSnapshotService = .shared
    ) -> PaneTurnFiles {
        guard let root = GitService().repositoryRoot(from: workingDirectory) else {
            return PaneTurnFiles(repositoryRoot: nil, files: [], finishedAt: finishedAt, turnStartedAt: turnStartedAt)
        }
        var files: [TurnChangedFile] = []
        if let snapshot = TurnSnapshotService.currentTurnSnapshot(
            turnStartedAt: turnStartedAt,
            paneSnapshots: (try? service.list(repositoryRoot: root, paneID: paneID)) ?? []
        ) {
            files = ((try? service.changesSinceSnapshot(commit: snapshot.commit, repositoryRoot: root)) ?? []).map {
                TurnChangedFile(repositoryRoot: root, path: $0.path, status: $0.status)
            }
        }
        return PaneTurnFiles(repositoryRoot: root, files: files, finishedAt: finishedAt, turnStartedAt: turnStartedAt)
    }
}

/// The "N files changed" line of one Agents panel row.
nonisolated struct AgentRowFiles: Equatable, Sendable {
    /// How many files the tab's agents changed this turn; 0 for no line.
    let count: Int
    /// The pane and checkout the line opens: the pane that finished last.
    let paneID: UUID?
    let repositoryRoot: String?

    static let empty = AgentRowFiles(count: 0, paneID: nil, repositoryRoot: nil)

    var lineCount: Int { count > 0 ? 1 : 0 }

    /// Counts the union of `paneIDs`' files in `store`, each absolute path
    /// once.
    static func make(paneIDs: [UUID], store: TurnChangedFilesStore) -> AgentRowFiles {
        let panes = paneIDs.compactMap { id in store.entries[id].map { (id: id, entry: $0) } }
            .filter { !$0.entry.files.isEmpty }
        guard !panes.isEmpty else { return .empty }

        let paths = Set(panes.flatMap { $0.entry.files.map(\.absolutePath) })
        let latest = panes.max { $0.entry.finishedAt < $1.entry.finishedAt }
        return AgentRowFiles(count: paths.count, paneID: latest?.id, repositoryRoot: latest?.entry.repositoryRoot)
    }
}

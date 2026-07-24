import Cocoa

/// The window operations the worktrees panel needs from MainWindowController:
/// the active pane's directory (to resolve the repo root), the tab list (to
/// focus an existing checkout), and the tab create/switch + panel-refresh
/// hooks. MainWindowController owns the window chrome; `WorktreeFlowController`
/// owns the worktree create/remove/open flows behind this seam — the same
/// host-protocol split as `TabHost`/`TabController`.
@MainActor
protocol WorktreeFlowHost: AnyObject {
    /// Window worktree error sheets attach to.
    var worktreeWindow: NSWindow? { get }
    /// The open tabs, searched to focus a pane already sitting in a checkout.
    var worktreeTabs: [TabModel] { get }
    /// Working directory of the active pane, used to resolve the repo root.
    func worktreeWorkingDirectory() -> String?
    func worktreeSwitchToTab(index: Int)
    @discardableResult
    func worktreeCreateTab(workingDirectory: String?, command: [String]?) -> Bool
    /// Rebuild the worktrees panel after a create/remove.
    func worktreeRefreshPanel()
}

/// Owns the worktrees-panel flows — resolving the active repo root, opening or
/// focusing a checkout, and creating/removing worktrees (each shells out to git
/// off the main thread, then updates panes and surfaces failures). Extracted
/// from MainWindowController, which keeps the window chrome behind
/// `WorktreeFlowHost` and forwards the `SidebarContainerDelegate` calls here.
@MainActor
final class WorktreeFlowController {
    private weak var host: WorktreeFlowHost?

    init(host: WorktreeFlowHost) {
        self.host = host
    }

    func activeRepoRoot() -> String? {
        guard let cwd = host?.worktreeWorkingDirectory() else { return nil }
        // Cached: the worktrees panel asks for this on every refresh, and an
        // uncached `git rev-parse` per call stalled the main thread.
        return WorkspaceResolver.cachedGitRoot(from: cwd)
    }

    func openWorktree(path: String) {
        guard let host else { return }
        // Focus an existing pane in that checkout if there is one; else open a
        // fresh terminal there.
        if let index = host.worktreeTabs.firstIndex(where: { tab in
            tab.panes.contains { Self.path($0.resolvedWorkingDirectory(), isWithin: path) }
        }) {
            host.worktreeSwitchToTab(index: index)
        } else {
            host.worktreeCreateTab(workingDirectory: path, command: nil)
        }
    }

    func createWorktree(branch: String, agent: WorktreeAgent) {
        guard let repoRoot = activeRepoRoot() else {
            presentWorktreeError("Worktrees need a pane inside a git repository.")
            return
        }
        // Creating the worktree shells out to git (checks out files); do it off
        // the main thread, then open the pane on the resulting directory.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try WorktreeService().ensureWorktree(forBranch: branch, directory: repoRoot) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let path):
                    self.host?.worktreeCreateTab(workingDirectory: path, command: agent.argv)
                    self.host?.worktreeRefreshPanel()
                case .failure(let error):
                    self.presentWorktreeError(Self.worktreeErrorMessage(error))
                }
            }
        }
    }

    func removeWorktree(branch: String, force: Bool) {
        guard let repoRoot = activeRepoRoot() else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try WorktreeService().removeWorktree(forBranch: branch, directory: repoRoot, force: force) }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result {
                    self.presentWorktreeError(Self.worktreeErrorMessage(error))
                }
                self.host?.worktreeRefreshPanel()
            }
        }
    }

    func mergeWorktree(branch: String) {
        guard let repoRoot = activeRepoRoot() else {
            presentWorktreeError("Worktrees need a pane inside a git repository.")
            return
        }
        // Merging shells out to git in the primary checkout (dirty check, merge,
        // conflict abort); do it off the main thread, then refresh and surface
        // any failure — the guard/abort logic lives in WorktreeService.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try WorktreeService().mergeBranch(branch, intoPrimaryFrom: repoRoot) }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result {
                    self.presentWorktreeError(Self.worktreeErrorMessage(error))
                }
                self.host?.worktreeRefreshPanel()
            }
        }
    }

    /// True when `candidate` is the worktree `path` or lives inside it.
    private static func path(_ candidate: String?, isWithin path: String) -> Bool {
        guard let candidate else { return false }
        let base = URL(fileURLWithPath: path).standardizedFileURL.path
        let other = URL(fileURLWithPath: candidate).standardizedFileURL.path
        return other == base || other.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private func presentWorktreeError(_ message: String) {
        guard let window = host?.worktreeWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Worktree"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private static func worktreeErrorMessage(_ error: Error) -> String {
        switch error {
        case WorktreeService.WorktreeError.notAGitRepository:
            return "Not a git repository — worktree commands need a directory inside one."
        case WorktreeService.WorktreeError.noWorktreeForBranch(let branch):
            return "No worktree registered for branch '\(branch)'."
        case WorktreeService.WorktreeError.primaryHasUncommittedChanges:
            return "The primary checkout has uncommitted changes. Commit or stash them before merging, so the merge can't discard local work."
        case WorktreeService.WorktreeError.gitFailed(let message):
            return "git worktree failed: \(message)"
        default:
            return "Worktree operation failed: \(error.localizedDescription)"
        }
    }
}

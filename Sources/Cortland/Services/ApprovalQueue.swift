import Foundation

/// One agent edit awaiting review: the hook's proposed old/new content for
/// `path`, the pane the edit hook ran in, and when it arrived.
struct PendingApproval {
    let id: UUID
    let paneID: UUID?
    let path: String
    let old: String
    let new: String
    let requestedAt: Date
    /// Whether `path` matched an `always_ask` rule. Those cards can only be
    /// answered once — `always_ask` outranks every "remember" grant in policy —
    /// so the card hides the remember popup rather than offer a silent no-op.
    let isAlwaysAsk: Bool
}

/// The live queue of hook edits awaiting review — the model behind the agents
/// panel's approvals section (F3). `DiffApprovalCoordinator` enqueues entries
/// and owns the policy around them; the UI resolves them through `resolve`.
/// Every mutation posts `.pendingApprovalsChanged`, so the sidebar list, the
/// activity-bar badge, and the dock-attention logic all track one source of
/// truth instead of each shadowing the queue.
///
/// MainActor-isolated (the module default): entries arrive from the IPC
/// delegate on the main thread and are resolved from UI actions.
final class ApprovalQueue {
    static let shared = ApprovalQueue()

    private(set) var pending: [PendingApproval] = []

    /// Held hook responses, keyed by entry id. Kept out of `PendingApproval`
    /// so the UI can copy entries around freely without owning a closure that
    /// must fire exactly once.
    private var completions: [UUID: (ApprovalOutcome) -> Void] = [:]

    /// Adds an entry to the back of the queue and returns its id. `completion`
    /// runs exactly once, when the entry is resolved by the user or by a drain —
    /// but not when it is `withdraw`n, which drops the held completion unfired.
    @discardableResult
    func enqueue(
        paneID: UUID?,
        path: String,
        old: String,
        new: String,
        isAlwaysAsk: Bool = false,
        completion: @escaping (ApprovalOutcome) -> Void
    ) -> UUID {
        let entry = PendingApproval(
            id: UUID(),
            paneID: paneID,
            path: path,
            old: old,
            new: new,
            requestedAt: Date(),
            isAlwaysAsk: isAlwaysAsk
        )
        pending.append(entry)
        completions[entry.id] = completion
        notifyChanged()
        return entry.id
    }

    /// Resolves one entry and releases its held hook response. An unknown id
    /// is a no-op — a click racing a window-close drain must not double-fire.
    func resolve(id: UUID, outcome: ApprovalOutcome) {
        guard let index = pending.firstIndex(where: { $0.id == id }),
              let completion = completions.removeValue(forKey: id) else { return }
        pending.remove(at: index)
        completion(outcome)
        notifyChanged()
    }

    /// Removes an entry whose hook client has vanished (the process died while
    /// its edit waited at the desk), dropping the held completion UNFIRED —
    /// there's no live socket left to answer, so replying would only write to a
    /// dead fd. Returns the removed entry so the caller can emit the withdrawn
    /// event, or nil if it was already resolved (a human answered in the same
    /// instant the client dropped).
    @discardableResult
    func withdraw(id: UUID) -> PendingApproval? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = pending.remove(at: index)
        completions.removeValue(forKey: id)
        notifyChanged()
        return entry
    }

    /// Resolves every queued entry through `decide` — the window-close drain.
    /// The queue is emptied before any completion runs so a completion that
    /// re-reads `pending` sees the drained state.
    func drainAll(_ decide: (PendingApproval) -> ApprovalOutcome) {
        guard !pending.isEmpty else { return }
        let entries = pending
        let held = completions
        pending.removeAll()
        completions.removeAll()
        for entry in entries {
            held[entry.id]?(decide(entry))
        }
        notifyChanged()
    }

    /// Pending entries for one pane — the per-pane badge count.
    func count(forPane paneID: UUID?) -> Int {
        pending.filter { $0.paneID == paneID }.count
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .pendingApprovalsChanged, object: self)
    }
}

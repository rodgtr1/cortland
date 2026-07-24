import Foundation
import Darwin

/// One line in the `cortland-ctl events --follow` JSONL stream. A single struct
/// with optional fields (matching `IPCResult`'s house style) keeps the wire
/// format flat and self-describing; the synthesized encoder omits nil fields, so
/// each event only carries the keys its `type` populates.
///
///  - `hello`        — sent once on subscribe, so a client knows it's connected.
///  - `agent_state`  — a pane's agent state transitioned (idle/working/ready/done).
///  - `command`      — a shell command finished (OSC 133 D mark).
///  - `diff`         — a hook edit was queued / accepted / rejected.
nonisolated struct CortlandEvent: Codable, Sendable {
    let type: String
    let at: String

    var paneID: String?
    var tabID: String?
    var state: String?
    var command: String?
    var exitCode: Int?
    var duration: Double?
    var path: String?
    var decision: String?
    // `telemetry` events
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?
    var turns: Int?

    enum CodingKeys: String, CodingKey {
        case type, at, state, command, duration, path, decision, model, turns
        case paneID = "pane_id"
        case tabID = "tab_id"
        case exitCode = "exit_code"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
    }

    // Configured once and only ever read, so the shared instance is safe despite
    // ISO8601DateFormatter not being Sendable.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(type: String, at: Date = Date()) {
        self.type = type
        self.at = Self.timestampFormatter.string(from: at)
    }
}

/// Fans live app events out to every connected `events --follow` client as
/// newline-delimited JSON. The IPC accept loop hands a subscribed socket here
/// (after the same UID check every command gets); `AutomationCoordinator` — the
/// single place that already sees every state change, command mark, and diff —
/// feeds events in through `emit`.
///
/// Lifecycle: the connection's own IPC thread registers the FD, then blocks
/// reading it (a client never sends on an event stream) so EOF unblocks promptly
/// for cleanup. That reader thread is the *sole owner* of `close`, which it takes
/// under `writeLock` so it can't fire mid-write; `send` re-checks membership under
/// `lock` while holding `writeLock`, so an in-flight emit that snapshotted the fd
/// never writes into a recycled descriptor. `emit` runs on the main thread
/// (notifications fire there); to a dead or wedged consumer it `shutdown`s the
/// socket — never `close`s it — so the owning reader wakes and closes it.
/// Optional narrowing for an `events --follow` subscriber. A nil field matches
/// everything; the `hello` connection marker is always delivered regardless, so
/// a client always learns it connected even under a filter that excludes it.
nonisolated struct EventFilter {
    var paneID: String?
    var type: String?

    func matches(_ event: CortlandEvent) -> Bool {
        if event.type == "hello" { return true }
        if let paneID, event.paneID != paneID { return false }
        if let type, event.type != type { return false }
        return true
    }
}

// @unchecked Sendable: all mutable state (`subscribers`, `lastStateByPane`) is
// accessed only under `lock`, so this is safe to share across the main thread
// (where `emit` runs) and the per-connection IPC threads (which add/remove
// subscribers). The unsafe FD writes are serialized by the same lock-guarded
// membership set. Marked explicitly to prep for the Swift 6 strict-concurrency
// migration without flipping the language mode yet.
nonisolated final class EventBroadcaster: @unchecked Sendable {
    static let shared = EventBroadcaster()

    private let lock = NSLock()
    private var subscribers: [Int32: EventFilter] = [:]

    /// Serializes the actual `write()`s. `emit` (main thread) and `addSubscriber`
    /// (the connection's IPC thread) both write to the same fd; without this a
    /// hello/backlog write and a live-event write can interleave mid-line and
    /// corrupt the subscriber's JSONL stream. Separate from `lock` so the
    /// `drop(_:)` call inside a failing write — which takes `lock` — can't
    /// self-deadlock (writeLock is always the outer lock, `lock` the inner).
    private let writeLock = NSLock()

    /// Last `agent_state` event seen per pane. Replayed (filtered) to a new
    /// subscriber so a late-joining supervisor knows the current state of every
    /// pane without waiting for the next transition.
    private var lastStateByPane: [String: CortlandEvent] = [:]

    /// Internal (not private) so tests can exercise an isolated instance;
    /// `shared` is the canonical one the app uses.
    init() {}

    /// True while at least one client is following. Lets the emit sites skip
    /// building events nobody is listening for (agent_state excepted — it always
    /// emits so `lastStateByPane` stays current for backlog-on-connect).
    var hasSubscribers: Bool {
        lock.lock(); defer { lock.unlock() }
        return !subscribers.isEmpty
    }

    /// Registers a subscriber socket and greets it, then replays the current
    /// per-pane state backlog (subject to `filter`). Called on the connection's
    /// IPC thread, which then blocks reading the socket until the client hangs
    /// up and calls `removeSubscriber`.
    ///
    /// `includeBacklog: false` skips the replay: a wait-for-the-next-event
    /// client (`cortland_wait_event`) must not have its wait satisfied by a
    /// state that predates the subscription.
    func addSubscriber(_ fd: Int32, filter: EventFilter = EventFilter(), includeBacklog: Bool = true) {
        // Register, snapshot the backlog, and deliver hello+backlog all while
        // holding `writeLock`. A concurrent `emit` that sees this fd in
        // `subscribers` must take `writeLock` to write, so its live event queues
        // strictly after the backlog here — otherwise it could win the lock
        // between the snapshot and delivery and land a newer state ahead of the
        // stale backlog value, regressing the subscriber's view of a pane.
        writeLock.lock()
        defer { writeLock.unlock() }

        lock.lock()
        subscribers[fd] = filter
        let backlog = includeBacklog ? sortedSnapshotLocked() : []
        lock.unlock()

        if let hello = framedLine(for: CortlandEvent(type: "hello")) {
            sendLocked(line: hello, to: fd)
        }
        for event in backlog where filter.matches(event) {
            if let line = framedLine(for: event) {
                sendLocked(line: line, to: fd)
            }
        }
    }

    /// Called by the owning reader thread once its socket reaches EOF. The sole
    /// `close` site. Taken under `writeLock` so the close can't fire while `emit`
    /// holds it mid-`write`; paired with the membership re-check in `send(line:)`,
    /// this closes the FD-reuse window — an in-flight emit that snapshotted this
    /// fd re-verifies subscription under `writeLock` before writing, so it either
    /// writes before removal or skips after it, never into a recycled descriptor.
    func removeSubscriber(_ fd: Int32) {
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.lock()
        subscribers[fd] = nil
        lock.unlock()
        close(fd)
    }

    /// Serializes `event` to one JSON line and writes it to every subscriber
    /// whose filter matches. Also records `agent_state` events as the current
    /// per-pane state for backlog-on-connect.
    func emit(_ event: CortlandEvent) {
        if event.type == "agent_state", let pane = event.paneID {
            lock.lock(); lastStateByPane[pane] = event; lock.unlock()
        }

        guard let line = framedLine(for: event) else { return }

        lock.lock()
        let targets = subscribers.compactMap { $0.value.matches(event) ? $0.key : nil }
        lock.unlock()
        for fd in targets {
            send(line: line, to: fd)
        }
    }

    /// Current per-pane agent state, newest value per pane, ordered by pane id
    /// for deterministic replay. Used for backlog-on-connect (and tests).
    func currentStateSnapshot() -> [CortlandEvent] {
        lock.lock(); defer { lock.unlock() }
        return sortedSnapshotLocked()
    }

    /// Caller must hold `lock`.
    private func sortedSnapshotLocked() -> [CortlandEvent] {
        lastStateByPane.values.sorted { ($0.paneID ?? "") < ($1.paneID ?? "") }
    }

    // MARK: - Writing

    /// Serializes an event to one newline-framed JSONL line, or nil if encoding
    /// fails.
    private func framedLine(for event: CortlandEvent) -> Data? {
        guard let data = try? JSONEncoder().encode(event) else { return nil }
        var line = data
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// Writes one already-framed line. If the socket isn't immediately writable
    /// (slow/wedged consumer) or the write fails, drops the subscriber from the
    /// active set and `shutdown`s it so the owning reader closes it.
    private func send(line: Data, to fd: Int32) {
        writeLock.lock()
        defer { writeLock.unlock() }
        sendLocked(line: line, to: fd)
    }

    /// Body of `send(line:)`, factored out so callers already holding `writeLock`
    /// (e.g. `addSubscriber`) can write without re-entering the non-recursive
    /// lock. The caller MUST hold `writeLock`.
    private func sendLocked(line: Data, to fd: Int32) {
        // Re-verify membership under `lock` while holding `writeLock`:
        // `removeSubscriber` clears the entry and closes the fd in the same
        // writeLock-guarded section, so an fd still present here is guaranteed
        // open for the duration of this write — never closed and recycled
        // between `emit`'s snapshot and this `write()`.
        lock.lock()
        let subscribed = subscribers[fd] != nil
        lock.unlock()
        guard subscribed else { return }
        guard isWritable(fd) else {
            drop(fd)
            return
        }
        let wrote = line.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var cursor = base
            var remaining = raw.count
            while remaining > 0 {
                let count = write(fd, cursor, remaining)
                guard count > 0 else { return false }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
            return true
        }
        if !wrote { drop(fd) }
    }

    /// Non-blocking readiness probe so `emit` never stalls the main thread on a
    /// consumer that stopped draining.
    private func isWritable(_ fd: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&pfd, 1, 0) > 0 && (pfd.revents & Int16(POLLOUT)) != 0
    }

    /// Removes from the active set and `shutdown`s (does not close — the reader
    /// owns that) so a wedged consumer's socket unblocks for cleanup.
    private func drop(_ fd: Int32) {
        lock.lock()
        let wasActive = subscribers.removeValue(forKey: fd) != nil
        lock.unlock()
        if wasActive {
            shutdown(fd, SHUT_RDWR)
        }
    }
}

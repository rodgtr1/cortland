import Foundation
import Darwin
import CortlandIPCCore
import CortlandTelemetryCore

// MARK: - IPC Command Types
nonisolated struct IPCCommand: Codable, Sendable {
    let action: String
    let path: String?
    let old: String?
    let new: String?
    let cwd: String?
    let paneID: String?
    let direction: String?
    let focus: Bool?
    let command: [String]?
    let text: String?
    let key: String?
    let source: String?
    let lines: Int?
    /// Delta-read cursor from a prior `pane_read` response: return only output
    /// appended since it (or a truncated full read when it's stale).
    let since: String?
    let status: String?
    let match: String?
    let timeoutMS: Int?
    let format: String?
    let worktree: String?
    let force: Bool?
    /// Event-type filter for an `events` subscription (e.g. "agent_state").
    let type: String?
    /// Whether an `events` subscription replays the current per-pane state on
    /// connect (default true). Wait-for-next-event clients pass false.
    let backlog: Bool?
    /// JSON-encoded `TranscriptUsage` blob for a `report_telemetry` call.
    let telemetry: String?
    /// Wire-protocol version declared by an `agent_status` report. Absent from
    /// pre-handshake helpers, which is exactly what makes them detectable —
    /// see `AgentStatusReport.legacyProtocolVersion`.
    let protocolVersion: Int?

    enum CodingKeys: String, CodingKey {
        case action, path, old, new, cwd, direction, focus, command, text, key, source, lines, since, status, match, format, worktree, force, type, backlog, telemetry
        case paneID = "pane_id"
        case timeoutMS = "timeout_ms"
        case protocolVersion = "protocol_version"
    }
}

nonisolated struct IPCPaneInfo: Codable, Sendable {
    let paneID: String
    let tabID: String
    let type: String
    let cwd: String?
    let focused: Bool
    let agentStatus: String
    let processID: Int32?

    enum CodingKeys: String, CodingKey {
        case type, cwd, focused
        case paneID = "pane_id"
        case tabID = "tab_id"
        case agentStatus = "agent_status"
        case processID = "process_id"
    }
}

/// One finished shell command, returned by `pane_read` with `format: "json"`.
nonisolated struct IPCCommandRecord: Codable, Sendable {
    let command: String
    let exitCode: Int
    let duration: Double?
    let output: String

    enum CodingKeys: String, CodingKey {
        case command, duration, output
        case exitCode = "exit_code"
    }
}

/// One registered git worktree, returned by `worktree_list`. Mirrors
/// `GitWorktree` but as the IPC wire shape the CLI/MCP clients consume.
nonisolated struct IPCWorktreeInfo: Codable, Sendable {
    let path: String
    let branch: String?
    let head: String?
    let detached: Bool
    let locked: Bool
    let bare: Bool
}

/// One agent pane's fleet status, returned by `agent_list`. This is the same
/// per-pane data the Agents sidebar dashboard renders (state + elapsed +
/// telemetry), flattened to a wire row so a driver can poll the whole fleet in
/// one call instead of walking `pane_list` and the telemetry stream.
nonisolated struct IPCAgentInfo: Codable, Sendable {
    let paneID: String
    let tabID: String
    /// Owning tab's title (directory/branch or the user's rename).
    let tab: String
    /// Short model name from the pane's latest telemetry (e.g. "opus-4.8"),
    /// the closest thing the dashboard tracks to an agent identity. Nil until a
    /// turn has been billed for the pane.
    let agent: String?
    /// Agent state: working | ready | done (idle panes aren't listed).
    let state: String
    /// Seconds the pane has been in `state`.
    let sinceS: Int
    /// Estimated USD cost of the pane's latest reported usage, when its model
    /// has a known rate. Nil otherwise.
    let costUSD: Double?
    /// Branch name when the pane sits in a linked git worktree; nil otherwise.
    let worktree: String?

    enum CodingKeys: String, CodingKey {
        case tab, agent, state, worktree
        case paneID = "pane_id"
        case tabID = "tab_id"
        case sinceS = "since_s"
        case costUSD = "cost_usd"
    }
}

nonisolated struct IPCResult: Codable, Sendable {
    let panes: [IPCPaneInfo]?
    let pane: IPCPaneInfo?
    let agents: [IPCAgentInfo]?
    let text: String?
    let matched: Bool?
    let commands: [IPCCommandRecord]?
    let worktrees: [IPCWorktreeInfo]?
    /// Recent-output cursor at read time — pass back as `since` for a delta read.
    let cursor: String?
    /// True when a `since` cursor couldn't be served as a delta (stale or
    /// evicted) and `text` is a full re-read instead. Absent otherwise.
    let truncated: Bool?

    init(
        panes: [IPCPaneInfo]? = nil,
        pane: IPCPaneInfo? = nil,
        agents: [IPCAgentInfo]? = nil,
        text: String? = nil,
        matched: Bool? = nil,
        commands: [IPCCommandRecord]? = nil,
        worktrees: [IPCWorktreeInfo]? = nil,
        cursor: String? = nil,
        truncated: Bool? = nil
    ) {
        self.panes = panes
        self.pane = pane
        self.agents = agents
        self.text = text
        self.matched = matched
        self.commands = commands
        self.worktrees = worktrees
        self.cursor = cursor
        self.truncated = truncated
    }
}

nonisolated struct IPCResponse: Codable, Sendable {
    let ok: Bool
    let error: String?
    let accepted: Bool?
    let result: IPCResult?

    init(ok: Bool = true, error: String? = nil, accepted: Bool? = nil, result: IPCResult? = nil) {
        self.ok = ok
        self.error = error
        self.accepted = accepted
        self.result = result
    }
}

nonisolated enum IPCCommandType {
    case ping
    case newTab(cwd: String?)
    case showDiff(paneID: UUID?, path: String, old: String, new: String)
    case agentReady
    case agentBusy
    case agentDone
    case agentIdle
    case agentStatus(paneID: UUID, status: String)
    case paneList
    case agentList
    case paneCurrent(paneID: UUID?)
    case paneSplit(paneID: UUID, direction: SplitDirection, cwd: String?, command: [String]?, focus: Bool, worktree: String?)
    case paneFocus(paneID: UUID)
    case paneClose(paneID: UUID)
    case paneSendText(paneID: UUID, text: String)
    case paneRun(paneID: UUID, text: String)
    case paneSendKey(paneID: UUID, key: String)
    case paneRead(paneID: UUID, source: String, lines: Int?, json: Bool, since: String?)
    case waitAgentStatus(paneID: UUID, status: AgentState, timeoutMS: Int)
    case waitOutput(paneID: UUID, match: String, timeoutMS: Int)
    case worktreeList(cwd: String?)
    case worktreeRemove(branch: String, cwd: String?, force: Bool)
    case worktreePrune(cwd: String?)
    case reportTelemetry(paneID: UUID, usage: TranscriptUsage)
    case resetTelemetry(paneID: UUID)

    /// Outcome of parsing an `IPCCommand`, distinguishing "unknown command"
    /// from "known command, invalid arguments" straight from the switch in
    /// `parse` — no separate action list to keep in sync. (`events` never
    /// reaches `parse`; the server routes it to the event stream first.)
    enum ParseResult {
        case command(IPCCommandType)
        case invalidArguments
        case unknownAction
    }

    static func from(_ command: IPCCommand) -> IPCCommandType? {
        guard case .command(let commandType) = parse(command) else { return nil }
        return commandType
    }

    /// The pane and version of an `agent_status` report whose helper is older
    /// than the wire protocol this build speaks, or nil when there's nothing to
    /// warn about (a current or future helper, or another command entirely).
    ///
    /// Read alongside `parse`, never instead of it: the staleness verdict is a
    /// *side* observation, so the report itself is delivered either way. A helper
    /// that can't say what it speaks (no `protocol_version` field) counts as v0 —
    /// that's every helper shipped before this handshake existed, and the whole
    /// reason a stale `~/.local/bin` copy was invisible.
    static func staleAgentStatusReport(_ command: IPCCommand) -> (paneID: UUID, protocolVersion: Int)? {
        guard command.action == "agent_status",
              let paneID = uuid(command.paneID),
              AgentStatusReport.isStale(protocolVersion: command.protocolVersion) else { return nil }
        return (paneID, command.protocolVersion ?? AgentStatusReport.legacyProtocolVersion)
    }

    static func parse(_ command: IPCCommand) -> ParseResult {
        switch command.action {
        case "ping":
            return .command(.ping)
        case "new_tab":
            return .command(.newTab(cwd: command.cwd.flatMap(Self.validatedDirectory)))
        case "show_diff":
            guard let path = command.path,
                  let old = command.old,
                  let new = command.new,
                  let validPath = Self.validatedDiffPath(path) else { return .invalidArguments }
            // pane_id is optional: it scopes "approve & remember" grants to the
            // pane the edit hook ran in. Absent (or unparseable) → unscoped.
            return .command(.showDiff(paneID: command.paneID.flatMap(UUID.init(uuidString:)),
                                      path: validPath, old: old, new: new))
        case "agent_ready":
            return .command(.agentReady)
        case "agent_busy":
            return .command(.agentBusy)
        case "agent_done":
            return .command(.agentDone)
        case "agent_idle":
            return .command(.agentIdle)
        case "agent_status":
            // The pane-scoped report `cortland-agent-status` sends when it has no
            // controlling terminal to write the OSC 666 escape to. Unlike the
            // legacy `agent_*` verbs above (which set the *active tab's* state),
            // this names its pane and feeds that pane's detector, so a hook firing
            // in a background pane lands where it belongs. The status vocabulary
            // is the hooks' own ("busy"), not AgentState's raw values, and the
            // token travels on unmapped: some tokens ("gated") carry more than
            // the state they map to, and the detector is the one parser for both
            // transports.
            guard let paneID = uuid(command.paneID),
                  let rawStatus = command.status,
                  AgentStateDetector.state(fromStatus: rawStatus) != nil else { return .invalidArguments }
            return .command(.agentStatus(paneID: paneID, status: rawStatus))
        case "pane_list":
            return .command(.paneList)
        case "agent_list":
            return .command(.agentList)
        case "pane_current":
            if let rawPaneID = command.paneID {
                guard let paneID = UUID(uuidString: rawPaneID) else { return .invalidArguments }
                return .command(.paneCurrent(paneID: paneID))
            }
            return .command(.paneCurrent(paneID: nil))
        case "pane_split":
            guard let paneID = uuid(command.paneID),
                  let direction = splitDirection(command.direction) else { return .invalidArguments }
            let cwd: String?
            if let requestedCWD = command.cwd {
                guard let validCWD = validatedDirectory(requestedCWD) else { return .invalidArguments }
                cwd = validCWD
            } else {
                cwd = nil
            }
            if let argv = command.command, argv.isEmpty || argv.count > 256 || argv.contains(where: { $0.count > 32_768 }) {
                return .invalidArguments
            }
            let worktree: String?
            if let requestedBranch = command.worktree {
                guard let validBranch = validatedBranchName(requestedBranch) else { return .invalidArguments }
                worktree = validBranch
            } else {
                worktree = nil
            }
            return .command(.paneSplit(
                paneID: paneID,
                direction: direction,
                cwd: cwd,
                command: command.command,
                focus: command.focus ?? true,
                worktree: worktree
            ))
        case "pane_focus":
            guard let paneID = uuid(command.paneID) else { return .invalidArguments }
            return .command(.paneFocus(paneID: paneID))
        case "pane_close":
            guard let paneID = uuid(command.paneID) else { return .invalidArguments }
            return .command(.paneClose(paneID: paneID))
        case "pane_send_text":
            guard let paneID = uuid(command.paneID), let text = command.text, text.count <= 1_000_000 else { return .invalidArguments }
            return .command(.paneSendText(paneID: paneID, text: text))
        case "pane_run":
            guard let paneID = uuid(command.paneID), let text = command.text, text.count <= 1_000_000 else { return .invalidArguments }
            return .command(.paneRun(paneID: paneID, text: text))
        case "pane_send_key":
            guard let paneID = uuid(command.paneID), let key = command.key, !key.isEmpty else { return .invalidArguments }
            return .command(.paneSendKey(paneID: paneID, key: key))
        case "pane_read":
            guard let paneID = uuid(command.paneID) else { return .invalidArguments }
            let source = command.source ?? "visible"
            let format = command.format ?? "text"
            guard source == "visible" || source == "recent",
                  format == "text" || format == "json",
                  command.lines.map({ (1...10_000).contains($0) }) ?? true,
                  command.since.map({ $0.count <= 128 }) ?? true else { return .invalidArguments }
            return .command(.paneRead(paneID: paneID, source: source, lines: command.lines, json: format == "json", since: command.since))
        case "wait_agent_status":
            guard let paneID = uuid(command.paneID),
                  let rawStatus = command.status,
                  let status = AgentState(rawValue: rawStatus),
                  let timeout = validTimeout(command.timeoutMS) else { return .invalidArguments }
            return .command(.waitAgentStatus(paneID: paneID, status: status, timeoutMS: timeout))
        case "wait_output":
            guard let paneID = uuid(command.paneID),
                  let match = command.match, !match.isEmpty, match.count <= 16_384,
                  let timeout = validTimeout(command.timeoutMS) else { return .invalidArguments }
            return .command(.waitOutput(paneID: paneID, match: match, timeoutMS: timeout))
        case "worktree_list":
            guard let cwd = optionalDirectory(command.cwd) else { return .invalidArguments }
            return .command(.worktreeList(cwd: cwd))
        case "worktree_remove":
            guard let rawBranch = command.worktree,
                  let branch = validatedBranchName(rawBranch),
                  let cwd = optionalDirectory(command.cwd) else { return .invalidArguments }
            return .command(.worktreeRemove(branch: branch, cwd: cwd, force: command.force ?? false))
        case "worktree_prune":
            guard let cwd = optionalDirectory(command.cwd) else { return .invalidArguments }
            return .command(.worktreePrune(cwd: cwd))
        case "report_telemetry":
            guard let paneID = uuid(command.paneID),
                  let json = command.telemetry,
                  let data = json.data(using: .utf8),
                  let usage = try? JSONDecoder().decode(TranscriptUsage.self, from: data) else { return .invalidArguments }
            return .command(.reportTelemetry(paneID: paneID, usage: usage))
        case "reset_telemetry":
            guard let paneID = uuid(command.paneID) else { return .invalidArguments }
            return .command(.resetTelemetry(paneID: paneID))
        default:
            return .unknownAction
        }
    }

    private static func uuid(_ value: String?) -> UUID? {
        value.flatMap(UUID.init(uuidString:))
    }

    /// Validates an optional `cwd`: nil stays nil (resolve from the active pane
    /// later), a present value must be a real directory. Returns `.some(nil)`
    /// for absent, `.some(dir)` for valid, and `nil` to signal "present but
    /// invalid" so the command is rejected.
    private static func optionalDirectory(_ value: String?) -> String?? {
        guard let value else { return .some(nil) }
        guard let valid = validatedDirectory(value) else { return nil }
        return .some(valid)
    }

    private static func splitDirection(_ value: String?) -> SplitDirection? {
        switch value {
        case "right", "horizontal": return .horizontal
        case "down", "vertical": return .vertical
        default: return nil
        }
    }

    private static func validTimeout(_ value: Int?) -> Int? {
        let timeout = value ?? 30_000
        return (1...3_600_000).contains(timeout) ? timeout : nil
    }

    /// Accepts a git branch name for `pane split --worktree`. Leaves the full
    /// ref-name rules to git itself (an invalid name just fails the command),
    /// but rejects the cases that would be a problem before git sees them: an
    /// empty/oversized value, a leading `-` (would parse as a git option), and
    /// whitespace/control characters (never valid in a ref, and a shell-paste
    /// hazard in logs/UI).
    private static func validatedBranchName(_ branch: String) -> String? {
        guard !branch.isEmpty, branch.count <= 255, !branch.hasPrefix("-") else { return nil }
        let invalid = branch.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar == " " || scalar == "\u{7F}"
        }
        return invalid ? nil : branch
    }

    /// Resolves symlinks and requires an absolute path. The file may not
    /// exist yet (a hook can ask to review the creation of a new file), but
    /// an existing path must be a regular file.
    private static func validatedDiffPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue {
            return nil
        }
        return resolved
    }

    /// Resolves symlinks and requires an absolute path to an existing directory.
    private static func validatedDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return resolved
    }
}

// MARK: - IPC Server Delegate
protocol IPCServerDelegate: AnyObject {
    /// Called on the main thread. The delegate may call `completion`
    /// synchronously, or hold it and respond later (e.g. after the user
    /// accepts/rejects a diff) — the client socket stays open until then.
    ///
    /// `registerDisconnect` lets a deferring delegate arm a handler the server
    /// runs if the client hangs up BEFORE `completion` fires — the server watches
    /// the parked socket for the drop. Used by the edit-approval desk to withdraw
    /// an entry whose hook process died while it waited. A delegate that answers
    /// promptly (or whose wait can't outlive the client) simply doesn't call it.
    func ipcServer(
        _ server: IPCServer,
        didReceiveCommand command: IPCCommandType,
        onClientDisconnect registerDisconnect: @escaping (@escaping @Sendable () -> Void) -> Void,
        completion: @escaping @Sendable (IPCResponse) -> Void
    )

    /// A pane's `agent_status` hook spoke an older wire protocol than this build.
    /// Called on the main thread just *before* the report itself is delivered:
    /// the report is always honored, this is only how the app gets to say that
    /// the helper behind it needs refreshing.
    func ipcServer(
        _ server: IPCServer,
        didReceiveStaleAgentStatusReport paneID: UUID,
        protocolVersion: Int
    )
}

/// Coordinates a deferred IPC request between the two paths that can end it: the
/// delegate finally calling `completion`, or the client hanging up while the
/// request is still parked. Exactly one wins, so the response is written and the
/// fd closed exactly once.
///
/// `claim()` returns true only for the first caller — it guards a deferred
/// completion against a delegate that invokes it more than once, and lets the
/// completion path know it beat any drop. A reference-captured latch is data-race
/// free where a captured `var Bool` is not, satisfying strict concurrency's
/// mutable-capture check (prep for the Swift 6 migration).
///
/// A deferring delegate may `arm` a disconnect handler; `watchForClientDrop`
/// then polls the parked socket and, on hang-up, `claimDrop()`s the request so
/// the handler runs (withdrawing the orphaned approval-desk entry) instead of
/// the completion writing to a dead socket.
nonisolated final class DeferredResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var disconnectHandler: (@Sendable () -> Void)?

    /// The completion path claims the request. True only for the first caller.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }

    /// Registers a handler to run if the client drops before the completion
    /// fires. Only a deferring command (a parked show_diff) arms one.
    func arm(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        disconnectHandler = handler
    }

    /// Whether a disconnect handler is armed — the server only watches the socket
    /// for a drop when one is.
    var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return disconnectHandler != nil
    }

    /// True once either path has ended the request; the drop watcher stops
    /// polling as soon as it is.
    var isSettled: Bool {
        lock.lock(); defer { lock.unlock() }
        return settled
    }

    /// The drop watcher claims the request on hang-up. Returns the armed handler
    /// to run when this caller wins the race, or nil when the completion already
    /// settled it (a human answered as the client vanished).
    func claimDrop() -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        if settled { return nil }
        settled = true
        return disconnectHandler
    }
}

// MARK: - IPC Server
// @unchecked Sendable: mutable state (`isRunning`) is guarded by `stateLock`;
// `serverFD` is assigned once at startup before the accept loop reads it. The
// accept loop runs on a background thread and per-connection work hops to the
// main queue. Marked explicitly to prep for the Swift 6 strict-concurrency
// migration without flipping the language mode yet.
nonisolated final class IPCServer: @unchecked Sendable {
    private let socketURL: URL
    private var serverFD: Int32 = -1
    private let stateLock = NSLock()
    private var isRunning = false
    weak var delegate: IPCServerDelegate?

    /// Requests larger than this are rejected to bound memory per client.
    /// Sized to fit show_diff payloads (two ~4MB file bodies, JSON-escaped).
    private static let maxRequestBytes = 16 * 1024 * 1024

    /// Caps concurrent `events --follow` subscribers. Each one owns a dedicated
    /// Thread blocked in `read()` for its lifetime (kept off the shared GCD
    /// global pool so it can't starve other `DispatchQueue.global` work); this
    /// bounds how many such reader threads a leaking client can accumulate.
    private static let maxEventSubscribers = 64
    private let eventSubscriberLock = NSLock()
    private var eventSubscriberCount = 0

    static let shared = IPCServer()

    private init() {
        // Socket path: ~/.config/cortland/cortland.sock
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let configDirectory = homeDirectory.appendingPathComponent(".config/cortland")
        socketURL = configDirectory.appendingPathComponent("cortland.sock")
    }

    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return }

        setupSocketDirectory()
        cleanupExistingSocket()

        guard let fd = bindAndListen() else { return }
        serverFD = fd
        isRunning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop(serverFD: fd)
        }
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return }
        isRunning = false
        // Wake the accept loop deterministically: close() alone is not
        // guaranteed to unblock a thread already parked in accept() on this fd,
        // so shutdown() first, then close(). The loop then sees the -1 return
        // and observes isRunning == false to exit. (EventBroadcaster.drop uses
        // the same shutdown-to-unblock idiom.)
        if serverFD >= 0 {
            shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            serverFD = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private var shouldKeepRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    private func setupSocketDirectory() {
        let configDirectory = socketURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory only applies permissions on creation; enforce them
            // even when the directory already existed.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: configDirectory.path
            )
        } catch {
            Log.debug("IPCServer: Failed to prepare config directory: \(error)")
        }
    }

    private func cleanupExistingSocket() {
        if FileManager.default.fileExists(atPath: socketURL.path) {
            do {
                try FileManager.default.removeItem(at: socketURL)
            } catch {
                Log.debug("IPCServer: Failed to remove existing socket: \(error)")
            }
        }
    }

    private func bindAndListen() -> Int32? {
        let socketPath = socketURL.path

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD != -1 else {
            Log.debug("IPCServer: Failed to create socket")
            return nil
        }
        // Never let pane shells inherit IPC fds: forkpty snapshots every open
        // descriptor, so without close-on-exec each spawned shell keeps a copy
        // of the listener for its whole lifetime.
        _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            Log.debug("IPCServer: Socket path too long")
            close(socketFD)
            return nil
        }

        socketPath.withCString { pathCString in
            withUnsafeMutablePointer(to: &address.sun_path.0) { pathPtr in
                strncpy(pathPtr, pathCString, maxPathLength - 1)
                pathPtr[maxPathLength - 1] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult != -1 else {
            Log.debug("IPCServer: Failed to bind socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            return nil
        }

        // Restrict the socket itself to the owner, independent of directory perms.
        chmod(socketPath, 0o600)

        guard listen(socketFD, 5) != -1 else {
            Log.debug("IPCServer: Failed to listen on socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            return nil
        }

        Log.debug("IPCServer: Listening on \(socketPath)")
        return socketFD
    }

    private func acceptLoop(serverFD: Int32) {
        while shouldKeepRunning {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD != -1 else {
                if shouldKeepRunning {
                    Log.debug("IPCServer: Failed to accept connection: \(String(cString: strerror(errno)))")
                    continue
                }
                break
            }

            guard peerIsCurrentUser(clientFD) else {
                Log.debug("IPCServer: Rejecting connection from other user")
                close(clientFD)
                continue
            }

            // Close-on-exec, or a pane shell forked while this connection is
            // in flight (pane_split / new_tab spawning their own pane's shell)
            // inherits the fd and holds the socket open for the pane's whole
            // lifetime — the client waiting on EOF then blocks until that
            // unrelated pane closes, which reads as a hung split.
            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)

            // Responses can be deferred (diff approval), so the client may be
            // gone by the time we write. Without this, write() to a closed
            // peer raises SIGPIPE and kills the app; with it, write() just
            // returns EPIPE.
            var noSigpipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

            // A client that connects but never sends a full request line would
            // otherwise pin this GCD global-pool worker in read() forever, with
            // no cap on how many can accumulate. Bound the wait; readLine
            // treats the timed-out read like a hang-up. `events` subscribers
            // get this cleared again once their request is parsed — their
            // drain read is *supposed* to idle indefinitely.
            var receiveTimeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD: clientFD)
            }
        }
    }

    /// Verifies the connecting peer runs as the same UID as this process.
    private func peerIsCurrentUser(_ clientFD: Int32) -> Bool {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(clientFD, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0 else {
            return false
        }
        return credentials.cr_uid == getuid()
    }

    private func handleClient(clientFD: Int32) {
        // Read a single newline-terminated request. The client may keep its
        // write side open while waiting for the response, so reading to EOF
        // would deadlock.
        let requestData: Data
        switch readLine(from: clientFD) {
        case .line(let data):
            requestData = data
        case .eof:
            Log.debug("IPCServer: Failed to read command")
            close(clientFD)
            return
        case .tooLarge:
            // The client is likely still blocked in write() with the rest of
            // the oversized request; if we reply and close now, that write
            // fails with EPIPE before the client ever reads, and the error is
            // lost. Discard the remainder first so the client's write
            // completes and it can actually receive the response.
            drainRequestRemainder(from: clientFD)
            sendResponse(IPCResponse(ok: false, error: "Request exceeds maximum size of \(Self.maxRequestBytes) bytes"), to: clientFD)
            close(clientFD)
            return
        }

        guard let commandString = String(data: requestData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !commandString.isEmpty,
              let commandData = commandString.data(using: .utf8) else {
            sendResponse(IPCResponse(ok: false, error: "Empty or invalid request"), to: clientFD)
            close(clientFD)
            return
        }

        let command: IPCCommand
        do {
            command = try JSONDecoder().decode(IPCCommand.self, from: commandData)
        } catch {
            Log.debug("IPCServer: Failed to parse command: \(error)")
            sendResponse(IPCResponse(ok: false, error: "Invalid JSON command"), to: clientFD)
            close(clientFD)
            return
        }

        // `events` is a long-lived stream, not a request/response: hand the
        // socket to the broadcaster and block a thread reading it so the client's
        // hang-up unblocks promptly for cleanup. The reader is the sole owner of
        // close() (see EventBroadcaster).
        //
        // That read blocks for the whole subscription, so it must NOT run on this
        // GCD global-pool worker — ~60 idle subscribers would pin the shared pool
        // and starve every other DispatchQueue.global user (worktree completions,
        // response writes, the accept loop's own handlers). Own it on a dedicated
        // Thread off the pool, capped so a leaking client can't spawn threads
        // without bound.
        if command.action == "events" {
            guard reserveEventSubscriberSlot() else {
                sendResponse(IPCResponse(ok: false, error: "Too many event subscribers"), to: clientFD)
                close(clientFD)
                return
            }
            // Clear the accept loop's request-phase receive timeout: the drain
            // loop below treats read() <= 0 as hang-up, so a timed-out read
            // (EAGAIN after 10 idle seconds) would disconnect a healthy
            // subscriber that is quietly waiting for events.
            var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
            let filter = Self.eventFilter(from: command)
            let includeBacklog = command.backlog ?? true
            let reader = Thread { [weak self] in
                EventBroadcaster.shared.addSubscriber(clientFD, filter: filter, includeBacklog: includeBacklog)
                var drain = [UInt8](repeating: 0, count: 256)
                while read(clientFD, &drain, drain.count) > 0 { /* clients don't send */ }
                EventBroadcaster.shared.removeSubscriber(clientFD)
                self?.releaseEventSubscriberSlot()
            }
            reader.name = "app.cortland.ipc.events"
            reader.stackSize = 128 * 1024
            reader.start()
            return
        }

        let commandType: IPCCommandType
        switch IPCCommandType.parse(command) {
        case .command(let parsed):
            commandType = parsed
        case .invalidArguments:
            // A recognized action that failed validation (e.g. a bad --cwd) is
            // an argument error, not an unknown command — report it as such so
            // the caller can tell a typo'd verb from a bad path.
            let error = "Invalid arguments for command: \(command.action)"
            Log.debug("IPCServer: \(error)")
            sendResponse(IPCResponse(ok: false, error: error), to: clientFD)
            close(clientFD)
            return
        case .unknownAction:
            let error = "Unknown command: \(command.action)"
            Log.debug("IPCServer: \(error)")
            sendResponse(IPCResponse(ok: false, error: error), to: clientFD)
            close(clientFD)
            return
        }

        // Execute on the main thread without blocking this queue; the
        // response is written (and the socket closed) once the delegate calls
        // the completion — which may be deferred (e.g. diff approval).
        DispatchQueue.main.async { [weak self] in
            // Delivered on the main queue, so the main-actor `delegate` access
            // below is safe to run synchronously.
            MainActor.assumeIsolated {
                guard let self = self else {
                    close(clientFD)
                    return
                }

                guard let delegate = self.delegate else {
                    self.sendResponse(IPCResponse(ok: false, error: "No delegate"), to: clientFD)
                    close(clientFD)
                    return
                }

                // A stale helper still gets its report through — this only notes
                // the version gap so the pane can say so once.
                if let stale = IPCCommandType.staleAgentStatusReport(command) {
                    delegate.ipcServer(
                        self,
                        didReceiveStaleAgentStatusReport: stale.paneID,
                        protocolVersion: stale.protocolVersion
                    )
                }

                let pending = DeferredResponse()
                delegate.ipcServer(
                    self,
                    didReceiveCommand: commandType,
                    onClientDisconnect: { handler in pending.arm(handler) }
                ) { [weak self] response in
                    guard pending.claim() else { return }
                    // This completion runs on the main thread (immediately or
                    // deferred by a wait/approval). A response larger than the
                    // socket send buffer to a client that stops draining would
                    // stall the write — so it never happens on main.
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.sendResponse(response, to: clientFD)
                        close(clientFD)
                    }
                }

                // A parked request (a deferred completion that armed a disconnect
                // handler) holds the client's socket open while it waits at the
                // approval desk. If the hook process dies there — its 600s
                // timeout, a killed agent, a closed pane — watch for the hang-up
                // and withdraw the orphaned entry rather than leave a ghost card
                // no one can answer. Armed synchronously above, so this is
                // decided by the time the delegate call returns.
                if pending.isArmed {
                    self.watchForClientDrop(clientFD: clientFD, pending: pending)
                }
            }
        }
    }

    /// Watches a parked request's socket for the client hanging up. The hook
    /// holds the connection open (blocked reading its response) while its edit
    /// waits at the desk, so an EOF / POLLHUP there means the hook process is
    /// gone. Runs on a dedicated thread — like the events subscriber reader, off
    /// the shared GCD pool — polling at 1s granularity; parked requests are rare
    /// and short-lived, so these never accumulate. On a drop it claims the
    /// request and runs the armed handler (which withdraws the desk entry), then
    /// owns the close; when the completion path wins instead, it exits without
    /// touching the fd.
    private func watchForClientDrop(clientFD: Int32, pending: DeferredResponse) {
        let watcher = Thread {
            while !pending.isSettled {
                var pfd = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 1000)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 { continue }          // timeout — re-check settled
                // The completion path may have settled (and be closing the fd)
                // during our poll; don't touch the fd if so — it races with reuse.
                if pending.isSettled { return }
                let revents = pfd.revents
                if (revents & Int16(POLLNVAL)) != 0 { return }
                var hungUp = (revents & Int16(POLLHUP | POLLERR)) != 0
                if !hungUp && (revents & Int16(POLLIN)) != 0 {
                    // Readable while parked means EOF: the hook only ever reads
                    // its response, never sends more. Peek so a stray byte from a
                    // still-healthy client isn't consumed out from under the read.
                    var byte: UInt8 = 0
                    hungUp = recv(clientFD, &byte, 1, Int32(MSG_PEEK)) <= 0
                }
                if hungUp {
                    if let handler = pending.claimDrop() {
                        handler()
                        close(clientFD)
                    }
                    return
                }
            }
        }
        watcher.name = "app.cortland.ipc.diffdrop"
        watcher.stackSize = 128 * 1024
        watcher.start()
    }

    /// Claims one of the bounded `events` subscriber slots. Returns false when
    /// the cap is already reached, so the caller rejects the subscription rather
    /// than spawning an unbounded reader thread.
    private func reserveEventSubscriberSlot() -> Bool {
        eventSubscriberLock.lock(); defer { eventSubscriberLock.unlock() }
        guard eventSubscriberCount < Self.maxEventSubscribers else { return false }
        eventSubscriberCount += 1
        return true
    }

    /// Releases a slot claimed by `reserveEventSubscriberSlot` once the reader
    /// thread's drain loop ends (client hang-up).
    private func releaseEventSubscriberSlot() {
        eventSubscriberLock.lock(); defer { eventSubscriberLock.unlock() }
        eventSubscriberCount -= 1
    }

    /// Builds an `EventFilter` from an `events` subscribe request. A pane id is
    /// lowercased to match the emitted form; a present-but-unmatched pane or
    /// type simply yields no events (only the `hello` marker), which reads as
    /// "nothing matched" rather than silently broadcasting everything.
    private static func eventFilter(from command: IPCCommand) -> EventFilter {
        let paneID = command.paneID.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let type = command.type.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
        return EventFilter(paneID: paneID, type: type)
    }

    /// Outcome of reading a single request line, so the caller can answer an
    /// oversized request distinctly instead of closing the socket silently.
    private enum ReadResult {
        case line(Data)
        case eof
        case tooLarge
    }

    private func readLine(from clientFD: Int32) -> ReadResult {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while request.count < Self.maxRequestBytes {
            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead <= 0 {
                // EOF or error: accept what we have if the client closed
                // its write side instead of sending a trailing newline.
                return request.isEmpty ? .eof : .line(request)
            }
            request.append(contentsOf: buffer[0..<bytesRead])
            if buffer[0..<bytesRead].contains(UInt8(ascii: "\n")) {
                return .line(request)
            }
        }
        // Ran past the cap without a terminating newline: tell the client so it
        // doesn't just see a bare EOF with no error.
        return .tooLarge
    }

    /// How long `drainRequestRemainder` will keep discarding an oversized
    /// request before giving up — bounds how long a client that streams
    /// forever (or wedges mid-write) can pin a worker thread.
    private static let requestDrainTimeout: TimeInterval = 10

    /// Discards the rest of an oversized request until its terminating
    /// newline or EOF, so a client still blocked in write() can finish and
    /// then read the error response we send before closing.
    private func drainRequestRemainder(from clientFD: Int32) {
        let deadline = Date().addingTimeInterval(Self.requestDrainTimeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            var receiveTimeout = timeval(
                tv_sec: Int(remaining),
                tv_usec: Int32((remaining - floor(remaining)) * 1_000_000)
            )
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead < 0 && errno == EINTR { continue }
            if bytesRead <= 0 { return } // EOF, error, or receive timeout
            if buffer[0..<bytesRead].contains(UInt8(ascii: "\n")) { return }
        }
    }

    /// A client that connects, sends a request, and stops draining its socket
    /// gets this long for the response before we give up and close on it —
    /// bounds how long a response write can pin a worker thread.
    private static let responseWriteTimeout: DispatchTimeInterval = .seconds(10)

    private func sendResponse(_ response: IPCResponse, to clientFD: Int32) {
        let responseData: Data
        if let encoded = try? JSONEncoder().encode(response) {
            responseData = encoded
        } else {
            responseData = Data("{\"ok\":false}".utf8)
        }

        // The fd is blocking, and a blocking write() past the kernel send
        // buffer stalls until the client drains — indefinitely, for a client
        // that never does. Flip it non-blocking and wait for writability in
        // poll() against a deadline instead, so the worst a wedged client
        // costs is `responseWriteTimeout` on a background thread.
        let flags = fcntl(clientFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)
        }
        let deadline = DispatchTime.now() + Self.responseWriteTimeout

        var payload = responseData
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            var remaining = payload.count
            var cursor = baseAddress
            while remaining > 0 {
                let written = write(clientFD, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                    continue
                }
                guard written < 0, errno == EAGAIN || errno == EINTR else { return }
                let nowNanos = DispatchTime.now().uptimeNanoseconds
                guard deadline.uptimeNanoseconds > nowNanos else { return }
                let waitMillis = Int32(min((deadline.uptimeNanoseconds - nowNanos) / 1_000_000, 1_000))
                var pfd = pollfd(fd: clientFD, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, max(waitMillis, 1))
                if ready < 0 && errno != EINTR { return }
                if ready > 0 && (pfd.revents & Int16(POLLOUT | POLLHUP | POLLERR)) == 0 { return }
            }
        }
    }
}

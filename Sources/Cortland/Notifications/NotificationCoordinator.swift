import AppKit
@preconcurrency import UserNotifications

/// What `NotificationCoordinator` needs from the app to build and route
/// notifications, kept as a protocol so the coordinator doesn't reach into
/// `MainWindowController`'s internals. `MainWindowController` conforms.
@MainActor
protocol NotificationCoordinatorHost: AnyObject {
    /// The title to show for a pane's notification (its tab title), or nil if the
    /// pane no longer exists.
    func notificationTabTitle(forPane paneID: UUID) -> String?

    /// Bring Cortland forward and focus the tab + pane. Called ONLY when the user
    /// clicks a notification — the one time activating is the user's intent.
    func focusPaneFromNotification(paneID: UUID)
}

/// Mirrors the app's existing attention signals — agent state transitions, the
/// C2 failed-command mark, and long-running command completions — to native
/// macOS notifications. A thin, strictly opt-in bridge: it observes the same
/// `NotificationCenter` events the rest of the app already posts, runs the pure
/// `NotificationsConfig` gate to decide whether to deliver, and drives
/// `UNUserNotificationCenter`. All decision logic lives in `NotificationPolicy`
/// so it can be tested without this plumbing.
///
/// Invariants:
/// - Never notifies while Cortland is frontmost (`NSApp.isActive`).
/// - Never activates or steals focus except on a notification click.
/// - One identifier per pane, so repeats replace rather than stack.
/// - Withdraws a pane's notification when its attention resolves (agent resumed,
///   command mark cleared) or when the user returns to Cortland.
/// - Requests authorization lazily (on first enable / first delivery), never at
///   launch.
@MainActor
final class NotificationCoordinator: NSObject {
    private weak var host: NotificationCoordinatorHost?
    private var config: NotificationsConfig

    /// The trigger currently showing for each pane, so a resolution event knows
    /// whether (and what) to withdraw. Keyed by `PaneModel.id`.
    private var delivered: [UUID: NotificationTrigger] = [:]

    /// Last agent state we saw per pane. `.paneAgentStateChanged` fires on every
    /// detection, not just changes, so we diff against this to find real
    /// transitions.
    private var lastAgentState: [UUID: AgentState] = [:]

    /// Each pane's most recently finished command, so a failed-command
    /// notification can name the command instead of just the tab. Fed by
    /// `.paneCommandStatusChanged`, which also produces the attention mark.
    private var lastCommandStatus: [UUID: TerminalCommandStatus] = [:]

    /// When Cortland last became inactive; nil while it is frontmost. Drives the
    /// background grace period for completion/failure notifications.
    private var backgroundSince: Date?

    init(host: NotificationCoordinatorHost, config: NotificationsConfig) {
        self.host = host
        self.config = config
        self.backgroundSince = NSApp.isActive ? nil : Date()
        super.init()

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        observe()
    }

    // MARK: - Config

    /// Swap in a fresh config (config-file reload or a Preferences change). Does
    /// NOT request authorization — that stays a user-initiated action so we never
    /// prompt at launch. See `requestAuthorizationIfNeeded()`.
    func updateConfig(_ newConfig: NotificationsConfig) {
        config = newConfig
    }

    // MARK: - Authorization (lazy, never at launch)

    /// Make sure the user can actually receive notifications, prompting only
    /// when macOS has never asked. Calls back on the main actor with the
    /// effective status: `.notDetermined` resolves to the user's answer to the
    /// system prompt; `.denied` means Cortland is blocked in System Settings and
    /// the caller should point the user there; `.authorized`/`.provisional` need
    /// nothing. Called from a Preferences toggle — a user action, never launch.
    func ensureAuthorization(completion: @escaping @MainActor (UNAuthorizationStatus) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    Task { @MainActor in completion(granted ? .authorized : .denied) }
                }
            default:
                let status = settings.authorizationStatus
                Task { @MainActor in completion(status) }
            }
        }
    }

    // MARK: - Observation

    private func observe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(agentStateChanged(_:)),
                       name: .paneAgentStateChanged, object: nil)
        nc.addObserver(self, selector: #selector(commandAttentionChanged(_:)),
                       name: .paneCommandAttentionChanged, object: nil)
        nc.addObserver(self, selector: #selector(commandStatusChanged(_:)),
                       name: .paneCommandStatusChanged, object: nil)
        nc.addObserver(self, selector: #selector(paneDidClose(_:)),
                       name: .paneDidClose, object: nil)
        nc.addObserver(self, selector: #selector(appDidResignActive),
                       name: NSApplication.didResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidBecomeActive),
                       name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func agentStateChanged(_ note: Notification) {
        guard let pane = note.object as? PaneModel,
              let newState = note.userInfo?["agentState"] as? AgentState else { return }
        let old = lastAgentState[pane.id] ?? .idle
        lastAgentState[pane.id] = newState

        if let trigger = NotificationTrigger.forAgentTransition(from: old, to: newState) {
            attemptDeliver(trigger, paneID: pane.id)
        } else if let showing = delivered[pane.id], showing.isResolvedByAgentTransition(to: newState) {
            withdraw(paneID: pane.id)
        }
    }

    @objc private func commandAttentionChanged(_ note: Notification) {
        guard let pane = note.object as? PaneModel else { return }
        if pane.failedCommandAttention {
            // Deferred one runloop tick: the attention mark and our
            // `lastCommandStatus` are both fed by the same
            // `.paneCommandStatusChanged` post, and observer order is not
            // guaranteed. By the next tick the status observer has definitely
            // run, so the notification can name the command that failed.
            DispatchQueue.main.async { [weak self, weak pane] in
                guard let self, let pane, pane.failedCommandAttention else { return }
                self.attemptDeliver(.commandFailed, paneID: pane.id, status: self.lastCommandStatus[pane.id])
            }
        } else if let showing = delivered[pane.id], showing.isResolvedByCommandAttentionClear {
            withdraw(paneID: pane.id)
        }
    }

    @objc private func commandStatusChanged(_ note: Notification) {
        guard let pane = note.object as? PaneModel,
              let status = note.userInfo?["status"] as? TerminalCommandStatus else { return }
        lastCommandStatus[pane.id] = status
        guard config.longRunningCommandQualifies(duration: status.duration) else { return }
        attemptDeliver(.longRunningCommand, paneID: pane.id, status: status)
    }

    @objc private func paneDidClose(_ note: Notification) {
        guard let pane = note.object as? PaneModel else { return }
        lastAgentState[pane.id] = nil
        lastCommandStatus[pane.id] = nil
        withdraw(paneID: pane.id)
    }

    @objc private func appDidResignActive() {
        if backgroundSince == nil { backgroundSince = Date() }
    }

    @objc private func appDidBecomeActive() {
        backgroundSince = nil
        // The user returned, so every pending/delivered notification's attention
        // is resolved — clear the noise without stealing focus (we're already
        // frontmost here).
        withdrawAll()
    }

    // MARK: - Delivery

    private func backgroundedFor() -> TimeInterval? {
        backgroundSince.map { Date().timeIntervalSince($0) }
    }

    private func attemptDeliver(_ trigger: NotificationTrigger, paneID: UUID, status: TerminalCommandStatus? = nil) {
        let decision = config.shouldDeliver(
            trigger,
            appIsActive: NSApp.isActive,
            backgroundedFor: backgroundedFor()
        )
        guard decision == .deliver else { return }
        guard let tabTitle = host?.notificationTabTitle(forPane: paneID) else { return }

        delivered[paneID] = trigger
        post(
            identifier: paneID.uuidString,
            title: title(for: trigger, status: status),
            subtitle: tabTitle,
            body: body(for: trigger, status: status),
            paneID: paneID
        )
    }

    private func title(for trigger: NotificationTrigger, status: TerminalCommandStatus?) -> String {
        switch trigger {
        case .needsInput: return "Agent waiting for input"
        case .finished: return "Agent finished"
        case .commandFailed: return "Command failed"
        case .longRunningCommand: return (status?.succeeded == false) ? "Command failed" : "Command finished"
        }
    }

    /// The body names the command and its outcome; the tab lives in the
    /// subtitle and the verdict in the title, so neither is repeated here.
    private func body(for trigger: NotificationTrigger, status: TerminalCommandStatus?) -> String {
        switch trigger {
        case .needsInput, .finished:
            return ""
        case .commandFailed, .longRunningCommand:
            guard let status else { return "" }
            var parts: [String] = []
            if let command = status.command { parts.append(Self.truncate(command)) }
            if !status.succeeded { parts.append("exit \(status.exitCode)") }
            if let duration = status.duration { parts.append(Self.durationString(duration)) }
            return parts.joined(separator: " · ")
        }
    }

    private static func truncate(_ command: String, to limit: Int = 80) -> String {
        command.count > limit ? command.prefix(limit - 1) + "…" : command
    }

    private static func durationString(_ duration: TimeInterval) -> String {
        guard duration >= 60 else { return String(format: "%.1fs", duration) }
        return "\(Int(duration) / 60)m \(Int(duration) % 60)s"
    }

    /// Schedule (or replace, since the identifier is per-pane) a system
    /// notification. No sound by default — quiet hours are macOS Focus/DND's job.
    private func post(identifier: String, title: String, subtitle: String, body: String, paneID: UUID) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = nil
        content.userInfo = ["paneID": paneID.uuidString]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                center.add(request)
            case .notDetermined:
                // Lazy first-delivery authorization — the prompt appears on a real
                // event, never at launch.
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { center.add(request) }
                }
            default:
                break  // denied — nothing to do
            }
        }
    }

    // MARK: - Withdrawal

    private func withdraw(paneID: UUID) {
        guard delivered.removeValue(forKey: paneID) != nil else { return }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let id = paneID.uuidString
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    private func withdrawAll() {
        guard !delivered.isEmpty else { return }
        let ids = delivered.keys.map { $0.uuidString }
        delivered.removeAll()
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationCoordinator: UNUserNotificationCenterDelegate {
    /// A click: focus the tab + pane (the only time activation is allowed).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let paneIDString = response.notification.request.content.userInfo["paneID"] as? String
        if let paneIDString, let paneID = UUID(uuidString: paneIDString) {
            Task { @MainActor in
                self.delivered[paneID] = nil
                self.host?.focusPaneFromNotification(paneID: paneID)
            }
        }
        completionHandler()
    }

    /// We only ever deliver while inactive; if the app is frontmost when one is
    /// about to present, suppress the banner (the user is already here).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

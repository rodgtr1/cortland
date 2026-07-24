import Cocoa

/// A single app-wide local event monitor shared by every terminal pane.
///
/// Previously each `TerminalViewController` installed its own
/// `NSEvent.addLocalMonitorForEvents`, so every scroll / drag / mouse-up in the
/// app ran O(panes) closures — one per pane — even though only the pane under
/// the cursor ever acts on the event (P6). This installs exactly one monitor;
/// panes register on load and unregister on deinit, and each event is dispatched
/// to the pane whose terminal it lands on.
///
/// Handlers self-filter (window match, visibility, bounds) and return `nil` to
/// consume the event or the event to pass it through, so dispatch just walks the
/// registered panes and stops at the first one that consumes — behaviourally
/// identical to the old chain of monitors, minus the per-pane OS registrations.
@MainActor
final class TerminalEventCoordinator {
    static let shared = TerminalEventCoordinator()
    private init() {}

    private struct WeakPane {
        weak var controller: TerminalViewController?
    }

    private var monitor: Any?
    private var panes: [WeakPane] = []

    /// Whether the in-flight left-button gesture has dragged. A drag is a text
    /// selection and must never be treated as a link click. This lives on the
    /// coordinator rather than per pane because there is only one pointer, and a
    /// drag that begins in one pane must still be visible to the pane that
    /// receives the mouse-up.
    private var sawLeftMouseDrag = false

    func register(_ controller: TerminalViewController) {
        panes.removeAll { $0.controller == nil || $0.controller === controller }
        panes.append(WeakPane(controller: controller))
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
            ) { [weak self] event in
                self?.dispatch(event) ?? event
            }
        }
    }

    func unregister(_ controller: TerminalViewController) {
        removePanes { $0.controller == nil || $0.controller === controller }
    }

    /// Self-free variant of `unregister` for use from a deinit that has hopped to
    /// the main thread and can no longer reference the controller: a deallocating
    /// controller's weak entry already reads nil, so pruning nil entries removes
    /// it and tears down the monitor once the last pane is gone.
    func pruneDeallocated() {
        removePanes { $0.controller == nil }
    }

    private func removePanes(where shouldRemove: (WeakPane) -> Bool) {
        panes.removeAll(where: shouldRemove)
        if panes.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func dispatch(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            // Never consumed — the pane it lands on only notes whether the
            // press starts a ⌘+click, whose mouse reports Cortland keeps to
            // itself. Every registered pane is offered it; each self-filters.
            return deliver(event) { $0.handleTerminalMouseDown(event) }
        case .leftMouseDragged:
            // A drag is a selection gesture; note it and let SwiftTerm finish it.
            sawLeftMouseDrag = true
            return event
        case .leftMouseUp:
            let wasDrag = sawLeftMouseDrag
            sawLeftMouseDrag = false
            return deliver(event) { $0.handleTerminalMouseUp(event, wasDrag: wasDrag) }
        case .scrollWheel:
            return deliver(event) { $0.handleScrollWheelEvent(event) }
        default:
            return event
        }
    }

    /// Offers the event to each live pane until one consumes it (returns nil).
    /// Panes over which the event doesn't land return the event unchanged, so at
    /// most one non-overlapping visible pane ever acts.
    private func deliver(
        _ event: NSEvent,
        _ handler: (TerminalViewController) -> NSEvent?
    ) -> NSEvent? {
        var pruneNeeded = false
        var current: NSEvent? = event
        for weakPane in panes {
            guard let pane = weakPane.controller else { pruneNeeded = true; continue }
            current = handler(pane)
            if current == nil { break }
        }
        if pruneNeeded {
            panes.removeAll { $0.controller == nil }
        }
        return current
    }
}

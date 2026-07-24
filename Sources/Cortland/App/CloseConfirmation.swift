import Foundation

/// The wording of the alert shown before a close tears panes down: busy agents,
/// editor buffers with unsaved edits, or both in a single prompt. Pure so the
/// rules are unit-testable without a live window — MainWindowController turns it
/// into an NSAlert (see `runConfirmation`).
///
/// The split between the two factories mirrors the two kinds of close:
/// `quit` for the whole window (never gated by `behavior.confirm_close` — it's
/// the last line of defense before the PTYs die), `close` for a pane or tab.
struct CloseConfirmation: Equatable {
    let messageText: String
    let informativeText: String
    /// The button that proceeds and loses the work ("Quit Anyway", "Close").
    let proceedButtonTitle: String
    /// True when the close would discard unsaved editor edits, so the alert
    /// leads with a Save button (Save / Cancel / proceed) instead of the plain
    /// proceed / Cancel pair.
    let offersSave: Bool

    /// Confirmation for ⌘Q or a window close, where everything every tab holds
    /// goes away. Nil when there's nothing to lose.
    static func quit(busyPaneCount: Int, modifiedFileNames: [String]) -> CloseConfirmation? {
        guard busyPaneCount > 0 || !modifiedFileNames.isEmpty else { return nil }

        var sentences: [String] = []
        if !modifiedFileNames.isEmpty {
            sentences.append(unsavedSentence(modifiedFileNames))
        }
        if busyPaneCount > 0 {
            sentences.append("Quitting Cortland will end "
                + (busyPaneCount == 1 ? "this session" : "these sessions")
                + " and any running commands.")
        }
        sentences.append("Quit anyway?")

        let message: String
        if busyPaneCount > 0 {
            message = busyPaneCount == 1 ? "An agent is still working" : "\(busyPaneCount) agents are still working"
        } else {
            message = modifiedFileNames.count == 1
                ? "\(modifiedFileNames[0]) has unsaved changes"
                : "\(modifiedFileNames.count) files have unsaved changes"
        }

        return CloseConfirmation(
            messageText: message,
            informativeText: sentences.joined(separator: " "),
            proceedButtonTitle: "Quit Anyway",
            offersSave: !modifiedFileNames.isEmpty
        )
    }

    /// Confirmation for closing a pane, tab, or window from the UI.
    ///
    /// `confirmSessionClose` is `behavior.confirm_close`, and gates the *session*
    /// half only: keyboard closes (⌘W / ⇧⌘W) pass it, a mouse X passes false so
    /// clicking the X stays prompt-free for sessions (commit 0811e51 — a click on
    /// the X isn't a stray keystroke). Unsaved editor edits prompt on every path:
    /// they're silent data loss, not a session the user can restart.
    ///
    /// `terminalPaneCount` is how many of the panes hold a shell, so a pane with
    /// nothing running (a clean editor) needs no confirmation at all.
    static func close(target: String,
                      terminalPaneCount: Int,
                      busyPaneCount: Int,
                      modifiedFileNames: [String],
                      confirmSessionClose: Bool) -> CloseConfirmation? {
        let confirmsSessions = confirmSessionClose && (terminalPaneCount > 0 || busyPaneCount > 0)
        guard confirmsSessions || !modifiedFileNames.isEmpty else { return nil }

        var sentences: [String] = []
        if !modifiedFileNames.isEmpty {
            sentences.append(unsavedSentence(modifiedFileNames))
        }
        if confirmsSessions {
            if busyPaneCount > 0 {
                sentences.append((busyPaneCount == 1
                    ? "An agent is still working here."
                    : "\(busyPaneCount) agents are still working here.")
                    + " Closing will end "
                    + (busyPaneCount == 1 ? "its session" : "their sessions")
                    + " and any running commands.")
            } else {
                let sessions = terminalPaneCount == 1
                    ? "its terminal session"
                    : "its \(terminalPaneCount) terminal sessions"
                sentences.append("Closing will end \(sessions) and any running commands.")
            }
        }

        return CloseConfirmation(
            messageText: "Close this \(target)?",
            informativeText: sentences.joined(separator: " "),
            proceedButtonTitle: "Close",
            offersSave: !modifiedFileNames.isEmpty
        )
    }

    private static func unsavedSentence(_ names: [String]) -> String {
        "Unsaved edits to \(list(names)) will be lost."
    }

    /// "a.txt", "a.txt and b.txt", "a.txt, b.txt, and 2 more".
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return "\(names[0]), \(names[1]), and \(names.count - 2) more"
        }
    }
}

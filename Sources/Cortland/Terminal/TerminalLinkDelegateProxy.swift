import AppKit
import SwiftTerm

/// Cortland's stand-in for the terminal view's own `TerminalViewDelegate`.
///
/// `LocalProcessTerminalView` makes *itself* the `terminalDelegate` and forwards
/// only a hand-picked few of those callbacks to its `processDelegate` (the one
/// Cortland gets to implement). `requestOpenLink` is not among them, and
/// `LocalProcessTerminalView` doesn't implement it either — so link activation
/// falls through to SwiftTerm's protocol-extension default:
///
///     if let url = URL(string: link) { NSWorkspace.shared.open(url) }
///
/// That default hands LaunchServices raw terminal text. A clicked file path
/// (`/private/tmp/…/notes.md`) parses as a schemeless URL, LaunchServices
/// refuses it with -50, and Finder puts up "The application can't be opened."
/// Worse, it's invisible from Cortland's side: a `requestOpenLink` written on
/// `TerminalViewController` is dead code, because the protocol that controller
/// conforms to has no such requirement, and a subclass of
/// `LocalProcessTerminalView` can't override it either — the witness was bound
/// to the extension default when the superclass declared the conformance.
///
/// Slotting this proxy in between gives link activation one owner. Every other
/// callback is forwarded untouched to the view, whose implementations (PTY
/// resize, keystroke send, title, cwd) have to keep running exactly as before.
final class TerminalLinkDelegateProxy: TerminalViewDelegate {
    /// The view that would otherwise be its own delegate. Unowned: the view owns
    /// this proxy's lifetime through the controller that holds both.
    private unowned let view: LocalProcessTerminalView
    private let onOpenLink: (String) -> Void

    init(view: LocalProcessTerminalView, onOpenLink: @escaping (String) -> Void) {
        self.view = view
        self.onOpenLink = onOpenLink
    }

    // MARK: - The one callback Cortland handles itself

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        onOpenLink(link)
    }

    // MARK: - Forwarded to the view's own implementations

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        view.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Keystrokes and mouse reports on their way to the PTY. Dispatches to
        // AgentAwareTerminalView's override, which is where Cortland's input
        // gating lives, before the base class writes to the process.
        view.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        view.scrolled(source: source, position: position)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        view.clipboardCopy(source: source, content: content)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        view.rangeChanged(source: source, startY: startY, endY: endY)
    }

    // MARK: - Callbacks SwiftTerm defaults for everyone

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        // Same no-op as SwiftTerm's default.
    }
}

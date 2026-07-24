import Cocoa
import CortlandIPCCore
import SwiftTerm

protocol TerminalViewControllerDelegate: AnyObject {
    func terminalDidUpdateTitle(_ terminal: TerminalViewController, directory: String, branch: String?)
    func terminalDidDetectAgentState(_ terminal: TerminalViewController, state: AgentState)
    func terminalDidUpdateCommandStatus(_ terminal: TerminalViewController, status: TerminalCommandStatus?)
    func terminalRequestsOpenURL(_ terminal: TerminalViewController, url: URL)
    func terminalRequestsOpenFile(_ terminal: TerminalViewController, path: String, line: Int?)
}

/// Classifies the raw byte sequences the terminal sends upstream to the child
/// process, so we can tell genuine keystrokes from terminal-generated reports
/// (focus / mouse) and, within mouse reports, pointer motion from button clicks.
enum MouseReportClassifier {
    /// True when `data` is purely a focus-tracking (CSI I / CSI O) or
    /// mouse-report (CSI M… / CSI <…) sequence the terminal generated on its
    /// own, rather than a genuine keystroke or paste.
    nonisolated static func isTerminalGeneratedReport(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count >= 3 else { return false }
        let bytes = Array(data)
        guard bytes[0] == 0x1B, bytes[1] == 0x5B else { return false } // ESC [
        switch bytes[2] {
        case 0x49, 0x4F:          // CSI I / CSI O — focus in / focus out
            return bytes.count == 3
        case 0x4D, 0x3C:          // CSI M / CSI < — mouse report (X10 / SGR)
            return true
        default:
            return false
        }
    }

    /// A mouse report that presses or releases a button, used to track button
    /// state. A hover (motion with no button) and a drag (motion with a button
    /// held) encode identically in the button field, so the bytes of a motion
    /// report alone can't tell them apart — only the running press/release
    /// state can.
    nonisolated enum ButtonTransition: Equatable { case press, release, none }

    /// Classifies whether `data` presses or releases a mouse button (as opposed
    /// to motion, wheel, or a non-mouse sequence). Wheel events (bit 6) are not
    /// treated as button holds.
    nonisolated static func buttonTransition(_ data: ArraySlice<UInt8>) -> ButtonTransition {
        guard data.count >= 4 else { return .none }
        let bytes = Array(data)
        guard bytes[0] == 0x1B, bytes[1] == 0x5B else { return .none } // ESC [
        switch bytes[2] {
        case 0x3C: // SGR: ESC [ < Cb ; Cx ; Cy (M|m)
            if isMouseMotionReport(data) { return .none }
            var value = 0
            var sawDigit = false
            for b in bytes[3...] {
                guard b >= 0x30, b <= 0x39 else { break }
                value = value * 10 + Int(b - 0x30)
                sawDigit = true
            }
            guard sawDigit, (value & 0x40) == 0 else { return .none } // skip wheel
            switch bytes[bytes.count - 1] {
            case 0x4D: return .press   // 'M'
            case 0x6D: return .release // 'm'
            default:   return .none
            }
        case 0x4D: // X10: ESC [ M Cb Cx Cy — no per-button release; button 3 = release
            if isMouseMotionReport(data) { return .none }
            let cb = Int(bytes[3]) - 32
            guard cb >= 0, (cb & 0x40) == 0 else { return .none } // skip wheel
            return (cb & 0x03) == 3 ? .release : .press
        default:
            return .none
        }
    }

    /// True when `data` is a mouse *motion* report (the pointer moved) rather
    /// than a button press or release. Motion is flagged by bit 5 (value 0x20)
    /// of the button field, in both SGR (`CSI < Cb ; Cx ; Cy`) and X10
    /// (`CSI M Cb Cx Cy`, each byte offset by 32) encodings. Clicks and
    /// releases leave that bit clear.
    nonisolated static func isMouseMotionReport(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = Array(data)
        guard bytes[0] == 0x1B, bytes[1] == 0x5B else { return false } // ESC [
        switch bytes[2] {
        case 0x3C: // SGR: ESC [ < Cb ; Cx ; Cy (M | m)
            var value = 0
            var sawDigit = false
            for b in bytes[3...] {
                guard b >= 0x30, b <= 0x39 else { break }
                value = value * 10 + Int(b - 0x30)
                sawDigit = true
            }
            return sawDigit && (value & 0x20) != 0
        case 0x4D: // X10: ESC [ M Cb Cx Cy
            let cb = Int(bytes[3]) - 32
            return cb >= 0 && (cb & 0x20) != 0
        default:
            return false
        }
    }
}

/// Turns the string SwiftTerm reports under a clicked cell into a URL worth
/// handing to the browser.
///
/// SwiftTerm's implicit matcher is a path matcher as much as a URL one, so it
/// happily returns `developers.cloudflare.com/docs-for-agents/` — a real link
/// with no scheme. `NSWorkspace` can't open that (it fails with -50, "The
/// application can't be opened"), so a link whose first segment reads as a
/// hostname is promoted to https here. Everything else that isn't http(s) is
/// refused: file paths get their turn earlier, in the ⌘+click file handler.
enum TerminalLinkNormalizer {
    nonisolated static func openableURL(from raw: String) -> URL? {
        var candidate = raw
        // Trim punctuation that commonly trails URLs in prose.
        while let last = candidate.last, ".,;:!?".contains(last) {
            candidate.removeLast()
        }
        guard !candidate.isEmpty else { return nil }

        let lowered = candidate.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: candidate)
        }
        // Scheme-ish text that isn't http(s) — mailto:, file:, a Windows path —
        // is none of our business. Checked before the hostname test because a
        // dotted authority with a port (`host.com:8080/x`) parses as a URL whose
        // "scheme" is the host: dots are legal scheme characters.
        guard !lowered.contains("://"),
              looksLikeHostname(candidate.prefix { $0 != "/" }) else { return nil }
        return URL(string: "https://" + candidate)
    }

    /// A dotted authority (`docs.example.com`, `example.co.uk:8080`) as opposed
    /// to a relative file path. Requires two or more labels and an alphabetic
    /// last one, so `src/main.rs` and `build/out.tar.gz` stay paths.
    nonisolated private static func looksLikeHostname(_ authority: Substring) -> Bool {
        var host = authority
        // Strip a trailing :port, but only if it really is digits.
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return false }
            host = host[..<colon]
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty,
                  label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return false }
        }
        guard let tld = labels.last, tld.count >= 2, tld.count <= 24,
              tld.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return true
    }
}

private final class AgentAwareTerminalView: LocalProcessTerminalView {
    var onOutput: ((String) -> Void)?
    /// Carries the keystroke's bytes so the agent-state detector can tell a
    /// prompt-answering key (Enter, option digit) from arrows or typing.
    var onInput: ((ArraySlice<UInt8>) -> Void)?

    /// Whether a mouse button is currently held, tracked from the press/release
    /// reports we forward. Lets `send` tell a hover (motion, no button) from a
    /// drag (motion with a button held) — the two are byte-identical otherwise.
    private var mouseButtonDown = false

    /// Set while a click that belongs to Cortland rather than to the app inside
    /// is in flight — the click that switched pane focus (its job was picking a
    /// pane, not picking whatever option sat under the pointer) and any
    /// ⌘+click (its job is opening a link or file). Their mouse reports must
    /// not reach the app. Armed from the click monitors, which run before the
    /// view sees the mouse-down, and disarmed by the gesture's release.
    private var suppressFocusClickReports = false

    /// Arms the gate for the in-flight click gesture.
    func suppressReportsForClickGesture() {
        suppressFocusClickReports = true
    }

    /// Force-clears the button-held latch. The latch is normally cleared by the
    /// release report passing through `send`, but a mouse-up that Cortland
    /// swallows (a click on a link) never produces one, so the physical mouse-up
    /// handler calls this directly. Otherwise the latch stays stuck `true` and
    /// later hover motion on the alternate screen is mis-forwarded as a drag.
    /// The focus-click gate is cleared here too: a focusing click over an app
    /// with mouse reporting off produces no release report to disarm it.
    func clearMouseButtonLatch() {
        mouseButtonDown = false
        suppressFocusClickReports = false
    }

    /// Bytes of a multibyte UTF-8 rune that arrived split across PTY reads,
    /// held until the rest shows up. SwiftTerm always gets the raw slice for
    /// display; this only affects the decoded `onOutput` detection stream.
    private var utf8Carry: [UInt8] = []

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // The terminal display always receives the raw bytes, untouched.
        super.dataReceived(slice: slice)

        guard onOutput != nil else { return }
        utf8Carry.append(contentsOf: slice)
        let prefix = Self.completeUTF8PrefixCount(utf8Carry)
        // The whole buffer is a single still-incomplete rune — wait for more.
        guard prefix > 0 else { return }
        let chunk = String(decoding: utf8Carry[0..<prefix], as: UTF8.self)
        utf8Carry.removeFirst(prefix)
        onOutput?(chunk)
    }

    /// Number of leading bytes that form complete UTF-8 sequences, holding back
    /// only a trailing multibyte sequence whose continuation bytes haven't all
    /// arrived yet. Genuinely malformed bytes (no lead found) are not held back
    /// — they're emitted and decode to U+FFFD, matching prior behavior.
    private static func completeUTF8PrefixCount(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var i = bytes.count - 1
        let lowerBound = max(0, bytes.count - 3)
        while i >= lowerBound {
            let b = bytes[i]
            if b & 0x80 == 0 { return bytes.count }          // ASCII: complete to end
            if b & 0xC0 == 0xC0 {                            // multibyte lead byte
                let expected = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : 2)
                return (bytes.count - i) >= expected ? bytes.count : i
            }
            i -= 1                                           // continuation byte: walk to its lead
        }
        return bytes.count
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Track button state from the press/release reports we forward, so we
        // can tell a hover from a drag below.
        let transition = MouseReportClassifier.buttonTransition(data)
        switch transition {
        case .press:   mouseButtonDown = true
        case .release: mouseButtonDown = false
        case .none:    break
        }

        // The click that switched pane focus: drop its press, drag motion, and
        // release so "click to activate this pane" can't double as "answer the
        // prompt in it". Keystrokes and focus in/out reports still pass.
        if suppressFocusClickReports {
            if transition == .release {
                suppressFocusClickReports = false
                return
            }
            if transition == .press || MouseReportClassifier.isMouseMotionReport(data) {
                return
            }
        }

        // Pointer motion belongs to Cortland — selection, scrollback, link
        // hover — not to inline apps, EXCEPT a real drag-select inside an
        // alternate-screen TUI (vim, lazygit). Claude Code runs on the
        // alternate screen yet keeps motion reporting (DECSET 1003) on for its
        // hover-to-expand effect; forwarding that hover motion makes it
        // re-render on every pixel of movement, which flickers the inline tool
        // rows and — via SwiftTerm's synchronized-output (CSI 2026) snapshot —
        // could wedge the display on a stale frame while the agent waits for
        // unseen input. A hover and a drag encode identically, so we split them
        // by tracked button state: drop motion unless a button is held on the
        // alternate screen. Clicks/releases always reach the app, so selection,
        // scrollback, prompt clicks, and link hover are untouched. Companion to
        // the scroll-wheel gate in 925c08b.
        if MouseReportClassifier.isMouseMotionReport(data) {
            let dragInAltScreen = mouseButtonDown && getTerminal().isCurrentBufferAlternate
            if !dragInAltScreen { return }
        }
        // Clicks on the NORMAL screen belong to Cortland too — the same
        // decision the scroll-wheel gate makes. Claude Code and other inline
        // REPLs keep mouse reporting on, so a click that was only meant to
        // land focus (or check which pane is active) silently picked whatever
        // prompt option sat under the pointer; answering is arrows + Enter.
        // Alternate-screen TUIs (vim, lazygit) keep full click support.
        if transition != .none, !getTerminal().isCurrentBufferAlternate {
            return
        }
        // Focus and mouse reports are emitted by the emulator itself when the
        // view is focused, clicked, or hovered — the user didn't type them, so
        // they must not count as "the user is working" (that flipped a finished
        // agent back to Working whenever its tab was activated).
        if !MouseReportClassifier.isTerminalGeneratedReport(data) {
            onInput?(data)
        }
        super.send(source: source, data: data)
    }
}

class TerminalViewController: NSViewController, LocalProcessTerminalViewDelegate {
    weak var delegate: TerminalViewControllerDelegate?
    private var terminalView: LocalProcessTerminalView!
    private var config: Config
    /// The four terminal inset constraints paired with their sign, kept so
    /// applyConfig can re-apply window.padding live instead of only at setup.
    private var paddingConstraints: [(constraint: NSLayoutConstraint, sign: CGFloat)] = []
    // nonisolated(unsafe) only so deinit's off-main branch can hand the timer
    // to the main queue for invalidation; every other access is MainActor.
    nonisolated(unsafe) private var cwdTimer: Timer?
    private var currentCWD: String = "~"
    private var isUpdatingCWD = false

    // Consolidated git access: the single entry point for asking git a question
    // (repo root, branch), spawning through the shared ProcessRunner.
    private let gitService = GitService()
    // FSEvents-backed branch tracking for the pane title, so an in-place branch
    // switch or commit (which leaves the cwd unchanged) refreshes the title
    // without polling. Points at the current cwd's repository root.
    private let branchWatcher = RepositoryWatcher()
    private var watchedRepoRoot: String?

    // SwiftTerm tracks the exact child PID; scanning `ps` for "a child of
    // this app" breaks as soon as a second tab (or any transient child
    // process) exists.
    private var shellPID: pid_t {
        terminalView?.process?.shellPid ?? 0
    }

    /// Kills the pane's shell (SIGTERM) and closes its PTY. SwiftTerm never
    /// does this on dealloc — `LocalProcess`'s pending DispatchIO read keeps
    /// itself, the master fd, and the child alive — so every pane/tab close
    /// path must call this or the shell (and anything it runs, like a dev
    /// server holding a port) survives invisibly until app quit.
    func terminateProcess() {
        terminalView?.process?.terminate()
    }
    private var initialDirectory: String?
    private let paneID: UUID
    private let initialCommand: [String]?
    /// The agent-state machine (explicit OSC 666 reports, text heuristics,
    /// quiet-period done detection, blocked-state polling), extracted so its
    /// interacting state is testable. Wired to this pane in `viewDidLoad`.
    private let agentStateDetector = AgentStateDetector()
    /// Buffered OSC 133/666 sequence extraction from the output stream.
    private var shellIntegrationParser = ShellIntegrationParser()
    private var pendingDetectionOutput = ""
    private var detectionFlushScheduled = false
    private var automationOutput = ""
    // Monotonic UTF-8 byte count of everything ever appended to
    // `automationOutput` over this shell's lifetime — the offset a `pane_read`
    // cursor encodes. `automationOutputDroppedBytes` tracks how many of those
    // leading bytes the rolling-buffer trim has since evicted, so the invariant
    // `dropped + automationOutput.utf8.count == total` holds; a `since` cursor
    // pointing before `dropped` can no longer be served as a delta.
    private var automationOutputTotalBytes = 0
    private var automationOutputDroppedBytes = 0

    private var findBar: TerminalFindBar?
    private var alternateScrollAccumulator: CGFloat = 0

    // Dev-server detection
    private var serverBannerDetector = ServerBannerDetector()
    private var detectedServerURL: URL?

    // The pane's one advisory bar (see showBanner): at most one showing at a time.
    private var bannerView: NSView?
    private var bannerDismissWork: DispatchWorkItem?

    // True once this pane has warned about a stale agent-status helper, so a hook
    // firing on every prompt doesn't re-raise the same banner all session.
    private var warnedStaleAgentStatusHelper = false

    // True once the shell has produced any output (prompt drawn). Gates
    // `sendOnShellReady` so a startup command waits for the prompt, not a timer.
    private var hasProducedOutput = false
    private var pendingStartupCommand: String?

    // Shell integration (OSC 7 + OSC 133) state
    private var hasShellIntegration = false
    private var promptMarkRows: [Int] = []
    private static let maxPromptMarks = 500

    // Per-command record capture (OSC 133 C..D windows), surfaced by
    // `cortland-ctl pane read --json` for agent-legible command history.
    private var commandRecorder = CommandRecorder()

    init(
        config: Config,
        initialDirectory: String? = nil,
        paneID: UUID = UUID(),
        command: [String]? = nil
    ) {
        self.config = config
        self.initialDirectory = initialDirectory
        self.paneID = paneID
        self.initialCommand = command?.isEmpty == false ? command : nil
        super.init(nibName: nil, bundle: nil)
        // Record an authoritative Session Recall ledger entry when Cortland
        // launches an agent (claude/codex): we know the cwd + branch first-hand
        // here, so the session list can later backfill logs that never recorded
        // a cwd. Fire-and-forget, background, and a no-op for non-agent commands.
        if let argv = self.initialCommand {
            let cwd = initialDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            SessionLaunchLedger.record(command: argv, cwd: cwd)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The detector already delivers state changes async on the main queue
        // and deduped, so the delegate is called directly here.
        agentStateDetector.onStateChange = { [weak self] state in
            guard let self else { return }
            self.delegate?.terminalDidDetectAgentState(self, state: state)
        }
        agentStateDetector.readVisibleScreen = { [weak self] in
            self?.readVisibleScreenText() ?? ""
        }
        // A change under the repo (commit, checkout, stage) can flip the branch
        // without moving the cwd, so refresh the title from FSEvents rather than
        // waiting for the next cwd change.
        branchWatcher.onChange = { [weak self] in
            self?.updateTitle()
        }
        setupTerminal()
        startConfiguredProcess()
        startCWDTracking()
        TerminalEventCoordinator.shared.register(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontZoomChanged),
            name: FontZoom.didChangeNotification,
            object: nil
        )
    }

    @objc private func fontZoomChanged() {
        terminalView.font = terminalFont(for: config)
    }

    /// The configured font with the app-wide zoom scale applied.
    private func terminalFont(for config: Config) -> NSFont {
        let size = CGFloat(Double(config.font.size) * FontZoom.shared.scale)
        return NSFont(name: config.font.family, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// A ⌘+click is Cortland's gesture — it opens a link in the browser or a
    /// file in the editor — so none of its mouse reports may reach the app in
    /// this terminal. `handleTerminalMouseUp` already swallows the release, but
    /// the press ran ahead of it and was forwarded: on the alternate screen
    /// (where Claude Code sits with mouse reporting on) the agent saw a plain
    /// click on the same link and opened it itself, so one ⌘+click landed two
    /// browser tabs. The xterm protocol has no bit for Command, so the app
    /// could not tell that click apart from an ordinary one.
    ///
    /// Always returns the event: SwiftTerm still needs the mouse-down for
    /// selection, and the pane-activation monitor still needs to see it. Only
    /// the reports going upstream to the child process are gated.
    func handleTerminalMouseDown(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command),
              let window = view.window,
              event.window === window,
              let terminalView = terminalView,
              !terminalView.isHiddenOrHasHiddenAncestor else { return event }

        let pointInView = terminalView.convert(event.locationInWindow, from: nil)
        guard terminalView.bounds.contains(pointInView) else { return event }

        (terminalView as? AgentAwareTerminalView)?.suppressReportsForClickGesture()
        return event
    }

    /// Owns link/file activation over the terminal. ⌘+click opens file paths
    /// in the built-in editor and URLs in the external browser. When the release
    /// lands on a link/file the event is swallowed so SwiftTerm's own handler
    /// can't ALSO open it — that handler opens links in the *external* browser
    /// (NSWorkspace.open) and fired even on stray clicks that SwiftTerm
    /// resolved to a URL, which is what made links open seemingly on hover.
    ///
    /// `wasDrag` is threaded in from `TerminalEventCoordinator` (a drag is a
    /// selection, never a link click). Returns nil to swallow the release, or the
    /// event to let SwiftTerm handle it. Self-filters to releases over this pane.
    func handleTerminalMouseUp(_ event: NSEvent, wasDrag: Bool) -> NSEvent? {
        guard let window = view.window,
              event.window === window,
              let terminalView = terminalView,
              // Hidden tabs share window coordinates with the visible one;
              // without this, an invisible terminal swallows the click.
              !terminalView.isHiddenOrHasHiddenAncestor else { return event }

        // The physical button is now up, so clear the held-button latch directly.
        // When we swallow this release below (a click on a link), SwiftTerm never
        // forwards a release report to clear it via `send`, which would otherwise
        // leave the latch stuck and mis-forward later hover motion as a drag (M9).
        (terminalView as? AgentAwareTerminalView)?.clearMouseButtonLatch()

        let pointInView = terminalView.convert(event.locationInWindow, from: nil)
        guard terminalView.bounds.contains(pointInView) else { return event }

        // A drag is a selection — let SwiftTerm finish it normally.
        guard !wasDrag else { return event }

        let terminal = terminalView.getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return event }

        let cellWidth = max(1, terminalView.bounds.width / CGFloat(terminal.cols))
        let cellHeight = max(1, terminalView.bounds.height / CGFloat(terminal.rows))
        let col = min(terminal.cols - 1, max(0, Int(pointInView.x / cellWidth)))
        let row = min(terminal.rows - 1, max(0, Int((terminalView.bounds.height - pointInView.y) / cellHeight)))

        let hasCommand = event.modifierFlags.contains(.command)

        if hasCommand, handleCommandClick(col: col, row: row) {
            return nil
        }
        if let url = urlUnderClick(col: col, row: row) {
            // Only a deliberate ⌘+click opens the link; a plain click is
            // swallowed so the link never opens on its own.
            if hasCommand {
                delegate?.terminalRequestsOpenURL(self, url: url)
            }
            return nil
        }
        // Not on a link/file: let SwiftTerm handle the click normally.
        return event
    }

    private func urlUnderClick(col: Int, row: Int) -> URL? {
        // Ask SwiftTerm for the link at this cell: it spans wrapped rows (so a
        // URL broken across lines is returned whole, not just the clicked
        // fragment) and understands OSC 8 hyperlinks.
        guard let candidate = terminalView.getTerminal().link(
            at: .screen(Position(col: col, row: row)),
            mode: .explicitAndImplicit
        ), !candidate.isEmpty else { return nil }

        return TerminalLinkNormalizer.openableURL(from: candidate)
    }

    /// SwiftTerm's scrollWheel only ever scrolls the scrollback buffer, which
    /// breaks full-screen (alternate-buffer) apps:
    ///  - alternate-screen apps WITH mouse reporting want the wheel as xterm
    ///    button 4/5 so they can scroll their own viewport;
    ///  - alternate-screen apps WITHOUT mouse reporting (vim, less) have no
    ///    scrollback, so wheel events should become arrow keys.
    /// On the NORMAL screen we always scroll our own scrollback — even when the
    /// app (e.g. Claude Code) keeps mouse reporting on for clicks — so scrolling
    /// over an inline prompt can't silently pick an option. Plain shells fall
    /// through to normal scrollback scrolling too. Dispatched from
    /// `TerminalEventCoordinator`; self-filters to scrolls over this pane.
    func handleScrollWheelEvent(_ event: NSEvent) -> NSEvent? {
        guard let window = view.window,
              event.window === window,
              let terminalView = terminalView,
              // Hidden tabs share window coordinates with the visible one;
              // without this, an invisible terminal handles the scroll.
              !terminalView.isHiddenOrHasHiddenAncestor else { return event }

        let terminal = terminalView.getTerminal()
        let reportsMouse = terminal.mouseMode != .off
        // Only hijack the wheel for full-screen (alternate-buffer) apps. Claude
        // Code and other normal-screen REPLs keep mouse reporting on to catch
        // clicks, so forwarding the wheel to them turns a scroll over an inline
        // prompt into a silent selection. On the normal screen the wheel scrolls
        // our own scrollback instead — which IS the app's output — matching
        // Ghostty/iTerm/xterm.
        guard terminal.isCurrentBufferAlternate else { return event }

        // Only handle events over this terminal's view.
        let pointInView = terminalView.convert(event.locationInWindow, from: nil)
        guard terminalView.bounds.contains(pointInView) else { return event }

        let lines: Int
        if event.hasPreciseScrollingDeltas {
            // Trackpad: accumulate pixel deltas into whole cell rows.
            let cellHeight = max(1, terminalView.bounds.height / CGFloat(max(1, terminal.rows)))
            alternateScrollAccumulator += event.scrollingDeltaY
            let wholeLines = Int(alternateScrollAccumulator / cellHeight)
            guard wholeLines != 0 else { return nil }
            alternateScrollAccumulator -= CGFloat(wholeLines) * cellHeight
            lines = wholeLines
        } else {
            guard event.deltaY != 0 else { return nil }
            lines = Int(event.deltaY.rounded(.awayFromZero))
        }

        let scrollingUp = lines > 0
        let count = min(10, abs(lines))

        if reportsMouse {
            // Send wheel events at the hovered cell (xterm buttons 4/5).
            let col = min(terminal.cols - 1, max(0, Int(pointInView.x / max(1, terminalView.bounds.width / CGFloat(max(1, terminal.cols))))))
            let cellHeight = max(1, terminalView.bounds.height / CGFloat(max(1, terminal.rows)))
            let row = min(terminal.rows - 1, max(0, Int((terminalView.bounds.height - pointInView.y) / cellHeight)))
            let buttonFlags = terminal.encodeButton(
                button: scrollingUp ? 4 : 5,
                release: false,
                shift: event.modifierFlags.contains(.shift),
                meta: event.modifierFlags.contains(.option),
                control: event.modifierFlags.contains(.control)
            )
            for _ in 0..<count {
                terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
            }
        } else {
            // Alternate screen without mouse reporting: arrow keys.
            let sequence = terminal.applicationCursor
                ? (scrollingUp ? "\u{1B}OA" : "\u{1B}OB")
                : (scrollingUp ? "\u{1B}[A" : "\u{1B}[B")
            terminalView.send(txt: String(repeating: sequence, count: count))
        }
        return nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Resume CWD polling for a tab that was hidden (no-op once shell
        // integration is detected — OSC 7 then pushes the cwd and the timer
        // stays off for good). Gate on the process still running rather than a
        // bare shellPID: SwiftTerm never clears shellPid after exit, so without
        // this a hide/show would restart a 1Hz poll against a dead PID.
        if !hasShellIntegration, cwdTimer == nil, terminalView?.process?.running == true {
            startCWDTracking()
        }
        // Focus terminal after view appears
        focusTerminal()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // A hidden tab's title/branch doesn't need live updates, so stop the 1Hz
        // CWD poll while it's offscreen. (Blocked-state polling is intentionally
        // left running: it's what surfaces a background un-hooked agent's
        // permission prompt as a dock bounce while you're looking elsewhere.)
        cwdTimer?.invalidate()
        cwdTimer = nil
    }

    private func setupTerminal() {
        let font = terminalFont(for: config)

        Log.debug("🔤 Terminal font: \(font.fontName) size: \(font.pointSize)", category: "terminal")

        let agentAwareTerminalView = AgentAwareTerminalView(frame: view.bounds)
        agentAwareTerminalView.onOutput = { [weak self] output in
            DispatchQueue.main.async {
                self?.appendAutomationOutput(output)
                self?.queueAgentDetection(output)
            }
        }
        agentAwareTerminalView.onInput = { [weak self] data in
            let bytes = [UInt8](data)
            DispatchQueue.main.async {
                self?.handleTerminalInput(bytes[...])
            }
        }
        terminalView = agentAwareTerminalView
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.font = font
        terminalView.useBrightColors = config.font.boldIsBright

        // Keep the first 16 ANSI colors themed, but leave 256-color indexes on
        // the standard xterm cube so CLI theme pickers render selected colors faithfully.
        terminalView.terminal.ansi256PaletteStrategy = .xterm
        applyThemeColors()

        // Apply background based on blur configuration
        terminalView.wantsLayer = true
        applyTerminalAppearance(config)

        // Set delegate to receive process events
        terminalView.processDelegate = self

        view.addSubview(terminalView)

        // Apply padding from config. Keep the constraints (with their edge sign)
        // so applyConfig can update the inset when window.padding changes.
        let padding = CGFloat(config.window.padding)
        let top = terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: padding)
        let leading = terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding)
        let trailing = terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding)
        let bottom = terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding)
        paddingConstraints = [(top, 1), (leading, 1), (trailing, -1), (bottom, -1)]
        NSLayoutConstraint.activate([top, leading, trailing, bottom])
    }

    /// Re-applies `window.padding` to the terminal inset constraints.
    private func applyPadding(_ config: Config) {
        let padding = CGFloat(config.window.padding)
        for entry in paddingConstraints {
            entry.constraint.constant = entry.sign * padding
        }
    }

    /// Fixed launch script for direct workers, run as the user's shell's `-c`
    /// command. `exec "$@"` runs the requested argv without re-parsing it. The
    /// PATH prepend runs after the shell's rc files (which may rewrite PATH),
    /// putting Cortland's worker shims first, so an agent CLI resolved anywhere
    /// in the worker's process tree — even inside a `sh -c 'exec claude …'`
    /// wrapper, which the argv injection below cannot see through — still
    /// receives the pane-scoped approval flags. Internal for tests.
    static let workerLaunchScript =
        #"[ -n "$CORTLAND_SHIM_DIR" ] && PATH="$CORTLAND_SHIM_DIR:$PATH"; exec "$@""#

    /// Injects `--permission-mode <mode>` into a Cortland-launched `claude` worker
    /// when an auto/bypass approval level is active. Workers run via `exec`, which
    /// bypasses the shell-integration `claude` wrapper, so the flag must go on the
    /// argv directly. Leaves a caller-supplied `--permission-mode` untouched and
    /// only touches commands whose program is `claude`.
    private static func applyingClaudePermissionMode(_ command: [String]) -> [String] {
        guard let mode = AgentApprovalState.claudePermissionMode,
              let program = command.first,
              URL(fileURLWithPath: program).lastPathComponent == "claude",
              !command.contains(where: { $0 == "--permission-mode" || $0.hasPrefix("--permission-mode=") })
        else { return command }
        return [program, "--permission-mode", mode] + command.dropFirst()
    }

    /// Injects Cortland's scoped Codex approval/sandbox flags into a
    /// Cortland-launched `codex` worker when an auto/bypass level is active. Like
    /// the Claude path: workers run via `exec`, bypassing the shell-integration
    /// `codex` wrapper, so the flags must go on the argv directly. Leaves a
    /// caller-supplied approval/sandbox flag untouched and only touches commands
    /// whose program is `codex`.
    private static func applyingCodexApprovalFlags(_ command: [String]) -> [String] {
        let flags = AgentApprovalState.codexApprovalArgs
        guard codexApprovalReviewer(command: command, flags: flags) != nil,
              let program = command.first else { return command }
        return [program] + flags + command.dropFirst()
    }

    /// Who answers approval requests for a worker Cortland is about to launch
    /// with `flags`, or nil when Cortland is not the one choosing: another
    /// program, no flags to inject, or a caller's own approval flags (which win,
    /// so the reviewer is theirs to know).
    ///
    /// Stamped into the worker's environment, where its hooks inherit it. Only
    /// `-c approvals_reviewer=auto_review` puts a machine in charge; every other
    /// flag set Cortland injects leaves the human answering.
    static func codexApprovalReviewer(command: [String], flags: [String]) -> String? {
        guard !flags.isEmpty,
              let program = command.first,
              URL(fileURLWithPath: program).lastPathComponent == "codex",
              !command.contains(where: AgentIntegrationInstaller.isCodexApprovalOverride),
              !AgentIntegrationInstaller.commandContainsCodexReviewerOverride(command)
        else { return nil }
        let autoReview = "approvals_reviewer=\(AgentStatusReport.autoReviewReviewer)"
        return flags.contains(autoReview)
            ? AgentStatusReport.autoReviewReviewer
            : AgentStatusReport.userReviewer
    }

    private func startConfiguredProcess() {
        let shell = getShell()
        let shellIdiom = "-" + NSString(string: shell).lastPathComponent
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path

        // Use initialDirectory if provided, otherwise use home directory.
        // Validate before handing it to SwiftTerm so a stale tracked cwd falls back cleanly.
        let requestedDirectory = initialDirectory ?? homeDirectory
        var isDirectory: ObjCBool = false
        let startDirectory: String
        if FileManager.default.fileExists(atPath: requestedDirectory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            startDirectory = requestedDirectory
        } else {
            startDirectory = homeDirectory
        }

        currentCWD = startDirectory

        // Start the shell with SwiftTerm's default environment plus
        // TERM_PROGRAM so the shell-integration script can detect Cortland.
        var environment = Terminal.getEnvironmentVariables()
        environment.append("TERM_PROGRAM=\(ShellIntegration.termProgram)")
        environment.append("CORTLAND_ENV=1")
        environment.append("CORTLAND_PANE_ID=\(paneID.uuidString.lowercased())")
        environment.append("CORTLAND_SOCKET_PATH=\(Self.socketPath)")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            environment.append("TERM_PROGRAM_VERSION=\(version)")
        }
        // Interactive shells resolve the live mode again whenever an agent starts,
        // so a Preferences change reaches the next launch in an existing pane.
        // The env value is a safe fallback if the snapshot file cannot be read.
        // Always fail closed if the live file is missing or unreadable. It is the
        // authority; the fallback must not preserve a stale permissive pane mode.
        environment.append("CORTLAND_APPROVAL_MODE=ask")
        environment.append("CORTLAND_APPROVAL_MODE_FILE=\(AgentApprovalState.modeFileURL.path)")
        // Consumed by the worker launch script below; interactive panes never
        // touch it (their wrapper functions already scope the mode).
        environment.append("CORTLAND_SHIM_DIR=\(ShellIntegration.shimDirectoryURL.path)")
        // Names the reviewer the argv injection below is about to put in charge,
        // for the worker's status hooks to read. Interactive panes and
        // wrapper-hidden workers get theirs from the wrapper/shim that injects
        // the flags there; leaving it unset says the human answers.
        if let reviewer = Self.codexApprovalReviewer(
            command: initialCommand ?? [], flags: AgentApprovalState.codexApprovalArgs) {
            environment.append("\(AgentStatusReport.activeApprovalReviewerEnvVar)=\(reviewer)")
        }
        if let command = initialCommand
            .map(Self.applyingClaudePermissionMode)
            .map(Self.applyingCodexApprovalFlags) {
            // Launch the worker through the user's login+interactive shell so
            // it inherits the same PATH and version-manager setup a normal pane
            // gets (e.g. ~/.local/bin, nvm). The command string is a fixed
            // literal; the requested argv arrives as positional
            // parameters, so the shell never re-parses it — no interpolation or
            // command-injection. `exec` replaces the shell so the worker is the
            // pane's root process and its exit transitions the pane to .done.
            terminalView.startProcess(
                executable: shell,
                args: ["-i", "-c", Self.workerLaunchScript, shellIdiom] + command,
                environment: environment,
                execName: shellIdiom,
                currentDirectory: startDirectory
            )
        } else {
            terminalView.startProcess(
                executable: shell,
                environment: environment,
                execName: shellIdiom,
                currentDirectory: startDirectory
            )
        }

        // Publish the initial title/CWD once the process is up. If OSC 7 already
        // reported a real directory within this window (fast shell integration),
        // it owns currentCWD now — don't stomp it back to the start directory.
        // The title publish itself stays unconditional: this is the only
        // initialization path, since the OSC 7 handler only publishes on a cwd
        // *change* and the shell usually starts right where the pane did.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if !self.hasShellIntegration {
                self.currentCWD = startDirectory
            }
            self.updateTitle()
        }
    }

    private static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cortland/cortland.sock").path
    }

    // Returns the shell associated with the current account
    private func getShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else {
            return "/bin/bash"
        }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer {
            buffer.deallocate()
        }
        var pwd = passwd()
        // getpwuid_r writes the address of `pwd` (or NULL when there's no entry)
        // into `result`; it must not be a heap allocation we own — the old
        // `.allocate(capacity: 1)` here was never freed.
        var result: UnsafeMutablePointer<passwd>?

        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 || result == nil {
            return "/bin/bash"
        }
        return String(cString: pwd.pw_shell)
    }

    private func startCWDTracking() {
        cwdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCWD() }
        }
    }

    private func updateCWD() {
        guard shellPID > 0 else { return }
        guard !isUpdatingCWD else { return }

        isUpdatingCWD = true
        let pid = shellPID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cwd = CWDDetector.getCWD(for: pid)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isUpdatingCWD = false

                // Only refresh the title (which spawns git for the branch)
                // when the directory actually changed.
                if let cwd = cwd, cwd != self.currentCWD {
                    self.currentCWD = cwd
                    self.updateTitle()
                }
            }
        }
    }

    private func updateTitle() {
        // Read the main-actor cwd once here and pass it into the background
        // git lookup, rather than touching `currentCWD` from the off-main closure.
        let cwd = currentCWD
        let cwdURL = URL(fileURLWithPath: cwd)
        let basename = cwdURL.lastPathComponent.isEmpty ? "~" : cwdURL.lastPathComponent

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            // Single git entry point: resolve the repo root, then read the
            // branch. A nil root means the cwd isn't in a repository, so the
            // title shows just the directory (no bogus "(unknown)").
            let repositoryRoot = self.gitService.repositoryRoot(from: cwd)
            let branch = repositoryRoot.flatMap { try? self.gitService.currentBranch(repositoryRoot: $0) }

            // GitService reports a detached HEAD already parenthesized as
            // "(sha)"; unwrap it so neither the window title nor the tab title
            // (both add their own parens) ends up double-wrapped as "((sha))".
            let label = Self.titleBranchLabel(branch)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Lookups for several cwds can be in flight at once (a fast `cd`
                // sequence), and the background queue is concurrent, so they can
                // finish out of order. Drop any result whose cwd is no longer the
                // current one: applying it would leave a stale title and — worse,
                // since nothing re-polls until the cwd changes again — a branch
                // watcher permanently attached to the previous repo.
                guard cwd == self.currentCWD else { return }

                // Update window title
                if let label = label, !label.isEmpty {
                    self.view.window?.title = "\(basename) (\(label)) - Cortland"
                } else {
                    self.view.window?.title = "\(basename) - Cortland"
                }

                // Point the FSEvents watcher at the current repo so an in-place
                // branch change refreshes the title without polling.
                self.updateBranchWatch(repositoryRoot: repositoryRoot)

                // Notify delegate for tab title updates
                self.delegate?.terminalDidUpdateTitle(self, directory: cwd, branch: label)
            }
        }
    }

    /// Normalizes `GitService.currentBranch` output for display in a title that
    /// wraps it in parens: a detached HEAD arrives as "(sha)", so strip the
    /// paired parens to avoid "((sha))". Real branch names never arrive already
    /// parenthesized.
    nonisolated private static func titleBranchLabel(_ branch: String?) -> String? {
        guard let branch = branch else { return nil }
        if branch.hasPrefix("("), branch.hasSuffix(")"), branch.count >= 2 {
            return String(branch.dropFirst().dropLast())
        }
        return branch
    }

    /// (Re)targets the branch watcher when the pane's repository changes. A no-op
    /// when the root is unchanged so an FSEvents-driven `updateTitle` doesn't
    /// tear down and rebuild the very stream that triggered it.
    private func updateBranchWatch(repositoryRoot: String?) {
        guard repositoryRoot != watchedRepoRoot else { return }
        watchedRepoRoot = repositoryRoot
        if let repositoryRoot {
            branchWatcher.start(root: repositoryRoot)
        } else {
            branchWatcher.stop()
        }
    }

    private func handleProcessTerminated() {
        cwdTimer?.invalidate()
        cwdTimer = nil
        if initialCommand != nil {
            // A directly launched worker has no parent shell to return to.
            // Keep the finished pane actionable for waiters and the dashboard.
            agentStateDetector.markWorkerFinished()
        } else {
            agentStateDetector.reset()
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate Methods

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Terminal has been resized - SwiftTerm handles this automatically
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Don't update the window title - we use tab titles instead
        // The window title stays as "Cortland"
    }

    /// SwiftTerm's own link activation. On the normal screen its `mouseDown`
    /// runs a selection tracking loop that pulls the release straight out of the
    /// event queue, so that release never reaches our shared mouse-up monitor —
    /// SwiftTerm handles the link click itself and calls this. Left to the
    /// library default it would `NSWorkspace.open` the raw string, which double-
    /// opens alongside the monitor when both do see the release, and fails with
    /// -50 on the schemeless links the implicit matcher returns. Routing it
    /// through the same normalizer and open path gives link opening one owner;
    /// the dedupe downstream absorbs the case where both paths fire.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = TerminalLinkNormalizer.openableURL(from: link) else { return }
        delegate?.terminalRequestsOpenURL(self, url: url)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 command received - update current directory
        // The directory comes as a file:// URL, convert to path
        guard let directory = directory else { return }

        let newCWD: String
        if let url = URL(string: directory), url.scheme == "file" {
            newCWD = url.path
        } else if directory.hasPrefix("file://") {
            // Shell integration emits the path unencoded; URL parsing fails
            // for paths with spaces, so strip the scheme and host manually.
            let afterScheme = directory.dropFirst("file://".count)
            if let firstSlash = afterScheme.firstIndex(of: "/") {
                newCWD = String(afterScheme[firstSlash...])
            } else {
                return
            }
        } else {
            newCWD = directory
        }

        // The shell is reporting its own directory — polling is redundant.
        markShellIntegrationDetected()

        if newCWD != currentCWD {
            currentCWD = newCWD
            updateTitle()
        }
    }

    /// Once the shell proves it has integration (OSC 7 or OSC 133), stop
    /// the CWD polling timer — updates now arrive for free.
    private func markShellIntegrationDetected() {
        guard !hasShellIntegration else { return }
        hasShellIntegration = true
        cwdTimer?.invalidate()
        cwdTimer = nil
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        handleProcessTerminated()
        if let exitCode = exitCode {
            Log.debug("Shell process terminated with exit code: \(exitCode)", category: "terminal")
        } else {
            Log.debug("Shell process vanished unexpectedly", category: "terminal")
        }
    }

    private func queueAgentDetection(_ output: String) {
        // Coalesce high-throughput output into ~10Hz detection passes so the
        // regex scanning doesn't run once per output chunk.
        pendingDetectionOutput += output

        // Under an output flood (>16KB inside one 100ms window) the buffer used
        // to be suffix()-trimmed, dropping its prefix unseen — and any OSC
        // 133/666 mark in that prefix with it (missed command records, missed
        // agent-state transitions). Flush through detection early instead:
        // memory stays just as bounded and the mark consumers see every byte.
        // Any already-scheduled flush finds an empty buffer and no-ops.
        if pendingDetectionOutput.utf8.count > 16_000 {
            let chunk = pendingDetectionOutput
            pendingDetectionOutput = ""
            detectAgentState(from: chunk)
            return
        }

        guard !detectionFlushScheduled else { return }
        detectionFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.detectionFlushScheduled = false
            let chunk = self.pendingDetectionOutput
            self.pendingDetectionOutput = ""
            guard !chunk.isEmpty else { return }
            self.detectAgentState(from: chunk)
        }
    }

    /// Queues `text` to be sent once the shell has produced its first output
    /// (i.e. the prompt is drawn). Replaces fixed-delay guesses for commands that
    /// must wait for shell startup. If output already arrived, sends immediately.
    func sendOnShellReady(_ text: String) {
        if hasProducedOutput {
            send(text: text + "\n")
        } else {
            pendingStartupCommand = text
        }
    }

    private func appendAutomationOutput(_ output: String) {
        let bytesBefore = automationOutput.utf8.count
        TerminalText.appendBounded(output, to: &automationOutput, cap: 64_000)
        // Advance the monotonic cursor by what we appended, and fold whatever
        // the bounded-append trimmed off the front into the evicted-bytes total
        // so `dropped + automationOutput.utf8.count == total` stays invariant.
        let appended = output.utf8.count
        automationOutputTotalBytes += appended
        automationOutputDroppedBytes += bytesBefore + appended - automationOutput.utf8.count

        // First output means the shell is up and has drawn its prompt — flush any
        // command queued via sendOnShellReady().
        hasProducedOutput = true
        if let pending = pendingStartupCommand {
            pendingStartupCommand = nil
            send(text: pending + "\n")
        }

        if !outputMatchers.isEmpty {
            feedOutputMatchers(strippedChunk: TerminalText.stripANSIEscapes(output))
        }

        // While a command is running (between OSC 133 C and D), accumulate its
        // output for the command-record history. ANSI is stripped at finalize.
        //
        // The alternate screen is read here, at processing time, rather than
        // when the bytes arrived: this runs on the main queue one dispatch after
        // the PTY read, and the flag flips mid-stream when the TUI switches
        // buffers. So the on/off boundary is only accurate to a chunk — a chunk
        // that both leaves the alt screen and prints a summary is captured
        // whole, one that prints and then enters it is dropped whole. That's the
        // right trade: the alternative is re-scanning every chunk for the
        // enter/leave escapes to split it, at real cost, to salvage bytes that
        // sit either side of a redraw frame.
        commandRecorder.appendOutput(
            output, onAlternateScreen: terminalView.getTerminal().isCurrentBufferAlternate)
    }

    private func detectAgentState(from output: String) {
        for mark in shellIntegrationParser.consumeCommandMarks(from: output) {
            handleCommandMark(kind: mark.kind, parameter: mark.parameter)
        }
        detectDevServer(in: output)

        // An explicit OSC 666 report (even an unknown token) supersedes the
        // text heuristics for this chunk.
        let statuses = shellIntegrationParser.consumeAgentStatuses(from: output)
        if !statuses.isEmpty {
            for status in statuses {
                agentStateDetector.handleStatusToken(status)
            }
            return
        }

        agentStateDetector.processHeuristics(chunk: output)
    }

    // MARK: - Cmd+click file opening

    private static let filePathTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "((?:~|\\.{1,2})?/?[A-Za-z0-9_@+.\\-]+(?:/[A-Za-z0-9_@+.\\-]+)*)(?::(\\d+))?"
    )

    /// Cmd+click: if the clicked cell sits on a file path (optionally with
    /// `:line`), open it in the built-in editor. Returns true when handled.
    private func handleCommandClick(col: Int, row: Int) -> Bool {
        guard let line = terminalView.getTerminal().getLine(row: row) else { return false }
        let text = line.translateToString(trimRight: true)
        guard !text.isEmpty else { return false }

        guard let regex = Self.filePathTokenRegex else { return false }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            // The clicked column must fall inside this token.
            guard match.range.location <= col, col < match.range.location + match.range.length else { continue }

            let candidate = nsText.substring(with: match.range(at: 1))
            var lineNumber: Int?
            if match.range(at: 2).location != NSNotFound {
                lineNumber = Int(nsText.substring(with: match.range(at: 2)))
            }

            // Require something path-like, not a bare word.
            guard candidate.contains("/") || candidate.contains(".") else { continue }

            guard let resolved = resolveFilePath(candidate) else { continue }
            delegate?.terminalRequestsOpenFile(self, path: resolved, line: lineNumber)
            return true
        }
        return false
    }

    private func resolveFilePath(_ candidate: String) -> String? {
        let expanded: String
        if candidate.hasPrefix("~") {
            expanded = NSString(string: candidate).expandingTildeInPath
        } else if candidate.hasPrefix("/") {
            expanded = candidate
        } else {
            expanded = URL(fileURLWithPath: currentCWD).appendingPathComponent(candidate).path
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    // MARK: - Dev-server detection

    private func detectDevServer(in output: String) {
        guard let serverURL = serverBannerDetector.detectServerURL(in: output) else { return }
        showServerBanner(for: serverURL)
    }

    private func showServerBanner(for url: URL) {
        detectedServerURL = url
        let host = url.host ?? "localhost"
        let port = url.port.map { ":\($0)" } ?? ""
        showBanner(title: "Open \(host)\(port) in browser", action: #selector(serverBannerOpenClicked))
    }

    // MARK: - Pane advisory banner

    /// The pane's advisory bar: a small non-modal strip at the top of the
    /// terminal with one primary action and a ✕, auto-dismissing after 20s. It
    /// is the app's lightest way to tell the user something about *this* pane —
    /// the dev-server offer uses it, and so does the stale-helper warning below.
    /// One at a time: a second call replaces whatever is showing.
    ///
    /// `action` nil makes the title itself the dismiss button, for a banner that
    /// only has something to say.
    private func showBanner(title: String, action: Selector?) {
        hideBanner()

        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.backgroundColor = Theme.shared.palette.surface0.cgColor
        banner.layer?.cornerRadius = 6
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = Theme.shared.palette.surface1.cgColor
        banner.translatesAutoresizingMaskIntoConstraints = false

        let titleButton = NSButton(
            title: title,
            target: self,
            action: action ?? #selector(bannerDismissClicked)
        )
        titleButton.bezelStyle = .inline
        titleButton.isBordered = false
        titleButton.contentTintColor = action == nil ? AppTheme.mutedText : AppTheme.accent
        titleButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleButton.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(
            title: "✕",
            target: self,
            action: #selector(bannerDismissClicked)
        )
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = AppTheme.mutedText
        closeButton.font = NSFont.systemFont(ofSize: 11)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        banner.addSubview(titleButton)
        banner.addSubview(closeButton)
        view.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            banner.heightAnchor.constraint(equalToConstant: 30),

            titleButton.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            titleButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: titleButton.trailingAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])

        bannerView = banner

        let dismissWork = DispatchWorkItem { [weak self] in
            self?.hideBanner()
        }
        bannerDismissWork = dismissWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: dismissWork)
    }

    private func hideBanner() {
        bannerDismissWork?.cancel()
        bannerDismissWork = nil
        bannerView?.removeFromSuperview()
        bannerView = nil
    }

    @objc private func serverBannerOpenClicked() {
        if let url = detectedServerURL {
            delegate?.terminalRequestsOpenURL(self, url: url)
        }
        hideBanner()
    }

    @objc private func bannerDismissClicked() {
        hideBanner()
    }

    // MARK: - Stale agent-status helper

    /// A status hook running against this pane reported over an older wire
    /// protocol than this build speaks: its `cortland-agent-status` binary
    /// predates part of the contract, so some of what it reports (or fails to)
    /// is going nowhere — silently, because a hook must never disrupt the agent.
    ///
    /// Said once per pane, not once per report: the hook fires on every prompt,
    /// tool call, and stop.
    func noteStaleAgentStatusHelper(reportedVersion: Int) {
        guard !warnedStaleAgentStatusHelper else { return }
        warnedStaleAgentStatusHelper = true

        Log.error(
            "Pane \(paneID.uuidString): agent-status hook reported wire protocol "
                + "v\(reportedVersion), but this build speaks v\(AgentStatusReport.protocolVersion). "
                + "The installed cortland-agent-status is stale — relaunch Cortland to refresh "
                + "~/.local/bin, or re-run scripts/install-agent-status-hooks.",
            category: "ipc"
        )
        // Not "reinstall from Preferences → Agents": that installer dedups hooks
        // by binary name, so it leaves an existing ~/.local/bin hook entry (and
        // its stale binary) exactly where it is. Relaunching runs the self-heal,
        // and the installer script rebuilds the binary in place; both fix the
        // hook where it already points. The log line names the versions.
        showBanner(title: "Agent status helper is out of date — relaunch Cortland or re-run the installer", action: nil)
    }

    // MARK: - Shell integration (OSC 133 command marks)

    private func handleCommandMark(kind: String, parameter: String?) {
        markShellIntegrationDetected()

        switch kind {
        case "A":
            // Prompt drawn — remember where, for jump-to-prompt navigation.
            if let row = absoluteCursorRow() {
                promptMarkRows.append(row)
                if promptMarkRows.count > Self.maxPromptMarks {
                    promptMarkRows.removeFirst(promptMarkRows.count - Self.maxPromptMarks)
                }
            }
        case "C":
            // Command started — clear the previous command's status and begin
            // capturing a new record. The shell integration carries the command
            // line base64-encoded in the C parameter (`133;C;<base64>`).
            commandRecorder.commandStarted(
                command: ShellIntegrationParser.decodeCommandParameter(parameter),
                promptRow: promptMarkRows.last
            )
            delegate?.terminalDidUpdateCommandStatus(self, status: nil)
        case "D":
            let exitCode = parameter.flatMap { Int($0) } ?? 0
            let status = commandRecorder.commandFinished(exitCode: exitCode)
            delegate?.terminalDidUpdateCommandStatus(self, status: status)
            // The foreground command exited and the shell is back at its
            // prompt — whatever agent was running here (Ctrl+C'd, quit, or
            // crashed) is gone, so drop the tab from the agents panel.
            agentStateDetector.reset()
        default:
            break
        }
    }

    /// The most recently finished commands (oldest first), capped to `limit`
    /// when given. Surfaced over IPC for `cortland-ctl pane read --json`.
    func recentCommandRecords(limit: Int? = nil) -> [TerminalCommandRecord] {
        commandRecorder.recentRecords(limit: limit)
    }

    /// The cursor's absolute row in the scrollback buffer, derived from
    /// public SwiftTerm API (yBase itself is not exposed).
    private func absoluteCursorRow() -> Int? {
        let buffer = terminalView.getTerminal().buffer

        // Pinned at the bottom (or no scrollback yet): yDisp == yBase.
        if !terminalView.canScroll || terminalView.scrollPosition >= 1.0 {
            return buffer.yDisp + buffer.y
        }

        // Scrolled up: recover yBase from scrollPosition = yDisp / maxScrollback.
        let position = terminalView.scrollPosition
        guard position > 0, buffer.yDisp > 0 else { return nil }
        let yBase = Int((Double(buffer.yDisp) / position).rounded())
        return yBase + buffer.y
    }

    /// Scrolls so the most recent prompt above the current view lands at the top.
    func scrollToPreviousPrompt() {
        let currentTop = terminalView.getTerminal().buffer.yDisp
        guard let target = promptMarkRows.last(where: { $0 < currentTop }) else {
            terminalView.scrollUp(lines: terminalView.getTerminal().rows)
            return
        }
        terminalView.scrollUp(lines: currentTop - target)
    }

    /// Scrolls so the next prompt below the current view lands at the top.
    func scrollToNextPrompt() {
        let currentTop = terminalView.getTerminal().buffer.yDisp
        guard let target = promptMarkRows.first(where: { $0 > currentTop }) else {
            terminalView.scrollDown(lines: terminalView.getTerminal().rows)
            return
        }
        terminalView.scrollDown(lines: target - currentTop)
    }

    private func handleTerminalInput(_ bytes: ArraySlice<UInt8>) {
        agentStateDetector.handleUserInput(bytes: bytes)
    }

    private func readVisibleScreenText() -> String {
        let terminal = terminalView.getTerminal()
        let cursor = terminal.getCursorLocation()
        var lines: [String] = []
        // Interactive dialogs live at the bottom. Restricting the scan keeps a
        // prompt higher in the viewport's scrollback from looking current.
        let firstRow = max(0, terminal.rows - 12)
        for row in firstRow..<terminal.rows {
            if let line = terminal.getLine(row: row) {
                // Dim/gray suggestion text at the cursor (Claude Code's
                // autosuggest, shell autosuggestions) reads identically to
                // typed input once flattened; mark it so agents monitoring
                // this pane don't attribute it to the user.
                if row == cursor.y, let marked = GhostText.markedLine(line, cursorCol: cursor.x) {
                    lines.append(marked)
                } else {
                    lines.append(line.translateToString(trimRight: true))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func getCurrentWorkingDirectory() -> String {
        return currentCWD
    }

    // MARK: - Copy/Paste Support
    // SwiftTerm's LocalProcessTerminalView already handles copy/paste through the responder chain
    // These methods ensure the terminal view receives the copy/paste commands

    @objc func copy(_ sender: Any?) {
        terminalView.copy(sender as Any)
    }

    @objc func paste(_ sender: Any?) {
        terminalView.paste(sender as Any)
    }

    func send(text: String) {
        // Send text to the terminal
        terminalView.send(txt: text)
    }

    /// An agent hook reported this pane's state over the control socket instead
    /// of as an OSC 666 escape in the output stream — the route taken when the
    /// hook process has no controlling terminal to write the escape to (Claude
    /// Code spawns its hooks detached). Same authority as the in-band report.
    ///
    /// Takes the hook's raw status token, not a mapped state: some tokens
    /// ("gated") carry more than the state they map to, and the detector is the
    /// one parser for both transports.
    func applyAgentStatusReport(token: String) {
        agentStateDetector.handleStatusToken(token)
    }

    /// Reports a state Cortland itself knows the agent to be in — the edit-gate
    /// desk parking a pane on its hook. Carries the same authority as a hook's
    /// own report, because the agent really is blocked in that hook.
    func applyAgentStatusReport(_ state: AgentState) {
        agentStateDetector.handleStatusReport(state)
    }

    @discardableResult
    func send(key: String) -> Bool {
        let sequence: String
        switch key.lowercased() {
        case "enter", "return": sequence = "\r"
        case "tab": sequence = "\t"
        case "escape", "esc": sequence = "\u{1B}"
        case "backspace": sequence = "\u{7F}"
        case "ctrl-c", "control-c": sequence = "\u{03}"
        case "ctrl-d", "control-d": sequence = "\u{04}"
        case "up": sequence = terminalView.getTerminal().applicationCursor ? "\u{1B}OA" : "\u{1B}[A"
        case "down": sequence = terminalView.getTerminal().applicationCursor ? "\u{1B}OB" : "\u{1B}[B"
        case "right": sequence = terminalView.getTerminal().applicationCursor ? "\u{1B}OC" : "\u{1B}[C"
        case "left": sequence = terminalView.getTerminal().applicationCursor ? "\u{1B}OD" : "\u{1B}[D"
        default: return false
        }
        terminalView.send(txt: sequence)
        return true
    }

    var shellProcessID: pid_t {
        shellPID
    }

    func visibleScreenText(lineLimit: Int? = nil) -> String {
        TerminalText.lastLines(of: readVisibleScreenText(), limit: lineLimit)
    }

    /// Copies what a `recent` read needs off this pane, cheaply, so the caller can
    /// normalize it on a background queue: the rolling raw buffer with its cursor
    /// counters (scoped to this pane's shell PID, so a cursor minted by a previous
    /// shell reads as truncated) plus the interpreted line buffer. See
    /// `TerminalText.recentRead` for the delta/truncation semantics.
    func recentReadSnapshot() -> TerminalText.RecentReadSnapshot {
        TerminalText.RecentReadSnapshot(
            screen: interpretedBufferText(),
            buffer: automationOutput,
            total: automationOutputTotalBytes,
            dropped: automationOutputDroppedBytes,
            generation: Int(shellPID))
    }

    /// The terminal's interpreted line buffer (scrollback + screen) as plain rows,
    /// or nil on the alternate screen, which by definition keeps no scrollback: a
    /// full-screen TUI's history exists only in the raw output stream.
    ///
    /// SwiftTerm exposes scrollback rows only as a whole-buffer dump (`buffer.lines`
    /// itself is internal), so this walks the buffer rather than just its tail. It
    /// is bounded by the scrollback cap, and it is the only main-thread work a
    /// recent read now does — the strips and the line cap run against this copy.
    private func interpretedBufferText() -> String? {
        let terminal = terminalView.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return nil }
        return String(decoding: terminal.getBufferAsData(), as: UTF8.self)
    }

    /// The recent-output buffer with just the CSI escapes stripped — the shape the
    /// `wait output` matchers are fed chunk by chunk. Pane reads normalize much
    /// harder (`TerminalText.transcript`); the matchers deliberately don't, so a
    /// needle can't fall into a seam between this seed and the chunks appended
    /// after it.
    private func matcherSeedText() -> String {
        TerminalText.stripANSIEscapes(automationOutput)
    }

    // MARK: - Streaming output match (for `wait output`)

    /// A pending `wait output` request: an incremental matcher plus the callback
    /// to fire when it hits.
    private struct OutputMatcher {
        var matcher: StreamingMatcher
        let onMatch: () -> Void
    }
    private var outputMatchers: [UUID: OutputMatcher] = [:]

    /// Registers `needle` to fire `onMatch` once it appears in the output
    /// stream. Returns nil (and does not register) when the needle is already
    /// present in the current buffer, so the caller can resolve immediately.
    func registerOutputMatcher(_ needle: String, onMatch: @escaping () -> Void) -> UUID? {
        if matcherSeedText().contains(needle) || visibleScreenText().contains(needle) {
            return nil
        }
        let id = UUID()
        let matcher = StreamingMatcher(needle: needle, seed: matcherSeedText())
        outputMatchers[id] = OutputMatcher(matcher: matcher, onMatch: onMatch)
        return id
    }

    func cancelOutputMatcher(_ id: UUID) {
        outputMatchers[id] = nil
    }

    /// Feeds a freshly stripped output chunk to every pending matcher. Callbacks
    /// are collected and fired after the loop so an onMatch that cancels a
    /// matcher can't mutate `outputMatchers` mid-iteration.
    private func feedOutputMatchers(strippedChunk: String) {
        guard !outputMatchers.isEmpty else { return }
        var fired: [() -> Void] = []
        for id in Array(outputMatchers.keys) {
            guard var entry = outputMatchers[id] else { continue }
            if entry.matcher.feed(strippedChunk) {
                outputMatchers.removeValue(forKey: id)
                fired.append(entry.onMatch)
            } else {
                outputMatchers[id] = entry
            }
        }
        for onMatch in fired { onMatch() }
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(terminalView)
    }

    /// The in-flight click's purpose was switching pane focus; its mouse
    /// reports must not reach the app in this terminal. Called by the
    /// pane-activation monitor before the view processes the mouse-down.
    func suppressMouseReportsForFocusClick() {
        (terminalView as? AgentAwareTerminalView)?.suppressReportsForClickGesture()
    }

    /// True when keyboard input is actually going to this terminal (not an
    /// editor, browser, find bar, or sidebar field).
    var isTerminalFocused: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === terminalView || responder.isDescendant(of: terminalView)
    }

    /// True when shell integration is active and a command (e.g. nvim) is
    /// running in the foreground — image paste should not fire in this state.
    var isCommandRunning: Bool {
        hasShellIntegration && commandRecorder.isCommandInFlight
    }

    // MARK: - Scrollback search

    func showFindBar() {
        if findBar == nil {
            let bar = TerminalFindBar()
            bar.delegate = self
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
            ])
            findBar = bar
        }
        findBar?.isHidden = false
        findBar?.focusSearchField()
    }

    func hideFindBar() {
        guard let findBar = findBar, !findBar.isHidden else { return }
        findBar.isHidden = true
        terminalView.clearSearch()
        focusTerminal()
    }

    func applyConfig(_ newConfig: Config) {
        Log.debug("🔄 Applying config to terminal: font=\(newConfig.font.family) size=\(newConfig.font.size) blur=\(newConfig.window.enableBlur)", category: "terminal")
        self.config = newConfig

        // Update font (respecting the current app-wide zoom)
        terminalView.font = terminalFont(for: newConfig)
        terminalView.useBrightColors = newConfig.font.boldIsBright

        applyThemeColors()
        applyTerminalAppearance(newConfig)
        applyPadding(newConfig)

        // Force terminal to refresh
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    /// Install the active theme's ANSI palette, foreground and cursor colors.
    /// Called at setup and again whenever the theme changes.
    private func applyThemeColors() {
        terminalView.installColors(Theme.shared.ansiColors)
        terminalView.nativeForegroundColor = Theme.shared.palette.text
        terminalView.caretColor = Theme.shared.palette.rosewater
    }

    private func applyTerminalAppearance(_ config: Config) {
        let baseColor = Theme.shared.palette.base

        if config.window.enableBlur {
            let alpha = CGFloat(max(0.0, min(1.0, config.window.opacity)))
            Log.debug("🎨 Setting terminal background alpha to \(alpha)", category: "terminal")
            let backgroundColor = baseColor.withAlphaComponent(alpha)
            view.layer?.backgroundColor = backgroundColor.cgColor
            view.layer?.isOpaque = false
            // Clear native background so the translucent container layer (and
            // the window blur behind it) shows through. Do NOT set
            // terminal.backgroundColor to an opaque color here: it is kept in
            // sync with nativeBackgroundColor by SwiftTerm, so an opaque value
            // would repaint every default cell opaque and defeat the blur.
            terminalView.nativeBackgroundColor = .clear
            terminalView.layer?.backgroundColor = NSColor.clear.cgColor
            terminalView.layer?.isOpaque = false
            terminalView.alphaValue = 1.0
        } else {
            view.layer?.backgroundColor = baseColor.cgColor
            view.layer?.isOpaque = true
            terminalView.nativeBackgroundColor = baseColor
            terminalView.layer?.backgroundColor = baseColor.cgColor
            terminalView.layer?.isOpaque = true
            terminalView.alphaValue = 1.0
        }
    }

    deinit {
        // The timers are main-run-loop scheduled and the event-monitor teardown
        // is main-thread-only. deinit is nonisolated: assumeIsolated is only safe
        // while the final release lands on the main thread. If a future off-main
        // strong capture ever deallocates us elsewhere, hop the cleanup to main
        // (self is gone by then, so prune the coordinator's now-nil entry).
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                cwdTimer?.invalidate()
                TerminalEventCoordinator.shared.unregister(self)
            }
        } else {
            // A future off-main last-release can't run the MainActor teardown
            // here, so hand the timer to the main queue and invalidate it
            // there. It must not just be abandoned: repeating timers are
            // retained by the run loop indefinitely, so a leaked one would
            // fire no-ops at 1Hz for the app's lifetime. The event monitor is
            // pruned the same way (self is gone by then, so its weak entry in
            // the coordinator reads nil). The agent-state detector's timers are
            // its own deinit's responsibility.
            let timer = cwdTimer
            DispatchQueue.main.async {
                timer?.invalidate()
                TerminalEventCoordinator.shared.pruneDeallocated()
            }
        }
    }
}

extension TerminalViewController: TerminalFindBarDelegate {
    func findBar(_ bar: TerminalFindBar, searchChanged term: String) {
        terminalView.clearSearch()
        guard !term.isEmpty else { return }
        terminalView.findNext(term)
    }

    func findBar(_ bar: TerminalFindBar, findNext term: String) {
        terminalView.findNext(term)
    }

    func findBar(_ bar: TerminalFindBar, findPrevious term: String) {
        terminalView.findPrevious(term)
    }

    func findBarDidClose(_ bar: TerminalFindBar) {
        hideFindBar()
    }
}

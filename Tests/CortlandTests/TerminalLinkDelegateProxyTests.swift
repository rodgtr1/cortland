import XCTest
import Cocoa
import SwiftTerm
@testable import Cortland

/// The proxy takes over the terminal view's own `TerminalViewDelegate` slot, so
/// it sits in the path of everything the emulator reports — titles, cwd,
/// keystrokes on their way to the PTY. These tests hold that line: link
/// activation must reach Cortland instead of `NSWorkspace`, and nothing else
/// may go missing on the way through.
@MainActor
final class TerminalLinkDelegateProxyTests: XCTestCase {
    private final class SpyProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
        var title: String?
        var directory: String?
        var lastSize: (cols: Int, rows: Int)?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            lastSize = (newCols, newRows)
        }
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            self.title = title
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            self.directory = directory
        }
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }

    private func makeView() -> (LocalProcessTerminalView, SpyProcessDelegate) {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let spy = SpyProcessDelegate()
        view.processDelegate = spy
        return (view, spy)
    }

    func testLinkActivationGoesToCortlandRatherThanTheSystemOpener() {
        let (view, _) = makeView()
        var opened: [String] = []
        let proxy = TerminalLinkDelegateProxy(view: view) { opened.append($0) }
        view.terminalDelegate = proxy

        // The shape that produced the Finder -50 alert: a schemeless path handed
        // to the library default would have gone straight to NSWorkspace.
        proxy.requestOpenLink(source: view, link: "/private/tmp/scratch/notes.md", params: [:])
        XCTAssertEqual(opened, ["/private/tmp/scratch/notes.md"])
    }

    func testTitleReportsStillReachTheProcessDelegate() {
        let (view, spy) = makeView()
        let proxy = TerminalLinkDelegateProxy(view: view) { _ in }
        view.terminalDelegate = proxy

        view.feed(text: "\u{1b}]0;cortland — zsh\u{07}")

        XCTAssertEqual(spy.title, "cortland — zsh")
    }

    func testShellIntegrationCWDReportsStillReachTheProcessDelegate() {
        let (view, spy) = makeView()
        let proxy = TerminalLinkDelegateProxy(view: view) { _ in }
        view.terminalDelegate = proxy

        view.feed(text: "\u{1b}]7;file:///Users/x/Repos/cortland\u{07}")

        XCTAssertEqual(spy.directory, "file:///Users/x/Repos/cortland")
    }

    func testKeystrokesStillReachTheViewsSendPath() {
        let (view, _) = makeView()
        let proxy = TerminalLinkDelegateProxy(view: view) { _ in }
        view.terminalDelegate = proxy

        // No process is running, so this only has to prove the forward exists and
        // lands in LocalProcessTerminalView's own send (which drops it there).
        proxy.send(source: view, data: Array("ls\r".utf8)[...])
    }
}

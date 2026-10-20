import XCTest
import Cocoa
import SwiftTerm
@testable import Cortland

/// OSC 52 copies must reach the pasteboard. SwiftTerm's own path drops them on
/// macOS, so these tests pin both the parameter parsing and the fact that a
/// sequence fed through the real emulator lands on the pasteboard Cortland
/// installed.
@MainActor
final class ClipboardEscapeTests: XCTestCase {
    private func params(_ s: String) -> ArraySlice<UInt8> { Array(s.utf8)[...] }
    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    func testClipboardSelectorDecodes() {
        XCTAssertEqual(ClipboardEscape.copyText(from: params("c;" + b64("hello"))), "hello")
    }

    func testEmptySelectorMeansDefaultSelectionAndStillCopies() {
        // tmux copy mode sends `52;;…`.
        XCTAssertEqual(ClipboardEscape.copyText(from: params(";" + b64("from tmux"))), "from tmux")
    }

    func testEveryXSelectionLandsOnTheOneMacClipboard() {
        for selector in ["p", "s", "cp", "s0", "q7"] {
            XCTAssertEqual(ClipboardEscape.copyText(from: params(selector + ";" + b64("x"))), "x", selector)
        }
    }

    func testMultilineAndUnicodePayloadRoundTrips() {
        let text = "func main() {\n\tprint(\"héllo → 🌍\")\n}\n"
        XCTAssertEqual(ClipboardEscape.copyText(from: params("c;" + b64(text))), text)
    }

    func testWrappedAndUnpaddedBase64Decode() {
        // GNU base64 wraps at 76 columns; some encoders strip the `=` padding.
        let wrapped = "aGVsbG8g\r\nd29ybGQ=\n"
        XCTAssertEqual(ClipboardEscape.copyText(from: params("c;" + wrapped)), "hello world")
        XCTAssertEqual(ClipboardEscape.copyText(from: params("c;aGVsbG8gd29ybGQ")), "hello world")
    }

    func testQueryMalformedAndEmptyAreIgnored() {
        XCTAssertNil(ClipboardEscape.copyText(from: params("c;?")))
        XCTAssertNil(ClipboardEscape.copyText(from: params("c;")))
        XCTAssertNil(ClipboardEscape.copyText(from: params("c;  \n")))
        XCTAssertNil(ClipboardEscape.copyText(from: params("c;not base64!")))
        XCTAssertNil(ClipboardEscape.copyText(from: params("x;" + b64("bad selector"))))
        XCTAssertNil(ClipboardEscape.copyText(from: params(b64("no selector field"))))
    }

    func testSequenceFedThroughTheEmulatorReachesThePasteboard() {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cortland.tests.osc52"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        ClipboardEscape.install(on: view.terminal, pasteboard: pasteboard)

        // BEL-terminated, then ST-terminated, then a query that must not clobber.
        view.terminal.feed(byteArray: Array("\u{1B}]52;c;\(b64("via BEL"))\u{07}".utf8))
        XCTAssertEqual(pasteboard.string(forType: .string), "via BEL")

        view.terminal.feed(byteArray: Array("\u{1B}]52;;\(b64("via ST"))\u{1B}\\".utf8))
        XCTAssertEqual(pasteboard.string(forType: .string), "via ST")

        view.terminal.feed(byteArray: Array("\u{1B}]52;c;?\u{07}".utf8))
        XCTAssertEqual(pasteboard.string(forType: .string), "via ST")
    }
}

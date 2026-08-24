import XCTest
@testable import Cortland

final class TerminalDropPathsTests: XCTestCase {
    func testPlainPathIsSingleQuoted() {
        XCTAssertEqual(TerminalDropPaths.quoted("/Users/ada/notes.md"), "'/Users/ada/notes.md'")
    }

    func testSpacesStayInsideTheQuotes() {
        XCTAssertEqual(
            TerminalDropPaths.quoted("/Users/ada/My Documents/read me.txt"),
            "'/Users/ada/My Documents/read me.txt'"
        )
    }

    func testSingleQuoteIsSplicedNotLeftUnbalanced() {
        XCTAssertEqual(TerminalDropPaths.quoted("/tmp/ada's file.png"), "'/tmp/ada'\\''s file.png'")
    }

    func testCharactersTheShellWouldExpandStayLiteral() {
        XCTAssertEqual(TerminalDropPaths.quoted("/tmp/$HOME *?.txt"), "'/tmp/$HOME *?.txt'")
    }

    func testMultiplePathsAreSpaceSeparatedInOrder() {
        let text = TerminalDropPaths.typedText(for: ["/a/one.txt", "/b/two three.txt", "/c/it's.png"])
        XCTAssertEqual(text, "'/a/one.txt' '/b/two three.txt' '/c/it'\\''s.png'")
    }

    func testNoPathsTypesNothing() {
        XCTAssertEqual(TerminalDropPaths.typedText(for: []), "")
    }
}

import XCTest
@testable import Cortland

/// Format Document: the buffer goes through an external formatter found in the
/// project or on the search path, and comes back as one small undoable edit.
/// The formatters here are stand-in shell scripts, so the tests exercise the
/// lookup and the stdin/stdout plumbing without needing Prettier installed.
@MainActor
final class DocumentFormatterTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("sk-format-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    /// Writes an executable script named `name` into `directory`.
    private func installTool(_ name: String, in directory: URL, script: String) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func searchPath(_ directory: URL) -> String {
        "\(directory.path):/usr/bin:/bin"
    }

    // MARK: - Tool table

    func testKnownExtensionsMapToTheirFormatter() {
        XCTAssertEqual(DocumentFormatter.tools(forExtension: "ts").map(\.name), ["prettier"])
        XCTAssertEqual(DocumentFormatter.tools(forExtension: "rs").map(\.name), ["rustfmt"])
        XCTAssertEqual(DocumentFormatter.tools(forExtension: "py").map(\.name), ["ruff", "black"])
        XCTAssertTrue(DocumentFormatter.tools(forExtension: "txt").isEmpty)
    }

    // MARK: - Running

    func testFormatPipesTheBufferThroughTheToolOnTheSearchPath() throws {
        let bin = tempDir.appendingPathComponent("bin")
        try installTool("gofmt", in: bin, script: "tr a-z A-Z")
        let file = tempDir.appendingPathComponent("main.go")

        let outcome = DocumentFormatter.format("package main\n", fileURL: file, searchPath: searchPath(bin))

        XCTAssertEqual(outcome, .formatted("PACKAGE MAIN\n"))
    }

    func testProjectLocalNodeModulesWinsOverTheSearchPath() throws {
        let bin = tempDir.appendingPathComponent("bin")
        try installTool("prettier", in: bin, script: "cat >/dev/null; echo global")
        try installTool(
            "prettier",
            in: tempDir.appendingPathComponent("project/node_modules/.bin"),
            script: "cat >/dev/null; echo local"
        )
        let source = tempDir.appendingPathComponent("project/src/deep")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)

        let outcome = DocumentFormatter.format(
            "x\n", fileURL: source.appendingPathComponent("a.ts"), searchPath: searchPath(bin))

        XCTAssertEqual(outcome, .formatted("local\n"))
    }

    func testTheFilePathReachesTheToolAndItRunsInTheFilesDirectory() throws {
        let bin = tempDir.appendingPathComponent("bin")
        // `ls` of a relative name only succeeds from the file's directory.
        try installTool("prettier", in: bin, script: "cat >/dev/null; echo \"$1 $2\"; ls a.css")
        let file = tempDir.appendingPathComponent("a.css")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)

        let outcome = DocumentFormatter.format("x\n", fileURL: file, searchPath: searchPath(bin))

        XCTAssertEqual(outcome, .formatted("--stdin-filepath \(file.path)\na.css\n"))
    }

    func testMissingToolReportsWhatToInstall() {
        let outcome = DocumentFormatter.format(
            "x\n", fileURL: tempDir.appendingPathComponent("a.py"), searchPath: tempDir.path)
        XCTAssertEqual(outcome, .noFormatter(["ruff", "black"]))
    }

    func testAFailingToolReportsItsStderr() throws {
        let bin = tempDir.appendingPathComponent("bin")
        try installTool("gofmt", in: bin, script: "cat >/dev/null; echo 'syntax error on line 3' >&2; exit 2")

        let outcome = DocumentFormatter.format(
            "x\n", fileURL: tempDir.appendingPathComponent("a.go"), searchPath: searchPath(bin))

        XCTAssertEqual(outcome, .failed("syntax error on line 3"))
    }

    func testEmptyOutputIsAFailureNotAnEmptyBuffer() throws {
        let bin = tempDir.appendingPathComponent("bin")
        try installTool("gofmt", in: bin, script: "cat >/dev/null")

        let outcome = DocumentFormatter.format(
            "x\n", fileURL: tempDir.appendingPathComponent("a.go"), searchPath: searchPath(bin))

        XCTAssertEqual(outcome, .failed("gofmt produced no output."))
    }

    /// More than a pipe buffer in each direction: stdin is fed while stdout
    /// drains, or this deadlocks.
    func testALargeBufferRoundTrips() throws {
        let bin = tempDir.appendingPathComponent("bin")
        try installTool("gofmt", in: bin, script: "cat")
        let text = String(repeating: "func main() {}\n", count: 40_000)

        let outcome = DocumentFormatter.format(
            text, fileURL: tempDir.appendingPathComponent("a.go"), searchPath: searchPath(bin))

        XCTAssertEqual(outcome, .formatted(text))
    }

    // MARK: - Prettier config

    /// A stand-in that answers --find-config-path the way Prettier does: the
    /// config's path and exit 0, or an error and exit 1.
    private func installPrettier(in bin: URL, configFound: Bool) throws {
        let answer = configFound ? "echo .prettierrc; exit 0" : "echo 'Can not find configure file' >&2; exit 1"
        try installTool("prettier", in: bin, script: "if [ \"$1\" = --find-config-path ]; then \(answer); fi; cat")
    }

    func testPrettierConfigMissingFollowsPrettiersOwnAnswer() throws {
        let file = tempDir.appendingPathComponent("a.ts")
        let without = tempDir.appendingPathComponent("without")
        try installPrettier(in: without, configFound: false)
        XCTAssertTrue(DocumentFormatter.prettierConfigMissing(for: file, searchPath: searchPath(without)))

        let with = tempDir.appendingPathComponent("with")
        try installPrettier(in: with, configFound: true)
        XCTAssertFalse(DocumentFormatter.prettierConfigMissing(for: file, searchPath: searchPath(with)))
    }

    func testPrettierConfigMissingIsFalseWhenPrettierIsNotTheFormatter() throws {
        let bin = tempDir.appendingPathComponent("bin")
        try installPrettier(in: bin, configFound: false)
        // A Go file never goes to Prettier, and a TS file with no Prettier
        // installed has nothing to configure yet.
        XCTAssertFalse(DocumentFormatter.prettierConfigMissing(
            for: tempDir.appendingPathComponent("a.go"), searchPath: searchPath(bin)))
        XCTAssertFalse(DocumentFormatter.prettierConfigMissing(
            for: tempDir.appendingPathComponent("a.ts"), searchPath: "/usr/bin:/bin"))
    }

    // MARK: - Minimal edit

    private func apply(_ old: String, _ new: String) -> (result: String, range: NSRange) {
        let edit = DocumentFormatter.minimalEdit(from: old, to: new)
        let result = (old as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, edit.range)
    }

    func testMinimalEditTouchesOnlyTheChangedSpan() {
        let (result, range) = apply("let a = 1\nlet   b = 2\nlet c = 3\n", "let a = 1\nlet b = 2\nlet c = 3\n")
        XCTAssertEqual(result, "let a = 1\nlet b = 2\nlet c = 3\n")
        XCTAssertEqual(range, NSRange(location: 14, length: 2))
    }

    func testMinimalEditHandlesInsertionDeletionAndRepeats() {
        for (old, new) in [("abc", "abXc"), ("abXc", "abc"), ("aaa", "aa"), ("aa", "aaa"), ("", "x"), ("x", ""), ("same", "same")] {
            XCTAssertEqual(apply(old, new).result, new, "\(old) -> \(new)")
        }
    }

    func testMinimalEditNeverSplitsASurrogatePair() {
        // 😀 and 😁 share a lead surrogate; 😁 and 🤁 share a trail surrogate.
        for (old, new) in [("a😀b", "a😁b"), ("a😁b", "a🤁b")] {
            let (result, range) = apply(old, new)
            XCTAssertEqual(result, new)
            XCTAssertEqual(range, NSRange(location: 1, length: 2))
        }
    }

    // MARK: - Editor

    private func makeEditor(_ file: URL, bin: URL) -> EditorViewController {
        let editor = EditorViewController()
        _ = editor.view
        editor._formatterSearchPath = searchPath(bin)
        editor.openFile(file)
        return editor
    }

    private func waitForBuffer(_ editor: EditorViewController, toEqual expected: String) {
        let done = expectation(description: "buffer formatted")
        func poll(_ remaining: Int) {
            if editor._textView?.string == expected || remaining == 0 {
                done.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(remaining - 1) }
            }
        }
        poll(100)
        wait(for: [done], timeout: 10)
    }

    func testFormatDocumentRewritesTheBufferAndLeavesTheFileUnsaved() throws {
        let bin = tempDir.appendingPathComponent("bin")
        try installTool("gofmt", in: bin, script: "sed 's/  */ /g'")
        let file = tempDir.appendingPathComponent("main.go")
        try "var a  =  1\nvar b = 2\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = makeEditor(file, bin: bin)
        XCTAssertTrue(editor.canFormatDocument)
        // Caret on the `b` of the second line, after the span that changes.
        editor._textView?.setSelectedRange(NSRange(location: 16, length: 0))

        editor.formatDocument()
        waitForBuffer(editor, toEqual: "var a = 1\nvar b = 2\n")

        XCTAssertEqual(editor._textView?.string, "var a = 1\nvar b = 2\n")
        XCTAssertTrue(editor.isModified)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "var a  =  1\nvar b = 2\n")
        XCTAssertEqual(editor._textView?.selectedRange(), NSRange(location: 14, length: 0), "caret left the `b`")
    }

    func testAResultForATextThatHasSinceChangedIsDropped() throws {
        let bin = tempDir.appendingPathComponent("bin")
        try installTool("gofmt", in: bin, script: "sleep 0.3; tr a-z A-Z")
        let file = tempDir.appendingPathComponent("main.go")
        try "abc\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = makeEditor(file, bin: bin)

        editor.formatDocument()
        editor._textView?.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))

        let settled = expectation(description: "formatter finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(editor._textView?.string, "typed abc\n")
    }

    func testFilesWithoutAFormatterCannotBeFormatted() throws {
        let file = tempDir.appendingPathComponent("notes.txt")
        try "a  b\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = makeEditor(file, bin: tempDir)
        XCTAssertFalse(editor.canFormatDocument)
    }

    // MARK: - Shortcut

    func testShiftOptionFRoutesToFormatDocument() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift, .option], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 3))
        XCTAssertEqual(KeyboardCommandRouter().command(for: event, tabCount: 1), .formatDocument)
        XCTAssertEqual(KeyboardCommand.formatDocument.displayShortcut, "⇧⌥F")
    }
}

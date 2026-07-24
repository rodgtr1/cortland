import XCTest
@testable import Cortland

@MainActor
final class TreeSitterHighlighterTests: XCTestCase {
    private static let testScheme = SyntaxHighlighter.SyntaxColorScheme(
        text: .black, background: .white, comment: .gray, keyword: .red,
        string: .green, number: .blue, function: .purple, type: .orange
    )

    /// Runs one highlight pass over `storage`, the way `SyntaxHighlighter` does.
    @discardableResult
    private func highlight(
        _ document: TreeSitterHighlighter.Document,
        _ storage: NSTextStorage,
        dirtyRange: NSRange?,
        ext: String = "swift"
    ) -> Bool {
        let ns = storage.string as NSString
        storage.beginEditing()
        defer { storage.endEditing() }
        return document.highlight(
            textStorage: storage,
            fullText: ns,
            dirtyRange: dirtyRange,
            ext: ext,
            scheme: Self.testScheme
        )
    }

    private func color(_ storage: NSTextStorage, at location: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    func testSupportedExtensions() {
        for ext in ["swift", "SWIFT", "go", "rs", "js", "jsx", "ts", "tsx", "md", "mdx", "py"] {
            XCTAssertTrue(TreeSitterHighlighter.canHighlight(ext: ext), "expected \(ext) supported")
        }
        XCTAssertFalse(TreeSitterHighlighter.canHighlight(ext: "txt"))
    }

    /// Each grammar's embedded query must compile against its linked grammar
    /// (ABI match) and classify real source — otherwise that language silently
    /// degrades to the regex fallback.
    func testEachGrammarQueryCompilesAndClassifies() {
        let samples: [(ext: String, src: String)] = [
            ("go", "package main\nfunc main() { x := 42 }\n"),
            ("py", "def f(x):\n    return 42  # comment\n"),
            ("rs", "fn main() { let x = 42; }\n"),
            ("ts", "const x: number = 42\nfunction f(): string { return \"s\" }\n"),
            ("tsx", "const e = <div className=\"a\">{42}</div>\n"),
            ("js", "const x = 42\nfunction f() { return \"s\" }\n"),
        ]
        for sample in samples {
            guard let kinds = TreeSitterHighlighter._captureKinds(in: sample.src, ext: sample.ext) else {
                XCTFail("\(sample.ext): query failed to compile against the grammar")
                continue
            }
            // `keyword` is universal proof the query compiled against the grammar
            // and classified tokens. We don't assert specific literal captures —
            // grammars differ (e.g. Rust tags integer literals @constant.builtin,
            // not @number) — only that real, multi-class highlighting happens.
            XCTAssertTrue(kinds.contains("keyword"), "\(sample.ext): expected keyword, got \(kinds)")
            XCTAssertGreaterThanOrEqual(kinds.count, 2, "\(sample.ext): expected multi-class highlighting, got \(kinds)")
        }
    }

    /// Regression: the query cursor's byte window must be computed in the
    /// tree's own byte space (UTF-16LE, 2× the NSRange units). A UTF-8
    /// conversion under-shoots by half, so a full-document pass silently
    /// dropped every capture in the back half of the file. Asserts a keyword
    /// past the midpoint actually gets colored.
    func testHighlightsReachTheBackHalfOfTheDocument() {
        // Padding pushes a `func` keyword well past the halfway byte offset.
        let padding = String(repeating: "let filler = 1\n", count: 40)
        let storage = NSTextStorage(string: padding + "func trailing() {}\n")

        XCTAssertTrue(
            highlight(TreeSitterHighlighter.Document(), storage, dirtyRange: nil),
            "Swift source should be handled by tree-sitter"
        )

        let keywordLocation = (storage.string as NSString).range(of: "func trailing").location
        XCTAssertEqual(
            color(storage, at: keywordLocation),
            Self.testScheme.keyword,
            "keyword past the file midpoint must be colored"
        )
    }

    /// Confirms the embedded highlights query compiles against the linked Swift
    /// grammar (ABI match) and classifies real tokens — the runtime risk that
    /// `try? Query(...)` would otherwise swallow into a silent regex fallback.
    func testSwiftQueryCompilesAndClassifiesTokens() {
        let source = """
        // a comment
        func greet(_ name: String) -> Int {
            let count = 42
            return count
        }
        """
        guard let kinds = TreeSitterHighlighter._captureKinds(in: source, ext: "swift") else {
            return XCTFail("Swift query failed to compile against the grammar")
        }
        XCTAssertTrue(kinds.contains("keyword"), "expected keyword captures, got \(kinds)")
        XCTAssertTrue(kinds.contains("comment"), "expected comment captures, got \(kinds)")
        XCTAssertTrue(kinds.contains("number"), "expected number captures, got \(kinds)")
        XCTAssertTrue(kinds.contains("type"), "expected type captures, got \(kinds)")
    }

    /// Markdown uses the @text.* capture family (no @keyword), so it's checked
    /// separately: a heading + code span must classify as text captures.
    func testMarkdownBlockClassifies() {
        let source = "# Heading\n\nSome `code` and a para.\n"
        guard let kinds = TreeSitterHighlighter._captureKinds(in: source, ext: "md") else {
            return XCTFail("markdown query failed to compile against the grammar")
        }
        XCTAssertTrue(kinds.contains("text"), "expected @text.* captures, got \(kinds)")
    }

    func testUnsupportedLanguageReturnsNil() {
        XCTAssertNil(TreeSitterHighlighter._captureKinds(in: "x = 1", ext: "rb"))
    }

    // MARK: - Incremental highlighting (TreeSitterHighlighter.Document)

    /// Opening a string literal re-parses every line below it as string content.
    /// (An unterminated `/*` would be the other classic case, but this grammar
    /// parses it as an error and leaves the tokens below it alone.)
    private static let openStringEdit = "let s = \"\n"

    /// #11: a structural edit re-parses everything below it, but the recolor was
    /// confined to the paragraph the user typed in — so opening a string literal
    /// left the rest of the file wearing the colors of the old parse. The tree
    /// diff has to pull those regions into the recolor.
    func testStructuralEditRecolorsPastTheEditedParagraph() {
        let storage = NSTextStorage(string: "let a = 1\nfunc alpha() {}\nfunc beta() {}\n")
        let document = TreeSitterHighlighter.Document()

        XCTAssertTrue(highlight(document, storage, dirtyRange: nil))
        XCTAssertEqual(color(storage, at: (storage.string as NSString).range(of: "func beta").location), Self.testScheme.keyword)

        let edit = Self.openStringEdit
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: edit)
        document.noteEdit(editedRange: NSRange(location: 0, length: edit.utf16.count), changeInLength: edit.utf16.count)

        let ns = storage.string as NSString
        let dirty = ns.paragraphRange(for: NSRange(location: 0, length: edit.utf16.count))
        XCTAssertTrue(highlight(document, storage, dirtyRange: dirty))

        XCTAssertEqual(
            color(storage, at: ns.range(of: "func beta").location),
            Self.testScheme.string,
            "text the edit re-parsed as string content must be recolored, not left keyword-colored"
        )
    }

    /// The same structural edit, with an emoji on every line so the source is
    /// dense with surrogate pairs. The incremental reparse feeds the parser one
    /// whole UTF-16LE buffer for exactly this reason: a reader that chunks the
    /// source can split a pair, end the parse early, and lose every capture past
    /// the split.
    func testIncrementalReparseSurvivesSurrogatePairs() {
        let filler = String(repeating: "let filler = 1 // 😀\n", count: 200)
        let storage = NSTextStorage(string: filler + "func trailing() {}\n")
        let document = TreeSitterHighlighter.Document()

        XCTAssertTrue(highlight(document, storage, dirtyRange: nil))
        XCTAssertEqual(color(storage, at: (storage.string as NSString).range(of: "func trailing").location), Self.testScheme.keyword)

        let edit = Self.openStringEdit
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: edit)
        document.noteEdit(editedRange: NSRange(location: 0, length: edit.utf16.count), changeInLength: edit.utf16.count)

        let ns = storage.string as NSString
        XCTAssertTrue(highlight(document, storage, dirtyRange: ns.paragraphRange(for: NSRange(location: 0, length: edit.utf16.count))))
        XCTAssertEqual(
            color(storage, at: ns.range(of: "func trailing").location),
            Self.testScheme.string,
            "the reparse must reach the end of a source full of surrogate pairs"
        )
    }

    /// A local edit still recolors the text that was typed, even though
    /// tree-sitter reports no changed range for a keystroke that only grows a
    /// leaf node.
    func testLocalEditRecolorsTheTypedText() {
        let storage = NSTextStorage(string: "let a = 1\nvar b = 2\n")
        let document = TreeSitterHighlighter.Document()
        XCTAssertTrue(highlight(document, storage, dirtyRange: nil))

        // Turn `var` into `func` on the second line.
        let ns0 = storage.string as NSString
        let varRange = ns0.range(of: "var")
        storage.replaceCharacters(in: varRange, with: "func")
        document.noteEdit(editedRange: NSRange(location: varRange.location, length: 4), changeInLength: 1)

        let ns = storage.string as NSString
        XCTAssertTrue(highlight(document, storage, dirtyRange: ns.paragraphRange(for: NSRange(location: varRange.location, length: 4))))
        XCTAssertEqual(color(storage, at: ns.range(of: "func").location), Self.testScheme.keyword)
        XCTAssertEqual(color(storage, at: ns.range(of: "let").location), Self.testScheme.keyword)
    }

    /// An edit the highlighter is never told about (or a bogus one) must not be
    /// fed to tree-sitter as a tree edit: the delta is checked against the two
    /// texts first, and a mismatch throws the tree away for a full reparse.
    func testEditThatDoesNotDescribeTheTextFallsBackToAFullParse() {
        let storage = NSTextStorage(string: "let a = 1\n")
        let document = TreeSitterHighlighter.Document()
        XCTAssertTrue(highlight(document, storage, dirtyRange: nil))

        // Replace the whole document behind the highlighter's back, then report
        // an edit that describes none of it.
        storage.replaceCharacters(
            in: NSRange(location: 0, length: storage.length),
            with: "func replaced() {}\nlet x = 7\n"
        )
        document.noteEdit(editedRange: NSRange(location: 0, length: 1), changeInLength: 1)

        let ns = storage.string as NSString
        XCTAssertTrue(highlight(document, storage, dirtyRange: NSRange(location: 0, length: ns.length)))
        XCTAssertEqual(color(storage, at: ns.range(of: "func").location), Self.testScheme.keyword)
        XCTAssertEqual(color(storage, at: ns.range(of: "7").location), Self.testScheme.number)
    }

    /// The same fix, driven through the real editor: type an opening quote into
    /// an open `.swift` file and the lines below it must lose their keyword
    /// colors. Covers the wiring the tests above stub out — the text view's edit
    /// reaching the storage delegate, and the delegate reporting it to the
    /// highlighter before the debounced pass runs.
    func testTypingAStructuralEditInTheEditorRecolorsTheRestOfTheFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("treesitter-\(UUID().uuidString).swift")
        try "let a = 1\nfunc alpha() {}\nfunc beta() {}\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let editor = EditorViewController()
        _ = editor.view // force loadView so the text view exists
        editor.openFile(file)

        let textView = try XCTUnwrap(editor._textView)
        let storage = try XCTUnwrap(textView.textStorage)
        let scheme = SyntaxHighlighter.SyntaxColorScheme.current
        XCTAssertEqual(color(storage, at: (storage.string as NSString).range(of: "func beta").location), scheme.keyword)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText(Self.openStringEdit, replacementRange: NSRange(location: 0, length: 0))
        // The editor debounces highlighting by 0.3s off the main run loop.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        XCTAssertEqual(
            color(storage, at: (storage.string as NSString).range(of: "func beta").location),
            scheme.string,
            "the keyword colors below the edit must not survive the reparse"
        )
    }

    // MARK: - Pure logic

    /// Keystrokes arrive one at a time but the reparse is debounced, so the
    /// deltas fold into one before tree-sitter sees it. The fold must describe
    /// old → new exactly: tree-sitter reuses the subtrees on either side of the
    /// window, so a window that is too small silently corrupts the parse.
    func testEditDeltaFoldDescribesTheOldAndNewText() {
        // Each case is a run of (range to replace, replacement) applied in order.
        let scenarios: [[(NSRange, String)]] = [
            [(NSRange(location: 4, length: 0), "x")],                                    // one insert
            [(NSRange(location: 4, length: 0), "x"), (NSRange(location: 5, length: 0), "y")], // typing forward
            [(NSRange(location: 9, length: 0), "z"), (NSRange(location: 2, length: 0), "w")], // then editing earlier
            [(NSRange(location: 2, length: 5), ""), (NSRange(location: 6, length: 3), "ab")], // delete, then edit after
            [(NSRange(location: 3, length: 2), "long replacement"), (NSRange(location: 1, length: 12), "")], // deletion spanning the window
            [(NSRange(location: 0, length: 20), "")]                                     // wipe the document
        ]

        for edits in scenarios {
            let old = "let a = 1\nvar b = 2\n"
            let text = NSMutableString(string: old)
            var delta: TreeSitterHighlighter.EditDelta?

            for (range, replacement) in edits {
                text.replaceCharacters(in: range, with: replacement)
                let edited = NSRange(location: range.location, length: (replacement as NSString).length)
                let change = (replacement as NSString).length - range.length
                delta = delta?.merging(editedRange: edited, changeInLength: change)
                    ?? TreeSitterHighlighter.EditDelta(editedRange: edited, changeInLength: change)
            }

            guard let delta else { return XCTFail("no delta for \(edits)") }
            let oldNS = old as NSString
            let newNS = text as NSString
            XCTAssertTrue(
                delta.describes(oldLength: oldNS.length, newLength: newNS.length),
                "\(delta) does not describe \(edits)"
            )
            // The text outside the window is what tree-sitter will reuse, so it
            // has to be identical on both sides.
            XCTAssertEqual(oldNS.substring(to: delta.start), newNS.substring(to: delta.start), "prefix differs for \(edits)")
            XCTAssertEqual(oldNS.substring(from: delta.oldEnd), newNS.substring(from: delta.newEnd), "suffix differs for \(edits)")
        }
    }

    func testRecolorRangesMergeOverlapsAndClampToTheDocument() {
        let ranges = TreeSitterHighlighter.Document.recolorRanges(
            dirty: NSRange(location: 0, length: 10),
            edited: NSRange(location: 5, length: 3),
            changed: [NSRange(location: 8, length: 4), NSRange(location: 40, length: 100)],
            documentLength: 60
        )
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 12), NSRange(location: 40, length: 20)])
    }

    func testRecolorRangesWithNothingToRecolor() {
        XCTAssertEqual(
            TreeSitterHighlighter.Document.recolorRanges(dirty: nil, edited: nil, changed: [], documentLength: 10),
            []
        )
    }

    /// Columns in an `InputEdit` point are byte offsets into their row, and the
    /// parser reads UTF-16LE, so they are 2× the UTF-16 offset into the line.
    func testLineIndexPoints() {
        let index = TreeSitterHighlighter.LineIndex("ab\ncdé\nz")
        XCTAssertEqual(index.length, 8)

        func rowAndColumn(_ offset: Int) -> [Int] {
            let point = index.point(atUTF16: offset)
            return [Int(point.row), Int(point.column)]
        }

        XCTAssertEqual(rowAndColumn(0), [0, 0])
        XCTAssertEqual(rowAndColumn(2), [0, 4])
        XCTAssertEqual(rowAndColumn(3), [1, 0])
        XCTAssertEqual(rowAndColumn(6), [1, 6])
        XCTAssertEqual(rowAndColumn(7), [2, 0])
        // Out-of-range offsets clamp rather than trap.
        XCTAssertEqual(rowAndColumn(99), [2, 2])
    }

    /// The query is restricted to the edited range's UTF-8 byte span. A multibyte
    /// character on an earlier line makes UTF-8 byte offsets diverge from UTF-16,
    /// so this proves the byte-range conversion is correct: the `func` keyword in
    /// the dirty range must still be colored as a keyword.
    func testSubRangeHighlightingWithMultibytePrefix() {
        let ns = "let café = \"☕\"\nfunc greet() {}\n" as NSString
        let storage = NSTextStorage(string: ns as String)
        let dirty = ns.paragraphRange(for: ns.range(of: "func greet() {}"))

        XCTAssertTrue(highlight(TreeSitterHighlighter.Document(), storage, dirtyRange: dirty))

        XCTAssertEqual(
            color(storage, at: ns.range(of: "func").location),
            Self.testScheme.keyword,
            "keyword in the dirty range should be highlighted"
        )
    }
}

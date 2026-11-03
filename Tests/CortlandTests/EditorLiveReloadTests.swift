import XCTest
import TOMLKit
@testable import Cortland

/// Live reload and Markdown read mode in the editor, driven through the real
/// controller: files change on disk under an FSEvents watcher, and the
/// buffer, bar, and reader respond the way the config says.
@MainActor
final class EditorLiveReloadTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("ck-reload-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private func makeEditor(liveReload: Bool = true, readMode: Bool = true) -> EditorViewController {
        let editor = EditorViewController()
        _ = editor.view
        var config = Config()
        config.editor?.liveReload = liveReload
        config.editor?.markdownReadMode = readMode
        editor.applyConfig(config)
        return editor
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    private func waitUntil(_ timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    // MARK: - Config

    func testEditorConfigDefaultsAndOverrides() throws {
        XCTAssertTrue(EditorConfig().liveReload)
        XCTAssertTrue(EditorConfig().markdownReadMode)

        let legacy = try TOMLDecoder().decode(EditorConfig.self, from: try TOMLTable(string: "word_wrap = false"))
        XCTAssertTrue(legacy.liveReload, "a config written before the key existed keeps the default")
        XCTAssertTrue(legacy.markdownReadMode)

        let off = try TOMLDecoder().decode(
            EditorConfig.self,
            from: try TOMLTable(string: "live_reload = false\nmarkdown_read_mode = false")
        )
        XCTAssertFalse(off.liveReload)
        XCTAssertFalse(off.markdownReadMode)
    }

    // MARK: - Live reload

    func testCleanBufferFollowsTheFile() throws {
        let file = tempDir.appendingPathComponent("notes.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.openFile(file)
        XCTAssertEqual(editor._textView?.string, "one\n")

        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil { editor._textView?.string == "one\ntwo\n" }, "buffer never picked up the on-disk change")
        XCTAssertFalse(editor.isModified)
        XCTAssertFalse(editor.isShowingExternalChangeBar)
    }

    func testDirtyBufferKeepsEditsAndShowsTheBar() throws {
        let file = tempDir.appendingPathComponent("draft.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.openFile(file)
        let textView = try XCTUnwrap(editor._textView)
        textView.insertText("mine ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.isModified)

        try "theirs\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil { editor.isShowingExternalChangeBar }, "the bar never appeared")
        XCTAssertEqual(textView.string, "mine base\n", "unsaved edits were discarded")
        XCTAssertTrue(editor.isModified)

        // Reload is the explicit way to take the disk version.
        editor.reloadFromDisk()
        XCTAssertEqual(textView.string, "theirs\n")
        XCTAssertFalse(editor.isModified)
        XCTAssertFalse(editor.isShowingExternalChangeBar)
    }

    func testLiveReloadOffLeavesTheBufferAlone() throws {
        let file = tempDir.appendingPathComponent("static.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = makeEditor(liveReload: false)
        editor.openFile(file)

        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(waitUntil(1.5) { editor._textView?.string == "two\n" })
        XCTAssertEqual(editor._textView?.string, "one\n")
        XCTAssertFalse(editor.isShowingExternalChangeBar)
    }

    func testOwnSaveDoesNotTriggerAReload() throws {
        let file = tempDir.appendingPathComponent("saved.txt")
        try "a\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.openFile(file)
        let textView = try XCTUnwrap(editor._textView)
        textView.insertText("b", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.saveFile())

        // Give the watcher time to fire for our own write; nothing should change.
        XCTAssertFalse(waitUntil(1.5) { editor.isShowingExternalChangeBar || textView.string != "ba\n" })
        XCTAssertEqual(textView.string, "ba\n")
        XCTAssertFalse(editor.isModified)
    }

    // MARK: - Read mode

    func testMarkdownOpensRenderedAndTogglesToTheEditor() throws {
        let file = tempDir.appendingPathComponent("note.md")
        try "# Hello\n\nSome **bold** text.\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.openFile(file)

        XCTAssertTrue(editor.isReadMode)
        XCTAssertTrue(editor.canUseReadMode)
        XCTAssertEqual(editor._readerText?.string, "Hello\nSome bold text.")

        editor.toggleReadMode()
        XCTAssertFalse(editor.isReadMode)
        XCTAssertNil(editor._readerText)
        XCTAssertEqual(editor._textView?.string, "# Hello\n\nSome **bold** text.\n")

        // Unsaved edits show when switching back to read.
        let end = ((editor._textView?.string ?? "") as NSString).length
        editor._textView?.insertText("\nMore.\n", replacementRange: NSRange(location: end, length: 0))
        editor.toggleReadMode()
        XCTAssertTrue(editor.isReadMode)
        XCTAssertEqual(editor._readerText?.string, "Hello\nSome bold text.\nMore.")
    }

    func testReadModeFollowsLiveReload() throws {
        let file = tempDir.appendingPathComponent("live.md")
        try "# Log\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.openFile(file)
        XCTAssertEqual(editor._readerText?.string, "Log")

        try "# Log\n\n- first entry\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil { editor._readerText?.string == "Log\n•\tfirst entry" }, "reader did not re-render")
        XCTAssertTrue(editor.isReadMode)
    }

    func testNonMarkdownAndDisabledModeOpenInTheEditor() throws {
        let swift = tempDir.appendingPathComponent("a.swift")
        try "let a = 1\n".write(to: swift, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.openFile(swift)
        XCTAssertFalse(editor.isReadMode)
        XCTAssertFalse(editor.canUseReadMode)
        editor.toggleReadMode()
        XCTAssertFalse(editor.isReadMode, "a source file must never hide behind the reader")

        let md = tempDir.appendingPathComponent("b.md")
        try "# B\n".write(to: md, atomically: true, encoding: .utf8)
        let disabled = makeEditor(readMode: false)
        disabled.openFile(md)
        XCTAssertFalse(disabled.isReadMode)
        XCTAssertFalse(disabled.canUseReadMode)
        disabled.toggleReadMode()
        XCTAssertFalse(disabled.isReadMode)
    }

    func testTurningTheModeOffInConfigLeavesTheReader() throws {
        let md = tempDir.appendingPathComponent("c.md")
        try "# C\n".write(to: md, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.openFile(md)
        XCTAssertTrue(editor.isReadMode)

        var config = Config()
        config.editor?.markdownReadMode = false
        editor.applyConfig(config)
        XCTAssertFalse(editor.isReadMode)
    }

    func testNavigateToLineLeavesReadMode() throws {
        let md = tempDir.appendingPathComponent("d.md")
        try "# D\n\nline three\n".write(to: md, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.openFile(md)
        XCTAssertTrue(editor.isReadMode)
        editor.navigateToLine(3)
        XCTAssertFalse(editor.isReadMode)
    }
}

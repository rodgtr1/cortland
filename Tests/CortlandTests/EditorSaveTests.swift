import XCTest
@testable import Cortland

/// Save-path invariants for the editor: a save writes through a symlink instead
/// of replacing it, keeps the file's original encoding, and can tell that
/// something else touched the file since it was read.
@MainActor
final class EditorSaveTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("sk-editor-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    // MARK: - Symlinks

    func testWritePreservesSymlinkAndReachesItsTarget() throws {
        let real = tempDir.appendingPathComponent("real.txt")
        try "old\n".write(to: real, atomically: true, encoding: .utf8)
        let link = tempDir.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "real.txt")

        try EditorViewController.write("new\n", to: link, encoding: .utf8)

        let linkType = try fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(linkType, .typeSymbolicLink, "the atomic write replaced the symlink with a regular file")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "new\n")
    }

    /// The whole path end to end: open a file through a symlink, save it, and
    /// the link is still a link with the edit behind it.
    func testSaveFileThroughASymlinkKeepsTheLink() throws {
        let real = tempDir.appendingPathComponent("target.txt")
        try "contents\n".write(to: real, atomically: true, encoding: .utf8)
        let link = tempDir.appendingPathComponent("alias.txt")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")

        let editor = EditorViewController()
        _ = editor.view // force loadView so the text view exists
        editor.openFile(link)
        XCTAssertTrue(editor.saveFile())

        let linkType = try fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(linkType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "contents\n")
        XCTAssertFalse(editor.isModified)
    }

    // MARK: - Encoding

    func testReadReportsUTF8AndNonUTF8BytesSurviveARoundTrip() throws {
        let utf8File = tempDir.appendingPathComponent("utf8.txt")
        try "héllo 👋\n".write(to: utf8File, atomically: true, encoding: .utf8)
        let utf8Read = try EditorViewController.read(contentsOf: utf8File)
        XCTAssertEqual(utf8Read.encoding, .utf8)
        XCTAssertEqual(utf8Read.text, "héllo 👋\n")

        // A legacy 8-bit file: whichever single-byte encoding the read lands on,
        // writing it back with that encoding must reproduce the same bytes
        // rather than transcode the file to UTF-8.
        let legacyFile = tempDir.appendingPathComponent("legacy.txt")
        let legacyBytes = Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) // "café\n" in Latin-1
        try legacyBytes.write(to: legacyFile)

        let legacy = try EditorViewController.read(contentsOf: legacyFile)
        XCTAssertNotEqual(legacy.encoding, .utf8, "invalid UTF-8 should not be reported as UTF-8")
        try EditorViewController.write(legacy.text, to: legacyFile, encoding: legacy.encoding)
        XCTAssertEqual(try Data(contentsOf: legacyFile), legacyBytes)
    }

    func testEncodingForWriteKeepsTheFilesOwnUnlessItCantHoldTheText() {
        XCTAssertEqual(
            EditorViewController.encodingForWrite(text: "café", fileEncoding: .isoLatin1),
            .isoLatin1
        )
        // An emoji typed into a Latin-1 file: nothing to write it as but UTF-8.
        XCTAssertEqual(
            EditorViewController.encodingForWrite(text: "café 👋", fileEncoding: .isoLatin1),
            .utf8
        )
    }

    // MARK: - External changes

    func testFileChangedExternallyComparesModificationDates() {
        let now = Date()
        XCTAssertFalse(EditorViewController.fileChangedExternally(recorded: now, current: now))
        XCTAssertTrue(EditorViewController.fileChangedExternally(
            recorded: now,
            current: now.addingTimeInterval(1)
        ))
        // Nothing recorded (never opened from disk) or nothing on disk (the file
        // was deleted, and the save recreates it): no comparison to make.
        XCTAssertFalse(EditorViewController.fileChangedExternally(recorded: nil, current: now))
        XCTAssertFalse(EditorViewController.fileChangedExternally(recorded: now, current: nil))
    }

    func testModificationDateFollowsSymlinksAndTracksWrites() throws {
        let real = tempDir.appendingPathComponent("watched.txt")
        try "one\n".write(to: real, atomically: true, encoding: .utf8)
        let link = tempDir.appendingPathComponent("watched-link.txt")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "watched.txt")

        let before = try XCTUnwrap(EditorViewController.modificationDate(of: link))
        XCTAssertEqual(before, EditorViewController.modificationDate(of: real))

        // Stand in for an agent rewriting the file behind the editor's back.
        try fm.setAttributes([.modificationDate: before.addingTimeInterval(5)], ofItemAtPath: real.path)

        let after = try XCTUnwrap(EditorViewController.modificationDate(of: link))
        XCTAssertTrue(EditorViewController.fileChangedExternally(recorded: before, current: after))
    }
}

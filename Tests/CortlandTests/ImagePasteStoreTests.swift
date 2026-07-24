import XCTest
@testable import Cortland

@MainActor
final class ImagePasteStoreTests: XCTestCase {
    func testStoreWritesIntoDedicatedDirectoryAndPrunePreservesFreshFiles() throws {
        let url = try ImagePasteStore.store(png: Data([0x89, 0x50, 0x4E, 0x47]))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.deletingLastPathComponent(), ImagePasteStore.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // A just-written paste must survive a prune.
        ImagePasteStore.pruneOldFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testPruneRemovesFilesOlderThanADay() throws {
        let url = try ImagePasteStore.store(png: Data([0x89]))
        defer { try? FileManager.default.removeItem(at: url) }

        // Backdate the file two days.
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: url.path)

        ImagePasteStore.pruneOldFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

import XCTest
@testable import Cortland

/// R2/1: a session.json that exists but can't be decoded must not be silently
/// swallowed and then overwritten by the 60s autosave. Load moves it aside to
/// session.json.bak; the next save writes a fresh file and leaves the backup.
@MainActor
final class SessionCorruptionTests: XCTestCase {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("sk-session-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleState() -> SessionState {
        SessionState(
            tabs: [SessionTabState(
                panes: [SessionPaneState(type: "terminal", cwd: "/tmp", url: nil)],
                activePaneIndex: 0,
                customTitle: "work"
            )],
            activeTabIndex: 0
        )
    }

    func testRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")

        SessionStore.save(sampleState(), to: url)
        XCTAssertEqual(SessionStore.load(from: url), sampleState())
    }

    func testAbsentFileLoadsNilAndLeavesNoBackup() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")

        XCTAssertNil(SessionStore.load(from: url))
        XCTAssertFalse(fm.fileExists(atPath: url.appendingPathExtension("bak").path),
                       "A missing session is normal, not a corruption — no .bak")
    }

    func testCorruptFileIsMovedAsideAndSurvivesTheNextSave() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")
        let bakURL = url.appendingPathExtension("bak")
        let corrupt = #"{"tabs": [{"panes": [ TRUNCATED"#
        try corrupt.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(SessionStore.load(from: url), "A file that fails to decode restores nothing")

        // The unusable file is preserved verbatim, and moved (not copied) so the
        // next save can't overwrite the original.
        XCTAssertTrue(fm.fileExists(atPath: bakURL.path))
        XCTAssertEqual(try String(contentsOf: bakURL, encoding: .utf8), corrupt)
        XCTAssertFalse(fm.fileExists(atPath: url.path))

        // The autosave that follows writes a fresh session and leaves the backup.
        SessionStore.save(sampleState(), to: url)
        XCTAssertEqual(SessionStore.load(from: url), sampleState())
        XCTAssertEqual(try String(contentsOf: bakURL, encoding: .utf8), corrupt,
                       "save() must not destroy the recovery artifact")
    }

    func testEmptyFileLoadsNilAndLeavesNoBackup() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")
        try Data().write(to: url)

        XCTAssertNil(SessionStore.load(from: url))
        XCTAssertFalse(fm.fileExists(atPath: url.appendingPathExtension("bak").path),
                       "An empty file has nothing to recover")
    }

    func testValidSessionWithNoTabsRestoresNothingButIsNotTreatedAsCorrupt() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")
        SessionStore.save(SessionState(tabs: [], activeTabIndex: 0), to: url)

        XCTAssertNil(SessionStore.load(from: url))
        XCTAssertFalse(fm.fileExists(atPath: url.appendingPathExtension("bak").path),
                       "It decoded fine — it just has no tabs")
    }
}

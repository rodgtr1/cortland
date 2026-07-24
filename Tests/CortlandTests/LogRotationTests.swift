import XCTest
@testable import Cortland

/// R3/3: the log file grew without bound, every record reopened it, and debug
/// records were always written. RotatingLogFile keeps one open handle, rotates at
/// a cap it tracks in memory (no stat per record), and `Log.level` gates the
/// noisy records out of a shipped build.
final class LogRotationTests: XCTestCase {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("sk-log-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A record of exactly `bytes` bytes.
    private func record(_ char: Character, _ bytes: Int) -> Data {
        Data(String(repeating: char, count: bytes).utf8)
    }

    // MARK: - the rotation threshold

    func testDoesNotRotateBelowTheCap() {
        XCTAssertFalse(RotatingLogFile.shouldRotate(bytesWritten: 0, incoming: 100, cap: 1000))
        XCTAssertFalse(RotatingLogFile.shouldRotate(bytesWritten: 899, incoming: 100, cap: 1000))
    }

    func testDoesNotRotateWhenTheRecordLandsExactlyOnTheCap() {
        XCTAssertFalse(RotatingLogFile.shouldRotate(bytesWritten: 900, incoming: 100, cap: 1000))
    }

    func testRotatesWhenTheRecordWouldCrossTheCap() {
        XCTAssertTrue(RotatingLogFile.shouldRotate(bytesWritten: 901, incoming: 100, cap: 1000))
        XCTAssertTrue(RotatingLogFile.shouldRotate(bytesWritten: 1000, incoming: 1, cap: 1000))
    }

    func testShippedCapIsSane() {
        XCTAssertEqual(Limits.maxLogFileSize, 5 * 1024 * 1024)
    }

    // MARK: - the file itself

    func testCreatesTheFileAndItsDirectoryOnFirstRecord() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        // Nested and absent: this is ~/Library/Logs/Cortland having been cleared.
        let url = dir.appendingPathComponent("Logs/Cortland/Cortland.log")
        let log = RotatingLogFile(fileURL: url, cap: 1000)

        log.append(record("a", 10))
        log.close()

        XCTAssertEqual(try Data(contentsOf: url).count, 10)
    }

    func testAppendsAcrossRecordsWithoutTruncating() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Cortland.log")
        let log = RotatingLogFile(fileURL: url, cap: 1000)

        log.append(Data("one\n".utf8))
        log.append(Data("two\n".utf8))
        log.append(Data("three\n".utf8))
        log.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\nthree\n")
    }

    func testRotatesPastTheCapAndKeepsTheOldContentInGenerationOne() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Cortland.log")
        let log = RotatingLogFile(fileURL: url, cap: 100)

        log.append(record("a", 60))
        log.append(record("b", 40)) // exactly on the cap: still no rotation
        XCTAssertFalse(fm.fileExists(atPath: log.rotatedURL.path))

        log.append(record("c", 10)) // crosses it
        log.close()

        XCTAssertEqual(try String(contentsOf: log.rotatedURL, encoding: .utf8),
                       String(repeating: "a", count: 60) + String(repeating: "b", count: 40))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       String(repeating: "c", count: 10),
                       "the live file restarts with the record that triggered the rotation")
    }

    func testKeepsExactlyOneGeneration() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Cortland.log")
        let log = RotatingLogFile(fileURL: url, cap: 50)

        log.append(record("1", 40))
        log.append(record("2", 40)) // rotates: .1 holds the 1s
        log.append(record("3", 40)) // rotates again: .1 now holds the 2s
        log.close()

        XCTAssertEqual(try String(contentsOf: log.rotatedURL, encoding: .utf8),
                       String(repeating: "2", count: 40),
                       "the older generation is replaced, not stacked up")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), String(repeating: "3", count: 40))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["Cortland.log", "Cortland.log.1"])
    }

    func testRotatesALogInheritedFromAPreviousLaunchInsteadOfGrowingIt() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Cortland.log")
        // A log left behind by an older build, already over the cap. The byte
        // counter is seeded from the file's size on open, so the first record
        // rotates rather than appending forever.
        try record("o", 500).write(to: url)

        let log = RotatingLogFile(fileURL: url, cap: 100)
        log.append(record("n", 10))
        log.close()

        XCTAssertEqual(try Data(contentsOf: log.rotatedURL).count, 500)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), String(repeating: "n", count: 10))
    }

    func testRecreatesTheFileAfterItIsDeletedOutFromUnderTheHandle() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Cortland.log")
        // Re-checked every third record here; the app uses 256, so the common
        // path costs no stat at all.
        let log = RotatingLogFile(fileURL: url, cap: 10_000, existenceCheckInterval: 3)

        log.append(Data("before\n".utf8))
        try fm.removeItem(at: url) // someone clears the log by hand

        // Between checks, records go to the unlinked inode and vanish — that is
        // the bounded price of not statting on every record.
        log.append(Data("lost\n".utf8))
        // The third record trips the check: the path is gone, so reopen recreates it.
        log.append(Data("after\n".utf8))
        log.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "after\n",
                       "logging recovers on its own instead of writing into a deleted file forever")
    }

    // MARK: - the level gate

    func testErrorLevelSuppressesEverythingQuieter() {
        XCTAssertTrue(Log.shouldLog(.error, minimum: .error))
        XCTAssertFalse(Log.shouldLog(.info, minimum: .error))
        XCTAssertFalse(Log.shouldLog(.debug, minimum: .error))
    }

    func testInfoLevelKeepsInfoAndErrorButDropsDebug() {
        XCTAssertTrue(Log.shouldLog(.error, minimum: .info))
        XCTAssertTrue(Log.shouldLog(.info, minimum: .info))
        XCTAssertFalse(Log.shouldLog(.debug, minimum: .info), "the point of the knob")
    }

    func testDebugLevelKeepsEverything() {
        for level: Log.Level in [.debug, .info, .error] {
            XCTAssertTrue(Log.shouldLog(level, minimum: .debug))
        }
    }
}

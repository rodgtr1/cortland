import XCTest
@testable import Cortland

/// M3: a broken config.toml must not be silently replaced with defaults and then
/// clobbered on disk. Load must flag the failure, save must refuse to overwrite,
/// and the unparseable file must be backed up.
@MainActor
final class ConfigLoadFailureTests: XCTestCase {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("sk-cfg-fail-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testValidConfigLoadsWithoutFailureFlag() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml").path
        var valid = Config()
        valid.font.size = 20
        valid.save(to: path)

        let config = Config.load(from: path)
        XCTAssertFalse(config.loadDidFail)
        XCTAssertEqual(config.font.size, 20)
    }

    func testUnparseableConfigFlagsFailureAndWritesBackup() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("config.toml")
        let broken = "this is not = valid toml [[[["
        try broken.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = Config.load(from: fileURL.path)
        XCTAssertTrue(config.loadDidFail, "A parse error must set loadDidFail")

        // The original, broken content is preserved as a sibling .bak file.
        let bakURL = fileURL.appendingPathExtension("bak")
        XCTAssertTrue(fm.fileExists(atPath: bakURL.path))
        XCTAssertEqual(try String(contentsOf: bakURL, encoding: .utf8), broken)
    }

    func testSaveRefusesToOverwriteAfterFailedLoad() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("config.toml")
        let broken = "not valid = = toml ]]]]"
        try broken.write(to: fileURL, atomically: true, encoding: .utf8)

        var config = Config.load(from: fileURL.path)
        XCTAssertTrue(config.loadDidFail)

        // Mutating and saving a failed-load config must NOT touch the on-disk file.
        config.font.size = 42
        config.save(to: fileURL.path)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), broken,
                       "save() must leave a broken config untouched")
    }

    func testFreshDefaultIsNotFlaggedAndSavesNormally() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml").path

        // File doesn't exist yet: load creates a default and does not flag failure.
        let config = Config.load(from: path)
        XCTAssertFalse(config.loadDidFail)
        XCTAssertTrue(fm.fileExists(atPath: path))

        // A plain Config() must save normally (round-trips back).
        var edited = Config()
        edited.font.size = 17
        edited.save(to: path)
        XCTAssertEqual(Config.load(from: path).font.size, 17)
    }
}

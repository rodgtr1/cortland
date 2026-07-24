import XCTest
@testable import Cortland

@MainActor
final class ConfigSaveSymlinkTests: XCTestCase {
    private let fm = FileManager.default

    func testSavePreservesStowSymlinkAndWritesThroughToTarget() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sk-cfg-\(UUID().uuidString)")
        let dotfiles = root.appendingPathComponent("dotfiles")
        let configDir = root.appendingPathComponent("config")
        try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Real file in the "dotfiles repo", and a relative symlink into "config"
        // (mirroring stow's `config.toml -> ../dotfiles/config.toml`).
        let realFile = dotfiles.appendingPathComponent("config.toml")
        try "font = { size = 13 }".write(to: realFile, atomically: true, encoding: .utf8)
        let linkFile = configDir.appendingPathComponent("config.toml")
        try fm.createSymbolicLink(atPath: linkFile.path, withDestinationPath: "../dotfiles/config.toml")

        var config = Config()
        config.font.size = 99
        config.save(to: linkFile.path)

        // The symlink must still be a symlink (not clobbered into a real file)…
        let linkType = try fm.attributesOfItem(atPath: linkFile.path)[.type] as? FileAttributeType
        XCTAssertEqual(linkType, .typeSymbolicLink)
        // …and the write must have reached the real dotfiles file.
        XCTAssertTrue(try String(contentsOf: realFile, encoding: .utf8).contains("99"))
    }

    func testResolvingSymlinkForWriteLeavesPlainFileUnchanged() {
        let url = URL(fileURLWithPath: "/no/such/plain/config.toml")
        XCTAssertEqual(Config.resolvingSymlinkForWrite(url), url)
    }
}

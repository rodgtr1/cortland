import XCTest
import TOMLKit
@testable import Cortland

@MainActor
final class DiffConfigTests: XCTestCase {
    private func diff(from toml: String) throws -> DiffConfig {
        try TOMLDecoder().decode(DiffConfig.self, from: try TOMLTable(string: toml))
    }

    func testFontSizeDefaultsUnset() {
        XCTAssertNil(DiffConfig().fontSize)
    }

    func testConfigWithoutFontSizeKeyStillDecodes() throws {
        // A config written before the key existed must still parse, with the
        // diff following the editor's size.
        let d = try diff(from: "context_lines = 5")
        XCTAssertEqual(d.contextLines, 5)
        XCTAssertNil(d.fontSize)
    }

    func testFontSizeDecodes() throws {
        let d = try diff(from: "context_lines = 3\nfont_size = 14")
        XCTAssertEqual(d.fontSize, 14)
    }

    func testDefaultConfigFileLeavesFontSizeUnset() throws {
        // The template ships font_size commented out, so the diff follows
        // the editor until the user sets it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffConfigTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml").path
        _ = Config.load(from: path) // writes the default template
        let config = Config.load(from: path)
        XCTAssertFalse(config.loadDidFail)
        XCTAssertNil(config.diff.fontSize)
    }
}

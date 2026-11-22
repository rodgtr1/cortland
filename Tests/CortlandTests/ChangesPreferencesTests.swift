import XCTest
@testable import Cortland

/// The Preferences control for `[changes] show_on_agent_done`: its options,
/// which one a stored value selects, and what saving a choice writes.
@MainActor
final class ChangesPreferencesTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("config.toml").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("changes-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOptionsAreThreeInOrderWithTheirConfigValues() {
        let options = PreferencesWindowController.showChangesOnAgentDoneOptions
        XCTAssertEqual(options.map(\.title), [
            "Show the changes beside the agent",
            "Show the changes in a background tab",
            "Do nothing"
        ])
        XCTAssertEqual(options.map(\.value.rawValue), ["split", "tab", "off"])
    }

    func testStoredValueSelectsItsOption() {
        let index = PreferencesWindowController.showChangesOnAgentDoneIndex
        XCTAssertEqual(index("split"), 0)
        XCTAssertEqual(index("tab"), 1)
        XCTAssertEqual(index("off"), 2)
        XCTAssertEqual(index("TAB"), 1)
    }

    func testUnknownOrMissingValueSelectsTheDefault() {
        let index = PreferencesWindowController.showChangesOnAgentDoneIndex
        XCTAssertEqual(index("popup"), 0)
        XCTAssertEqual(index(""), 0)
        XCTAssertEqual(index(nil), 0)
    }

    func testSavingEachChoiceParsesBackToThatChoice() throws {
        for value in ChangesShowOnAgentDone.allCases {
            var config = Config()
            PreferencesWindowController.settingShowChangesOnAgentDone(value, in: &config)
            config.save(to: path)

            let reloaded = Config.load(from: path)
            XCTAssertFalse(reloaded.loadDidFail)
            XCTAssertEqual(reloaded.changes?.showOnAgentDoneSetting, value)
            XCTAssertEqual(reloaded.changes?.showOnAgentDone, value.rawValue)
        }
    }

    func testSavingIntoAConfigWithoutAChangesSectionAddsItAndKeepsOtherValues() throws {
        var existing = Config()
        existing.changes = nil
        existing.font.family = "Menlo"
        existing.font.size = 17
        existing.approval?.mode = "auto"
        existing.save(to: path)
        XCTAssertFalse(try String(contentsOfFile: path, encoding: .utf8).contains("[changes]"))

        var config = Config.load(from: path)
        XCTAssertFalse(config.loadDidFail)
        XCTAssertNil(config.changes)

        PreferencesWindowController.settingShowChangesOnAgentDone(.off, in: &config)
        config.save(to: path)

        let saved = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("[changes]"))
        let reloaded = Config.load(from: path)
        XCTAssertFalse(reloaded.loadDidFail)
        XCTAssertEqual(reloaded.changes?.showOnAgentDoneSetting, .off)
        XCTAssertEqual(reloaded.font.family, "Menlo")
        XCTAssertEqual(reloaded.font.size, 17)
        XCTAssertEqual(reloaded.approval?.mode, "auto")
    }

    func testUnknownValueSurvivesASaveOfAnotherSetting() throws {
        var existing = Config()
        existing.changes?.showOnAgentDone = "popup"
        existing.save(to: path)

        var config = Config.load(from: path)
        config.font.size = 15
        config.save(to: path)

        let reloaded = Config.load(from: path)
        XCTAssertEqual(reloaded.changes?.showOnAgentDone, "popup")
        XCTAssertEqual(reloaded.changes?.showOnAgentDoneSetting, .split)
    }
}

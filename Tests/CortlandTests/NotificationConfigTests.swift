import XCTest
import TOMLKit
@testable import Cortland

@MainActor
final class NotificationConfigTests: XCTestCase {
    private func notifications(from toml: String) throws -> NotificationsConfig {
        try TOMLDecoder().decode(NotificationsConfig.self, from: try TOMLTable(string: toml))
    }

    func testDefaultsAreAllOff() {
        let n = NotificationsConfig()
        XCTAssertFalse(n.enabled)
        XCTAssertFalse(n.needsInput)
        XCTAssertFalse(n.finished)
        XCTAssertFalse(n.commandFailed)
        XCTAssertFalse(n.longRunningCommand)
        XCTAssertEqual(n.longRunningThresholdSeconds, 30)
        XCTAssertEqual(n.backgroundGraceSeconds, 0)
    }

    func testTopLevelConfigDefaultsToSilent() {
        let n = Config().notifications
        XCTAssertNotNil(n)
        XCTAssertFalse(n?.enabled ?? true)
        XCTAssertFalse(n?.anyTriggerActive ?? true)
    }

    func testEmptySectionKeepsDefaults() throws {
        // A config written before this section existed must still parse and stay
        // completely silent.
        let n = try notifications(from: "")
        XCTAssertFalse(n.enabled)
        XCTAssertFalse(n.anyTriggerActive)
        XCTAssertEqual(n.longRunningThresholdSeconds, 30)
    }

    func testFullSectionParses() throws {
        let n = try notifications(from: """
        enabled = true
        needs_input = true
        finished = true
        command_failed = true
        long_running_command = true
        long_running_threshold_seconds = 45
        background_grace_seconds = 10
        """)
        XCTAssertTrue(n.enabled)
        XCTAssertTrue(n.needsInput)
        XCTAssertTrue(n.finished)
        XCTAssertTrue(n.commandFailed)
        XCTAssertTrue(n.longRunningCommand)
        XCTAssertEqual(n.longRunningThresholdSeconds, 45)
        XCTAssertEqual(n.backgroundGraceSeconds, 10)
        XCTAssertTrue(n.anyTriggerActive)
    }

    func testMissingKeysTolerated() throws {
        // Only the master switch present; everything else falls back to defaults.
        let n = try notifications(from: "enabled = true")
        XCTAssertTrue(n.enabled)
        XCTAssertFalse(n.needsInput)
        XCTAssertEqual(n.longRunningThresholdSeconds, 30)
        // Master on but no trigger on: not actually active.
        XCTAssertFalse(n.anyTriggerActive)
    }

    func testAnyTriggerActiveRequiresMasterSwitch() throws {
        // A trigger on but the master switch off means nothing can fire.
        let n = try notifications(from: """
        enabled = false
        needs_input = true
        """)
        XCTAssertFalse(n.anyTriggerActive)
    }
}

import XCTest
import TOMLKit
@testable import Cortland

@MainActor
final class BehaviorConfigTests: XCTestCase {
    private func behavior(from toml: String) throws -> BehaviorConfig {
        try TOMLDecoder().decode(BehaviorConfig.self, from: try TOMLTable(string: toml))
    }

    func testConfirmCloseDefaultsOn() {
        XCTAssertTrue(BehaviorConfig().confirmClose)
    }

    func testConfigWithoutConfirmCloseKeyKeepsDefault() throws {
        // A config written before the key existed must still parse with the
        // confirmation enabled.
        let b = try behavior(from: "restore_session = false")
        XCTAssertTrue(b.confirmClose)
        XCTAssertFalse(b.restoreSession)
    }

    func testConfirmCloseCanBeDisabled() throws {
        let b = try behavior(from: "confirm_close = false")
        XCTAssertFalse(b.confirmClose)
    }
}

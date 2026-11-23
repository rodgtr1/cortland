import XCTest
@testable import Cortland

final class ProcessRunnerTests: XCTestCase {
    /// One byte that isn't valid UTF-8 (Latin-1 `é`) must not blank the whole
    /// stream, as it did for `git diff` over a Latin-1 file.
    func testInvalidUTF8ByteKeepsTheRestOfStdout() throws {
        let result = try ProcessRunner.shared.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["a\\351b\\n"]
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.stdout.isEmpty)
        XCTAssertTrue(result.stdout.hasPrefix("a"))
        XCTAssertTrue(result.stdout.contains("b"))
    }

    func testACallerChosenTimeoutStopsTheChildEarly() throws {
        let start = Date()
        let result = try ProcessRunner.shared.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            currentDirectoryURL: nil,
            environment: nil,
            timeout: 0.5
        )

        XCTAssertLessThan(Date().timeIntervalSince(start), 1.8)
        XCTAssertFalse(result.succeeded)
    }
}

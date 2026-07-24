import XCTest
import TOMLKit
@testable import Cortland
import CortlandTelemetryCore

@MainActor
final class TelemetryConfigTests: XCTestCase {
    private func telemetry(from toml: String) throws -> TelemetryConfig {
        try TOMLDecoder().decode(TelemetryConfig.self, from: try TOMLTable(string: toml))
    }

    func testResolvedRatesOverrideDefaultsButKeepOthers() throws {
        let config = try telemetry(from: """
        [rates."claude-opus-4-8"]
        input = 7.0
        output = 30.0
        """)
        let rates = config.resolvedRates()
        XCTAssertEqual(rates["claude-opus-4-8"], TelemetryRate(inputPerMTok: 7, outputPerMTok: 30))
        // Models not overridden keep their built-in default.
        XCTAssertEqual(rates["claude-haiku-4-5"], TelemetryRate(inputPerMTok: 1, outputPerMTok: 5))
    }

    func testNewModelAddsToRateCard() throws {
        let config = try telemetry(from: """
        [rates."acme-1"]
        input = 2.0
        output = 8.0
        """)
        XCTAssertEqual(config.resolvedRates()["acme-1"], TelemetryRate(inputPerMTok: 2, outputPerMTok: 8))
    }

    func testMissingSectionFallsBackToDefaults() throws {
        let config = try telemetry(from: "")
        XCTAssertTrue(config.rates.isEmpty)
        XCTAssertEqual(config.resolvedRates()["claude-opus-4-8"], TelemetryRate(inputPerMTok: 5, outputPerMTok: 25))
    }

    func testDefaultConfigHasEmptyTelemetryRates() {
        XCTAssertEqual(Config().telemetry?.rates.isEmpty, true)
    }
}

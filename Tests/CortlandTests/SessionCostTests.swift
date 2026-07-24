import XCTest
import CortlandTelemetryCore

final class SessionCostTests: XCTestCase {
    private func makeRecord() -> SessionCostRecord {
        // Reference date keeps the timestamp deterministic for round-trip checks.
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        return SessionCostRecord(timestamp: when, tabs: [
            SessionTabCost(title: "api", model: "claude-opus-4-8", tokens: 30_000, costUSD: 1.25),
            SessionTabCost(title: "web", model: "claude-haiku-4-5", tokens: 12_000, costUSD: 0.20),
            // Unknown-rate tab: contributes tokens but no cost.
            SessionTabCost(title: "codex", model: "gpt-x", tokens: 8_000, costUSD: nil),
        ])
    }

    func testTotalsSumAcrossTabs() {
        let record = makeRecord()
        XCTAssertEqual(record.totalTokens, 50_000)
        XCTAssertEqual(record.totalCostUSD, 1.45, accuracy: 1e-9)
    }

    func testEmptyRecordHasZeroTotals() {
        let record = SessionCostRecord(timestamp: Date(timeIntervalSince1970: 0), tabs: [])
        XCTAssertEqual(record.totalTokens, 0)
        XCTAssertEqual(record.totalCostUSD, 0)
    }

    func testJSONLineIsSingleLine() {
        let line = makeRecord().jsonLine()
        XCTAssertNotNil(line)
        XCTAssertFalse(line!.contains("\n"))
    }

    func testJSONLineRoundTrips() {
        let record = makeRecord()
        guard let line = record.jsonLine(),
              let parsed = SessionCostRecord.parse(jsonLine: line) else {
            return XCTFail("record failed to serialize/parse")
        }
        XCTAssertEqual(parsed, record)
    }

    func testParseToleratesBlankAndMalformedLines() {
        XCTAssertNil(SessionCostRecord.parse(jsonLine: ""))
        XCTAssertNil(SessionCostRecord.parse(jsonLine: "   \n"))
        XCTAssertNil(SessionCostRecord.parse(jsonLine: "{not json"))
    }

    func testTimestampSurvivesAsISO8601() {
        // A record's line carries an ISO-8601 timestamp, not a raw double.
        let line = makeRecord().jsonLine() ?? ""
        XCTAssertTrue(line.contains("2023-11-14T"))
    }
}

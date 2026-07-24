import XCTest
@testable import Cortland

final class ShellIntegrationParserTests: XCTestCase {
    private let esc = "\u{001B}"
    private let bel = "\u{0007}"

    func testParsesCommandMarksInStreamOrder() {
        var parser = ShellIntegrationParser()
        let marks = parser.consumeCommandMarks(from: "\(esc)]133;A\(bel)prompt output\(esc)]133;D;0\(esc)\\")
        XCTAssertEqual(marks, [
            ShellIntegrationParser.CommandMark(kind: "A", parameter: nil),
            ShellIntegrationParser.CommandMark(kind: "D", parameter: "0")
        ])
    }

    func testMarkSplitAcrossChunksIsBufferedUntilComplete() {
        var parser = ShellIntegrationParser()
        XCTAssertEqual(parser.consumeCommandMarks(from: "\(esc)]133;C;aGVs"), [])
        XCTAssertEqual(
            parser.consumeCommandMarks(from: "bG8=\(bel)"),
            [ShellIntegrationParser.CommandMark(kind: "C", parameter: "aGVsbG8=")]
        )
    }

    func testIntroducerSplitAtChunkBoundary() {
        var parser = ShellIntegrationParser()
        // The chunk ends on a lone ESC — the first byte of the next introducer.
        XCTAssertEqual(parser.consumeCommandMarks(from: "output\(esc)"), [])
        XCTAssertEqual(
            parser.consumeCommandMarks(from: "]133;D;1\(bel)"),
            [ShellIntegrationParser.CommandMark(kind: "D", parameter: "1")]
        )
    }

    func testNonMarkOSCAndPlainOutputYieldNothing() {
        var parser = ShellIntegrationParser()
        XCTAssertEqual(parser.consumeCommandMarks(from: "\(esc)]0;window title\(bel)"), [])
        XCTAssertEqual(parser.consumeCommandMarks(from: "plain build output"), [])
        // A completed non-mark OSC must not poison the buffer for later marks.
        XCTAssertEqual(
            parser.consumeCommandMarks(from: "\(esc)]133;A\(bel)"),
            [ShellIntegrationParser.CommandMark(kind: "A", parameter: nil)]
        )
    }

    func testAgentStatusTokensExtracted() {
        var parser = ShellIntegrationParser()
        let sequence = "\(esc)]666;\(ShellIntegrationParser.agentStatusTermprop)=busy\(esc)\\"
        XCTAssertEqual(parser.consumeAgentStatuses(from: sequence), ["busy"])
        XCTAssertEqual(parser.consumeAgentStatuses(from: "no marks here"), [])
    }

    func testAgentStatusSplitAcrossChunks() {
        var parser = ShellIntegrationParser()
        XCTAssertEqual(parser.consumeAgentStatuses(from: "\(esc)]666;\(ShellIntegrationParser.agentStatusTermprop)=re"), [])
        XCTAssertEqual(parser.consumeAgentStatuses(from: "ady\(bel)"), ["ready"])
    }

    func testCommandAndStatusBuffersAreIndependent() {
        var parser = ShellIntegrationParser()
        let mixed = "\(esc)]133;C;\(bel)\(esc)]666;\(ShellIntegrationParser.agentStatusTermprop)=busy\(bel)"
        XCTAssertEqual(parser.consumeCommandMarks(from: mixed).map(\.kind), ["C"])
        XCTAssertEqual(parser.consumeAgentStatuses(from: mixed), ["busy"])
    }

    func testDecodeCommandParameter() {
        XCTAssertEqual(ShellIntegrationParser.decodeCommandParameter("bHMgLWxh"), "ls -la")
        XCTAssertEqual(ShellIntegrationParser.decodeCommandParameter(nil), "")
        XCTAssertEqual(ShellIntegrationParser.decodeCommandParameter(""), "")
        XCTAssertEqual(ShellIntegrationParser.decodeCommandParameter("!!!not base64!!!"), "")
    }
}

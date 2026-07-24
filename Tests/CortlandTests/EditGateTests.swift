import XCTest
@testable import CortlandIPCCore

/// Unit tests for the edit-gate core: PreToolUse payload → show_diff proposal,
/// and desk verdict → permission-decision JSON. Every rejection path here is a
/// fail-open in the executable (silent exit → Claude's own prompt), so these
/// tests pin down exactly which shapes reach the approval desk.
final class EditGateTests: XCTestCase {

    private func payload(
        tool: String,
        input: [String: Any],
        cwd: String? = nil
    ) -> Data {
        var json: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "tool_name": tool,
            "tool_input": input
        ]
        if let cwd { json["cwd"] = cwd }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func reader(_ files: [String: Data]) -> (String) -> Data? {
        { files[$0] }
    }

    // MARK: - Edit

    func testEditReplacesFirstOccurrence() {
        let proposal = EditGate.proposal(
            fromHookPayload: payload(tool: "Edit", input: [
                "file_path": "/repo/a.swift",
                "old_string": "let x = 1",
                "new_string": "let x = 2"
            ]),
            readFile: reader(["/repo/a.swift": Data("let x = 1\nlet x = 1\n".utf8)])
        )
        XCTAssertEqual(proposal?.path, "/repo/a.swift")
        XCTAssertEqual(proposal?.old, "let x = 1\nlet x = 1\n")
        XCTAssertEqual(proposal?.new, "let x = 2\nlet x = 1\n")
    }

    func testEditReplaceAllReplacesEveryOccurrence() {
        let proposal = EditGate.proposal(
            fromHookPayload: payload(tool: "Edit", input: [
                "file_path": "/repo/a.swift",
                "old_string": "foo",
                "new_string": "bar",
                "replace_all": true
            ]),
            readFile: reader(["/repo/a.swift": Data("foo foo foo".utf8)])
        )
        XCTAssertEqual(proposal?.new, "bar bar bar")
    }

    func testEditWhoseOldStringIsAbsentFailsOpen() {
        // Claude Code will fail this tool call itself; the desk shouldn't see it.
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: payload(tool: "Edit", input: [
                "file_path": "/repo/a.swift",
                "old_string": "not present",
                "new_string": "x"
            ]),
            readFile: reader(["/repo/a.swift": Data("contents".utf8)])
        ))
    }

    func testEditOnMissingFileFailsOpen() {
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: payload(tool: "Edit", input: [
                "file_path": "/repo/gone.swift",
                "old_string": "a",
                "new_string": "b"
            ]),
            readFile: reader([:])
        ))
    }

    // MARK: - Write

    func testWriteToNewFileProposesEmptyOld() {
        let proposal = EditGate.proposal(
            fromHookPayload: payload(tool: "Write", input: [
                "file_path": "/repo/new.txt",
                "content": "hello"
            ]),
            readFile: reader([:])
        )
        XCTAssertEqual(proposal?.old, "")
        XCTAssertEqual(proposal?.new, "hello")
    }

    func testWriteOverwriteProposesBothBodies() {
        let proposal = EditGate.proposal(
            fromHookPayload: payload(tool: "Write", input: [
                "file_path": "/repo/f.txt",
                "content": "after"
            ]),
            readFile: reader(["/repo/f.txt": Data("before".utf8)])
        )
        XCTAssertEqual(proposal?.old, "before")
        XCTAssertEqual(proposal?.new, "after")
    }

    func testNoOpWriteFailsOpen() {
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: payload(tool: "Write", input: [
                "file_path": "/repo/f.txt",
                "content": "same"
            ]),
            readFile: reader(["/repo/f.txt": Data("same".utf8)])
        ))
    }

    func testEmptyWriteToMissingFileFailsOpen() {
        // old == "" and new == "" is the app's "open a viewer" shape, not a review.
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: payload(tool: "Write", input: [
                "file_path": "/repo/empty.txt",
                "content": ""
            ]),
            readFile: reader([:])
        ))
    }

    // MARK: - Guards

    func testUnknownToolFailsOpen() {
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: payload(tool: "NotebookEdit", input: [
                "file_path": "/repo/n.ipynb", "content": "x"
            ]),
            readFile: reader([:])
        ))
    }

    func testBinaryFileFailsOpen() {
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: payload(tool: "Write", input: [
                "file_path": "/repo/img.png",
                "content": "text"
            ]),
            readFile: reader(["/repo/img.png": Data([0xFF, 0xFE, 0x00, 0x81])])
        ))
    }

    func testOversizedFileFailsOpen() {
        let big = Data(repeating: UInt8(ascii: "a"), count: EditGate.maxBodyBytes + 1)
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: payload(tool: "Write", input: [
                "file_path": "/repo/big.txt",
                "content": "small"
            ]),
            readFile: reader(["/repo/big.txt": big])
        ))
    }

    func testOversizedNewBodyFailsOpen() {
        let big = String(repeating: "a", count: EditGate.maxBodyBytes + 1)
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: payload(tool: "Write", input: [
                "file_path": "/repo/big.txt",
                "content": big
            ]),
            readFile: reader([:])
        ))
    }

    func testGarbagePayloadFailsOpen() {
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: Data("not json".utf8),
            readFile: reader([:])
        ))
    }

    func testRelativePathResolvesAgainstPayloadCwd() {
        let proposal = EditGate.proposal(
            fromHookPayload: payload(
                tool: "Write",
                input: ["file_path": "sub/f.txt", "content": "x"],
                cwd: "/repo"
            ),
            readFile: reader([:])
        )
        XCTAssertEqual(proposal?.path, "/repo/sub/f.txt")
    }

    func testRelativePathWithoutCwdFailsOpen() {
        XCTAssertNil(EditGate.proposal(
            fromHookPayload: payload(tool: "Write", input: [
                "file_path": "sub/f.txt", "content": "x"
            ]),
            readFile: reader([:])
        ))
    }

    // MARK: - IPC command

    func testIpcCommandCarriesBodiesAndPane() {
        let proposal = EditGate.Proposal(path: "/repo/f.txt", old: "a", new: "b")
        let command = EditGate.ipcCommand(for: proposal, paneID: "pane-1")
        XCTAssertEqual(command["action"] as? String, "show_diff")
        XCTAssertEqual(command["path"] as? String, "/repo/f.txt")
        XCTAssertEqual(command["old"] as? String, "a")
        XCTAssertEqual(command["new"] as? String, "b")
        XCTAssertEqual(command["pane_id"] as? String, "pane-1")
    }

    func testIpcCommandOmitsMissingPane() {
        let proposal = EditGate.Proposal(path: "/repo/f.txt", old: "a", new: "b")
        XCTAssertNil(EditGate.ipcCommand(for: proposal, paneID: nil)["pane_id"])
        XCTAssertNil(EditGate.ipcCommand(for: proposal, paneID: "")["pane_id"])
    }

    // MARK: - Decision JSON

    private func decision(_ json: String) -> [String: Any]? {
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return parsed?["hookSpecificOutput"] as? [String: Any]
    }

    func testAllowDecisionShape() {
        let output = decision(EditGate.decisionJSON(accepted: true, path: "/repo/f.txt"))
        XCTAssertEqual(output?["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(output?["permissionDecision"] as? String, "allow")
        XCTAssertEqual(output?["permissionDecisionReason"] as? String, "Approved in Cortland")
    }

    func testDenyDecisionNamesTheFileAndSteersTheAgent() {
        let output = decision(EditGate.decisionJSON(accepted: false, path: "/repo/secrets/.env"))
        XCTAssertEqual(output?["permissionDecision"] as? String, "deny")
        let reason = output?["permissionDecisionReason"] as? String ?? ""
        XCTAssertTrue(reason.contains(".env"))
        XCTAssertTrue(reason.contains("Ask the user"))
    }
}

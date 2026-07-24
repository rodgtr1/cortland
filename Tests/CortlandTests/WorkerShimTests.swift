import XCTest
@testable import Cortland
import CortlandIPCCore

/// The worker shims exist for one failure mode: a pane launched as
/// `--exec sh -c 'exec claude …'` hides the agent program from the argv
/// injection in TerminalViewController, and the inner non-interactive sh never
/// defines the shell-integration wrapper, so the worker silently lost the
/// pane's approval mode. The launch script prepends the shim directory to
/// PATH, so whichever process finally resolves `claude`/`codex` still applies
/// the live mode. These tests run the real scripts end-to-end against stub
/// binaries.
@MainActor
final class WorkerShimTests: XCTestCase {
    private let fm = FileManager.default

    private struct Fixture {
        let root: URL
        let shims: URL
        let bin: URL
        let modeFile: URL
    }

    private func makeFixture(mode: String?) throws -> Fixture {
        let root = fm.temporaryDirectory.appendingPathComponent("sk-shim-\(UUID().uuidString)")
        let shims = root.appendingPathComponent("shims")
        let bin = root.appendingPathComponent("bin")
        let modeFile = root.appendingPathComponent("approval-mode")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try ShellIntegration.installShims(at: shims)
        for stub in ["claude", "codex"] {
            let url = bin.appendingPathComponent(stub)
            try """
            #!/bin/sh
            printf '\(stub.uppercased())'
            for arg in "$@"; do printf ' <%s>' "$arg"; done
            printf '\\n'
            """.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        if let mode {
            try (mode + "\n").write(to: modeFile, atomically: true, encoding: .utf8)
        }
        return Fixture(root: root, shims: shims, bin: bin, modeFile: modeFile)
    }

    /// Runs the exact worker launch script the app uses, handing it `command`
    /// as the positional argv — the same shape TerminalViewController passes.
    private func runWorker(_ command: [String], fixture: Fixture) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", TerminalViewController.workerLaunchScript, "sh"] + command
        var environment = ProcessInfo.processInfo.environment
        environment["CORTLAND_SHIM_DIR"] = fixture.shims.path
        environment["CORTLAND_APPROVAL_MODE"] = "ask"
        environment["CORTLAND_APPROVAL_MODE_FILE"] = fixture.modeFile.path
        environment["PATH"] = "\(fixture.bin.path):/usr/bin:/bin"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "worker launch failed: \(error)")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testShimsParse() throws {
        for script in [ShellIntegration.claudeShim, ShellIntegration.codexShim] {
            let url = fm.temporaryDirectory
                .appendingPathComponent("sk-shim-parse-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: url) }
            try script.write(to: url, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", url.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "shim must parse as POSIX sh")
        }
    }

    func testInstallShimsWritesExecutableFiles() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("sk-shim-inst-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try ShellIntegration.installShims(at: dir)
        for name in ["claude", "codex"] {
            let path = dir.appendingPathComponent(name).path
            XCTAssertTrue(fm.isExecutableFile(atPath: path), "\(name) shim must be executable")
        }
    }

    /// The regression case itself: a `sh -c 'exec claude …'` wrapper must still
    /// pick up the live mode (review → Claude's `auto`).
    func testWrappedClaudeLaunchGetsLiveMode() throws {
        let fixture = try makeFixture(mode: "review")
        defer { try? fm.removeItem(at: fixture.root) }
        let output = try runWorker(
            ["sh", "-c", "exec claude --model opus -- packet"],
            fixture: fixture
        )
        XCTAssertEqual(output, "CLAUDE <--permission-mode> <auto> <--model> <opus> <--> <packet>")
    }

    func testDirectClaudeLaunchGetsLiveMode() throws {
        let fixture = try makeFixture(mode: "auto")
        defer { try? fm.removeItem(at: fixture.root) }
        let output = try runWorker(["claude", "--model", "opus"], fixture: fixture)
        XCTAssertEqual(output, "CLAUDE <--permission-mode> <acceptEdits> <--model> <opus>")
    }

    func testExplicitPermissionModeWins() throws {
        let fixture = try makeFixture(mode: "review")
        defer { try? fm.removeItem(at: fixture.root) }
        let output = try runWorker(
            ["sh", "-c", "exec claude --permission-mode plan"],
            fixture: fixture
        )
        XCTAssertEqual(output, "CLAUDE <--permission-mode> <plan>")
    }

    func testWrappedCodexLaunchGetsLiveMode() throws {
        let fixture = try makeFixture(mode: "review")
        defer { try? fm.removeItem(at: fixture.root) }
        let output = try runWorker(
            ["sh", "-c", "exec codex exec prompt"],
            fixture: fixture
        )
        XCTAssertEqual(
            output,
            "CODEX <--sandbox> <workspace-write> <--ask-for-approval> <on-request> "
                + "<-c> <approvals_reviewer=auto_review> <exec> <prompt>"
        )
    }

    /// Replaces a stub with one reporting the reviewer stamped on its
    /// environment — what Codex's status hooks inherit and read — instead of its
    /// argv. Reads it through the constant the helper reads, so a rename that
    /// misses the shim fails here rather than in a live pane.
    private func stubReportingReviewer(at url: URL) throws {
        try """
        #!/bin/sh
        printf '%s\n' "${\(AgentStatusReport.activeApprovalReviewerEnvVar):-unset}"
        """.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The wrapper-hidden launch is exactly the case the shim exists for, so the
    /// reviewer stamp has to survive it too: under `auto_review` the hook fires
    /// for requests the human never sees, and the environment is the only thing
    /// that says so.
    func testWrappedCodexLaunchStampsTheLiveReviewer() throws {
        for (mode, expected) in [
            ("review", "auto_review"),
            ("auto", "user"),
            ("bypass", "user"),
            ("ask", "user")
        ] {
            let fixture = try makeFixture(mode: mode)
            defer { try? fm.removeItem(at: fixture.root) }
            try stubReportingReviewer(at: fixture.bin.appendingPathComponent("codex"))
            let output = try runWorker(["sh", "-c", "exec codex exec prompt"], fixture: fixture)
            XCTAssertEqual(output, expected, "mode \(mode)")
        }
    }

    /// A caller's own approval flags win, so Cortland did not pick the reviewer
    /// and must not name one: unset leaves the helper reporting `ready` as it
    /// always has.
    func testCodexCallerOverrideIsNotStamped() throws {
        let fixture = try makeFixture(mode: "review")
        defer { try? fm.removeItem(at: fixture.root) }
        try stubReportingReviewer(at: fixture.bin.appendingPathComponent("codex"))
        let output = try runWorker(["sh", "-c", "exec codex -a=never exec prompt"], fixture: fixture)
        XCTAssertEqual(output, "unset")
    }

    /// A caller who names their own reviewer has taken approval control, so the
    /// shim must pass the launch through whole: injecting a second, conflicting
    /// `approvals_reviewer` would leave the stamp naming whichever value lost.
    func testCodexCallerReviewerOverrideIsNotStamped() throws {
        for launch in [
            "exec codex -c approvals_reviewer=user exec prompt",
            "exec codex --config approvals_reviewer=user exec prompt",
            "exec codex -c=approvals_reviewer=user exec prompt",
            "exec codex --config=approvals_reviewer=user exec prompt"
        ] {
            let fixture = try makeFixture(mode: "review")
            defer { try? fm.removeItem(at: fixture.root) }
            try stubReportingReviewer(at: fixture.bin.appendingPathComponent("codex"))
            let output = try runWorker(["sh", "-c", launch], fixture: fixture)
            XCTAssertEqual(output, "unset", launch)
        }
    }

    /// Only a `-c`/`--config` makes codex read `approvals_reviewer=…` as config.
    /// A prompt that merely talks about the setting is a prompt, so the shim owes
    /// it the pane's mode like any other launch.
    func testCodexReviewerInPromptTextIsNotAnOverride() throws {
        let launch = "exec codex exec 'approvals_reviewer=auto_review behaves incorrectly'"
        let fixture = try makeFixture(mode: "review")
        defer { try? fm.removeItem(at: fixture.root) }
        let argv = try runWorker(["sh", "-c", launch], fixture: fixture)
        XCTAssertEqual(
            argv,
            "CODEX <--sandbox> <workspace-write> <--ask-for-approval> <on-request> "
                + "<-c> <approvals_reviewer=auto_review> <exec> "
                + "<approvals_reviewer=auto_review behaves incorrectly>"
        )

        let stamped = try makeFixture(mode: "review")
        defer { try? fm.removeItem(at: stamped.root) }
        try stubReportingReviewer(at: stamped.bin.appendingPathComponent("codex"))
        XCTAssertEqual(try runWorker(["sh", "-c", launch], fixture: stamped), "auto_review")
    }

    func testCodexExplicitOverrideWins() throws {
        let fixture = try makeFixture(mode: "bypass")
        defer { try? fm.removeItem(at: fixture.root) }
        let output = try runWorker(
            ["sh", "-c", "exec codex -a=never exec prompt"],
            fixture: fixture
        )
        XCTAssertEqual(output, "CODEX <-a=never> <exec> <prompt>")
    }

    /// Missing mode file must fail closed to the env fallback (`ask`): no flag
    /// for claude, read-only sandbox for codex.
    func testMissingModeFileFailsClosed() throws {
        let fixture = try makeFixture(mode: nil)
        defer { try? fm.removeItem(at: fixture.root) }
        let claude = try runWorker(["sh", "-c", "exec claude -r"], fixture: fixture)
        XCTAssertEqual(claude, "CLAUDE <-r>")
        let codex = try runWorker(["sh", "-c", "exec codex exec prompt"], fixture: fixture)
        XCTAssertEqual(
            codex,
            "CODEX <--sandbox> <read-only> <--ask-for-approval> <on-request> "
                + "<-c> <approvals_reviewer=user> <exec> <prompt>"
        )
    }

    /// A pane without a shim dir (unset/empty env) must still exec the argv.
    func testLaunchScriptWorksWithoutShimDir() throws {
        let fixture = try makeFixture(mode: "review")
        defer { try? fm.removeItem(at: fixture.root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", TerminalViewController.workerLaunchScript, "sh", "claude", "--model", "opus"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CORTLAND_SHIM_DIR")
        environment["PATH"] = "\(fixture.bin.path):/usr/bin:/bin"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "CLAUDE <--model> <opus>")
    }
}

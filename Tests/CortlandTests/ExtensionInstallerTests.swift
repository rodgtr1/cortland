import XCTest
@testable import Cortland

/// Installing an extension from a git repository and updating it. Every test
/// uses temp directories and real local git repositories (no network), never
/// the real ~/.config/cortland.
@MainActor
final class ExtensionInstallerTests: XCTestCase {
    private var base: URL!
    private var extensionsDirectory: URL!
    private var reposDirectory: URL!
    private var stateFile: URL!
    private let fm = FileManager.default

    private static let searchPath = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ExtensionInstallerTests-\(UUID().uuidString)")
        extensionsDirectory = base.appendingPathComponent("extensions")
        reposDirectory = base.appendingPathComponent("repos")
        stateFile = base.appendingPathComponent("extensions.json")
        try fm.createDirectory(at: reposDirectory, withIntermediateDirectories: true)
        try XCTSkipIf(ExtensionInstaller.gitURL(searchPath: Self.searchPath) == nil, "git is not installed")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixtures

    /// Records every run, then runs it for real.
    private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
        struct Call {
            let arguments: [String]
            let environment: [String: String]?
        }
        private let lock = NSLock()
        private var recorded: [Call] = []

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func run(executableURL: URL, arguments: [String], currentDirectoryURL: URL?, environment: [String: String]?) throws -> ProcessResult {
            lock.lock()
            recorded.append(Call(arguments: arguments, environment: environment))
            lock.unlock()
            return try ProcessRunner.shared.run(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment
            )
        }
    }

    private var marker: URL { base.appendingPathComponent("command-ran") }

    private func manifest(id: String = "acme.widgets", version: String = "0.1.0", command: String = "bin/run") -> String {
        """
        api_version = 1
        id = "\(id)"
        name = "Widgets"
        version = "\(version)"
        command = "\(command)"
        """
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> ProcessResult {
        let git = try XCTUnwrap(ExtensionInstaller.gitURL(searchPath: Self.searchPath))
        let result = try ProcessRunner.shared.run(
            executableURL: git,
            arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments,
            currentDirectoryURL: directory,
            environment: nil
        )
        XCTAssertTrue(result.succeeded, "git \(arguments) failed: \(result.stderr)")
        return result
    }

    /// A git repository at `<repos>/<name>` holding `manifest` (nil for none)
    /// and an executable `bin/run` that writes the marker file if it ever runs.
    @discardableResult
    private func makeRepository(name: String = "widgets-extension", manifest text: String?) throws -> URL {
        let repo = reposDirectory.appendingPathComponent(name)
        try fm.createDirectory(at: repo.appendingPathComponent("bin"), withIntermediateDirectories: true)
        if let text {
            try text.write(to: repo.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        }
        let command = repo.appendingPathComponent("bin/run")
        try "#!/bin/sh\ntouch '\(marker.path)'\necho '{}'\n".write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        try git(["init", "-q"], in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "initial"], in: repo)
        return repo
    }

    private func commit(_ text: String, to repo: URL, message: String) throws {
        try text.write(to: repo.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", message], in: repo)
    }

    private func makeInstaller(runner: ProcessRunning = ProcessRunner.shared, searchPath: String = ExtensionInstallerTests.searchPath) -> ExtensionInstaller {
        ExtensionInstaller(extensionsDirectory: extensionsDirectory, runner: runner, searchPath: searchPath)
    }

    private func makeRegistry(runner: ProcessRunning = ProcessRunner.shared) -> ExtensionRegistry {
        ExtensionRegistry(
            extensionsDirectory: extensionsDirectory,
            stateFileURL: stateFile,
            removeFolder: { [fm] url in try fm.removeItem(at: url) },
            installer: makeInstaller(runner: runner)
        )
    }

    private func installError(_ location: String, installer: ExtensionInstaller? = nil) -> ExtensionInstallError? {
        do {
            _ = try (installer ?? makeInstaller()).install(from: location)
            return nil
        } catch {
            return error
        }
    }

    private func updateError(_ id: String) -> ExtensionInstallError? {
        do {
            _ = try makeInstaller().update(id)
            return nil
        } catch {
            return error
        }
    }

    /// Entries in the extensions directory, hidden ones included.
    private func extensionsEntries() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: extensionsDirectory.path)) ?? []).sorted()
    }

    private func assertNothingLeftBehind(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(extensionsEntries(), [], file: file, line: line)
    }

    // MARK: - Install

    func testInstallsFromALocalRepository() throws {
        let repo = try makeRepository(manifest: manifest())
        let result = try makeInstaller().install(from: "  \(repo.path)\n")

        XCTAssertEqual(result, ExtensionInstallResult(id: "acme.widgets", name: "Widgets", version: "0.1.0", enabled: false))
        let installed = extensionsDirectory.appendingPathComponent("acme.widgets")
        XCTAssertNoThrow(try ExtensionManifest.load(from: installed))
        XCTAssertTrue(ExtensionInstaller.isUpdatable(folder: installed))
        XCTAssertEqual(extensionsEntries(), ["acme.widgets"], "the staging folder must be gone")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.path), "install must not write extensions.json")
        XCTAssertFalse(fm.fileExists(atPath: marker.path), "install must not run the command")
    }

    func testInstallFolderIsNamedForTheIDNotTheRepository() throws {
        let repo = try makeRepository(name: "some-other-name", manifest: manifest())
        _ = try makeInstaller().install(from: repo.path)
        XCTAssertEqual(extensionsEntries(), ["acme.widgets"])
    }

    func testInstallCreatesAMissingExtensionsDirectory() throws {
        let repo = try makeRepository(manifest: manifest())
        XCTAssertFalse(fm.fileExists(atPath: extensionsDirectory.path))
        _ = try makeInstaller().install(from: repo.path)
        XCTAssertEqual(extensionsEntries(), ["acme.widgets"])
    }

    func testRejectsBadLocationsWithoutRunningGit() {
        let cases: [(String, ExtensionInstallError)] = [
            ("", .emptyLocation),
            ("   \n\t", .emptyLocation),
            ("-uupload-pack=touch /tmp/x", .locationStartsWithDash),
            ("  --help", .locationStartsWithDash),
            ("https://example.com/a\nb.git", .locationHasControlCharacter),
            ("https://example.com/a\u{7F}.git", .locationHasControlCharacter),
            ("https://example.com/a\u{1B}.git", .locationHasControlCharacter),
        ]
        for (location, expected) in cases {
            let runner = RecordingRunner()
            XCTAssertEqual(installError(location, installer: makeInstaller(runner: runner)), expected, "\(location.debugDescription)")
            XCTAssertTrue(runner.calls.isEmpty, "git ran for \(location.debugDescription)")
        }
        XCTAssertFalse(fm.fileExists(atPath: extensionsDirectory.path))
    }

    func testReportsMissingGit() throws {
        let empty = base.appendingPathComponent("empty-bin")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let runner = RecordingRunner()
        XCTAssertEqual(installError("/some/repo", installer: makeInstaller(runner: runner, searchPath: empty.path)), .gitNotFound)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testBadManifestsFailAndLeaveNothing() throws {
        let cases: [(String, String?, (ExtensionInstallError) -> Bool)] = [
            ("none", nil, { $0 == .manifestMissing }),
            ("toml", "id = [", { if case .invalidManifest(.invalidTOML) = $0 { return true } else { return false } }),
            ("noid", "api_version = 1\nname = \"W\"\n", { $0 == .invalidManifest(.missingField("id")) }),
            ("badid", manifest(id: "Not_Valid"), { $0 == .invalidManifest(.invalidID("Not_Valid")) }),
            ("nocommand", manifest(command: "bin/missing"), { $0 == .invalidManifest(.commandMissing("bin/missing")) }),
        ]
        for (name, text, matches) in cases {
            let repo = try makeRepository(name: name, manifest: text)
            let error = try XCTUnwrap(installError(repo.path), name)
            XCTAssertTrue(matches(error), "\(name): \(error)")
            assertNothingLeftBehind()
        }
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
    }

    func testAlreadyInstalledAsFolderSymlinkOrBrokenSymlink() throws {
        let repo = try makeRepository(manifest: manifest())
        let destination = extensionsDirectory.appendingPathComponent("acme.widgets")
        let elsewhere = base.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        let setups: [(String, () throws -> Void)] = [
            ("folder", { try self.fm.createDirectory(at: destination, withIntermediateDirectories: true) }),
            ("symlink", { try self.fm.createSymbolicLink(at: destination, withDestinationURL: elsewhere) }),
            ("broken symlink", { try self.fm.createSymbolicLink(atPath: destination.path, withDestinationPath: self.base.appendingPathComponent("gone").path) }),
        ]
        for (label, setup) in setups {
            try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
            try setup()
            let error = installError(repo.path)
            XCTAssertEqual(error, .alreadyInstalled("acme.widgets"), label)
            XCTAssertTrue(error?.localizedDescription.contains("Update") ?? false, label)
            XCTAssertEqual(extensionsEntries(), ["acme.widgets"], "\(label): staging folder left behind")
            try fm.removeItem(at: destination)
        }
    }

    func testFailedCloneReportsGitAndLeavesNothing() throws {
        let notARepo = base.appendingPathComponent("not-a-repo")
        try fm.createDirectory(at: notARepo, withIntermediateDirectories: true)
        guard case .gitFailed(let message) = installError(notARepo.path) else {
            return XCTFail("Expected gitFailed")
        }
        XCTAssertFalse(message.hasPrefix("Cloning into"), message)
        XCTAssertTrue(message.contains("fatal") || message.contains("repository"), message)
        assertNothingLeftBehind()
    }

    func testGitRunsWithBatchModeSSH() throws {
        let repo = try makeRepository(manifest: manifest())
        let runner = RecordingRunner()
        _ = try makeInstaller(runner: runner).install(from: repo.path)
        let clone = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(Array(clone.arguments.prefix(4)), ["clone", "--depth", "1", "--"])
        XCTAssertEqual(clone.arguments[4], repo.path)
        for call in runner.calls {
            XCTAssertEqual(call.environment?["GIT_SSH_COMMAND"], "ssh -o BatchMode=yes")
        }
    }

    // MARK: - Update

    func testUpdateWithNothingNew() throws {
        let repo = try makeRepository(manifest: manifest())
        _ = try makeInstaller().install(from: repo.path)
        let result = try makeInstaller().update("acme.widgets")
        XCTAssertEqual(result, ExtensionUpdateResult(id: "acme.widgets", updated: false, versionBefore: "0.1.0", versionAfter: "0.1.0", invalid: nil))
    }

    func testUpdateReportsTheNewVersion() throws {
        let repo = try makeRepository(manifest: manifest())
        _ = try makeInstaller().install(from: repo.path)
        try commit(manifest(version: "0.2.0"), to: repo, message: "bump")

        let runner = RecordingRunner()
        let result = try makeInstaller(runner: runner).update("acme.widgets")
        XCTAssertEqual(result, ExtensionUpdateResult(id: "acme.widgets", updated: true, versionBefore: "0.1.0", versionAfter: "0.2.0", invalid: nil))
        XCTAssertTrue(runner.calls.contains { $0.arguments.suffix(2) == ["pull", "--ff-only"] })
        for call in runner.calls {
            XCTAssertEqual(call.environment?["GIT_SSH_COMMAND"], "ssh -o BatchMode=yes")
        }
        XCTAssertFalse(fm.fileExists(atPath: marker.path), "update must not run the command")
    }

    func testUpdateThatBreaksTheManifestStillUpdates() throws {
        let repo = try makeRepository(manifest: manifest())
        _ = try makeInstaller().install(from: repo.path)
        try commit(manifest(command: "bin/missing"), to: repo, message: "break")

        let result = try makeInstaller().update("acme.widgets")
        XCTAssertTrue(result.updated)
        XCTAssertEqual(result.versionBefore, "0.1.0")
        XCTAssertNil(result.versionAfter)
        XCTAssertEqual(result.invalid, ExtensionManifestError.commandMissing("bin/missing").localizedDescription)
    }

    func testSymlinkedAndNonGitExtensionsAreNotUpdatable() throws {
        let repo = try makeRepository(manifest: manifest())
        try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let link = extensionsDirectory.appendingPathComponent("acme.widgets")
        try fm.createSymbolicLink(at: link, withDestinationURL: repo)
        XCTAssertFalse(ExtensionInstaller.isUpdatable(folder: link))
        XCTAssertEqual(updateError("acme.widgets"), .notUpdatable("acme.widgets"))

        let plain = extensionsDirectory.appendingPathComponent("acme.plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertFalse(ExtensionInstaller.isUpdatable(folder: plain))
        XCTAssertEqual(updateError("acme.plain"), .notUpdatable("acme.plain"))

        XCTAssertEqual(updateError("acme.missing"), .unknownExtension("acme.missing"))
    }

    // MARK: - Registry

    func testRegistryReloadsAfterInstallAndUpdateAndKeepsEnabledState() async throws {
        let repo = try makeRepository(manifest: manifest())
        let registry = makeRegistry()
        registry.reload()
        XCTAssertTrue(registry.extensions.isEmpty)

        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: .extensionsDidChange, object: registry, queue: nil) { _ in
            changes += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let installed = try await registry.install(from: repo.path)
        XCTAssertEqual(installed.id, "acme.widgets")
        XCTAssertEqual(registry.extensions.map(\.id), ["acme.widgets"])
        XCTAssertEqual(registry.extensions.first?.isEnabled, false)
        XCTAssertEqual(registry.extensions.first?.isUpdatable, true)
        XCTAssertEqual(changes, 1)

        try registry.setEnabled("acme.widgets", true)
        try commit(manifest(version: "0.2.0"), to: repo, message: "bump")
        let update = try await registry.update("acme.widgets")
        XCTAssertTrue(update.updated)
        XCTAssertEqual(registry.extensions.first?.manifest.version, "0.2.0")
        XCTAssertEqual(registry.extensions.first?.isEnabled, true)
        XCTAssertEqual(ExtensionRegistry.loadEnabled(from: stateFile), ["acme.widgets"])
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
    }

    func testRegistryListsAnExtensionBrokenByUpdateAsInvalid() async throws {
        let repo = try makeRepository(manifest: manifest())
        let registry = makeRegistry()
        _ = try await registry.install(from: repo.path)
        try commit(manifest(command: "bin/missing"), to: repo, message: "break")

        let update = try await registry.update("acme.widgets")
        XCTAssertNotNil(update.invalid)
        XCTAssertTrue(registry.extensions.isEmpty)
        XCTAssertEqual(registry.invalidExtensions.map(\.folderName), ["acme.widgets"])
        XCTAssertEqual(registry.invalidExtensions.first?.isUpdatable, true)
    }

    // MARK: - IPC parsing

    private func parse(_ request: [String: Any]) throws -> IPCCommandType.ParseResult {
        let data = try JSONSerialization.data(withJSONObject: request)
        return IPCCommandType.parse(try JSONDecoder().decode(IPCCommand.self, from: data))
    }

    func testIPCParsesInstall() throws {
        guard case .command(.extensionInstall(let url)) = try parse(["action": "extension_install", "url": " git@example.com:o/r.git "]) else {
            return XCTFail("Expected extensionInstall")
        }
        XCTAssertEqual(url, "git@example.com:o/r.git")
    }

    func testIPCRejectsBadInstallArguments() throws {
        guard case .invalidArguments = try parse(["action": "extension_install"]) else {
            return XCTFail("Expected invalidArguments for a missing url")
        }
        for url in ["", "  ", "-oProxyCommand=x", "https://e.com/a\nb", "https://e.com/\u{7F}"] {
            guard case .invalidArguments = try parse(["action": "extension_install", "url": url]) else {
                return XCTFail("Expected invalidArguments for \(url.debugDescription)")
            }
        }
    }

    func testIPCParsesUpdate() throws {
        guard case .command(.extensionUpdate(let id)) = try parse(["action": "extension_update", "id": "acme.widgets"]) else {
            return XCTFail("Expected extensionUpdate")
        }
        XCTAssertEqual(id, "acme.widgets")
    }

    func testIPCRejectsBadUpdateArguments() throws {
        guard case .invalidArguments = try parse(["action": "extension_update"]) else {
            return XCTFail("Expected invalidArguments for a missing id")
        }
        for id in ["", "a/b", ".", "..", "../acme.widgets"] {
            guard case .invalidArguments = try parse(["action": "extension_update", "id": id]) else {
                return XCTFail("Expected invalidArguments for \(id.debugDescription)")
            }
        }
    }
}

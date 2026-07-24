import Foundation
import Darwin

/// A lock-guarded `Data` holder so a background pipe-drain closure can publish
/// its result without mutating a captured `var` (rejected by strict concurrency).
private nonisolated final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newValue: Data) {
        lock.lock(); defer { lock.unlock() }
        data = newValue
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

nonisolated struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool {
        terminationStatus == 0
    }
}

nonisolated enum ProcessRunnerError: Error {
    case executableNotFound(String)
}

nonisolated protocol ProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]?
    ) throws -> ProcessResult
}

nonisolated extension ProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        try run(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment
        )
    }
}

// Stateless and called from background git/worktree work, so it opts out of the
// module's default main-actor isolation and is safely Sendable.
nonisolated final class ProcessRunner: ProcessRunning {
    static let shared = ProcessRunner()

    /// Backstop so a wedged child (e.g. one waiting on an interactive prompt we
    /// couldn't suppress, or a stalled network filesystem) can't hang a worker
    /// thread forever. Generous because it's a safety net, not a deadline — the
    /// git operations here are normally sub-second.
    private static let timeout: TimeInterval = 120

    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments
        task.currentDirectoryURL = currentDirectoryURL

        // Inherit the parent environment (setting `task.environment` replaces it
        // wholesale, which would strip PATH etc.), overlay any caller values,
        // then force git to never block on an interactive credential/askpass
        // prompt — it fails fast instead, which the timeout below backstops.
        var env = ProcessInfo.processInfo.environment
        if let environment { env.merge(environment) { _, new in new } }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        task.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        // The two pipes are drained on separate background queues to avoid the
        // 64KB pipe-buffer deadlock, so each closure writes into its own
        // reference-typed box rather than mutating a captured `var` (which strict
        // concurrency rejects even though `readGroup.wait()` orders the reads).
        let outputBox = DataBox()
        let errorBox = DataBox()
        let readGroup = DispatchGroup()

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }

        try task.run()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        // SIGTERM the child if it overruns the timeout, then SIGKILL if it
        // ignores that. Either way its pipes close, so the drains finish and
        // readGroup.wait() can't hang.
        if exited.wait(timeout: .now() + Self.timeout) == .timedOut {
            task.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        readGroup.wait()

        return ProcessResult(
            terminationStatus: task.terminationStatus,
            stdout: String(data: outputBox.value, encoding: .utf8) ?? "",
            stderr: String(data: errorBox.value, encoding: .utf8) ?? ""
        )
    }

    static func executableURL(named executableName: String, commonPaths: [String] = []) -> URL? {
        let fileManager = FileManager.default

        for path in commonPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let path = String(directory) + "/" + executableName
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }
}

import Foundation

/// Format Document for the GUI editor. Cortland ships no formatter of its own:
/// the buffer is piped through the one the project already uses (Prettier,
/// rustfmt, gofmt, ...), run from the file's directory so it picks up the
/// project's own config (.prettierrc, rustfmt.toml, .swift-format).
nonisolated enum DocumentFormatter {
    struct Tool: Sendable, Equatable {
        /// Executable name, looked up on the search path (and, for Prettier
        /// only, first in node_modules/.bin above the file).
        let name: String
        /// Arguments that make the tool read stdin and write stdout. `{file}`
        /// stands for the file's path, which formatters use to pick a parser
        /// and find their config.
        let arguments: [String]
    }

    enum Outcome: Sendable, Equatable {
        case formatted(String)
        /// None of these tools is installed.
        case noFormatter([String])
        case failed(String)
    }

    private static let prettierExtensions: Set<String> = [
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts",
        "json", "jsonc", "json5", "css", "scss", "less", "html", "htm", "vue",
        "md", "markdown", "mdx", "yaml", "yml", "graphql", "gql"
    ]

    /// The formatters to try for a file extension (lowercased), in order.
    /// Empty when the editor has nothing to offer for that file type.
    static func tools(forExtension ext: String) -> [Tool] {
        if prettierExtensions.contains(ext) {
            return [Tool(name: "prettier", arguments: ["--stdin-filepath", "{file}"])]
        }
        switch ext {
        case "swift":
            // xcrun finds the swift-format inside Xcode's toolchain, which is
            // not on PATH, and falls back to PATH for a Homebrew install.
            return [Tool(name: "xcrun", arguments: ["swift-format", "format", "--assume-filename", "{file}", "-"])]
        case "rs":
            // rustfmt on stdin does not read the edition from Cargo.toml and
            // defaults to 2015, which rejects `async fn`.
            return [Tool(name: "rustfmt", arguments: ["--edition", "2021", "--emit", "stdout"])]
        case "go":
            return [Tool(name: "gofmt", arguments: [])]
        case "py":
            return [
                Tool(name: "ruff", arguments: ["format", "--stdin-filename", "{file}", "-"]),
                Tool(name: "black", arguments: ["--quiet", "--stdin-filename", "{file}", "-"])
            ]
        default:
            return []
        }
    }

    /// Where `tool` lives for a file at `fileURL`: the directories of
    /// `searchPath`, except that Prettier first looks in the nearest
    /// node_modules/.bin above the file (the project's pinned Prettier wins
    /// over a global one). Only Prettier gets that walk: a cloned repo could
    /// otherwise ship its own `gofmt` or `xcrun` and have it run on Format.
    static func executable(for tool: Tool, fileURL: URL, searchPath: String) -> URL? {
        let fileManager = FileManager.default
        var directory = fileURL.deletingLastPathComponent().standardizedFileURL
        while tool.name == "prettier" {
            let local = directory.appendingPathComponent("node_modules/.bin/\(tool.name)")
            if fileManager.isExecutableFile(atPath: local.path) { return local }
            // deletingLastPathComponent on "/" yields "/..", never "/" again.
            if directory.path == "/" { break }
            directory = directory.deletingLastPathComponent()
        }
        for entry in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent(tool.name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Runs the formatter for `fileURL` over `text`. Blocks until the tool
    /// exits, so call it off the main thread.
    static func format(_ text: String, fileURL: URL, searchPath: String = shellSearchPath) -> Outcome {
        let tools = tools(forExtension: fileURL.pathExtension.lowercased())
        guard let (tool, executable) = tools.lazy
            .compactMap({ tool in
                Self.executable(for: tool, fileURL: fileURL, searchPath: searchPath).map { (tool, $0) }
            })
            .first
        else {
            return .noFormatter(tools.map(\.name))
        }

        let arguments = tool.arguments.map { $0 == "{file}" ? fileURL.path : $0 }
        // The child gets the same search path the lookup used: Prettier's
        // launcher is an `env node` script and needs to find node.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        do {
            let result = try run(
                executable,
                arguments: arguments,
                input: text,
                environment: environment,
                directory: fileURL.deletingLastPathComponent(),
                timeout: 15
            )
            guard result.status == 0 else {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed(message.isEmpty ? "\(tool.name) exited with status \(result.status)." : message)
            }
            // A formatter that prints nothing for a non-empty file did not
            // format it; never trade the buffer for an empty one.
            if result.stdout.isEmpty, !text.isEmpty {
                return .failed("\(tool.name) produced no output.")
            }
            return .formatted(result.stdout)
        } catch {
            return .failed("Could not run \(tool.name): \(error.localizedDescription)")
        }
    }

    /// Whether Prettier would format `fileURL` with nothing but its built-in
    /// defaults: no .prettierrc, prettier.config.*, or package.json "prettier"
    /// key anywhere above the file. Prettier itself is asked, since it owns
    /// the list of places a config can live. False for files Prettier does
    /// not format, and when Prettier is not installed. Blocks; call it off
    /// the main thread.
    static func prettierConfigMissing(for fileURL: URL, searchPath: String = shellSearchPath) -> Bool {
        guard let tool = tools(forExtension: fileURL.pathExtension.lowercased()).first,
              tool.name == "prettier",
              let executable = executable(for: tool, fileURL: fileURL, searchPath: searchPath)
        else { return false }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        // Prints the config's path and exits 0, or exits non-zero when the
        // search comes up empty.
        guard let result = try? run(
            executable,
            arguments: ["--find-config-path", fileURL.path],
            input: "",
            environment: environment,
            directory: fileURL.deletingLastPathComponent(),
            timeout: 15
        ) else { return false }
        return result.status != 0
    }

    /// The PATH an interactive shell would have. An app launched from Finder
    /// inherits a bare system PATH with no Homebrew, nvm, or cargo on it, so
    /// the user's shell is asked once. Falls back to the app's own PATH.
    static let shellSearchPath: String = {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // printenv rather than `echo $PATH`: fish holds PATH as a list.
        guard let result = try? run(
            URL(fileURLWithPath: shell),
            arguments: ["-ilc", "/usr/bin/printenv PATH"],
            input: "",
            environment: ProcessInfo.processInfo.environment,
            directory: nil,
            timeout: 5
        ), result.status == 0 else {
            return inherited
        }
        // Shell startup files can print to stdout; PATH is the last line.
        let lastLine = result.stdout
            .split(whereSeparator: \.isNewline)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let path = lastLine, path.contains("/") else { return inherited }
        return path
    }()

    /// The smallest single replacement that turns `old` into `new`: everything
    /// between their common prefix and common suffix. Applying this instead of
    /// swapping the whole buffer keeps the caret and scroll position where they
    /// were and gives undo one small step.
    static func minimalEdit(from old: String, to new: String) -> (range: NSRange, replacement: String) {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        let limit = min(oldUnits.count, newUnits.count)

        var prefix = 0
        while prefix < limit, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        // Never cut between the halves of a surrogate pair.
        if prefix > 0, UTF16.isLeadSurrogate(oldUnits[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        while suffix < limit - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(oldUnits[oldUnits.count - suffix]) { suffix -= 1 }

        let range = NSRange(location: prefix, length: oldUnits.count - prefix - suffix)
        let replacement = (new as NSString).substring(
            with: NSRange(location: prefix, length: newUnits.count - prefix - suffix)
        )
        return (range, replacement)
    }

    // MARK: - Process

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    private static func run(
        _ executable: URL,
        arguments: [String],
        input: String,
        environment: [String: String],
        directory: URL?,
        timeout: TimeInterval
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Feed stdin and drain both outputs concurrently: a formatter streams
        // output while it is still reading, and any one of the three pipes
        // filling up would otherwise stall the other two.
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let inputData = Data(input.utf8)
        queue.async(group: group) {
            // A tool that exits without reading closes the pipe; that failure
            // shows up as its exit status, so the write error is not reported.
            try? stdin.fileHandleForWriting.write(contentsOf: inputData)
            try? stdin.fileHandleForWriting.close()
        }
        queue.async(group: group) { outBox.data = stdout.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group: group) { errBox.data = stderr.fileHandleForReading.readDataToEndOfFile() }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        group.wait()

        return (
            process.terminationStatus,
            String(data: outBox.data, encoding: .utf8) ?? "",
            String(data: errBox.data, encoding: .utf8) ?? ""
        )
    }
}

import Foundation

/// Generates a short, human-readable title for a Codex session from its raw
/// first prompt, using the LOCAL Ollama CLI — zero API spend, fully offline.
/// Claude sessions carry their own `aiTitle`; Codex sessions don't, so their
/// rows would otherwise show the raw prompt verbatim.
///
/// Pure value type behind a RUNNER seam: the runner maps a prompt string to the
/// model's raw output (or nil on any failure). Production shells out to
/// `ollama run`; tests inject a fake runner and never touch the real binary.
/// `nonisolated`/`Sendable` so it can run off the main thread despite the
/// module's `@MainActor` default isolation.
nonisolated struct SessionTitler: Sendable {
    /// Maps a fully-built prompt to the model's raw stdout, or nil when the
    /// model could not be run (binary missing, non-zero exit, timeout, …).
    typealias Runner = @Sendable (String) -> String?

    private let runner: Runner

    init(runner: @escaping Runner = SessionTitler.ollamaRunner) {
        self.runner = runner
    }

    /// Turn a session's raw title text (its first human prompt) into a cleaned
    /// one-line title, or nil to signal "keep the raw title" — on any runner
    /// failure or unusable output. Never throws; failure always degrades to nil.
    func title(for rawTitle: String) -> String? {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let raw = runner(Self.buildPrompt(from: trimmed)) else { return nil }
        return Self.clean(raw, original: trimmed)
    }

    // MARK: - Prompt

    /// The maximum characters of the raw prompt to feed the model. Titles need
    /// only the gist; the first ~800 chars carry the task and keep the call fast.
    static let maxPromptChars = 800

    /// Build the instruction prompt. Passes only the first `maxPromptChars` of
    /// the session's prompt text and asks for a bare 3-8 word title.
    static func buildPrompt(from rawTitle: String) -> String {
        let input = String(rawTitle.prefix(maxPromptChars))
        return """
        You are labeling a past coding-assistant session for a list. Given the \
        user's first request below, write a concise 3-8 word title that names \
        the task. Output ONLY the title text: no quotes, no surrounding \
        punctuation, no preamble, no trailing period.

        Request:
        \(input)

        Title:
        """
    }

    // MARK: - Cleanup

    /// Defensively normalize the model's raw output into a display title, or nil
    /// if it's unusable (empty, or just echoes the prompt back unchanged).
    ///
    /// Robust against thinking models even when `--think=false` is honored: it
    /// (1) strips ANSI/control escape sequences the CLI interleaves into stdout,
    /// (2) drops any reasoning trace up to and including a final
    /// `...done thinking.` marker, then (3) takes the first non-empty line and
    /// strips wrapping quotes/backticks + a trailing period, collapses
    /// whitespace, and caps the length.
    static func clean(_ raw: String, original: String) -> String? {
        var text = stripControlSequences(raw)
        // A reasoning model streams its trace to stdout before the answer,
        // terminated by a "...done thinking." marker. Keep only what follows the
        // final such marker, dropping the marker's residual dots/whitespace.
        if let marker = text.range(of: "done thinking", options: [.backwards, .caseInsensitive]) {
            text = String(text[marker.upperBound...])
            text = String(text.drop { $0 == "." || $0.isWhitespace })
        }
        // First non-empty line of what remains.
        let firstLine = text
            .split(whereSeparator: { $0.isNewline })
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var title = firstLine
        // Strip wrapping quotes/backticks the model often adds despite the ask.
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        // Collapse any interior runs of whitespace to single spaces.
        title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Drop trailing periods (and any whitespace they leave behind).
        while title.hasSuffix(".") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        // Cap ~60 chars; trim a partial trailing word's dangling space.
        if title.count > maxTitleChars {
            title = String(title.prefix(maxTitleChars)).trimmingCharacters(in: .whitespaces)
        }
        // Reject a title that just parrots the prompt back — no value over the
        // raw text we already show.
        let collapsedOriginal = original.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if title.caseInsensitiveCompare(collapsedOriginal) == .orderedSame { return nil }
        return title
    }

    /// Display cap for a generated title.
    static let maxTitleChars = 60

    /// Strip ANSI escape sequences and stray control bytes the Ollama CLI
    /// interleaves into stdout (cursor moves like `ESC[3D`, line erases like
    /// `ESC[K`, spinner redraws). Newlines and tabs are kept so line-splitting
    /// still works; every other C0 control byte is dropped.
    static func stripControlSequences(_ raw: String) -> String {
        var text = raw
        // ANSI CSI sequences: ESC '[' <params> <intermediates> <final byte>.
        if let csi = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;?]*[ -/]*[@-~]") {
            text = csi.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
            )
        }
        // Any other two-byte escape (ESC + one byte).
        if let esc = try? NSRegularExpression(pattern: "\\x1B.") {
            text = esc.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
            )
        }
        // Drop remaining control bytes except newline/tab (catches a lone ESC).
        let scalars = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: - Production runner

    /// Absolute path to the Ollama CLI (Homebrew on Apple Silicon).
    static let ollamaBinary = "/opt/homebrew/bin/ollama"
    /// The local model to title with.
    static let ollamaModel = "gemma4:12b-mlx"
    /// Hard ceiling on a single title call, so a wedged model can never hang the
    /// background titling queue. Sized for a COLD model load (~37s observed);
    /// warm calls with `--think=false` return in a few seconds.
    static let ollamaTimeout: TimeInterval = 60

    /// The default runner: shell out to `ollama run <model> <prompt>` and return
    /// stdout, or nil if the binary is absent, exits non-zero, or overruns the
    /// timeout. No shell is involved (the prompt is a single argv element), so
    /// prompt text can't be interpreted as a command.
    @Sendable static func ollamaRunner(_ prompt: String) -> String? {
        runOllama(
            prompt: prompt,
            binary: ollamaBinary,
            model: ollamaModel,
            timeout: ollamaTimeout
        )
    }

    /// Testable core of the production runner (never invoked by unit tests,
    /// which inject a fake runner instead).
    static func runOllama(
        prompt: String,
        binary: String,
        model: String,
        timeout: TimeInterval
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // `--think=false` disables the reasoning trace: without it gemma streams
        // its "Thinking… …done thinking." trace to stdout (and is far slower).
        process.arguments = ["run", model, "--think=false", prompt]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain both pipes concurrently so a chatty stderr can't deadlock the
        // child against a full buffer while we wait on stdout. `Box` is a
        // reference so the reader closure mutates a shared property rather than a
        // captured `var` (which strict concurrency flags); the DispatchGroup
        // barrier makes the write visible before we read it back.
        final class Box: @unchecked Sendable { var data = Data() }
        let out = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            out.data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: out.data, as: UTF8.self)
    }
}

import Cocoa

protocol QuickOpenPanelDelegate: AnyObject {
    func quickOpenPanel(_ panel: QuickOpenPanel, didSelectFile filePath: String)
}

/// `nonisolated` because scoring builds these on a background queue and hands
/// them to the main actor (see `scoredResults`).
nonisolated struct FileResult: Sendable {
    let path: String
    let relativePath: String
    let fileName: String
    let score: Int
    let directory: String
}

/// Cmd+P quick-open: debounced `fd`/`find` search, fuzzy-ranked. The panel
/// chrome (search field, table, key handling) lives in `FilterableListPanel`;
/// this subclass supplies the file results and the async search.
class QuickOpenPanel: FilterableListPanel {
    /// Decides which finished search may write its rows into the panel.
    ///
    /// Terminating the child process isn't enough on its own: a killed `find`
    /// has usually already printed most of a large tree, so its reader keeps
    /// going, scores what it has, and hops to the main queue with results for a
    /// query that no longer exists. Clearing the field returns immediately, so
    /// those rows would reappear under an empty search field. Every search takes
    /// a ticket; anything that abandons the current search retires it, and a
    /// retired ticket is refused on arrival.
    ///
    /// `nonisolated` so the rule can be tested without a window.
    nonisolated struct SearchGate: Equatable {
        private var issued = 0
        private var active: Int?

        /// Begin a search and take the ticket it must present later.
        mutating func start() -> Int {
            issued += 1
            active = issued
            return issued
        }

        /// Abandon whatever search is running; every outstanding ticket is now
        /// stale.
        mutating func invalidate() {
            active = nil
        }

        /// Whether the holder of `ticket` is still the search the panel wants.
        func accepts(_ ticket: Int) -> Bool { active == ticket }
    }

    private var findTask: Process?
    private var searchGate = SearchGate()
    private var debounceWorkItem: DispatchWorkItem?

    weak var quickOpenDelegate: QuickOpenPanelDelegate?

    private var fileResults: [FileResult] = []
    private var currentWorkingDirectory: String = FileManager.default.currentDirectoryPath
    private nonisolated static let maxResults = 50

    /// Upper bound on candidate paths read and scored per keystroke on the
    /// `find` fallback. `fd` pre-filters and caps server-side
    /// (`fdCandidateCap`), but plain `find` returns the whole tree — without a
    /// bound a large repo would score tens of thousands of paths on every
    /// keystroke (P2). The reader stops at this many lines and kills the child,
    /// so the cap bounds the walk itself, not just the scoring. Generous enough
    /// that ordinary repos are covered in full.
    private nonisolated static let candidateScanCap = 20_000

    /// Wall-clock ceiling on one search. A `find` rooted somewhere enormous (a
    /// home directory, a network mount) can walk for minutes; past this the
    /// child is killed and whatever it printed so far is scored. Long enough
    /// that a normal repo never reaches it.
    private nonisolated static let searchTimeout: TimeInterval = 5

    /// Directory names never worth walking: version control, dependency, and
    /// build output trees. Pruned by `find` so it doesn't descend into them at
    /// all — the old `-not -path` form walked every one of `node_modules` and
    /// threw the results away afterwards.
    private nonisolated static let prunedDirectories = [".git", "node_modules", ".build", "target"]

    init() {
        super.init(chrome: Chrome(
            title: "Quick Open",
            placeholder: "Type to search files...",
            size: NSSize(width: 600, height: 400),
            columnIdentifier: "FileResult",
            hidesOnDeactivate: false
        ))
    }

    // MARK: - FilterableListPanel hooks

    override var itemCount: Int { fileResults.count }

    override func cellView(forRow row: Int) -> NSView? {
        let cellView = QuickOpenCellView()
        cellView.configure(with: fileResults[row])
        return cellView
    }

    override func queryChanged(_ query: String) {
        // Cancel previous debounce work and retire any in-flight find task.
        debounceWorkItem?.cancel()
        endActiveSearch()

        if query.isEmpty {
            fileResults = []
            tableView.reloadData()
            return
        }

        // Debounce search by 150ms.
        let workItem = DispatchWorkItem { [weak self] in
            self?.performFileSearch(query)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    override func activateRow(_ row: Int) {
        let result = fileResults[row]
        quickOpenDelegate?.quickOpenPanel(self, didSelectFile: result.path)
        close()
    }

    private func performFileSearch(_ searchText: String) {
        // Read once on the main actor; the background scorer needs it too.
        let root = currentWorkingDirectory

        // Use fd for fast file finding, fall back to find
        let task = Process()

        // Try fd first (faster)
        if let fdURL = ProcessRunner.executableURL(named: "fd", commonPaths: [
            "/opt/homebrew/bin/fd",
            "/usr/local/bin/fd",
            "/opt/local/bin/fd"
        ]) {
            task.executableURL = fdURL
            // Pass the query to fd as a subsequence regex matched against the full
            // path, so the file the user typed is actually in the result set. The
            // old match-all "." + low cap returned 50 arbitrary files and filtered
            // client-side, so the target usually never appeared. A larger cap still
            // bounds pathological matches; client-side scoring ranks what's left.
            task.arguments = [
                "--type", "f",
                "--full-path",
                "--ignore-case",
                "--max-results", String(fdCandidateCap),
                "--exclude", ".git",
                "--exclude", "node_modules",
                "--exclude", ".build",
                "--exclude", "target",
                Self.fuzzyRegex(for: searchText),
                currentWorkingDirectory
            ]
        } else {
            // Fallback to find
            task.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            task.arguments = Self.findArguments(root: currentWorkingDirectory)
        }

        let pipe = Pipe()
        task.standardOutput = pipe
        // /dev/null, not a Pipe: an unread pipe fills at ~64KB and blocks the
        // child forever (find prints a line per unreadable directory).
        task.standardError = FileHandle.nullDevice

        // Store reference, and take the ticket that says these results are the
        // ones the panel still wants.
        findTask = task
        let ticket = searchGate.start()

        do {
            try task.run()
            // A walk that never finishes must not hold a pipe reader hostage:
            // kill the child at the deadline and score whatever it printed. A
            // task that already exited is left alone, so this is a no-op on
            // every search that finished in time.
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + Self.searchTimeout) { [task] in
                    if task.isRunning { task.terminate() }
                }

            // Drain off the main thread: reading to EOF on the main queue froze the
            // UI for the whole walk on large trees. Results are dropped unless the
            // gate still accepts this ticket — a newer query, a cleared field, or a
            // closed panel all retire it.
            DispatchQueue.global(qos: .userInitiated).async { [weak self, task] in
                // Read incrementally and stop at the cap, instead of buffering
                // the whole tree: `find` on a large root prints far more than
                // will ever be scored, and readDataToEndOfFile held all of it.
                let paths = Self.readPaths(
                    from: pipe.fileHandleForReading,
                    cap: Self.candidateScanCap,
                    onCap: { if task.isRunning { task.terminate() } }
                )
                task.waitUntilExit()
                // Score off the main thread: on the `find` fallback this walked
                // and scored the whole tree on the main queue every keystroke.
                let results = Self.scoredResults(from: paths, searchText: searchText, root: root)
                DispatchQueue.main.async {
                    guard let self = self, self.searchGate.accepts(ticket) else { return }
                    self.applyResults(results)
                }
            }
        } catch {
            // A failed spawn must not blank out rows a newer search already put
            // there, so it clears only if it is still the current search.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchGate.accepts(ticket) else { return }
                self.fileResults = []
                self.tableView.reloadData()
            }
        }
    }

    /// Retire the running search: kill the child and drop the ticket, so
    /// anything still draining its pipe can no longer write to the panel. Called
    /// wherever the current results stop being wanted — a new query, an emptied
    /// field, a closed panel.
    private func endActiveSearch() {
        findTask?.terminate()
        findTask = nil
        searchGate.invalidate()
    }

    /// fd candidate ceiling. Higher than the display cap (`maxResults`) because
    /// the query now pre-filters server-side; client-side scoring ranks these.
    private var fdCandidateCap: Int { 500 }

    /// Builds a case-insensitive subsequence regex from `query` so fd returns any
    /// path whose characters appear in order (fuzzy match), e.g. "edsyn" matches
    /// "Editor/SyntaxHighlighter.swift". Regex metacharacters are escaped.
    static func fuzzyRegex(for query: String) -> String {
        query.map { ch -> String in
            let s = String(ch)
            return NSRegularExpression.escapedPattern(for: s)
        }.joined(separator: ".*")
    }

    /// The `find` fallback's argv. The pruned directories are cut off with
    /// `-prune` so the walk never enters them, and dot-names are pruned too,
    /// matching what the old `-not -path "*/.*"` filter hid. Everything left is
    /// printed as it's found, so the reader can stop the walk at the cap.
    nonisolated static func findArguments(root: String) -> [String] {
        var arguments = [root, "("]
        for (index, name) in (prunedDirectories + [".*"]).enumerated() {
            if index > 0 { arguments.append("-o") }
            arguments += ["-name", name]
        }
        arguments += [")", "-prune", "-o", "-type", "f", "-print"]
        return arguments
    }

    /// Accumulates newline-separated paths out of a stream of chunks, stopping
    /// at `cap` lines. Split out from the process plumbing so the chunk/line
    /// boundary handling — a path split across two reads — is testable without
    /// spawning anything.
    ///
    /// The carried-over tail stays as bytes, never as a decoded `String`: a read
    /// boundary can land in the middle of a multi-byte UTF-8 scalar, and
    /// decoding each chunk on arrival would turn the two halves of an "é" into
    /// replacement characters and hand back a path that doesn't exist. Only
    /// whole lines, delimited by newline bytes, are decoded.
    nonisolated struct BoundedLineReader {
        private static let newline = UInt8(0x0A)

        let cap: Int
        private(set) var lines: [String] = []
        /// The tail of the last chunk, which may be half a path — and, at the
        /// byte level, half a character.
        private var partial = Data()

        init(cap: Int) {
            self.cap = cap
        }

        var isFull: Bool { lines.count >= cap }

        mutating func consume(_ data: Data) {
            guard !isFull, !data.isEmpty else { return }
            var start = data.startIndex
            while let newlineIndex = data[start...].firstIndex(of: Self.newline) {
                partial.append(contentsOf: data[start..<newlineIndex])
                append(partial)
                partial.removeAll(keepingCapacity: true)
                start = newlineIndex + 1
                if isFull {
                    partial.removeAll()
                    return
                }
            }
            partial.append(contentsOf: data[start...])
        }

        /// Flush a final line that never got its newline (a child killed
        /// mid-print, or output that simply doesn't end in one).
        mutating func finish() {
            guard !isFull, !partial.isEmpty else { return }
            append(partial)
            partial.removeAll()
        }

        /// Decode one complete line. Lossy, like every other path we read off a
        /// pipe: a filename that isn't valid UTF-8 is better shown with a
        /// replacement character than dropped.
        private mutating func append(_ line: Data) {
            lines.append(String(decoding: line, as: UTF8.self))
        }
    }

    /// Drain `handle` into at most `cap` paths, calling `onCap` (which kills the
    /// child) as soon as the cap is hit so the walk stops instead of filling a
    /// pipe nobody will read.
    private nonisolated static func readPaths(
        from handle: FileHandle,
        cap: Int,
        onCap: () -> Void
    ) -> [String] {
        var reader = BoundedLineReader(cap: cap)
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }   // EOF
            reader.consume(chunk)
            if reader.isFull {
                onCap()
                // Keep draining so the child dies on its own write instead of
                // blocking forever on a full pipe; the reader discards it all.
                while !handle.availableData.isEmpty {}
                break
            }
        }
        reader.finish()
        return reader.lines
    }

    /// Path relative to `root`, tolerant of a trailing slash on `root`. Returns
    /// the original path when it isn't under `root`.
    nonisolated static func relativePath(of fullPath: String, under root: String) -> String {
        guard fullPath.hasPrefix(root) else { return fullPath }
        return String(fullPath.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    /// Scores candidate paths and returns the top `maxResults`. Pure and
    /// nonisolated so it can run on a background queue (P2). The reader already
    /// stopped at `candidateScanCap`; the count here is a second belt.
    nonisolated static func scoredResults(
        from paths: [String],
        searchText: String,
        root: String
    ) -> [FileResult] {
        var results: [FileResult] = []
        var scanned = 0

        for line in paths {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            if scanned >= candidateScanCap { break }
            scanned += 1

            let url = URL(fileURLWithPath: trimmedLine)
            let fileName = url.lastPathComponent
            let directory = url.deletingLastPathComponent().lastPathComponent
            let relativePath = relativePath(of: trimmedLine, under: root)

            // Score the filename and the relative path; take the better, with a
            // directory-only match discounted so filename hits still rank on top.
            // (fd now matches on the full path, so some results match only via a
            // directory component — keep those, just below true filename matches.)
            let nameScore = FuzzyScorer.score(candidate: fileName, query: searchText) ?? 0
            let pathScore = FuzzyScorer.score(candidate: relativePath, query: searchText) ?? 0
            let score = max(nameScore, pathScore / 2)
            guard score > 0 else { continue }

            results.append(FileResult(
                path: trimmedLine,
                relativePath: relativePath,
                fileName: fileName,
                score: score,
                directory: directory
            ))
        }

        // Sort by score (higher is better) and limit results
        return results.sorted { $0.score > $1.score }.prefix(maxResults).map { $0 }
    }

    private func applyResults(_ results: [FileResult]) {
        fileResults = results
        reloadAndSelectFirst()
    }

    func show(relativeTo parentWindow: NSWindow, workingDirectory: String) {
        currentWorkingDirectory = workingDirectory

        // Position relative to parent window
        let parentFrame = parentWindow.frame
        let panelSize = frame.size
        let newOrigin = NSPoint(
            x: parentFrame.midX - panelSize.width / 2,
            y: parentFrame.midY + 100
        )
        setFrameOrigin(newOrigin)

        // Clear previous search. Reopening on a different working directory
        // must not inherit rows (or a still-draining search) from the last one.
        debounceWorkItem?.cancel()
        endActiveSearch()
        fileResults = []
        tableView.reloadData()
        searchField.stringValue = ""

        // Show and focus
        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()
    }

    override func close() {
        // Cancel any running tasks
        debounceWorkItem?.cancel()
        endActiveSearch()

        super.close()
    }
}

// MARK: - Custom Cell View
class QuickOpenCellView: NSTableCellView {
    private var fileNameLabel: NSTextField!
    private var pathLabel: NSTextField!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        fileNameLabel = NSTextField(labelWithString: "")
        fileNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        fileNameLabel.textColor = AppTheme.primaryText
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = AppTheme.mutedText
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(fileNameLabel)
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            fileNameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            fileNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fileNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            pathLabel.topAnchor.constraint(equalTo: fileNameLabel.bottomAnchor, constant: 1),
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            pathLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    func configure(with result: FileResult) {
        fileNameLabel.stringValue = result.fileName
        pathLabel.stringValue = result.relativePath
    }
}

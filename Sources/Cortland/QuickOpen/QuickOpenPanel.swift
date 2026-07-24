import Cocoa

protocol QuickOpenPanelDelegate: AnyObject {
    func quickOpenPanel(_ panel: QuickOpenPanel, didSelectFile filePath: String)
}

struct FileResult {
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
    private var findTask: Process?
    private var debounceWorkItem: DispatchWorkItem?

    weak var quickOpenDelegate: QuickOpenPanelDelegate?

    private var fileResults: [FileResult] = []
    private var currentWorkingDirectory: String = FileManager.default.currentDirectoryPath
    private nonisolated static let maxResults = 50

    /// Upper bound on candidate paths scored per keystroke on the `find`
    /// fallback. `fd` pre-filters and caps server-side (`fdCandidateCap`), but
    /// plain `find` returns the whole tree — without a bound a large repo would
    /// score tens of thousands of paths on every keystroke (P2). Generous enough
    /// that ordinary repos are covered in full.
    private nonisolated static let candidateScanCap = 20_000

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
        // Cancel previous debounce work and any in-flight find task.
        debounceWorkItem?.cancel()
        findTask?.terminate()

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
            task.arguments = [
                currentWorkingDirectory,
                "-type", "f",
                "-not", "-path", "*/.*",
                "-not", "-path", "*/node_modules/*",
                "-not", "-path", "*/.build/*",
                "-not", "-path", "*/target/*"
            ]
        }

        let pipe = Pipe()
        task.standardOutput = pipe
        // /dev/null, not a Pipe: an unread pipe fills at ~64KB and blocks the
        // child forever (find prints a line per unreadable directory).
        task.standardError = FileHandle.nullDevice

        // Store reference
        findTask = task

        do {
            try task.run()
            // Drain off the main thread: reading to EOF on the main queue froze the
            // UI for the whole walk on large trees. Discard stale results if a newer
            // query started (findTask !== task), mirroring SearchPanelViewController.
            DispatchQueue.global(qos: .userInitiated).async { [weak self, task] in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                // Score off the main thread: on the `find` fallback this walked
                // and scored the whole tree on the main queue every keystroke.
                let results = Self.scoredResults(from: data, searchText: searchText, root: root)
                DispatchQueue.main.async {
                    guard let self = self, self.findTask === task else { return }
                    self.applyResults(results)
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.fileResults = []
                self?.tableView.reloadData()
            }
        }
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

    /// Path relative to `root`, tolerant of a trailing slash on `root`. Returns
    /// the original path when it isn't under `root`.
    nonisolated static func relativePath(of fullPath: String, under root: String) -> String {
        guard fullPath.hasPrefix(root) else { return fullPath }
        return String(fullPath.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    /// Scores candidate paths and returns the top `maxResults`. Pure and
    /// nonisolated so it can run on a background queue (P2).
    private nonisolated static func scoredResults(
        from data: Data,
        searchText: String,
        root: String
    ) -> [FileResult] {
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [FileResult] = []
        var scanned = 0

        for line in output.components(separatedBy: .newlines) {
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

        // Clear previous search
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
        findTask?.terminate()

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

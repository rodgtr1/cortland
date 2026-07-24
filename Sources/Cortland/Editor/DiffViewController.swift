import Cocoa

class DiffViewController: NSViewController {
    private var textView: NSTextView!
    private var scrollView: NSScrollView!

    private var filePath: String?
    private let gitService = GitService()

    /// Chrome colors shared by the diff surfaces (this controller and the
    /// uncommitted-changes panel). The diff *content* — added/removed lines,
    /// hunk/file headers, intraline emphasis — is colored entirely by
    /// InlineDiffRenderer, so this holds only the surrounding view colors.
    struct DiffColors {
        static var background: NSColor { AppTheme.windowBackground }
        static var text: NSColor { AppTheme.primaryText }
        static var context: NSColor { AppTheme.mutedText }
        static var fileHeader: NSColor { AppTheme.warning }
    }

    override func loadView() {
        view = NSView()
        // Call setup immediately after creating view
        setupTextView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // setupTextView is now called in loadView
    }

    private func setupTextView() {
        Log.debug("📝 DiffViewController: setupTextView called", category: "editor")

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        // Create text container and layout manager
        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let layoutManager = DiffLineBackgroundLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = DiffColors.background
        textView.textColor = DiffColors.text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.autoresizingMask = [.width]

        // Configure for scrolling
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        scrollView.documentView = textView

        // No line-number ruler: the inline diff rendering carries its own
        // gutter with the new file's line numbers.

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        Log.debug("📝 DiffViewController: setupTextView complete, view bounds: \(view.bounds)", category: "editor")
    }

    func showDiff(for filePath: String, kind: GitDiffKind = .uncommitted) {
        Log.debug("📝 DiffViewController: showDiff called for: \(filePath)", category: "editor")
        self.filePath = filePath

        // Load the diff off the main actor (loadGitDiff is nonisolated async),
        // then return here on the main actor to render. The enclosing Task
        // inherits main-actor isolation, so the post-await UI calls are safe.
        Task { [weak self] in
            guard let self else { return }
            do {
                let diffContent = try await self.loadGitDiff(for: filePath, kind: kind)
                Log.debug("📝 DiffViewController: Loaded diff content (\(diffContent.count) chars)", category: "editor")
                self.displayDiff(diffContent)
            } catch {
                Log.error("❌ DiffViewController: Failed to load diff: \(error.localizedDescription)", category: "diff")
                self.showError("Failed to load diff: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated func loadGitDiff(for filePath: String, kind: GitDiffKind) async throws -> String {
        Log.debug("📝 loadGitDiff: filePath = \(filePath)", category: "editor")

        let gitRoot = gitService.repositoryRoot(from: filePath) ?? URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        Log.debug("📝 loadGitDiff: gitRoot = \(gitRoot)", category: "editor")

        let workspace = WorkspaceContext(workingDirectory: gitRoot, repositoryRoot: gitRoot)
        let relativePath = workspace.relativePath(for: filePath)
        Log.debug("📝 loadGitDiff: relativePath = \(relativePath)", category: "editor")

        let diff: String
        switch kind {
        case .uncommitted:
            diff = try gitService.diff(relativePath: relativePath, repositoryRoot: gitRoot)
        case .againstDefaultBranch:
            // The committed vs-default diff needs the default branch; if it can't
            // be resolved there's nothing to compare against.
            guard let base = try gitService.defaultBranch(repositoryRoot: gitRoot) else {
                return "No changes"
            }
            diff = try gitService.diffAgainstDefaultBranch(
                relativePath: relativePath, repositoryRoot: gitRoot, defaultBranch: base
            )
        }
        Log.debug("📝 loadGitDiff: git diff output length = \(diff.count)", category: "editor")
        return diff
    }

    private func displayDiff(_ content: String) {
        Log.debug("📝 DiffViewController: displayDiff called with \(content.count) chars", category: "editor")

        guard let textStorage = textView.textStorage else {
            Log.error("❌ DiffViewController: textStorage is nil!", category: "diff")
            return
        }

        textStorage.setAttributedString(NSAttributedString())

        if content.trimmingCharacters(in: .whitespacesAndNewlines) == "No changes" {
            let noChangesText = NSAttributedString(string: "No changes", attributes: [
                .foregroundColor: DiffColors.context,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            ])
            textStorage.append(noChangesText)
            return
        }

        let ext = (filePath as NSString?)?.pathExtension.lowercased() ?? ""
        textStorage.append(InlineDiffRenderer.render(content, fileExtension: ext))

        Log.debug("📝 DiffViewController: Final textStorage length: \(textStorage.length)", category: "editor")
        Log.debug("📝 DiffViewController: textView bounds: \(textView.bounds)", category: "editor")
        Log.debug("📝 DiffViewController: textView isHidden: \(textView.isHidden)", category: "editor")
        Log.debug("📝 DiffViewController: scrollView bounds: \(scrollView.bounds)", category: "editor")

        // Force a layout update
        textView.setNeedsDisplay(textView.bounds)
        scrollView.setNeedsDisplay(scrollView.bounds)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Diff Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

import Cocoa

final class UncommittedChangesViewController: NSViewController {
    var onOpenFile: ((String) -> Void)?
    /// The agent panes working in a repository, asked fresh each time the
    /// review bar is shown or pressed.
    var agentsForRepository: ((String) -> [ChangesComments.Agent])?
    /// Delivers a prompt to an agent pane by id; false when it is gone.
    var sendToAgent: ((UUID, String) -> Bool)?

    private var repositoryPath: String
    /// The changes shown, fixed at creation.
    let source: ChangesSource
    private var focusedFilePath: String?
    private let gitService: GitService
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!

    /// Each diff text view soft-wraps, so its height depends on the laid-out
    /// width — unknown until Auto Layout runs. We seed each height constraint
    /// from the logical line count, then correct it to the real wrapped height in
    /// viewDidLayout (and on every resize). Without this, long/minified lines
    /// wrap to extra visual rows the fixed height never accounted for, clipping
    /// the bottom of the section.
    private struct DiffColumn {
        let textView: NSTextView
        let heightConstraint: NSLayoutConstraint
    }
    private var diffColumns: [DiffColumn] = []

    /// A text diff's view and its change blocks, keyed by relative path. Only
    /// sections whose diff body has been built have one.
    private struct DiffBody {
        let textView: NSTextView
        let blocks: [NSRange]
        let rows: [ChangesComments.Row]
    }
    private var diffBodies: [String: DiffBody] = [:]

    /// Keyboard review: the file the keys act on, the marked change block,
    /// and the accent bar drawn beside that block.
    private var currentFile: String?
    private var currentBlock: ChangesReview.BlockID?
    private let blockMark: NSView = {
        let mark = NSView()
        mark.wantsLayer = true
        return mark
    }()

    /// Review comments, held in memory for this pane only. Icons are keyed
    /// by path and first row.
    private var comments: [ChangesComments.Comment] = []
    private var commentIcons: [String: ChangesCommentIcon] = [:]
    private var commentPopover: NSPopover?
    private var reviewBar: NSView!
    private var reviewBarHeight: NSLayoutConstraint!
    private var reviewCountLabel: NSTextField!
    private var reviewPrimaryButton: NSButton!
    private var reviewDiscardButton: NSButton!
    /// The send mode the bar's primary button currently shows.
    private var displayedSendMode: ChangesComments.SendMode?
    /// Running while the bar shows a sent or copied confirmation.
    private var confirmationTimer: Timer?

    /// What the stack currently shows, keyed by relative path for the
    /// reconcile. nil until a load has displayed something.
    private var displayedSections: [ChangeSection]?
    private var sectionViews: [String: ChangeSectionView] = [:]
    /// Collapse and Viewed marks, keyed by relative path, for this pane only.
    private var sectionStates = ChangesSectionStates()
    private var requests = LatestRequestGate()
    private let watcher = RepositoryWatcher()
    /// The repository changed while the pane was hidden.
    private var isStale = false

    private enum Metrics {
        static let horizontalPadding: CGFloat = 12
        static let sectionSpacing: CGFloat = 10
        static let headerHeight: CGFloat = 28
        static let diffLineHeight: CGFloat = 19
        static let reviewBarHeight: CGFloat = 34
        static let commentIconSize: CGFloat = 12
    }

    init(
        repositoryPath: String,
        source: ChangesSource = .uncommitted,
        focusedFilePath: String? = nil,
        gitService: GitService = GitService()
    ) {
        self.repositoryPath = repositoryPath
        self.source = source
        self.focusedFilePath = focusedFilePath
        self.gitService = gitService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = WindowObservingView()
        rootView.onWindowChange = { [weak self] in
            self?.visibilityMayHaveChanged()
            if self?.comments.isEmpty == false {
                self?.updateReviewBar()
            }
        }
        rootView.onKeyDown = { [weak self] event in
            guard let self else { return false }
            return self.handleReviewKey(event) || self.handleScrollKey(event)
        }
        view = rootView
        view.wantsLayer = true
        view.layer?.backgroundColor = DiffColors.background.cgColor
        setupScrollView()
        setupReviewBar()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startWatching()
        loadChanges()
    }

    func reload(focusedFilePath: String?) {
        self.focusedFilePath = focusedFilePath
        loadChanges()
    }

    private func setupScrollView() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DiffColors.background
        view.addSubview(scrollView)

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = Metrics.sectionSpacing
        stackView.edgeInsets = NSEdgeInsets(
            top: Metrics.horizontalPadding,
            left: Metrics.horizontalPadding,
            bottom: Metrics.horizontalPadding,
            right: Metrics.horizontalPadding
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = DiffColors.background.cgColor
        documentView.addSubview(stackView)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            documentView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            documentView.topAnchor.constraint(equalTo: stackView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: stackView.bottomAnchor),

            stackView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor)
        ])
    }

    // MARK: - Live refresh

    /// Watches the working tree and the git directory so edits, stages, and
    /// commits all refresh the pane. The root covers `.git` in a normal repo; a
    /// linked worktree keeps its index under the main repo's
    /// `.git/worktrees/<name>`, so that directory is watched too. The watcher's
    /// own deinit stops the stream when this controller goes away.
    private func startWatching() {
        watcher.onChange = { [weak self] in self?.repositoryChanged() }
        var paths = [repositoryPath]
        if let gitDir = GitStatusModel.linkedWorktreeGitDir(forRoot: repositoryPath) {
            paths.append(gitDir)
        }
        watcher.start(paths: paths)
    }

    /// The pane is on screen only while its tab is attached to the window.
    private var isVisible: Bool {
        view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    /// A hidden pane skips the diff work and remembers it is behind.
    private func repositoryChanged() {
        if isVisible {
            loadChanges()
        } else {
            isStale = true
        }
    }

    private func visibilityMayHaveChanged() {
        guard isStale, isVisible else { return }
        loadChanges()
    }

    private func loadChanges() {
        isStale = false
        // "Loading" only fills an empty pane; a refresh leaves the current
        // content on screen until the new result is ready.
        if stackView.arrangedSubviews.isEmpty {
            showMessage("Loading changes...")
        }
        let request = requests.begin()

        DispatchQueue.global(qos: .userInitiated).async { [repositoryPath, gitService, source] in
            let result: Result<[ChangeSection], Error>
            do {
                if case .branch = source {
                    result = .success(try Self.branchSections(repositoryPath: repositoryPath, gitService: gitService))
                } else {
                    // Keep a stable order by relative path; the focused file is
                    // scrolled into view rather than reordered to the top.
                    let entries = try gitService.status(repositoryRoot: repositoryPath)
                        .sorted { $0.path < $1.path }

                    let diffs = try gitService.diffsByPath(for: entries, repositoryRoot: repositoryPath)
                    result = .success(entries.map { entry in
                        ChangeSection(
                            relativePath: entry.path,
                            diff: diffs[entry.path] ?? "No changes",
                            isConflicted: entry.isConflicted,
                            status: GitFileItem(
                                path: entry.path,
                                stagedChar: entry.stagedStatus,
                                unstagedChar: entry.unstagedStatus
                            ).displayStatus,
                            repositoryPath: repositoryPath,
                            isFullyStaged: ChangesReview.isFullyStaged(entry)
                        )
                    })
                }
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishLoad(request: request, result: result)
            }
        }
    }

    /// The branch's committed files against the default branch, in path
    /// order. None when the default branch cannot be resolved.
    private nonisolated static func branchSections(repositoryPath: String, gitService: GitService) throws -> [ChangeSection] {
        guard let base = try gitService.defaultBranch(repositoryRoot: repositoryPath) else { return [] }
        let entries = try gitService.changedFilesAgainstDefaultBranch(repositoryRoot: repositoryPath, defaultBranch: base)
            .sorted { $0.path < $1.path }
        let diffs = try gitService.diffsAgainstDefaultBranchByPath(repositoryRoot: repositoryPath, defaultBranch: base)
        return entries.map { entry in
            ChangeSection(
                relativePath: entry.path,
                diff: diffs[entry.path] ?? "No changes",
                isConflicted: false,
                status: GitBranchDiffItem(path: entry.path, status: entry.status).status,
                repositoryPath: repositoryPath
            )
        }
    }

    private func finishLoad(request: Int, result: Result<[ChangeSection], Error>) {
        // Watcher bursts and sidebar clicks overlap; only the newest wins.
        guard requests.isCurrent(request) else { return }

        switch result {
        case .failure(let error):
            // A failed refresh keeps what is on screen; only a first load reports.
            guard displayedSections == nil else { return }
            let what = source == .uncommitted ? "uncommitted changes" : "the changes on this branch"
            showMessage("Failed to load \(what): \(error.localizedDescription)")
        case .success(let sections):
            // The tab was hidden while this ran: catch up when it is shown.
            if displayedSections != nil && !isVisible {
                isStale = true
                return
            }
            display(sections)
        }
    }

    private func showMessage(_ message: String) {
        clearStack()
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = DiffColors.context
        label.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(label)
    }

    private func display(_ sections: [ChangeSection]) {
        let focus = focusedFilePath
        focusedFilePath = nil

        if let displayed = displayedSections {
            let plan = ChangesReconcilePlan(displayed: displayed, incoming: sections)
            if !plan.isNoOp {
                // A focus request scrolls on its own; otherwise hold the
                // reader's place across the change.
                let anchor = focus == nil ? captureScrollAnchor() : nil
                let previousTop = visibleTop
                reconcile(plan, sections: sections)
                if let anchor {
                    settleLayout()
                    scroll(toVisibleTop: anchor.restoredTop(in: sectionGeometry(), fallback: previousTop))
                }
            }
        } else {
            clearStack()
            if sections.isEmpty {
                showMessage("No changes")
            } else {
                updateSectionStates(sections, contentChanged: [])
                for section in sections {
                    let sectionView = makeSectionView(section)
                    stackView.addArrangedSubview(sectionView)
                    sectionViews[section.relativePath] = sectionView
                }
            }
            displayedSections = sections
        }

        // A sidebar click opens the file's section if it is collapsed; its
        // Viewed mark stays as it is.
        if let focus,
           let path = sectionViews.first(where: { $0.value.identifier?.rawValue == focus })?.key,
           let sectionView = sectionViews[path],
           sectionStates.state(for: path).isCollapsed {
            sectionStates.expand(path)
            applyState(to: sectionView, path: path)
        }

        if let focus {
            // Frames are only valid after layout, so scroll on the next
            // runloop pass once the stack view has sized its sections.
            DispatchQueue.main.async { [weak self] in
                self?.scrollToFocusedFile(focus)
            }
        }
    }

    /// Applies `plan` to the stack: kept section views stay untouched (so a
    /// text selection inside them survives), changed ones are rebuilt in
    /// place, new ones are inserted in path order, and vanished ones removed.
    private func reconcile(_ plan: ChangesReconcilePlan, sections: [ChangeSection]) {
        // Drop the "No changes" message and every view that is going away.
        let rebuilt = Set(plan.steps.compactMap { step -> String? in
            if case .rebuild(let path) = step { return path }
            return nil
        })
        let replaced = rebuilt.union(plan.removed)
        let keptViews = Set(sectionViews.filter { !replaced.contains($0.key) }.values.map(ObjectIdentifier.init))
        for arranged in stackView.arrangedSubviews where !keptViews.contains(ObjectIdentifier(arranged)) {
            stackView.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        for path in replaced {
            sectionViews.removeValue(forKey: path)
        }
        diffColumns.removeAll { !$0.textView.isDescendant(of: stackView) }
        diffBodies = diffBodies.filter { $0.value.textView.isDescendant(of: stackView) }

        updateSectionStates(
            sections,
            contentChanged: ChangesSectionStates.contentChangedPaths(displayed: displayedSections ?? [], incoming: sections)
        )

        // A rebuilt section's comments re-anchor once its body is built; a
        // file that left takes its comments out of the diff.
        let removed = Set(plan.removed)
        for index in comments.indices {
            let path = comments[index].path
            if removed.contains(path) {
                comments[index].anchor = .detached
            } else if rebuilt.contains(path) {
                comments[index].anchor = .pending
            }
        }

        // Kept views are already in path order, so everything before index i
        // is exactly sections[0..<i] and a new view slots in at i.
        for (index, section) in sections.enumerated() {
            guard sectionViews[section.relativePath] == nil else { continue }
            let sectionView = makeSectionView(section)
            stackView.insertArrangedSubview(sectionView, at: index)
            sectionViews[section.relativePath] = sectionView
        }

        if sections.isEmpty {
            showMessage("No changes")
        }
        displayedSections = sections

        // The current file follows its neighbour if it left; a block mark
        // survives only on a section that was kept as it was.
        if let currentFile {
            self.currentFile = ChangesReview.fileAfterRemoval(currentFile, paths: sections.map(\.relativePath))
        }
        if let currentBlock, !plan.steps.contains(.keep(currentBlock.path)) {
            self.currentBlock = nil
        }
        applyReviewMarks()
    }

    private func clearStack() {
        diffColumns.removeAll()
        diffBodies.removeAll()
        // Every body goes, so attached comments wait for the next one.
        for index in comments.indices {
            if case .attached = comments[index].anchor {
                comments[index].anchor = .pending
            }
        }
        commentIcons.values.forEach { $0.removeFromSuperview() }
        commentIcons.removeAll()
        currentFile = nil
        currentBlock = nil
        blockMark.removeFromSuperview()
        sectionViews.removeAll()
        displayedSections = nil
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    // MARK: - Scroll anchoring

    // Positions below are distances from the top of the document, whichever
    // way the document view is flipped.

    private var visibleTop: CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        let clip = scrollView.contentView.bounds
        return documentView.isFlipped ? clip.minY : documentView.bounds.height - clip.maxY
    }

    private func sectionGeometry() -> [ChangesScrollAnchor.Section] {
        guard let documentView = scrollView.documentView, let displayedSections else { return [] }
        let height = documentView.bounds.height
        return displayedSections.compactMap { section in
            guard let sectionView = sectionViews[section.relativePath] else { return nil }
            let frame = sectionView.convert(sectionView.bounds, to: documentView)
            return ChangesScrollAnchor.Section(
                path: section.relativePath,
                top: documentView.isFlipped ? frame.minY : height - frame.maxY
            )
        }
    }

    private func captureScrollAnchor() -> ChangesScrollAnchor? {
        ChangesScrollAnchor.capture(visibleTop: visibleTop, sections: sectionGeometry())
    }

    /// Diff heights are seeded from line counts and corrected in viewDidLayout,
    /// which itself changes constraints. Two passes let the corrected heights
    /// land before the anchor is measured against them.
    private func settleLayout() {
        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    private func scroll(toVisibleTop top: CGFloat) {
        guard let documentView = scrollView.documentView else { return }
        let documentHeight = documentView.bounds.height
        let clipHeight = scrollView.contentView.bounds.height
        guard documentHeight > clipHeight else { return }
        let clamped = min(max(0, top), documentHeight - clipHeight)
        let y = documentView.isFlipped ? clamped : documentHeight - clamped - clipHeight
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Now that each diff text view has its real width, size its height to the
        // wrapped layout so long/minified lines aren't clipped. The threshold
        // makes this converge: once heights match the content, no constraint
        // changes, so the layout pass this triggers is a no-op.
        for column in diffColumns {
            guard let layoutManager = column.textView.layoutManager,
                  let container = column.textView.textContainer else { continue }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let target = ceil(used + column.textView.textContainerInset.height * 2)
            if abs(column.heightConstraint.constant - target) > 0.5 {
                column.heightConstraint.constant = target
            }
        }
        // Re-wrapping moves the block's lines, so the mark and the comment
        // icons follow them.
        positionBlockMark()
        positionCommentIcons()
    }

    private func makeSectionView(_ section: ChangeSection) -> ChangeSectionView {
        let path = section.relativePath
        let header: ChangeSectionHeaderView
        let makeBody: () -> NSView

        if section.isConflicted {
            header = makeHeaderView(section, counts: nil)
            makeBody = { [weak self] in self?.makeConflictBody(section) ?? NSView() }
        } else if let preview = makeImagePreview(for: section) {
            // An image can't be shown as a text diff: git reports it as binary
            // and the section body would just read "(binary)". When the
            // working-tree file decodes as an image, show the picture itself.
            header = makeHeaderView(section, counts: nil)
            makeBody = {
                preview.view.heightAnchor.constraint(equalToConstant: preview.height).isActive = true
                return preview.view
            }
        } else {
            header = makeHeaderView(section, counts: InlineDiffRenderer.changeCounts(section.diff))
            makeBody = { [weak self] in self?.makeDiffBody(section) ?? NSView() }
        }

        let sectionView = ChangeSectionView(header: header, headerHeight: Metrics.headerHeight, makeBody: makeBody)
        sectionView.wantsLayer = true
        sectionView.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        sectionView.identifier = NSUserInterfaceItemIdentifier(section.absolutePath(repositoryPath: repositoryPath))
        header.onToggle = { [weak self] in
            self?.headerClicked(path)
        }
        header.onViewedChange = { [weak self] viewed in
            self?.changeState(of: path) { $0.setViewed(viewed, for: path) }
        }
        applyState(to: sectionView, path: path)
        return sectionView
    }

    /// The text diff under a header. Built only when the section is first
    /// expanded, so a collapsed lockfile never renders.
    private func makeDiffBody(_ section: ChangeSection) -> NSView {
        let renderedDiff = InlineDiffRenderer.render(section.diff, fileExtension: (section.relativePath as NSString).pathExtension.lowercased())
        let diffView = makeDiffColumn(text: renderedDiff)
        let path = section.relativePath
        (diffView as? ChangesDiffTextView)?.onMouseDown = { [weak self] event in
            self?.handleGutterClick(event, path: path) ?? false
        }

        // Size the diff to its full content height and let the outer scroll
        // view handle scrolling. Capping the height here would clip long diffs,
        // since each text view has no scroller of its own. This is only a seed:
        // it ignores soft-wrapping, so viewDidLayout corrects it to the real
        // laid-out height once the width is known.
        let lineCount = max(1, renderedDiff.string.filter { $0 == "\n" }.count + 1)
        let diffHeight = CGFloat(lineCount) * Metrics.diffLineHeight + 14
        let diffHeightConstraint = diffView.heightAnchor.constraint(equalToConstant: diffHeight)
        diffHeightConstraint.isActive = true

        diffColumns.append(DiffColumn(textView: diffView, heightConstraint: diffHeightConstraint))
        let rows = ChangesComments.rows(in: renderedDiff)
        diffBodies[path] = DiffBody(textView: diffView, blocks: ChangesReview.blockRanges(in: renderedDiff), rows: rows)
        for index in comments.indices where comments[index].path == path && comments[index].anchor == .pending {
            reanchor(&comments[index], rows: rows)
        }
        return diffView
    }

    private func updateSectionStates(_ sections: [ChangeSection], contentChanged: Set<String>) {
        sectionStates.update(sections: sections, contentChanged: contentChanged) { section in
            let counts = InlineDiffRenderer.changeCounts(section.diff)
            return counts.added + counts.removed
        }
    }

    private func applyState(to sectionView: ChangeSectionView, path: String) {
        let state = sectionStates.state(for: path)
        sectionView.header.apply(state)
        sectionView.setCollapsed(state.isCollapsed)
    }

    /// Applies a user's collapse or Viewed change, keeping the clicked header
    /// where it sits on screen while the content below it moves.
    private func changeState(of path: String, _ change: (inout ChangesSectionStates) -> Void) {
        guard let sectionView = sectionViews[path] else { return }
        let headerOffset = sectionGeometry().first { $0.path == path }.map { $0.top - visibleTop }
        change(&sectionStates)
        applyState(to: sectionView, path: path)
        if sectionStates.state(for: path).isCollapsed, currentBlock?.path == path {
            currentBlock = nil
            applyReviewMarks()
        }
        guard let headerOffset else { return }
        settleLayout()
        if let top = sectionGeometry().first(where: { $0.path == path })?.top {
            scroll(toVisibleTop: top - headerOffset)
        }
    }

    /// `counts` (added, removed) shows on the right; nil omits it (image
    /// previews and conflicted files).
    private func makeHeaderView(_ section: ChangeSection, counts: (added: Int, removed: Int)?) -> ChangeSectionHeaderView {
        let chevron = NSButton(image: NSImage(), target: nil, action: nil)
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.contentTintColor = AppTheme.mutedText
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.refusesFirstResponder = true
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: section.status.rawValue)
        status.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        status.textColor = section.status.color
        status.translatesAutoresizingMaskIntoConstraints = false

        let directory = (section.relativePath as NSString).deletingLastPathComponent
        let path = NSTextField(labelWithString: directory.isEmpty ? "" : directory + "/")
        path.font = NSFont.systemFont(ofSize: 12)
        path.textColor = DiffColors.context
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentHuggingPriority(.required, for: .horizontal)
        path.translatesAutoresizingMaskIntoConstraints = false

        let fileName = NSTextField(labelWithString: (section.relativePath as NSString).lastPathComponent)
        fileName.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        fileName.textColor = AppTheme.primaryText
        fileName.lineBreakMode = .byTruncatingMiddle
        fileName.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        fileName.setContentHuggingPriority(.required, for: .horizontal)
        fileName.translatesAutoresizingMaskIntoConstraints = false

        // Conflicted files are resolved, not reviewed, so they get no checkbox.
        var viewedBox: NSButton?
        if !section.isConflicted {
            let box = NSButton(checkboxWithTitle: "Viewed", target: nil, action: nil)
            box.controlSize = .small
            box.toolTip = "Mark as viewed (v)"
            // A click must not leave Space or a letter aimed at the checkbox.
            box.refusesFirstResponder = true
            box.attributedTitle = NSAttributedString(string: "Viewed", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: AppTheme.mutedText
            ])
            box.setContentCompressionResistancePriority(.required, for: .horizontal)
            box.translatesAutoresizingMaskIntoConstraints = false
            viewedBox = box
        }

        let header = ChangeSectionHeaderView(chevron: chevron, fileName: fileName, viewedBox: viewedBox)
        header.wantsLayer = true
        header.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let countsLabel = NSTextField(labelWithString: "")
        if let counts {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let text = NSMutableAttributedString(string: "+\(counts.added)", attributes: [
                .font: font, .foregroundColor: AppTheme.success
            ])
            text.append(NSAttributedString(string: "  -\(counts.removed)", attributes: [
                .font: font, .foregroundColor: AppTheme.error
            ]))
            countsLabel.attributedStringValue = text
        }
        countsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countsLabel.translatesAutoresizingMaskIntoConstraints = false

        let openImage = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open File") ?? NSImage()
        let openButton = NSButton(image: openImage, target: self, action: #selector(openFileClicked(_:)))
        openButton.isBordered = false
        openButton.contentTintColor = AppTheme.mutedText
        openButton.toolTip = "Open File (o)"
        openButton.refusesFirstResponder = true
        openButton.setAccessibilityLabel("Open File")
        openButton.identifier = NSUserInterfaceItemIdentifier(section.absolutePath(repositoryPath: repositoryPath))
        openButton.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(chevron)
        header.addSubview(status)
        header.addSubview(path)
        header.addSubview(fileName)
        header.addSubview(countsLabel)
        header.addSubview(openButton)

        if let viewedBox {
            header.addSubview(viewedBox)
            NSLayoutConstraint.activate([
                viewedBox.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                viewedBox.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -10),
                countsLabel.trailingAnchor.constraint(equalTo: viewedBox.leadingAnchor, constant: -12)
            ])
        } else {
            countsLabel.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -10).isActive = true
        }

        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14),

            status.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            status.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            path.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 8),
            path.firstBaselineAnchor.constraint(equalTo: fileName.firstBaselineAnchor),

            fileName.leadingAnchor.constraint(equalTo: path.trailingAnchor),
            fileName.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            fileName.trailingAnchor.constraint(lessThanOrEqualTo: countsLabel.leadingAnchor, constant: -12),

            countsLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            openButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            openButton.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        return header
    }

    /// Extensions AppKit's image loaders (ImageIO) decode from disk. SVG is
    /// included, but NSImage rasterizes it inconsistently, so the decode guard
    /// below falls back to the readable XML text diff whenever the draw fails.
    nonisolated static let previewableImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
        "tiff", "tif", "bmp", "ico", "icns", "svg"
    ]

    /// Renders the working-tree image for `section` when the file is one AppKit
    /// can decode, capped to a sensible height. Returns nil for non-images or a
    /// file that won't load, so the caller falls back to the text diff. The
    /// working copy is shown (the new or modified bytes), which is the version
    /// worth eyeballing before a commit.
    private func makeImagePreview(for section: ChangeSection) -> (view: NSView, height: CGFloat)? {
        let ext = (section.relativePath as NSString).pathExtension.lowercased()
        guard Self.previewableImageExtensions.contains(ext) else { return nil }

        let path = section.absolutePath(repositoryPath: repositoryPath)
        guard FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path),
              image.size.width > 0, image.size.height > 0 else { return nil }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: imageCaption(path: path, image: image, ext: ext))
        caption.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        caption.textColor = DiffColors.context
        caption.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(caption)

        // Cap the picture's height; a tall image scales down proportionally
        // rather than stretching the section past the panel.
        let maxImageHeight: CGFloat = 360
        let imageHeight = min(image.size.height, maxImageHeight)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            imageView.heightAnchor.constraint(equalToConstant: imageHeight),

            caption.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12)
        ])

        // header content inset (10 top) + image + caption gap/line + bottom pad.
        let totalHeight = 10 + imageHeight + 8 + 16 + 10
        return (container, totalHeight)
    }

    /// A one-line summary under the picture: type, pixel size, on-disk bytes.
    private func imageCaption(path: String, image: NSImage, ext: String) -> String {
        var parts = [ext.uppercased()]

        let pixels = image.representations
            .map { (width: $0.pixelsWide, height: $0.pixelsHigh) }
            .first { $0.width > 0 && $0.height > 0 }
        if let pixels {
            parts.append("\(pixels.width)×\(pixels.height)")
        } else {
            parts.append("\(Int(image.size.width))×\(Int(image.size.height))")
        }

        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func makeDiffColumn(text: NSAttributedString) -> NSTextView {
        // Build a manual TextKit 1 stack so the custom layout manager (which
        // paints full-width line backgrounds, incl. empty deleted lines) is
        // used instead of NSTextView's default TextKit 2 layout.
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true

        let layoutManager = DiffLineBackgroundLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = ChangesDiffTextView(frame: .zero, textContainer: textContainer)
        textView.onKeyDown = { [weak self] event in self?.handleReviewKey(event) ?? false }
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = DiffColors.background
        textView.textColor = DiffColors.text
        textView.textContainerInset = NSSize(width: 12, height: 7)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textStorage?.setAttributedString(text)
        return textView
    }

    @objc private func openFileClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onOpenFile?(path)
    }

    // MARK: - Conflict resolution

    private enum ConflictColors {
        static var currentBG: NSColor { AppTheme.success.withAlphaComponent(0.16) }
        static var currentHeaderBG: NSColor { AppTheme.success.withAlphaComponent(0.30) }
        static var incomingBG: NSColor { AppTheme.accent.withAlphaComponent(0.16) }
        static var incomingHeaderBG: NSColor { AppTheme.accent.withAlphaComponent(0.30) }
        static var separatorBG: NSColor { AppTheme.mutedText.withAlphaComponent(0.22) }
        static var context: NSColor { AppTheme.mutedText }
        static var text: NSColor { AppTheme.primaryText }
        static var current: NSColor { AppTheme.success }
        static var incoming: NSColor { AppTheme.accent }
    }

    /// Builds the section for a conflicted file: one block per conflict with
    /// Use current / incoming / both buttons, plus a "stage to continue" prompt
    /// once all markers are gone. Resolution rewrites the file on disk; the file
    /// is never opened in the editor, so a marker-laden file is never surfaced.
    private func makeConflictBody(_ section: ChangeSection) -> NSView {
        let absolutePath = section.absolutePath(repositoryPath: repositoryPath)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        // A nil read (missing / too large / not UTF-8) is NOT the same as an
        // empty string: the old `?? ""` made an unreadable file parse to zero
        // conflicts and show a false "All conflicts resolved" prompt. Surface it.
        guard let content = readConflictFileForDisplay(absolutePath) else {
            stack.addArrangedSubview(makeInfoRow(
                "Can’t display conflicts — file is too large or not UTF-8 text. Resolve it in your editor."
            ))
            layoutConflictBody(container: container, stack: stack)
            return container
        }
        let conflicts = MergeConflictParser.conflicts(in: content)

        if conflicts.isEmpty {
            stack.addArrangedSubview(makeResolvedPrompt(relativePath: section.relativePath))
        } else {
            let ns = content as NSString
            for (index, conflict) in conflicts.enumerated() {
                stack.addArrangedSubview(makeConflictBlock(
                    absolutePath: absolutePath,
                    index: index,
                    total: conflicts.count,
                    conflict: conflict,
                    content: ns
                ))
            }
        }

        layoutConflictBody(container: container, stack: stack)
        return container
    }

    private func layoutConflictBody(container: NSView, stack: NSView) {
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
    }

    /// Reads a conflicted file for display, bounded so a huge or non-UTF-8 file
    /// can neither stall the main thread nor be silently misread as an empty
    /// (→ "no conflicts") string. Returns nil when missing, oversized, or not
    /// valid UTF-8 — the caller shows an explanatory row instead.
    private func readConflictFileForDisplay(_ path: String) -> String? {
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
           size > Limits.maxFileSize {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func makeInfoRow(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = AppTheme.warning
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeConflictBlock(
        absolutePath: String,
        index: Int,
        total: Int,
        conflict: MergeConflict,
        content: NSString
    ) -> NSView {
        let block = NSView()
        block.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let counter = NSTextField(labelWithString: total > 1 ? "Conflict \(index + 1)/\(total)" : "Conflict")
        counter.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        counter.textColor = AppTheme.warning
        buttonRow.addArrangedSubview(counter)

        let currentTitle = conflict.currentLabel.isEmpty ? "Current" : conflict.currentLabel
        let incomingTitle = conflict.incomingLabel.isEmpty ? "Incoming" : conflict.incomingLabel
        buttonRow.addArrangedSubview(makeResolveButton("Use \(currentTitle)", absolutePath: absolutePath, index: index, choice: .current))
        buttonRow.addArrangedSubview(makeResolveButton("Use \(incomingTitle)", absolutePath: absolutePath, index: index, choice: .incoming))
        buttonRow.addArrangedSubview(makeResolveButton("Use Both", absolutePath: absolutePath, index: index, choice: .both))

        let (text, lineCount) = conflictAttributedText(content: content, conflict: conflict)
        let textView = makeDiffColumn(text: text)
        // Seed from the logical line count; viewDidLayout corrects it to the
        // real wrapped height once the width is known, same as diff sections.
        let textHeight = CGFloat(max(1, lineCount)) * Metrics.diffLineHeight + 14
        let textHeightConstraint = textView.heightAnchor.constraint(equalToConstant: textHeight)

        block.addSubview(buttonRow)
        block.addSubview(textView)

        NSLayoutConstraint.activate([
            buttonRow.topAnchor.constraint(equalTo: block.topAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: block.trailingAnchor),
            buttonRow.heightAnchor.constraint(equalToConstant: 22),

            textView.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 6),
            textView.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: block.bottomAnchor),
            textHeightConstraint
        ])

        diffColumns.append(DiffColumn(textView: textView, heightConstraint: textHeightConstraint))

        return block
    }

    private func makeResolveButton(_ title: String, absolutePath: String, index: Int, choice: MergeConflictResolution) -> NSButton {
        let button = ConflictResolveButton(title: title, target: self, action: #selector(resolveClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.filePath = absolutePath
        button.conflictIndex = index
        button.resolution = choice
        return button
    }

    private func makeResolvedPrompt(relativePath: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "✓ All conflicts resolved")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = ConflictColors.current
        row.addArrangedSubview(label)

        let stage = ConflictResolveButton(title: "Stage (mark resolved)", target: self, action: #selector(stageResolvedClicked(_:)))
        stage.bezelStyle = .rounded
        stage.controlSize = .small
        stage.filePath = relativePath
        row.addArrangedSubview(stage)

        return row
    }

    /// One conflict rendered as colored segments with a few lines of context.
    private func conflictAttributedText(content: NSString, conflict: MergeConflict, contextLines: Int = 3) -> (NSAttributedString, Int) {
        let result = NSMutableAttributedString()
        var lineCount = 0

        func append(_ line: String, bg: NSColor?, fg: NSColor) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: InlineDiffRenderer.font,
                .foregroundColor: fg
            ]
            if let bg { attributes[.backgroundColor] = bg }
            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
            lineCount += 1
        }

        func lines(_ range: NSRange) -> [String] {
            guard range.length > 0 else { return [] }
            var out = content.substring(with: range).components(separatedBy: "\n")
            if out.last == "" { out.removeLast() }
            return out
        }

        // Context preceding the conflict.
        let before = NSRange(location: 0, length: conflict.fullRange.location)
        for line in lines(before).suffix(contextLines) {
            append(line, bg: nil, fg: ConflictColors.context)
        }

        append(content.substring(with: conflict.openingMarkerLineRange), bg: ConflictColors.currentHeaderBG, fg: ConflictColors.current)
        for line in lines(conflict.currentRange) { append(line, bg: ConflictColors.currentBG, fg: ConflictColors.text) }
        append(content.substring(with: conflict.separatorMarkerLineRange), bg: ConflictColors.separatorBG, fg: ConflictColors.context)
        for line in lines(conflict.incomingRange) { append(line, bg: ConflictColors.incomingBG, fg: ConflictColors.text) }
        append(content.substring(with: conflict.closingMarkerLineRange), bg: ConflictColors.incomingHeaderBG, fg: ConflictColors.incoming)

        // Context following the conflict.
        let afterStart = NSMaxRange(conflict.fullRange)
        let after = NSRange(location: afterStart, length: content.length - afterStart)
        for line in lines(after).prefix(contextLines) {
            append(line, bg: nil, fg: ConflictColors.context)
        }

        return (result, lineCount)
    }

    @objc private func resolveClicked(_ sender: ConflictResolveButton) {
        guard let resolution = sender.resolution else { return }
        let filePath = sender.filePath
        guard let content = readConflictFileForDisplay(filePath) else {
            showMessage("Couldn’t read \(filePath) — file is too large or not UTF-8 text.")
            return
        }

        // Re-parse at click time so the right block is hit even if the file
        // changed since the view was built.
        let conflicts = MergeConflictParser.conflicts(in: content)
        guard sender.conflictIndex < conflicts.count else { loadChanges(); return }
        let conflict = conflicts[sender.conflictIndex]
        let replacement = MergeConflictParser.resolvedText(for: conflict, in: content, choice: resolution)
        let resolved = (content as NSString).replacingCharacters(in: conflict.fullRange, with: replacement)

        do {
            try resolved.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            showMessage("Failed to write \(filePath): \(error.localizedDescription)")
            return
        }
        loadChanges()
    }

    @objc private func stageResolvedClicked(_ sender: ConflictResolveButton) {
        let relativePath = sender.filePath
        DispatchQueue.global(qos: .userInitiated).async { [repositoryPath, gitService] in
            _ = try? gitService.stage(path: relativePath, repositoryRoot: repositoryPath)
            DispatchQueue.main.async { [weak self] in
                self?.loadChanges()
            }
        }
    }

    // MARK: - Keyboard review

    /// Takes the pane's single-key review keys; anything else passes on.
    private func handleReviewKey(_ event: NSEvent) -> Bool {
        if ChangesComments.isSendKey(characters: event.charactersIgnoringModifiers, modifierFlags: event.modifierFlags, hasComments: !comments.isEmpty) {
            performPrimaryReviewAction()
            return true
        }
        guard let key = ChangesReview.Key(characters: event.charactersIgnoringModifiers, modifierFlags: event.modifierFlags) else { return false }
        if key == .comment {
            beginKeyboardComment()
            return true
        }
        perform(key)
        return true
    }

    /// Scrolling keys while the pane's root view has focus; a focused diff
    /// text view keeps its own handling of them.
    private func handleScrollKey(_ event: NSEvent) -> Bool {
        guard let documentView = scrollView.documentView,
              let top = ChangesReview.scrollTop(
                characters: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags,
                visibleTop: visibleTop,
                viewportHeight: scrollView.contentView.bounds.height,
                documentHeight: documentView.bounds.height,
                lineHeight: Metrics.diffLineHeight
              ) else { return false }
        scroll(toVisibleTop: top)
        return true
    }

    private func perform(_ key: ChangesReview.Key) {
        guard let displayedSections, !displayedSections.isEmpty else { return }
        view.layoutSubtreeIfNeeded()
        let viewport = currentViewport()

        switch key {
        case .nextFile, .previousFile:
            let files = fileSpans()
            guard let target = ChangesReview.movedFile(currentFile, forward: key == .nextFile, files: files, viewport: viewport),
                  let span = files.first(where: { $0.path == target }) else { return }
            setCurrentFile(target)
            scroll(toVisibleTop: span.top)

        case .nextBlock, .previousBlock:
            guard let block = ChangesReview.movedBlock(currentBlock, forward: key == .nextBlock, blocks: blockSpans(), viewport: viewport) else { return }
            currentBlock = ChangesReview.BlockID(path: block.path, index: block.index)
            currentFile = block.path
            applyReviewMarks()
            scroll(toVisibleTop: block.top - scrollView.contentView.bounds.height / 4)

        case .toggleViewed, .toggleCollapsed, .stage, .open:
            guard let path = ChangesReview.rebasedFile(currentFile, files: fileSpans(), viewport: viewport),
                  let section = displayedSections.first(where: { $0.relativePath == path }) else { return }
            setCurrentFile(path)
            act(key, on: section)

        case .comment:
            break
        }
    }

    private func act(_ key: ChangesReview.Key, on section: ChangeSection) {
        let path = section.relativePath
        switch key {
        case .toggleViewed:
            guard !section.isConflicted else { return }
            let viewed = !sectionStates.state(for: path).isViewed
            changeState(of: path) { $0.setViewed(viewed, for: path) }
            guard viewed else { return }
            // Pressing v again walks on to the next file still to review.
            let paths = displayedSections?.map(\.relativePath) ?? []
            let conflicted = Set(displayedSections?.filter(\.isConflicted).map(\.relativePath) ?? [])
            guard let next = ChangesReview.nextUnviewed(after: path, paths: paths, isViewed: {
                conflicted.contains($0) || self.sectionStates.state(for: $0).isViewed
            }) else { return }
            setCurrentFile(next)
            if let span = fileSpans().first(where: { $0.path == next }), !currentViewport().shows(top: span.top, bottom: span.bottom) {
                scroll(toVisibleTop: span.top)
            }
        case .toggleCollapsed:
            changeState(of: path) { $0.toggleCollapsed(path) }
        case .stage:
            guard let action = ChangesReview.stageAction(for: section, source: source) else { return }
            DispatchQueue.global(qos: .userInitiated).async { [repositoryPath, gitService] in
                let succeeded: Bool
                switch action {
                case .stage: succeeded = (try? gitService.stage(path: path, repositoryRoot: repositoryPath)) ?? false
                case .unstage: succeeded = (try? gitService.unstage(path: path, repositoryRoot: repositoryPath)) ?? false
                }
                guard succeeded else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.loadChanges()
                }
            }
        case .open:
            onOpenFile?(section.absolutePath(repositoryPath: repositoryPath))
        case .nextFile, .previousFile, .nextBlock, .previousBlock, .comment:
            break
        }
    }

    /// A header or chevron click toggles the section and makes it current,
    /// taking keyboard focus into the pane if it is elsewhere.
    private func headerClicked(_ path: String) {
        if let window = view.window,
           !((window.firstResponder as? NSView)?.isDescendant(of: view) ?? false) {
            window.makeFirstResponder(view)
        }
        setCurrentFile(path)
        changeState(of: path) { $0.toggleCollapsed(path) }
    }

    private func setCurrentFile(_ path: String) {
        if currentBlock?.path != path {
            currentBlock = nil
        }
        currentFile = path
        applyReviewMarks()
    }

    /// Shows the current file's header bar and the current block's mark.
    private func applyReviewMarks() {
        for (path, sectionView) in sectionViews {
            sectionView.header.setCurrent(path == currentFile)
        }
        positionBlockMark()
        positionCommentIcons()
    }

    private func positionBlockMark() {
        guard let currentBlock,
              !sectionStates.state(for: currentBlock.path).isCollapsed,
              let body = diffBodies[currentBlock.path],
              body.blocks.indices.contains(currentBlock.index),
              let rect = blockRect(body.blocks[currentBlock.index], in: body.textView) else {
            blockMark.removeFromSuperview()
            return
        }
        if blockMark.superview !== body.textView {
            body.textView.addSubview(blockMark)
        }
        blockMark.layer?.backgroundColor = AppTheme.accent.cgColor
        blockMark.frame = NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height)
    }

    /// The laid-out rect of a block's lines, in the text view's coordinates.
    private func blockRect(_ range: NSRange, in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        layoutManager.ensureLayout(forGlyphRange: glyphs)
        var rect = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
            rect = rect.union(fragment)
        }
        guard !rect.isNull else { return nil }
        let origin = textView.textContainerOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    private func currentViewport() -> ChangesReview.Viewport {
        ChangesReview.Viewport(top: visibleTop, bottom: visibleTop + scrollView.contentView.bounds.height)
    }

    /// `rect` in `view`, as distances from the top of the document.
    private func documentSpan(_ rect: NSRect, in view: NSView) -> (top: CGFloat, bottom: CGFloat)? {
        guard let documentView = scrollView.documentView else { return nil }
        let frame = view.convert(rect, to: documentView)
        if documentView.isFlipped {
            return (frame.minY, frame.maxY)
        }
        let height = documentView.bounds.height
        return (height - frame.maxY, height - frame.minY)
    }

    private func fileSpans() -> [ChangesReview.FileSpan] {
        (displayedSections ?? []).compactMap { section in
            guard let sectionView = sectionViews[section.relativePath],
                  let span = documentSpan(sectionView.bounds, in: sectionView) else { return nil }
            return ChangesReview.FileSpan(path: section.relativePath, top: span.top, bottom: span.bottom)
        }
    }

    /// Every block of every expanded, built text diff, in display order.
    private func blockSpans() -> [ChangesReview.BlockSpan] {
        (displayedSections ?? []).flatMap { section -> [ChangesReview.BlockSpan] in
            let path = section.relativePath
            guard !sectionStates.state(for: path).isCollapsed, let body = diffBodies[path] else { return [] }
            return body.blocks.enumerated().compactMap { index, range in
                guard let rect = blockRect(range, in: body.textView),
                      let span = documentSpan(rect, in: body.textView) else { return nil }
                return ChangesReview.BlockSpan(path: path, index: index, top: span.top, bottom: span.bottom)
            }
        }
    }

    // MARK: - Review comments

    /// `c`: a comment on the selected diff lines, else on the current block.
    private func beginKeyboardComment() {
        if let textView = view.window?.firstResponder as? NSTextView,
           let (path, body) = diffBodies.first(where: { $0.value.textView === textView }).map({ ($0.key, $0.value) }),
           let rows = ChangesComments.rowRange(touching: textView.selectedRange(), rows: body.rows) {
            openNewComment(path: path, rows: rows)
            return
        }
        guard let currentBlock,
              !sectionStates.state(for: currentBlock.path).isCollapsed,
              let body = diffBodies[currentBlock.path],
              body.blocks.indices.contains(currentBlock.index),
              let rows = ChangesComments.rowRange(touching: body.blocks[currentBlock.index], rows: body.rows) else { return }
        openNewComment(path: currentBlock.path, rows: rows)
    }

    /// A plain click in a diff line's gutter (line number and marker area)
    /// starts a comment on that line. A click in the code passes on.
    private func handleGutterClick(_ event: NSEvent, path: String) -> Bool {
        guard event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
              let body = diffBodies[path],
              let layoutManager = body.textView.layoutManager,
              let container = body.textView.textContainer else { return false }
        let textView = body.textView
        let point = textView.convert(event.locationInWindow, from: nil)
        let origin = textView.textContainerOrigin
        let gutterRight = origin.x + container.lineFragmentPadding
            + DiffLineBackgroundLayoutManager.gutterMetrics(for: InlineDiffRenderer.font).width
        guard point.x < gutterRight, layoutManager.numberOfGlyphs > 0 else { return false }
        let containerPoint = NSPoint(x: max(0, point.x - origin.x), y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: container)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard containerPoint.y >= fragment.minY, containerPoint.y < fragment.maxY,
              let row = ChangesComments.row(atCharacter: layoutManager.characterIndexForGlyph(at: glyph), rows: body.rows) else { return false }
        openNewComment(path: path, rows: row..<(row + 1))
        return true
    }

    private func openNewComment(path: String, rows: Range<Int>) {
        guard let body = diffBodies[path] else { return }
        let lines = ChangesComments.lines(in: rows, rows: body.rows)
        let location = ChangesComments.location(of: rows, rows: body.rows)
        let textView = body.textView
        showCommentEditor(text: "", canDelete: false, path: path, rows: rows, onSave: { [weak self] text in
            guard let self else { return }
            var comment = ChangesComments.Comment(
                id: UUID(), path: path, text: text, lines: lines, location: location, anchor: .attached(rows)
            )
            // A refresh may have rebuilt the section while the popover was open.
            if self.diffBodies[path]?.textView !== textView {
                if let newBody = self.diffBodies[path] {
                    self.reanchor(&comment, rows: newBody.rows)
                } else {
                    let listed = self.displayedSections?.contains { $0.relativePath == path } ?? false
                    comment.anchor = listed ? .pending : .detached
                }
            }
            self.comments.append(comment)
            self.commentsChanged()
        }, onDelete: nil)
    }

    private func openExistingComment(_ id: UUID) {
        guard let comment = comments.first(where: { $0.id == id }),
              case .attached(let rows) = comment.anchor else { return }
        showCommentEditor(text: comment.text, canDelete: true, path: comment.path, rows: rows, onSave: { [weak self] text in
            guard let self, let index = self.comments.firstIndex(where: { $0.id == id }) else { return }
            self.comments[index].text = text
            self.commentsChanged()
        }, onDelete: { [weak self] in
            self?.comments.removeAll { $0.id == id }
            self?.commentsChanged()
        })
    }

    private func showCommentEditor(
        text: String,
        canDelete: Bool,
        path: String,
        rows: Range<Int>,
        onSave: @escaping (String) -> Void,
        onDelete: (() -> Void)?
    ) {
        guard let body = diffBodies[path], body.rows.indices.contains(rows.lowerBound), rows.upperBound <= body.rows.count else { return }
        commentPopover?.close()

        let first = body.rows[rows.lowerBound].range
        let characters = NSUnionRange(first, body.rows[rows.upperBound - 1].range)
        // Anchor below the part of the lines on screen, so the popover sits
        // next to the code it is about.
        guard let linesRect = blockRect(characters, in: body.textView) else { return }
        var anchorRect = linesRect.intersection(body.textView.visibleRect)
        if anchorRect.isEmpty {
            anchorRect = blockRect(first, in: body.textView) ?? linesRect
        }

        let editor = ChangesCommentEditor(text: text, canDelete: canDelete)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        editor.onCancel = { [weak popover] in popover?.close() }
        editor.onSave = { [weak popover] text in
            popover?.close()
            onSave(text)
        }
        if let onDelete {
            editor.onDelete = { [weak popover] in
                popover?.close()
                onDelete()
            }
        }
        commentPopover = popover
        popover.show(relativeTo: anchorRect, of: body.textView, preferredEdge: .maxY)
    }

    /// Moves a comment to the one place its quoted lines appear in `rows`,
    /// or detaches it.
    private func reanchor(_ comment: inout ChangesComments.Comment, rows: [ChangesComments.Row]) {
        if let range = ChangesComments.reanchor(comment.lines, in: rows) {
            comment.anchor = .attached(range)
            comment.location = ChangesComments.location(of: range, rows: rows)
        } else {
            comment.anchor = .detached
        }
    }

    private func commentsChanged() {
        positionCommentIcons()
        updateReviewBar()
    }

    /// One icon per commented first line, in the gutter's left margin so
    /// the line number stays readable. Collapsed sections show none.
    private func positionCommentIcons() {
        var groups: [String: (path: String, row: Int, ids: [UUID])] = [:]
        for comment in comments {
            guard case .attached(let rows) = comment.anchor,
                  !sectionStates.state(for: comment.path).isCollapsed,
                  diffBodies[comment.path] != nil else { continue }
            let key = "\(comment.path)\u{0}\(rows.lowerBound)"
            groups[key, default: (comment.path, rows.lowerBound, [])].ids.append(comment.id)
        }
        for key in commentIcons.keys where groups[key] == nil {
            commentIcons.removeValue(forKey: key)?.removeFromSuperview()
        }
        for (key, group) in groups {
            guard let body = diffBodies[group.path],
                  body.rows.indices.contains(group.row),
                  let line = firstLineRect(of: body.rows[group.row].range, in: body.textView) else {
                commentIcons.removeValue(forKey: key)?.removeFromSuperview()
                continue
            }
            let icon = commentIcons[key] ?? makeCommentIcon()
            if icon.superview !== body.textView {
                body.textView.addSubview(icon)
            }
            icon.commentIDs = group.ids
            icon.contentTintColor = AppTheme.accent
            icon.toolTip = group.ids.count == 1 ? "Edit comment" : "\(group.ids.count) comments"
            let size = Metrics.commentIconSize
            icon.frame = NSRect(x: max(0, line.minX - size), y: line.midY - size / 2, width: size, height: size)
            commentIcons[key] = icon
        }
    }

    private func makeCommentIcon() -> ChangesCommentIcon {
        let image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Comment") ?? NSImage()
        let icon = ChangesCommentIcon(image: image, target: self, action: #selector(commentIconClicked(_:)))
        icon.isBordered = false
        icon.imagePosition = .imageOnly
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        icon.refusesFirstResponder = true
        icon.setAccessibilityLabel("Comment")
        return icon
    }

    /// The first laid-out line of a character range, in the text view's
    /// coordinates.
    private func firstLineRect(of range: NSRange, in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager, range.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        layoutManager.ensureLayout(forGlyphRange: glyphs)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        guard !rect.isEmpty else { return nil }
        let origin = textView.textContainerOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    @objc private func commentIconClicked(_ sender: ChangesCommentIcon) {
        if sender.commentIDs.count == 1 {
            openExistingComment(sender.commentIDs[0])
            return
        }
        let menu = NSMenu()
        for id in sender.commentIDs {
            guard let comment = comments.first(where: { $0.id == id }) else { continue }
            let firstLine = comment.text.components(separatedBy: "\n").first ?? ""
            let title = firstLine.count > 50 ? String(firstLine.prefix(50)) + "..." : firstLine
            let item = NSMenuItem(title: title, action: #selector(commentMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func commentMenuItemChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openExistingComment(id)
    }

    // MARK: - Review bar

    private func setupReviewBar() {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = AppTheme.divider.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let count = NSTextField(labelWithString: "")
        count.font = NSFont.systemFont(ofSize: 12)
        count.textColor = AppTheme.secondaryText
        count.lineBreakMode = .byTruncatingTail
        count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.translatesAutoresizingMaskIntoConstraints = false

        let primary = NSButton(title: "", target: self, action: #selector(reviewPrimaryClicked))
        primary.bezelStyle = .rounded
        primary.controlSize = .small
        primary.toolTip = "⌘↩"
        primary.refusesFirstResponder = true
        primary.lineBreakMode = .byTruncatingMiddle
        primary.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        primary.translatesAutoresizingMaskIntoConstraints = false

        let discard = NSButton(title: "Discard", target: self, action: #selector(reviewDiscardClicked))
        discard.bezelStyle = .rounded
        discard.controlSize = .small
        discard.toolTip = "Remove all comments"
        discard.refusesFirstResponder = true
        discard.setContentCompressionResistancePriority(.required, for: .horizontal)
        discard.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(bar)
        bar.addSubview(divider)
        bar.addSubview(count)
        bar.addSubview(primary)
        bar.addSubview(discard)

        let height = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,

            divider.topAnchor.constraint(equalTo: bar.topAnchor),
            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            count.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Metrics.horizontalPadding),
            count.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: primary.leadingAnchor, constant: -10),

            discard.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Metrics.horizontalPadding),
            discard.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            primary.trailingAnchor.constraint(equalTo: discard.leadingAnchor, constant: -8),
            primary.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])

        reviewBar = bar
        reviewBarHeight = height
        reviewCountLabel = count
        reviewPrimaryButton = primary
        reviewDiscardButton = discard
    }

    private func setReviewBarVisible(_ visible: Bool) {
        reviewBar.isHidden = !visible
        reviewBarHeight.constant = visible ? Metrics.reviewBarHeight : 0
    }

    private func currentSendMode() -> ChangesComments.SendMode {
        ChangesComments.SendMode(agents: agentsForRepository?(repositoryPath) ?? [])
    }

    /// Shows the count and the primary button for the agents there are now,
    /// or hides the bar once the comments are gone (unless a confirmation
    /// is still showing).
    private func updateReviewBar() {
        guard !comments.isEmpty else {
            displayedSendMode = nil
            if confirmationTimer == nil {
                setReviewBarVisible(false)
            }
            return
        }
        confirmationTimer?.invalidate()
        confirmationTimer = nil

        let mode = currentSendMode()
        displayedSendMode = mode
        reviewCountLabel.stringValue = ChangesComments.countText(comments.count)
        switch mode {
        case .copy: reviewPrimaryButton.title = "Copy Comments"
        case .send(let agent): reviewPrimaryButton.title = "Send to \(agent.label)"
        case .choose: reviewPrimaryButton.title = "Send to Agent"
        }
        reviewPrimaryButton.isHidden = false
        reviewDiscardButton.isHidden = false
        setReviewBarVisible(true)
    }

    @objc private func reviewPrimaryClicked() {
        performPrimaryReviewAction()
    }

    /// The bar's primary button (and ⌘↩). Agents are asked again; a single
    /// agent or the clipboard is used only if it is what the button showed,
    /// otherwise the bar is brought up to date for the user to press again.
    private func performPrimaryReviewAction() {
        guard !comments.isEmpty else { return }
        let mode = currentSendMode()
        if mode != displayedSendMode {
            updateReviewBar()
        }
        switch mode {
        case .choose(let agents):
            showAgentMenu(agents)
        case .send(let agent):
            guard mode == displayedSendMode else { return }
            deliverComments(to: agent)
        case .copy:
            guard mode == displayedSendMode else { return }
            copyComments()
        }
    }

    private func showAgentMenu(_ agents: [ChangesComments.Agent]) {
        let menu = NSMenu()
        for agent in agents {
            let item = NSMenuItem(title: agent.label, action: #selector(agentMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: reviewPrimaryButton.bounds.height + 4), in: reviewPrimaryButton)
    }

    @objc private func agentMenuItemChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let agent = (agentsForRepository?(repositoryPath) ?? []).first(where: { $0.id == id }) else {
            updateReviewBar()
            return
        }
        deliverComments(to: agent)
    }

    private func deliverComments(to agent: ChangesComments.Agent) {
        let count = comments.count
        guard sendToAgent?(agent.id, ChangesComments.message(for: commentsForSending(), intro: source.commentIntro)) == true else {
            updateReviewBar()
            return
        }
        finishReview(confirmation: "Sent \(ChangesComments.countText(count)) to \(agent.label)")
    }

    private func copyComments() {
        let count = comments.count
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ChangesComments.message(for: commentsForSending(), intro: source.commentIntro), forType: .string)
        finishReview(confirmation: "Copied \(ChangesComments.countText(count))")
    }

    /// Comments as they go out. One waiting on a section body that was never
    /// built is matched against the section's diff now.
    private func commentsForSending() -> [ChangesComments.Comment] {
        comments.map { comment in
            guard comment.anchor == .pending else { return comment }
            var resolved = comment
            guard let section = displayedSections?.first(where: { $0.relativePath == comment.path }) else {
                resolved.anchor = .detached
                return resolved
            }
            let rendered = InlineDiffRenderer.render(section.diff, fileExtension: (section.relativePath as NSString).pathExtension.lowercased())
            reanchor(&resolved, rows: ChangesComments.rows(in: rendered))
            return resolved
        }
    }

    private func finishReview(confirmation: String) {
        comments.removeAll()
        commentPopover?.close()
        positionCommentIcons()
        displayedSendMode = nil
        reviewCountLabel.stringValue = confirmation
        reviewPrimaryButton.isHidden = true
        reviewDiscardButton.isHidden = true
        setReviewBarVisible(true)
        confirmationTimer?.invalidate()
        confirmationTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.confirmationTimer = nil
                if self.comments.isEmpty {
                    self.setReviewBarVisible(false)
                }
            }
        }
    }

    @objc private func reviewDiscardClicked() {
        comments.removeAll()
        commentPopover?.close()
        commentsChanged()
    }

    private func scrollToFocusedFile(_ filePath: String) {
        guard let sectionView = stackView.arrangedSubviews.first(where: { $0.identifier?.rawValue == filePath }),
              let documentView = scrollView.documentView else { return }

        view.layoutSubtreeIfNeeded()

        // Align the section's top edge with the top of the viewport,
        // accounting for the document view's coordinate orientation.
        let sectionFrame = sectionView.convert(sectionView.bounds, to: documentView)
        let clipHeight = scrollView.contentView.bounds.height
        let targetY: CGFloat
        if documentView.isFlipped {
            targetY = max(0, sectionFrame.minY - Metrics.sectionSpacing)
        } else {
            targetY = max(0, sectionFrame.maxY - clipHeight + Metrics.sectionSpacing)
        }

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

}

/// One file's section: a header above a body (diff text, image preview, or
/// conflict blocks). The body is built the first time the section expands
/// and hidden, not rebuilt, when it collapses again.
private final class ChangeSectionView: NSView {
    let header: ChangeSectionHeaderView
    private let makeBody: () -> NSView
    private var body: NSView?
    private var collapsedBottom: NSLayoutConstraint!
    private var expandedBottom: NSLayoutConstraint?

    init(header: ChangeSectionHeaderView, headerHeight: CGFloat, makeBody: @escaping () -> NSView) {
        self.header = header
        self.makeBody = makeBody
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight)
        ])
        collapsedBottom = header.bottomAnchor.constraint(equalTo: bottomAnchor)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCollapsed(_ collapsed: Bool) {
        if collapsed {
            expandedBottom?.isActive = false
            body?.isHidden = true
            collapsedBottom.isActive = true
            return
        }
        let body = self.body ?? buildBody()
        collapsedBottom.isActive = false
        body.isHidden = false
        expandedBottom?.isActive = true
    }

    private func buildBody() -> NSView {
        let body = makeBody()
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        expandedBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor)
        self.body = body
        return body
    }
}

/// A section header. A click anywhere on it that is not one of its buttons
/// toggles the section, the same as the chevron.
private final class ChangeSectionHeaderView: NSView {
    var onToggle: (() -> Void)?
    var onViewedChange: ((Bool) -> Void)?

    private let chevron: NSButton
    private let fileName: NSTextField
    private let viewedBox: NSButton?
    /// Accent bar at the left edge while this is the keyboard review's file.
    private let currentBar = NSView()

    init(chevron: NSButton, fileName: NSTextField, viewedBox: NSButton?) {
        self.chevron = chevron
        self.fileName = fileName
        self.viewedBox = viewedBox
        super.init(frame: .zero)
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        viewedBox?.target = self
        viewedBox?.action = #selector(viewedClicked(_:))

        currentBar.wantsLayer = true
        currentBar.isHidden = true
        currentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(currentBar)
        NSLayoutConstraint.activate([
            currentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            currentBar.topAnchor.constraint(equalTo: topAnchor),
            currentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            currentBar.widthAnchor.constraint(equalToConstant: 3)
        ])
    }

    func setCurrent(_ current: Bool) {
        currentBar.layer?.backgroundColor = AppTheme.accent.cgColor
        currentBar.isHidden = !current
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ state: ChangesSectionStates.State) {
        let label = state.isCollapsed ? "Expand" : "Collapse"
        chevron.image = NSImage(
            systemSymbolName: state.isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: label
        )
        chevron.toolTip = "\(label) (x)"
        viewedBox?.state = state.isViewed ? .on : .off
        fileName.textColor = state.isViewed ? AppTheme.mutedText : AppTheme.primaryText
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    @objc private func chevronClicked() {
        onToggle?()
    }

    @objc private func viewedClicked(_ sender: NSButton) {
        onViewedChange?(sender.state == .on)
    }
}

/// Button carrying the file + conflict it resolves (or the relative path to
/// stage, for the "mark resolved" prompt).
private final class ConflictResolveButton: NSButton {
    var filePath: String = ""
    var conflictIndex: Int = 0
    var resolution: MergeConflictResolution?
}

/// Chrome colors for the changes pane. InlineDiffRenderer colors the diff
/// content itself, so this holds only the surrounding view colors.
enum DiffColors {
    static var background: NSColor { AppTheme.windowBackground }
    static var text: NSColor { AppTheme.primaryText }
    static var context: NSColor { AppTheme.mutedText }
}

/// Which changes a changes pane shows, fixed when the pane is created.
nonisolated enum ChangesSource: Equatable, Sendable {
    /// Staged, unstaged, and untracked changes in the working tree.
    case uncommitted
    /// Changes committed on this branch since it left `defaultBranch`
    /// (`git diff <default>...HEAD`). The name labels the tab and the review
    /// message; each load resolves the default branch afresh.
    case branch(defaultBranch: String)

    var tabTitle: String {
        switch self {
        case .uncommitted: return "Uncommitted Changes"
        case .branch(let defaultBranch): return "Changes vs \(defaultBranch)"
        }
    }

    /// The first line of the review comments sent to an agent.
    var commentIntro: String {
        switch self {
        case .uncommitted:
            return "Review comments on the uncommitted changes in this repository. Please address each one."
        case .branch(let defaultBranch):
            return "Review comments on the changes committed on this branch (compared with \(defaultBranch)). Please address each one."
        }
    }

    var allowsStaging: Bool {
        self == .uncommitted
    }

    /// An open changes pane is reused for a request only when it shows the
    /// same repository and source, so a repository's uncommitted and branch
    /// views are separate tabs.
    static func paneMatches(
        paneRepository: String?,
        paneSource: ChangesSource?,
        repositoryPath: String,
        source: ChangesSource
    ) -> Bool {
        paneRepository == repositoryPath && paneSource == source
    }
}

/// One file's row in the changes pane. Equality decides whether a refresh
/// can keep the section view already on screen.
nonisolated struct ChangeSection: Equatable, Sendable {
    let relativePath: String
    let diff: String
    let isConflicted: Bool
    let status: GitFileStatus
    /// Staged with nothing unstaged left, so the review's `s` unstages it.
    let isFullyStaged: Bool
    /// Modification date and size, recorded for sections built from the file
    /// on disk (image previews, conflict blocks), where the diff text stays the
    /// same while the bytes change. nil for plain text diffs.
    let fileStamp: FileStamp?

    nonisolated struct FileStamp: Equatable, Sendable {
        let modificationDate: Date?
        let size: Int?
    }

    init(
        relativePath: String,
        diff: String,
        isConflicted: Bool,
        status: GitFileStatus,
        fileStamp: FileStamp? = nil,
        isFullyStaged: Bool = false
    ) {
        self.relativePath = relativePath
        self.diff = diff
        self.isConflicted = isConflicted
        self.status = status
        self.fileStamp = fileStamp
        self.isFullyStaged = isFullyStaged
    }

    /// Builds a section, reading the file's stamp when the view would be built
    /// from the file itself.
    init(
        relativePath: String,
        diff: String,
        isConflicted: Bool,
        status: GitFileStatus,
        repositoryPath: String,
        isFullyStaged: Bool = false
    ) {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        var stamp: FileStamp?
        if isConflicted || UncommittedChangesViewController.previewableImageExtensions.contains(ext) {
            let path = URL(fileURLWithPath: repositoryPath).appendingPathComponent(relativePath).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            stamp = FileStamp(
                modificationDate: attributes?[.modificationDate] as? Date,
                size: attributes?[.size] as? Int
            )
        }
        self.init(
            relativePath: relativePath,
            diff: diff,
            isConflicted: isConflicted,
            status: status,
            fileStamp: stamp,
            isFullyStaged: isFullyStaged
        )
    }

    func absolutePath(repositoryPath: String) -> String {
        URL(fileURLWithPath: repositoryPath).appendingPathComponent(relativePath).path
    }
}

/// How a refresh turns the displayed sections into the new ones. Both lists
/// are sorted by path, so kept sections never change relative order.
nonisolated struct ChangesReconcilePlan: Equatable {
    enum Step: Equatable {
        case keep(String)
        case rebuild(String)
        case insert(String)
    }

    /// One step per incoming section, in display order.
    let steps: [Step]
    /// Displayed paths absent from the new result.
    let removed: [String]

    init(displayed: [ChangeSection], incoming: [ChangeSection]) {
        let current = Dictionary(displayed.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        steps = incoming.map { section in
            guard let existing = current[section.relativePath] else { return .insert(section.relativePath) }
            return existing == section ? .keep(section.relativePath) : .rebuild(section.relativePath)
        }
        let incomingPaths = Set(incoming.map(\.relativePath))
        removed = displayed.map(\.relativePath).filter { !incomingPaths.contains($0) }
    }

    /// The new result matches what is on screen: touch nothing.
    var isNoOp: Bool {
        removed.isEmpty && steps.allSatisfy { if case .keep = $0 { true } else { false } }
    }
}

/// The reader's place: the section at the top of the viewport and how far into
/// it the viewport starts. Positions are distances from the document top.
nonisolated struct ChangesScrollAnchor: Equatable {
    struct Section: Equatable {
        let path: String
        let top: CGFloat
    }

    let path: String
    let offset: CGFloat

    /// The last section starting at or above `visibleTop`, or the first section
    /// when the viewport sits above every section (the top padding).
    static func capture(visibleTop: CGFloat, sections: [Section]) -> ChangesScrollAnchor? {
        guard let section = sections.last(where: { $0.top <= visibleTop }) ?? sections.first else { return nil }
        return ChangesScrollAnchor(path: section.path, offset: visibleTop - section.top)
    }

    /// Where the viewport top belongs in the new layout. If the anchor file is
    /// gone, the next section in path order takes its place; past the last
    /// section, `fallback` (the old position, clamped by the caller) is used.
    func restoredTop(in sections: [Section], fallback: CGFloat) -> CGFloat {
        if let section = sections.first(where: { $0.path == path }) {
            return section.top + offset
        }
        if let next = sections.first(where: { $0.path > path }) {
            return next.top
        }
        return fallback
    }
}

/// Hands out request numbers and says whether a finishing request is still
/// the newest, so a slow older load cannot overwrite a newer one.
nonisolated struct LatestRequestGate {
    private(set) var latest = 0

    mutating func begin() -> Int {
        latest += 1
        return latest
    }

    func isCurrent(_ request: Int) -> Bool {
        request == latest
    }
}

/// Which file sections are collapsed and which are marked Viewed, keyed by
/// relative path. Held in memory by the pane; nothing is saved.
nonisolated struct ChangesSectionStates {
    struct State: Equatable {
        var isCollapsed: Bool
        var isViewed: Bool
    }

    /// Generated dependency lockfiles, which start collapsed.
    static let lockfileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
        "Package.resolved", "Cargo.lock", "Gemfile.lock", "Podfile.lock", "poetry.lock",
        "uv.lock", "composer.lock", "go.sum"
    ]

    /// A diff with more changed lines (added plus removed) than this starts collapsed.
    static let largeDiffLineCount = 500

    static func startsCollapsed(relativePath: String, changedLines: Int) -> Bool {
        lockfileNames.contains((relativePath as NSString).lastPathComponent)
            || changedLines > largeDiffLineCount
    }

    /// Paths whose content differs between the two results. Only new content
    /// clears a Viewed mark: a stage or unstage changes the status letter and
    /// rebuilds the header, but the file still reads the same. A stamp that
    /// appears or vanishes only tracks the conflict flag, so it is not counted.
    static func contentChangedPaths(displayed: [ChangeSection], incoming: [ChangeSection]) -> Set<String> {
        let previous = Dictionary(displayed.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(incoming.compactMap { section -> String? in
            guard let old = previous[section.relativePath] else { return nil }
            let stampChanged = old.fileStamp != nil && section.fileStamp != nil && old.fileStamp != section.fileStamp
            return old.diff != section.diff || stampChanged ? section.relativePath : nil
        })
    }

    private var states: [String: State] = [:]

    func state(for path: String) -> State {
        states[path] ?? State(isCollapsed: false, isViewed: false)
    }

    /// Brings the states in line with a new result. A path seen for the first
    /// time gets the default (`changedLines` is asked only then); a path that
    /// left is forgotten; a Viewed file whose content changed needs another
    /// look, so it loses the mark and opens. Every other state is left alone.
    mutating func update(sections: [ChangeSection], contentChanged: Set<String>, changedLines: (ChangeSection) -> Int) {
        let incoming = Set(sections.map(\.relativePath))
        states = states.filter { incoming.contains($0.key) }
        for section in sections {
            let path = section.relativePath
            if let existing = states[path] {
                if existing.isViewed && contentChanged.contains(path) {
                    states[path] = State(isCollapsed: false, isViewed: false)
                }
            } else {
                let collapsed = Self.startsCollapsed(relativePath: path, changedLines: changedLines(section))
                states[path] = State(isCollapsed: collapsed, isViewed: false)
            }
        }
    }

    mutating func toggleCollapsed(_ path: String) {
        var state = state(for: path)
        state.isCollapsed.toggle()
        states[path] = state
    }

    /// Marking a file Viewed collapses it; clearing the mark opens it.
    mutating func setViewed(_ viewed: Bool, for path: String) {
        states[path] = State(isCollapsed: viewed, isViewed: viewed)
    }

    /// Opens the section without touching its Viewed mark.
    mutating func expand(_ path: String) {
        var state = state(for: path)
        state.isCollapsed = false
        states[path] = state
    }
}

/// The pane's root view, reporting when it joins or leaves a window (its tab
/// being selected or deselected).
private final class WindowObservingView: NSView {
    var onWindowChange: (() -> Void)?
    /// Offered each key press first; true means it was handled.
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A diff text view that offers key presses to the pane's review keys before
/// its own handling, which would otherwise beep on typed characters.
private final class ChangesDiffTextView: NSTextView {
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Offered each click first (a gutter click starts a comment); true
    /// means it was handled.
    var onMouseDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if onMouseDown?(event) == true { return }
        super.mouseDown(with: event)
    }
}

/// The changes pane's keyboard review: which keys it takes, what change
/// blocks a diff holds, and where each key moves. Positions are distances
/// from the top of the document.
nonisolated enum ChangesReview {
    enum Key: Equatable {
        case nextBlock, previousBlock, nextFile, previousFile
        case toggleViewed, toggleCollapsed, stage, open, comment

        /// Plain keys only: Command, Control, or Option held is never ours.
        /// `characters` is the event's `charactersIgnoringModifiers`; the
        /// letter is read lowercased and Shift decides the file variants, so
        /// Caps Lock does not turn j into J.
        init?(characters: String?, modifierFlags: NSEvent.ModifierFlags) {
            guard modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
            let shift = modifierFlags.contains(.shift)
            switch (characters?.lowercased(), shift) {
            case ("j", false): self = .nextBlock
            case ("k", false): self = .previousBlock
            case ("j", true): self = .nextFile
            case ("k", true): self = .previousFile
            case ("v", false): self = .toggleViewed
            case ("x", false): self = .toggleCollapsed
            case ("s", false): self = .stage
            case ("o", false): self = .open
            case ("c", false): self = .comment
            default: return nil
            }
        }
    }

    struct Viewport: Equatable {
        let top: CGFloat
        let bottom: CGFloat

        /// Any part of `top..<bottom` is on screen.
        func shows(top: CGFloat, bottom: CGFloat) -> Bool {
            bottom > self.top && top < self.bottom
        }
    }

    struct FileSpan: Equatable {
        let path: String
        let top: CGFloat
        let bottom: CGFloat
    }

    struct BlockID: Equatable {
        let path: String
        let index: Int
    }

    struct BlockSpan: Equatable {
        let path: String
        let index: Int
        let top: CGFloat
        let bottom: CGFloat
    }

    enum StageAction: Equatable {
        case stage, unstage
    }

    /// Where a scrolling key moves the viewport top, or nil when the key is
    /// not one (or Command, Control, or Option is held). Up/Down move three
    /// lines, Page Down and Space a viewport less one line, Page Up and
    /// Shift-Space back by the same, Home/End to either end. The caller clamps.
    static func scrollTop(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags,
        visibleTop: CGFloat,
        viewportHeight: CGFloat,
        documentHeight: CGFloat,
        lineHeight: CGFloat
    ) -> CGFloat? {
        guard modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let scalar = characters?.unicodeScalars.first,
              characters?.unicodeScalars.count == 1 else { return nil }
        let page = viewportHeight - lineHeight
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return visibleTop - 3 * lineHeight
        case NSDownArrowFunctionKey: return visibleTop + 3 * lineHeight
        case NSPageUpFunctionKey: return visibleTop - page
        case NSPageDownFunctionKey: return visibleTop + page
        case 0x20: return modifierFlags.contains(.shift) ? visibleTop - page : visibleTop + page
        case NSHomeFunctionKey: return 0
        case NSEndFunctionKey: return documentHeight - viewportHeight
        default: return nil
        }
    }

    /// Character ranges of each maximal run of added or removed lines, read
    /// from the rendered diff's gutter attribute. Context lines and rows
    /// without one (hunk headers, separators) end a run.
    static func blockRanges(in text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        var open: NSRange?
        text.enumerateAttribute(InlineDiffRenderer.gutterLine, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let isChange = (value as? DiffGutterLine).map { $0.kind != .context } ?? false
            if isChange, let current = open, NSMaxRange(current) == range.location {
                open = NSUnionRange(current, range)
            } else {
                if let current = open { ranges.append(current) }
                open = isChange ? range : nil
            }
        }
        if let open { ranges.append(open) }
        return ranges
    }

    /// The file a key acts from: the current one while any of it is on
    /// screen, otherwise the section at the top of the viewport.
    static func rebasedFile(_ current: String?, files: [FileSpan], viewport: Viewport) -> String? {
        if let current, let span = files.first(where: { $0.path == current }),
           viewport.shows(top: span.top, bottom: span.bottom) {
            return current
        }
        let sections = files.map { ChangesScrollAnchor.Section(path: $0.path, top: $0.top) }
        return ChangesScrollAnchor.capture(visibleTop: viewport.top, sections: sections)?.path
    }

    /// J / K. With no current file the first press picks the file at the top
    /// of the viewport. nil when there is nowhere to go.
    static func movedFile(_ current: String?, forward: Bool, files: [FileSpan], viewport: Viewport) -> String? {
        guard let start = rebasedFile(current, files: files, viewport: viewport) else { return nil }
        guard current != nil else { return start }
        guard let index = files.firstIndex(where: { $0.path == start }) else { return nil }
        let target = forward ? index + 1 : index - 1
        return files.indices.contains(target) ? files[target].path : nil
    }

    /// j / k over `blocks` (every block of every expanded file, in display
    /// order). Without a current block on screen, j takes the first block
    /// at or below the viewport top and k the last one above it.
    static func movedBlock(_ current: BlockID?, forward: Bool, blocks: [BlockSpan], viewport: Viewport) -> BlockSpan? {
        if let current,
           let index = blocks.firstIndex(where: { $0.path == current.path && $0.index == current.index }),
           viewport.shows(top: blocks[index].top, bottom: blocks[index].bottom) {
            let target = forward ? index + 1 : index - 1
            return blocks.indices.contains(target) ? blocks[target] : nil
        }
        return forward
            ? blocks.first { $0.top >= viewport.top }
            : blocks.last { $0.top < viewport.top }
    }

    /// The file that becomes current after a refresh: the same one if it is
    /// still listed, else the next in path order, else the previous.
    static func fileAfterRemoval(_ current: String, paths: [String]) -> String? {
        if paths.contains(current) { return current }
        return paths.first { $0 > current } ?? paths.last { $0 < current }
    }

    /// The first file after `path` that is not viewed, for `v`'s advance.
    static func nextUnviewed(after path: String, paths: [String], isViewed: (String) -> Bool) -> String? {
        guard let index = paths.firstIndex(of: path) else { return nil }
        return paths[(index + 1)...].first { !isViewed($0) }
    }

    /// Fully staged means something is staged and nothing unstaged or
    /// untracked remains.
    static func isFullyStaged(_ entry: GitStatusEntry) -> Bool {
        !entry.isConflicted && !entry.isUntracked && entry.hasStagedChanges && !entry.hasUnstagedChanges
    }

    /// `s`: unstage a fully staged file, stage anything else, and leave a
    /// conflicted file alone. Committed changes (the branch source) cannot
    /// be staged.
    static func stageAction(for section: ChangeSection, source: ChangesSource) -> StageAction? {
        guard source.allowsStaging, !section.isConflicted else { return nil }
        return section.isFullyStaged ? .unstage : .stage
    }
}

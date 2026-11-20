import Cocoa

final class UncommittedChangesViewController: NSViewController {
    var onOpenFile: ((String) -> Void)?

    private var repositoryPath: String
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
    }

    init(repositoryPath: String, focusedFilePath: String? = nil, gitService: GitService = GitService()) {
        self.repositoryPath = repositoryPath
        self.focusedFilePath = focusedFilePath
        self.gitService = gitService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = WindowObservingView()
        rootView.onWindowChange = { [weak self] in self?.visibilityMayHaveChanged() }
        view = rootView
        view.wantsLayer = true
        view.layer?.backgroundColor = DiffViewController.DiffColors.background.cgColor
        setupScrollView()
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
        scrollView.backgroundColor = DiffViewController.DiffColors.background
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
        documentView.layer?.backgroundColor = DiffViewController.DiffColors.background.cgColor
        documentView.addSubview(stackView)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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

        DispatchQueue.global(qos: .userInitiated).async { [repositoryPath, gitService] in
            let result: Result<[ChangeSection], Error>
            do {
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
                        repositoryPath: repositoryPath
                    )
                })
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishLoad(request: request, result: result)
            }
        }
    }

    private func finishLoad(request: Int, result: Result<[ChangeSection], Error>) {
        // Watcher bursts and sidebar clicks overlap; only the newest wins.
        guard requests.isCurrent(request) else { return }

        switch result {
        case .failure(let error):
            // A failed refresh keeps what is on screen; only a first load reports.
            guard displayedSections == nil else { return }
            showMessage("Failed to load uncommitted changes: \(error.localizedDescription)")
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
        label.textColor = DiffViewController.DiffColors.context
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

        updateSectionStates(
            sections,
            contentChanged: ChangesSectionStates.contentChangedPaths(displayed: displayedSections ?? [], incoming: sections)
        )

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
    }

    private func clearStack() {
        diffColumns.removeAll()
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
            self?.changeState(of: path) { $0.toggleCollapsed(path) }
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
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: section.status.rawValue)
        status.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        status.textColor = section.status.color
        status.translatesAutoresizingMaskIntoConstraints = false

        let directory = (section.relativePath as NSString).deletingLastPathComponent
        let path = NSTextField(labelWithString: directory.isEmpty ? "" : directory + "/")
        path.font = NSFont.systemFont(ofSize: 12)
        path.textColor = DiffViewController.DiffColors.context
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
        openButton.toolTip = "Open File"
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
        caption.textColor = DiffViewController.DiffColors.context
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

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = DiffViewController.DiffColors.background
        textView.textColor = DiffViewController.DiffColors.text
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

    init(chevron: NSButton, fileName: NSTextField, viewedBox: NSButton?) {
        self.chevron = chevron
        self.fileName = fileName
        self.viewedBox = viewedBox
        super.init(frame: .zero)
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        viewedBox?.target = self
        viewedBox?.action = #selector(viewedClicked(_:))
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
        chevron.toolTip = label
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

/// One file's row in the changes pane. Equality decides whether a refresh
/// can keep the section view already on screen.
nonisolated struct ChangeSection: Equatable, Sendable {
    let relativePath: String
    let diff: String
    let isConflicted: Bool
    let status: GitFileStatus
    /// Modification date and size, recorded for sections built from the file
    /// on disk (image previews, conflict blocks), where the diff text stays the
    /// same while the bytes change. nil for plain text diffs.
    let fileStamp: FileStamp?

    nonisolated struct FileStamp: Equatable, Sendable {
        let modificationDate: Date?
        let size: Int?
    }

    init(relativePath: String, diff: String, isConflicted: Bool, status: GitFileStatus, fileStamp: FileStamp? = nil) {
        self.relativePath = relativePath
        self.diff = diff
        self.isConflicted = isConflicted
        self.status = status
        self.fileStamp = fileStamp
    }

    /// Builds a section, reading the file's stamp when the view would be built
    /// from the file itself.
    init(relativePath: String, diff: String, isConflicted: Bool, status: GitFileStatus, repositoryPath: String) {
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
        self.init(relativePath: relativePath, diff: diff, isConflicted: isConflicted, status: status, fileStamp: stamp)
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

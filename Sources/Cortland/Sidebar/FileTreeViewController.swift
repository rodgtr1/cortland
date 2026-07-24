import Cocoa
import CoreServices

/// What the FSEvents context actually retains (via its retain/release
/// callbacks) — never the controller itself. The weak reference means a
/// callback racing a last-release on another thread reads nil instead of a
/// dangling controller pointer.
private final class FileTreeWatcherBox {
    weak var controller: FileTreeViewController?
    init(_ controller: FileTreeViewController) { self.controller = controller }
}

private let fileTreeEventCallback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
    guard let clientInfo = clientInfo else { return }
    let box = Unmanaged<FileTreeWatcherBox>.fromOpaque(clientInfo).takeUnretainedValue()

    // Paths are CFStrings (we pass kFSEventStreamCreateFlagUseCFTypes). Copy the
    // paths and flags out of the C buffers before hopping actors.
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

    // The stream is dispatched to the main queue, so the callback already runs on
    // the main actor — assert that to reach the controller's main-actor state.
    MainActor.assumeIsolated {
        box.controller?.handleFileSystemEvents(paths: paths, flags: flags)
    }
}

protocol FileTreeDelegate: AnyObject {
    func fileTree(_ fileTree: FileTreeViewController, didSelectFile url: URL)
    func fileTree(_ fileTree: FileTreeViewController, didOpenFile url: URL)
}

class FileTreeViewController: NSViewController {
    weak var delegate: FileTreeDelegate?

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var rootNode: FileTreeNode?
    private var currentPath: String = ""
    private var showHidden: Bool = false
    private var gitIgnoreChecker: GitIgnoreChecker?
    // Touched on the main actor while watching; read once by the nonisolated
    // deinit's stopWatching() at end-of-life (no other reference exists then).
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?
    nonisolated(unsafe) private var refreshWorkItem: DispatchWorkItem?
    private var lastRefreshFromFileEvent: Date?
    /// Expanded folders remembered per project root, so switching tabs and
    /// coming back restores the tree instead of collapsing it.
    private var expandedPathsByRoot: [String: Set<String>] = [:]
    /// A file we want to expand-to and select once the tree is loaded.
    private var pendingRevealURL: URL?
    /// Bumped on every full tree rebuild so a slow background build that has
    /// been superseded by a newer one is discarded instead of clobbering it.
    private var loadGeneration = 0
    /// Set while `expandLoadedItems` walks the tree. The expand/collapse
    /// delegates skip their icon-refreshing `reloadItem` during the walk — the
    /// reload that precedes it already redrew every row.
    private var isBulkExpanding = false
    /// A directory the owning sidebar asked us to load before the view loaded
    /// (lazy panel creation). `rebuildTree` renders into `outlineView`, which
    /// doesn't exist yet, so the request is deferred to `viewDidLoad`.
    private var pendingInitialPath: String?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    private var themeObserver: ThemeObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupOutlineView()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
        // The owning sidebar seeds `showHidden` (via setShowHidden) and, when it
        // knows one, a project directory before the view loads. Honor a seeded
        // directory; fall back to the home directory only when none was seeded.
        // showHidden is already set by the seed, so we don't re-read config here
        // (that would clobber a seeded/toggled value — the sidebar owns it).
        let initialPath = pendingInitialPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        loadFileTree(for: initialPath)
    }

    private func setupOutlineView() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.sidebarBackground
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = AppTheme.sidebarBackground

        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.backgroundColor = AppTheme.sidebarBackground
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickAction(_:))
        setupContextMenu()
        outlineView.usesAlternatingRowBackgroundColors = false
        if #available(macOS 12.0, *) {
            outlineView.style = .plain
        }
        outlineView.selectionHighlightStyle = .regular

        // Create column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.title = "Files"
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        scrollView?.contentView.backgroundColor = AppTheme.sidebarBackground
        outlineView?.backgroundColor = AppTheme.sidebarBackground
        outlineView?.reloadData()
    }

    private func setupContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
    }

    func loadFileTree(for path: String, force: Bool = false) {
        // Before the view loads there is no `outlineView` to render into, and
        // `rebuildTree`'s async completion would touch it. Defer: remember the
        // request so `viewDidLoad` performs the initial load once the view exists.
        guard isViewLoaded else {
            pendingInitialPath = path
            return
        }

        Log.debug("🌳 loadFileTree called with path: \(path)", category: "sidebar")

        let workspace = WorkspaceResolver.cachedContext(for: path)
        let displayPath = workspace.displayRoot
        Log.debug("🌳 displayPath: \(displayPath), gitRoot: \(workspace.repositoryRoot ?? "none")", category: "sidebar")
        let pathChanged = displayPath != currentPath

        guard force || pathChanged else {
            Log.debug("🌳 Skipping - already loaded: \(displayPath)", category: "sidebar")
            return
        }

        // Remember the outgoing project's expanded folders so returning to it
        // restores them instead of collapsing everything.
        if pathChanged, !currentPath.isEmpty {
            expandedPathsByRoot[currentPath] = expandedDirectoryPaths()
        }

        // Restore expansion: the live set on a forced refresh, otherwise the
        // saved set for the project we're switching to.
        let expandedPaths = force ? expandedDirectoryPaths() : (expandedPathsByRoot[displayPath] ?? [])

        currentPath = displayPath
        if pathChanged {
            startWatching(path: displayPath)
        }

        // (Re)create the gitignore checker for this root. It loads asynchronously
        // and triggers another rebuild once ready to apply ignore filtering.
        setupGitIgnoreChecker(for: displayPath)

        rebuildTree(displayPath: displayPath, expandedPaths: expandedPaths)
    }

    /// Configures `gitIgnoreChecker` for `displayPath`: a checker for git repos
    /// (which rebuilds the tree once its ignore data loads), or nil otherwise.
    private func setupGitIgnoreChecker(for displayPath: String) {
        let gitPath = URL(fileURLWithPath: displayPath).appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitPath) else {
            gitIgnoreChecker = nil
            return
        }

        let checker = GitIgnoreChecker(rootPath: displayPath)
        checker.onLoadComplete = { [weak self] in
            guard let self = self, self.currentPath == displayPath else { return }
            Log.debug("🔄 GitIgnore data loaded, refreshing tree", category: "sidebar")
            // Rebuild applying ignore filtering, preserving the live expansion.
            self.rebuildTree(displayPath: displayPath, expandedPaths: self.expandedDirectoryPaths())
        }
        gitIgnoreChecker = checker
    }

    /// Builds a fresh tree for `displayPath` entirely off the main thread, then
    /// swaps it in atomically on the main thread. The new tree is fully DETACHED
    /// (never assigned to `rootNode` or seen by AppKit) until the swap, so the
    /// background scan can never race the data source — which only ever reads the
    /// live tree on the main thread. A generation token discards a build that a
    /// newer rebuild has superseded.
    private func rebuildTree(displayPath: String, expandedPaths: Set<String>) {
        loadGeneration &+= 1
        let generation = loadGeneration
        let showHidden = self.showHidden
        let gitIgnoreChecker = self.gitIgnoreChecker
        let newRoot = FileTreeNode(url: URL(fileURLWithPath: displayPath))
        newRoot.isExpanded = true
        Log.debug("🌳 Rebuilding tree for: \(displayPath) (gen \(generation))", category: "sidebar")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            newRoot.loadSubtree(
                expandedPaths: expandedPaths,
                showHidden: showHidden,
                gitIgnoreChecker: gitIgnoreChecker
            )
            DispatchQueue.main.async {
                guard let self = self, self.loadGeneration == generation else { return }

                // FSEvents fire on every file an agent writes, but content edits
                // don't change the listing — the scan comes back describing the
                // rows already on screen. Swapping it in anyway costs a full
                // reloadData plus an expansion walk on the main thread, which
                // queues ahead of the user's clicks. Keep the live tree instead.
                if let liveRoot = self.rootNode, liveRoot.isStructurallyIdentical(to: newRoot) {
                    Log.debug("🌳 Tree unchanged (gen \(generation)); skipping reload", category: "sidebar")
                    self.attemptRevealPending()
                    return
                }

                self.rootNode = newRoot
                Log.debug("📁 Root node loaded with \(newRoot.children.count) children", category: "sidebar")
                self.outlineView.reloadData()
                self.expandLoadedItems(from: newRoot)
                self.attemptRevealPending()
            }
        }
    }

    func toggleHiddenFiles() {
        setShowHidden(!showHidden)
    }

    func setShowHidden(_ show: Bool) {
        guard show != showHidden else { return }
        showHidden = show
        if let rootPath = rootNode?.url.path {
            loadFileTree(for: rootPath, force: true)
        }
    }

    func refresh() {
        if let rootPath = rootNode?.url.path {
            loadFileTree(for: rootPath, force: true)
        }
    }

    // MARK: - Reveal / select a file

    /// Expand the folders leading to `url` and select it. If the tree is still
    /// loading the request is remembered and retried once it finishes.
    func revealFile(_ url: URL) {
        pendingRevealURL = url.standardizedFileURL
        attemptRevealPending()
    }

    /// Clear any selection (e.g. the active tab is no longer an editor).
    func clearSelection() {
        pendingRevealURL = nil
        outlineView?.deselectAll(nil)
    }

    private func attemptRevealPending() {
        guard isViewLoaded,
              let target = pendingRevealURL,
              let rootNode = rootNode,
              rootNode.isLoaded else { return }

        let targetPath = target.path
        let rootPath = rootNode.url.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            // File lives outside the current tree; nothing to reveal.
            pendingRevealURL = nil
            return
        }

        revealStep(target: target, in: rootNode)
    }

    private func revealStep(target: URL, in node: FileTreeNode) {
        let targetPath = target.path
        guard let child = node.children.first(where: { child in
            let childPath = child.url.standardizedFileURL.path
            return targetPath == childPath || targetPath.hasPrefix(childPath + "/")
        }) else {
            // Not present (likely hidden or gitignored); give up quietly.
            pendingRevealURL = nil
            return
        }

        if child.url.standardizedFileURL.path == targetPath {
            outlineView.expandItem(node)
            let row = outlineView.row(forItem: child)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
            pendingRevealURL = nil
            return
        }

        // `child` is an ancestor directory of the target: expand, then descend.
        if child.isLoaded {
            child.isExpanded = true
            outlineView.expandItem(child)
            revealStep(target: target, in: child)
        } else {
            // Scan off-main, then commit onto the live `child` on main (the node
            // is part of the displayed tree, so it must only be mutated there).
            let showHidden = self.showHidden
            let gitIgnoreChecker = self.gitIgnoreChecker
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak child] in
                guard let scanTarget = child else { return }
                let scanned = scanTarget.scanChildren(showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker)
                DispatchQueue.main.async { [weak child] in
                    guard let self = self, let child = child,
                          self.pendingRevealURL == target else { return }
                    if !child.isLoaded {
                        child.commitChildren(scanned)
                    }
                    child.isExpanded = true
                    // `child` is still collapsed here (nothing expanded it), so the
                    // reload has no descendant rows to rebuild; batch it with the
                    // expansion so both land in one layout pass.
                    self.outlineView.beginUpdates()
                    self.outlineView.reloadItem(child, reloadChildren: true)
                    self.outlineView.expandItem(child)
                    self.outlineView.endUpdates()
                    self.revealStep(target: target, in: child)
                }
            }
        }
    }

    private func startWatching(path: String) {
        stopWatching()

        guard shouldWatchPath(path) else { return }

        // The context retains a weak box, not the controller: FSEventStreamCreate
        // takes its own +1 via the retain callback and drops it when the stream
        // is deallocated after Invalidate, so a callback already in flight can
        // never see freed memory even if our last release happens off-main.
        let box = FileTreeWatcherBox(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info = info else { return nil }
                _ = Unmanaged<FileTreeWatcherBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info = info else { return }
                Unmanaged<FileTreeWatcherBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let pathsToWatch = [path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        let created = withExtendedLifetime(box) {
            FSEventStreamCreate(
                kCFAllocatorDefault,
                fileTreeEventCallback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,
                flags
            )
        }
        guard let stream = created else {
            Log.error("⚠️ Failed to watch file tree path: \(path)", category: "filetree")
            return
        }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    nonisolated private func stopWatching() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil

        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    private func expandedDirectoryPaths() -> Set<String> {
        guard let rootNode = rootNode else { return [] }

        var paths = Set<String>()
        collectExpandedDirectoryPaths(from: rootNode, into: &paths)
        return paths
    }

    private func collectExpandedDirectoryPaths(from node: FileTreeNode, into paths: inout Set<String>) {
        guard node.isDirectory else { return }

        if node === rootNode || outlineView.isItemExpanded(node) || node.isExpanded {
            paths.insert(node.url.path)
        }

        for child in node.children {
            collectExpandedDirectoryPaths(from: child, into: &paths)
        }
    }

    /// Restores expansion after a reload. Batched: every `expandItem` re-enters
    /// `shouldExpandItem`, so without `isBulkExpanding` a wide tree would queue
    /// one async `reloadItem` per expanded folder on top of the `reloadData`
    /// that already redrew all of them.
    private func expandLoadedItems(from node: FileTreeNode) {
        isBulkExpanding = true
        outlineView.beginUpdates()
        expandLoadedItemsRecursive(from: node)
        outlineView.endUpdates()
        isBulkExpanding = false
    }

    private func expandLoadedItemsRecursive(from node: FileTreeNode) {
        guard node.isDirectory else { return }

        if node === rootNode || node.isExpanded {
            outlineView.expandItem(node)
        }

        for child in node.children {
            expandLoadedItemsRecursive(from: child)
        }
    }

    /// Decide whether a batch of FSEvents warrants rebuilding the tree. Most git
    /// internals (`.git/index`, loose objects, refs, logs) don't change the
    /// working-tree file *listing* we display, so refreshing on them just burns a
    /// full rebuild + reloadData on the main thread — the staging/commit lag.
    /// Only refresh for events that can actually change what's shown.
    func handleFileSystemEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        var relevant = false
        for (index, flag) in flags.enumerated() {
            // When FSEvents loses history or asks us to rescan, we can't reason
            // about individual paths — refresh conservatively.
            let mustRescan = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged
            )
            if flag & mustRescan != 0 {
                relevant = true
                break
            }
            let path = index < paths.count ? paths[index] : ""
            if pathAffectsFileTree(path) {
                relevant = true
                break
            }
        }
        guard relevant else { return }
        scheduleRefreshFromFileEvent()
    }

    /// Whether a single changed path can affect the displayed tree.
    private func pathAffectsFileTree(_ path: String) -> Bool {
        // With hidden files shown, `.git` itself is part of the listing, so we
        // can't filter changes under it.
        guard !showHidden else { return true }

        let gitDir = currentPath + "/.git"
        // Anything outside the repo's `.git` directory affects the listing —
        // including `.gitignore` files and the working-tree files a checkout
        // adds/removes (those arrive as their own events). For worktrees and
        // submodules `.git` is a file, so this prefix simply never matches and
        // nothing is over-filtered.
        guard path == gitDir || path.hasPrefix(gitDir + "/") else { return true }

        // Inside `.git`: only ignore-rule changes alter what we display (which
        // entries render dimmed). `.git/index` is intentionally NOT treated as
        // relevant — that's the staging write we want to stop rebuilding on; a
        // newly-tracked file keeps its prior dimming until the next real refresh.
        return path.hasSuffix("/.git/info/exclude")
    }

    fileprivate func scheduleRefreshFromFileEvent() {
        // A refresh is already scheduled and will cover this event; it always
        // fires no later than the trailing deadline we'd compute here, so keep
        // it. (Cancel-and-reschedule would push a burst's first paint from
        // 0.75s out to the 2s window end — FSEvents' delivery latency
        // guarantees bursts arrive as multiple callbacks.)
        guard refreshWorkItem == nil else { return }

        // Leading edge: refresh 0.75s after the first event. An event that
        // lands inside the 2s throttle window after a refresh gets a single
        // trailing refresh when the window elapses, so a file created just
        // after a refresh still appears without waiting for another event.
        var delay = 0.75
        if let last = lastRefreshFromFileEvent {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 2.0 {
                delay = 2.0 - elapsed
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshWorkItem = nil
            self?.lastRefreshFromFileEvent = Date()
            self?.refresh()
        }

        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func shouldWatchPath(_ path: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return standardizedPath != homePath && standardizedPath != "/"
    }

    deinit {
        stopWatching()
    }

    @objc private func doubleClickAction(_ sender: Any) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }

        Log.debug("DoubleClick: \(node.name) - isDirectory: \(node.isDirectory) - path: \(node.url.path)", category: "sidebar")

        if node.isDirectory {
            // For directories, toggle expand/collapse
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            // Only open files, not directories
            delegate?.fileTree(self, didOpenFile: node.url)
        }
    }

    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension FileTreeViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }

        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let openInFinderItem = NSMenuItem(
            title: "Open in Finder",
            action: #selector(openInFinder(_:)),
            keyEquivalent: ""
        )
        openInFinderItem.target = self
        openInFinderItem.representedObject = node.url
        menu.addItem(openInFinderItem)
    }
}

extension FileTreeViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            let count = rootNode != nil ? 1 : 0
            Log.debug("📊 numberOfChildrenOfItem(nil) = \(count)", category: "sidebar")
            return count
        }

        guard let node = item as? FileTreeNode else { return 0 }

        // Return children count only if loaded
        // Loading happens in shouldExpandItem delegate method
        let count = node.isLoaded ? node.children.count : 0
        Log.debug("📊 numberOfChildrenOfItem(\(node.name)) = \(count), isLoaded: \(node.isLoaded), isExpanded: \(node.isExpanded)", category: "sidebar")
        return count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNode ?? NSNull()
        }

        guard let node = item as? FileTreeNode else {
            return NSNull()
        }

        // The live tree is only mutated on the main thread now, so this is no
        // longer racy — but AppKit can still ask for an index from a count it
        // cached before an interleaved reload. Bounds-check defensively and
        // return a placeholder instead of trapping; the next reload reconciles.
        let children = node.children
        guard index >= 0, index < children.count else {
            Log.error("⚠️ child index \(index) out of range (count \(children.count)) for \(node.name)", category: "sidebar")
            return NSNull()
        }

        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }
        return node.isDirectory && node.hasChildren(showHidden: showHidden)
    }
}

extension FileTreeViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        return FileTreeRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        var view = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

        if view == nil {
            view = NSTableCellView()
            view?.identifier = identifier

            let textField = NSTextField()
            textField.isEditable = false
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false

            view?.addSubview(imageView)
            view?.addSubview(textField)
            view?.textField = textField
            view?.imageView = imageView

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: view!.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: view!.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: view!.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: view!.centerYAnchor)
            ])
        }

        view?.textField?.stringValue = node.name
        view?.imageView?.image = node.icon

        // Style based on file state: hidden and gitignored entries render
        // dimmed (name and icon) so they're distinguishable at a glance.
        if node.isGitIgnored {
            view?.textField?.textColor = AppTheme.mutedText // Dimmed for ignored files
            view?.imageView?.alphaValue = 0.4
        } else if node.isHidden {
            view?.textField?.textColor = AppTheme.dimText // Slightly dimmed for hidden files
            view?.imageView?.alphaValue = 0.55
        } else {
            view?.textField?.textColor = AppTheme.primaryText // Normal text color
            view?.imageView?.alphaValue = 1.0
        }

        return view
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 22
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }

        Log.debug("Selection: \(node.name) - isDirectory: \(node.isDirectory)", category: "sidebar")

        // Only notify delegate about file selection, not directory selection
        if !node.isDirectory {
            delegate?.fileTree(self, didSelectFile: node.url)
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }

        node.isExpanded = true

        if node.isDirectory && !node.isLoaded {
            // Scan off-main, then commit onto the live `node` on main: the node is
            // displayed, so its children/isLoaded must only be mutated there.
            let currentShowHidden = showHidden
            let currentGitIgnoreChecker = gitIgnoreChecker
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak node] in
                guard let scanTarget = node else { return }
                let scanned = scanTarget.scanChildren(showHidden: currentShowHidden, gitIgnoreChecker: currentGitIgnoreChecker)
                DispatchQueue.main.async { [weak node] in
                    guard let self = self, let node = node else { return }

                    // Only the commit that first publishes children matches the
                    // zero-child row count AppKit cached while the node was
                    // unloaded; if something else (a reveal) got there first, the
                    // rows already exist and inserting them again would desync.
                    let didCommit = !node.isLoaded
                    if didCommit {
                        node.commitChildren(scanned)
                    }

                    self.outlineView.beginUpdates()
                    if didCommit, self.outlineView.isItemExpanded(node) {
                        // AppKit expanded the node the moment we returned true and
                        // cached zero children for it, so the committed children are
                        // the entire delta: insert exactly those rows, plus a
                        // childless reload of the node itself for its open-folder
                        // icon. reloadItem(reloadChildren: true) would instead throw
                        // away and rebuild every descendant row view, and that Auto
                        // Layout cascade is what stalls clicks on a large folder.
                        self.outlineView.reloadItem(node)
                        if !node.children.isEmpty {
                            self.outlineView.insertItems(
                                at: IndexSet(integersIn: 0..<node.children.count),
                                inParent: node,
                                withAnimation: []
                            )
                        }
                    } else {
                        // The node isn't expanded (collapsed while the scan ran) or
                        // was already loaded: no zero-row cache to insert into.
                        self.outlineView.reloadItem(node, reloadChildren: true)
                    }
                    self.outlineView.expandItem(node)
                    self.outlineView.endUpdates()
                }
            }
        } else if !isBulkExpanding {
            // Item is already loaded, just reload to update icon
            DispatchQueue.main.async {
                outlineView.reloadItem(node, reloadChildren: false)
            }
        }

        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }
        node.isExpanded = false

        // Reload the item to update its icon (from folder.open to folder)
        if !isBulkExpanding {
            DispatchQueue.main.async {
                outlineView.reloadItem(node, reloadChildren: false)
            }
        }

        return true
    }
}

private final class FileTreeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let selectionRect = bounds.insetBy(dx: 0, dy: 1)
        AppTheme.selection.setFill()
        selectionRect.fill()
    }
}

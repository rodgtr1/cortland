import Cocoa

protocol PaneSplitControllerDelegate: AnyObject {
    func paneSplitController(_ controller: PaneSplitController, didAddPane pane: PaneModel, at index: Int)
    func paneSplitController(_ controller: PaneSplitController, didActivatePane pane: PaneModel, at index: Int)
    func paneSplitController(_ controller: PaneSplitController, didClosePane pane: PaneModel, at index: Int)
    /// Asked before the pane's X button closes it; return false to veto. The
    /// window confirms when the pane holds an editor with unsaved edits. Closes
    /// that don't come from that button skip this: MCP `pane_close` is
    /// programmatic, and ⇧⌘W confirms for itself before calling in.
    func paneSplitController(_ controller: PaneSplitController, shouldClosePane pane: PaneModel) -> Bool
}

extension PaneSplitControllerDelegate {
    func paneSplitController(_ controller: PaneSplitController, shouldClosePane pane: PaneModel) -> Bool { true }
}

class PaneSplitController: NSViewController {
    weak var delegate: PaneSplitControllerDelegate?

    private var rootSplitView: NSSplitView!
    private var panes: [PaneModel] = []
    private var activePaneIndex: Int = 0
    private let config: Config

    // Track which container view wraps each pane
    private var paneContainers: [PaneModel: NSView] = [:]
    private var paneCloseButtons: [PaneModel: PaneCloseButton] = [:]
    // Track all split views we've created (for delegate management)
    private var allSplitViews: Set<NSSplitView> = []

    init(config: Config) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        setupSplitView()
    }

    private func setupSplitView() {
        rootSplitView = createSplitView(isVertical: true)
        rootSplitView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootSplitView)

        NSLayoutConstraint.activate([
            rootSplitView.topAnchor.constraint(equalTo: view.topAnchor),
            rootSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootSplitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // No initial pane here: every owner immediately calls
        // rebuildSplitView(for:) with the tab's real panes, and creating one
        // would spawn a shell that is discarded without being terminated.
    }

    private func createSplitView(isVertical: Bool) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = isVertical
        split.dividerStyle = .thin
        split.delegate = self
        allSplitViews.insert(split)
        return split
    }

    private func wrapPaneInContainer(_ pane: PaneModel, paneView: NSView) -> NSView {
        let container = ClickableContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(paneView)

        paneView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: container.topAnchor),
            paneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            paneView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let closeButton = PaneCloseButton()
        closeButton.pane = pane
        closeButton.target = self
        closeButton.action = #selector(closePaneButtonClicked(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        // Set click handler to make this pane active when clicked
        container.onMouseDown = { [weak self] in
            guard let self = self else { return }
            if let index = self.panes.firstIndex(of: pane) {
                Log.debug("🖱️ Clicked on pane \(index), making it active", category: "panes")
                self.setActivePane(index: index)
            }
        }

        paneContainers[pane] = container
        paneCloseButtons[pane] = closeButton
        updatePaneCloseButtons()
        return container
    }

    @objc private func closePaneButtonClicked(_ sender: PaneCloseButton) {
        guard let pane = sender.pane,
              let index = panes.firstIndex(of: pane) else { return }

        setActivePane(index: index)
        guard delegate?.paneSplitController(self, shouldClosePane: pane) ?? true else { return }
        closePane(index: index)
    }

    private func updatePaneCloseButtons() {
        guard panes.count > 1 else {
            paneCloseButtons.values.forEach { $0.isHidden = true }
            return
        }

        // A terminal pane only needs a close button when it's one of several
        // terminals. When the split exists solely because the user opened an
        // editor/diff alongside the terminal, leave the terminal alone
        // and show the X on that opened pane instead.
        let terminalCount = panes.filter { $0.paneType == .terminal }.count
        for (pane, button) in paneCloseButtons {
            // Every pane with a close button also has a container (both maps are
            // populated together in wrapPaneInContainer), so the old
            // `paneContainers[pane] == nil` guard was always false.
            let shouldShow = pane.paneType == .terminal ? terminalCount > 1 : true
            button.isHidden = !shouldShow
        }
    }

    private func findParentSplitView(for pane: PaneModel) -> NSSplitView? {
        guard let container = paneContainers[pane] else { return nil }
        return findSplitView(containing: container, in: rootSplitView)
    }

    /// Activates the pane under a left-click. The window-level monitor in
    /// MainWindowController calls this only on the active tab's controller, so
    /// hidden tabs can't claim clicks meant for the visible one.
    func activatePane(containing event: NSEvent) {
        guard event.window === view.window,
              let contentView = view.window?.contentView else { return }

        let pointInContent = contentView.convert(event.locationInWindow, from: nil)

        for (pane, container) in paneContainers {
            let pointInContainer = container.convert(pointInContent, from: contentView)
            guard container.bounds.contains(pointInContainer),
                  let index = panes.firstIndex(of: pane),
                  index != activePaneIndex else { continue }

            // This click's job is done — it picked the pane. Keep its mouse
            // reports out of the TUI inside, so activating a pane can't also
            // answer the prompt sitting under the pointer.
            pane.terminalViewController?.suppressMouseReportsForFocusClick()
            setActivePane(index: index)
            return
        }
    }

    private func findSplitView(containing view: NSView, in splitView: NSSplitView) -> NSSplitView? {
        if splitView.arrangedSubviews.contains(view) {
            return splitView
        }

        for subview in splitView.arrangedSubviews {
            if let nestedSplit = subview as? NSSplitView {
                if let found = findSplitView(containing: view, in: nestedSplit) {
                    return found
                }
            }
        }

        return nil
    }

    @discardableResult
    func splitPane(
        direction: SplitDirection,
        targetPaneID: UUID? = nil,
        initialDirectory: String? = nil,
        command: [String]? = nil,
        focus: Bool = true
    ) -> PaneModel? {
        guard panes.count < Limits.maxPanesPerTab else { return nil }
        let targetIndex: Int
        if let targetPaneID {
            guard let index = panes.firstIndex(where: { $0.id == targetPaneID }) else { return nil }
            targetIndex = index
        } else {
            guard activePaneIndex >= 0 && activePaneIndex < panes.count else { return nil }
            targetIndex = activePaneIndex
        }

        Log.debug("🔧 Splitting pane in \(direction) direction, current panes: \(panes.count)", category: "panes")

        let activePane = panes[targetIndex]
        guard let activePaneContainer = paneContainers[activePane],
              let parentSplit = findParentSplitView(for: activePane) else {
            Log.error("⚠️ Cannot find active pane container or parent split", category: "panes")
            return nil
        }

        Log.debug("🔧 Parent split isVertical: \(parentSplit.isVertical), arrangedSubviews: \(parentSplit.arrangedSubviews.count)", category: "panes")

        // Get the current directory from the active pane to use for the new terminal.
        let currentDirectory = initialDirectory ?? activePane.resolvedWorkingDirectory()
        Log.debug("🔧 Starting new pane in directory: \(currentDirectory ?? "home")", category: "panes")

        let newPane = PaneModel()
        newPane.createTerminalViewController(
            config: config,
            initialDirectory: currentDirectory,
            command: command
        )

        // The model isn't mutated and didAddPane isn't fired until the pane is
        // actually inserted into the view hierarchy below. A bail before then
        // would otherwise leave a pane (with a live shell) in the model but
        // absent from any split view — a ghost pane. On every failure path the
        // freshly spawned shell must be shut down.
        guard let newPaneView = newPane.view else {
            Log.error("⚠️ New pane has no view!", category: "panes")
            newPane.shutdown()
            return nil
        }

        let newContainer = wrapPaneInContainer(newPane, paneView: newPaneView)
        addPaneBorder(to: newPaneView, isActive: false)

        let needsVerticalSplit = (direction == .vertical) // top/bottom
        let parentIsVertical = parentSplit.isVertical

        Log.debug("🔧 needsVerticalSplit: \(needsVerticalSplit), parentIsVertical: \(parentIsVertical)", category: "panes")

        // Check if we need to create a nested split view
        if (needsVerticalSplit && parentIsVertical) || (!needsVerticalSplit && !parentIsVertical) {
            // Parent orientation doesn't match - need nested split
            Log.debug("🔧 Creating nested split view (nested will be vertical: \(!needsVerticalSplit))", category: "panes")

            let nestedSplit = createSplitView(isVertical: !needsVerticalSplit)
            nestedSplit.translatesAutoresizingMaskIntoConstraints = false

            // Find the index of the active pane's container in parent
            guard let containerIndex = parentSplit.arrangedSubviews.firstIndex(of: activePaneContainer) else {
                Log.error("⚠️ Cannot find container index", category: "panes")
                paneContainers.removeValue(forKey: newPane)
                newPane.shutdown()
                return nil
            }

            Log.debug("🔧 Container index in parent: \(containerIndex)", category: "panes")
            Log.debug("🔧 Parent before removal has \(parentSplit.arrangedSubviews.count) subviews", category: "panes")

            // Remove active pane container from parent
            parentSplit.removeArrangedSubview(activePaneContainer)
            activePaneContainer.removeFromSuperview()

            Log.debug("🔧 Parent after removal has \(parentSplit.arrangedSubviews.count) subviews", category: "panes")

            // Add nested split at the same position
            parentSplit.insertArrangedSubview(nestedSplit, at: containerIndex)

            Log.debug("🔧 Parent after inserting nested split has \(parentSplit.arrangedSubviews.count) subviews", category: "panes")

            // Add both panes to the nested split
            nestedSplit.addArrangedSubview(activePaneContainer)
            nestedSplit.addArrangedSubview(newContainer)

            Log.debug("🔧 Nested split now has \(nestedSplit.arrangedSubviews.count) subviews", category: "panes")
            Log.debug("🔧 Total pane count: \(panes.count)", category: "panes")

            // Set 50/50 split after layout
            DispatchQueue.main.async { [weak nestedSplit, weak parentSplit] in
                guard let split = nestedSplit else { return }
                SplitLayoutManager.setEvenSplit(in: split)

                // Also redistribute the parent split to ensure it maintains proper spacing
                if let parent = parentSplit {
                    Log.debug("🔧 Redistributing parent split after nested split creation", category: "panes")
                    SplitLayoutManager.distributeEvenly(in: parent)
                }
            }
        } else {
            // Parent orientation matches - add to existing split
            Log.debug("🔧 Adding to existing split view", category: "panes")

            guard let containerIndex = parentSplit.arrangedSubviews.firstIndex(of: activePaneContainer) else {
                Log.error("⚠️ Cannot find container index", category: "panes")
                paneContainers.removeValue(forKey: newPane)
                newPane.shutdown()
                return nil
            }

            Log.debug("🔧 Inserting at index \(containerIndex + 1)", category: "panes")

            // Insert new pane after the active pane
            parentSplit.insertArrangedSubview(newContainer, at: containerIndex + 1)

            Log.debug("🔧 Parent now has \(parentSplit.arrangedSubviews.count) subviews", category: "panes")

            // Redistribute space evenly after layout
            DispatchQueue.main.async { [weak parentSplit] in
                guard let split = parentSplit else { return }
                SplitLayoutManager.distributeEvenly(in: split)
            }
        }

        // Now that the pane is in the view hierarchy, commit it to the model and
        // notify the delegate — past every early-return guard, so there's no
        // window where the model holds a pane the view tree doesn't.
        panes.append(newPane)
        delegate?.paneSplitController(self, didAddPane: newPane, at: panes.count - 1)

        if focus {
            setActivePane(index: panes.count - 1)
        }
        updatePaneCloseButtons()
        return newPane
    }

    func closePane(index: Int) {
        guard index >= 0 && index < panes.count && panes.count > 1 else { return }

        let pane = panes[index]
        guard let container = paneContainers[pane],
              let parentSplit = findParentSplitView(for: pane) else {
            Log.error("⚠️ Cannot find pane container or parent split", category: "panes")
            return
        }

        // Remove from parent split
        parentSplit.removeArrangedSubview(container)
        container.removeFromSuperview()

        // Clean up tracking
        paneContainers.removeValue(forKey: pane)
        paneCloseButtons.removeValue(forKey: pane)
        panes.remove(at: index)
        delegate?.paneSplitController(self, didClosePane: pane, at: index)

        // Clean up nested split views if needed
        cleanupEmptySplitViews()
        updatePaneCloseButtons()

        // Adjust active pane index
        if activePaneIndex >= panes.count {
            activePaneIndex = panes.count - 1
        } else if activePaneIndex > index {
            activePaneIndex -= 1
        }

        setActivePane(index: activePaneIndex)
    }

    private func cleanupEmptySplitViews() {
        cleanupSplitViewRecursive(rootSplitView)
    }

    private func cleanupSplitViewRecursive(_ splitView: NSSplitView) {
        // First, recursively clean up any nested splits
        for subview in splitView.arrangedSubviews {
            if let nestedSplit = subview as? NSSplitView {
                cleanupSplitViewRecursive(nestedSplit)
            }
        }

        // If this split (not root) has only one child, unwrap it
        if splitView != rootSplitView && splitView.arrangedSubviews.count == 1 {
            guard let onlyChild = splitView.arrangedSubviews.first,
                  let grandparent = splitView.superview as? NSSplitView,
                  let splitIndex = grandparent.arrangedSubviews.firstIndex(of: splitView) else {
                return
            }

            Log.debug("🧹 Unwrapping single-child split view", category: "panes")

            // Remove the child from this split
            splitView.removeArrangedSubview(onlyChild)
            onlyChild.removeFromSuperview()

            // Remove this split from grandparent
            grandparent.removeArrangedSubview(splitView)
            splitView.removeFromSuperview()

            // Add the child directly to grandparent at the same position
            grandparent.insertArrangedSubview(onlyChild, at: splitIndex)

            // Remove from tracking
            allSplitViews.remove(splitView)
        }
    }

    @discardableResult
    func closeActivePane() -> Bool {
        guard panes.count > 1 else { return false }
        closePane(index: activePaneIndex)
        return true
    }

    @discardableResult
    func closePane(id: UUID) -> Bool {
        guard let index = panes.firstIndex(where: { $0.id == id }), panes.count > 1 else {
            return false
        }
        closePane(index: index)
        return true
    }

    @discardableResult
    func focusPane(id: UUID) -> Bool {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return false }
        setActivePane(index: index)
        return true
    }

    func setActivePane(index: Int) {
        guard index >= 0 && index < panes.count else {
            Log.error("⚠️ setActivePane: invalid index \(index), pane count: \(panes.count)", category: "panes")
            return
        }

        Log.debug("🎯 setActivePane: changing from \(activePaneIndex) to \(index)", category: "panes")

        // Unfocus previous pane
        if activePaneIndex < panes.count {
            panes[activePaneIndex].unfocus()
            if let paneView = panes[activePaneIndex].view {
                Log.debug("🎯 Removing active border from pane \(activePaneIndex)", category: "panes")
                addPaneBorder(to: paneView, isActive: false)
            }
        }

        // Focus new pane
        activePaneIndex = index
        panes[activePaneIndex].focus()
        if let paneView = panes[activePaneIndex].view {
            Log.debug("🎯 Adding active border to pane \(index)", category: "panes")
            addPaneBorder(to: paneView, isActive: true)
        }

        delegate?.paneSplitController(self, didActivatePane: panes[activePaneIndex], at: activePaneIndex)
    }

    func focusNextPane() {
        guard panes.count > 1 else {
            Log.debug("⌨️ focusNextPane: only 1 pane, skipping", category: "panes")
            return
        }
        let nextIndex = (activePaneIndex + 1) % panes.count
        Log.debug("⌨️ focusNextPane: moving from \(activePaneIndex) to \(nextIndex)", category: "panes")
        setActivePane(index: nextIndex)
    }

    func focusPreviousPane() {
        guard panes.count > 1 else {
            Log.debug("⌨️ focusPreviousPane: only 1 pane, skipping", category: "panes")
            return
        }
        let prevIndex = (activePaneIndex - 1 + panes.count) % panes.count
        Log.debug("⌨️ focusPreviousPane: moving from \(activePaneIndex) to \(prevIndex)", category: "panes")
        setActivePane(index: prevIndex)
    }

    private func addPaneBorder(to view: NSView, isActive: Bool) {
        // Remove existing border
        let existingBorders = view.subviews.filter { $0.identifier?.rawValue == "paneBorder" }
        Log.debug("🖼️ addPaneBorder: removing \(existingBorders.count) existing borders, isActive: \(isActive)", category: "panes")
        existingBorders.forEach { $0.removeFromSuperview() }

        // Only add border if there are multiple panes
        guard panes.count > 1 else {
            Log.debug("🖼️ Only one pane, skipping border", category: "panes")
            return
        }

        // Add new border
        let borderView = NSView()
        borderView.identifier = NSUserInterfaceItemIdentifier("paneBorder")
        borderView.wantsLayer = true

        let borderColor = isActive ?
            AppTheme.accent :                 // Blue for active
            Theme.shared.palette.surface0     // Dim for inactive

        borderView.layer?.borderColor = borderColor.cgColor
        borderView.layer?.borderWidth = isActive ? 2 : 1
        borderView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(borderView)
        Log.debug("🖼️ Added \(isActive ? "active" : "inactive") border to view", category: "panes")

        NSLayoutConstraint.activate([
            borderView.topAnchor.constraint(equalTo: view.topAnchor),
            borderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            borderView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Send border to back
        view.addSubview(borderView, positioned: .below, relativeTo: nil)
    }

    func getActivePaneTerminal() -> TerminalViewController? {
        guard activePaneIndex >= 0 && activePaneIndex < panes.count else { return nil }
        return panes[activePaneIndex].terminalViewController
    }

    var paneCount: Int {
        return panes.count
    }

    var activePane: PaneModel? {
        guard activePaneIndex >= 0 && activePaneIndex < panes.count else { return nil }
        return panes[activePaneIndex]
    }

    var activePaneID: UUID? {
        activePane?.id
    }

    func rebuildSplitView(for tab: TabModel) {
        Log.debug("🔧 rebuildSplitView called with \(tab.panes.count) panes", category: "panes")

        // Clear all existing content
        for arrangedSubview in rootSplitView.arrangedSubviews {
            rootSplitView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        // Clear all nested split views
        allSplitViews.removeAll()
        allSplitViews.insert(rootSplitView)
        paneContainers.removeAll()
        paneCloseButtons.removeAll()

        // Update panes reference
        self.panes = tab.panes
        self.activePaneIndex = tab.activePaneIndex

        // Add all pane views to root split view in a flat structure
        for (index, pane) in panes.enumerated() {
            if let paneView = pane.view {
                Log.debug("🔧 Adding pane \(index) (\(pane.paneType)) to split view", category: "panes")
                let container = wrapPaneInContainer(pane, paneView: paneView)
                rootSplitView.addArrangedSubview(container)
                addPaneBorder(to: paneView, isActive: index == activePaneIndex)
            } else {
                Log.error("⚠️ Pane \(index) (\(pane.paneType)) has no view!", category: "panes")
            }
        }

        Log.debug("🔧 Split view now has \(rootSplitView.arrangedSubviews.count) arranged subviews", category: "panes")
        updatePaneCloseButtons()

        // Distribute evenly
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            SplitLayoutManager.distributeEvenly(in: self.rootSplitView)
        }

        // Focus the active pane
        if activePaneIndex < panes.count {
            panes[activePaneIndex].focus()
        }
    }

    /// Appends `pane` as a new arranged subview of the root split, leaving any
    /// existing nested split subtrees untouched — so opening an editor beside a
    /// 2×2 grid keeps the grid intact instead of flattening it (unlike
    /// rebuildSplitView, which discards the nested tree). The caller is
    /// responsible for having already appended `pane` to the tab's model.
    func addPane(_ pane: PaneModel) {
        guard let paneView = pane.view else {
            Log.error("⚠️ addPane: pane (\(pane.paneType)) has no view!", category: "panes")
            return
        }

        panes.append(pane)
        let container = wrapPaneInContainer(pane, paneView: paneView)
        rootSplitView.addArrangedSubview(container)
        updatePaneCloseButtons()
        // setActivePane paints the active border on the new pane and clears the
        // old one; calling addPaneBorder(isActive:false) afterward would wrongly
        // overwrite that with an inactive border, so let setActivePane own it.
        setActivePane(index: panes.count - 1)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            SplitLayoutManager.distributeEvenly(in: self.rootSplitView)
        }
    }
}

// MARK: - ClickableContainerView
class ClickableContainerView: NSView, NSGestureRecognizerDelegate {
    var onMouseDown: (() -> Void)?
    private var clickGestureRecognizer: NSClickGestureRecognizer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGestureRecognizer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestureRecognizer()
    }

    private func setupGestureRecognizer() {
        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        clickRecognizer.delaysPrimaryMouseButtonEvents = false
        clickRecognizer.delegate = self
        self.addGestureRecognizer(clickRecognizer)
        self.clickGestureRecognizer = clickRecognizer
    }

    // Activation runs solely through the click gesture recognizer. It fires even
    // when the click lands on the pane's content subview (which fills the
    // container and would otherwise swallow mouseDown), so a separate mouseDown
    // override only double-fired setActivePane without covering any new case.
    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        onMouseDown?()
    }

    // The recognizer spans the whole container, so it also sees clicks that
    // land on the pane's close button. It recognizes on mouse-up and AppKit
    // then withholds that mouse-up from the button, so the X highlights but
    // its action never fires — the click only re-activates the pane. Bow out
    // when the click starts on the button; activation still fires for clicks
    // anywhere else, and closing a pane activates it first anyway.
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard let superview else { return true }
        var view = hitTest(superview.convert(event.locationInWindow, from: nil))
        while let current = view, current !== self {
            if current is PaneCloseButton { return false }
            view = current.superview
        }
        return true
    }
}

final class PaneCloseButton: NSButton {
    weak var pane: PaneModel?

    init() {
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")
        imagePosition = .imageOnly
        bezelStyle = .rounded
        isBordered = false
        contentTintColor = AppTheme.primaryText
        toolTip = "Close Pane"
        wantsLayer = true
        layer?.backgroundColor = Theme.shared.palette.surface0.withAlphaComponent(0.9).cgColor
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The terminal underneath claims an I-beam cursor for its whole surface;
    // without an explicit rect the X inherits it and reads as dead UI.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - NSSplitViewDelegate
extension PaneSplitController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return false // Don't allow collapsing panes
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        return true // Allow all panes to resize
    }

    /// Minimum width/height for a single pane.
    static let minPaneSize: CGFloat = 100

    /// The per-pane reservation, scaled down when the split is too narrow to
    /// give every pane the full minimum. Without the scaling, min (leading ×
    /// 100) can exceed max (total − trailing × 100) for any split narrower
    /// than paneCount × 100pt, and NSSplitView's behavior on an inverted
    /// min/max range is undefined.
    private func paneReservation(in splitView: NSSplitView) -> CGFloat {
        let totalSize = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let paneCount = max(1, splitView.arrangedSubviews.count)
        return min(Self.minPaneSize, totalSize / CGFloat(paneCount))
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Reserve minPaneSize for every pane on the leading side of this divider,
        // not just one — otherwise dragging a later divider left can squeeze the
        // earlier panes below the minimum.
        let leadingPanes = CGFloat(dividerIndex + 1)
        return max(proposedMinimumPosition, leadingPanes * paneReservation(in: splitView))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let totalSize = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        // Reserve minPaneSize for every pane on the trailing side of this divider.
        // With 3+ panes, reserving for only one lets divider 0 crush the rest.
        let trailingPanes = CGFloat(splitView.arrangedSubviews.count - (dividerIndex + 1))
        return min(proposedMaximumPosition, totalSize - trailingPanes * paneReservation(in: splitView))
    }
}

import Cocoa

protocol TabBarDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelectTab index: Int)
    func tabBar(_ tabBar: TabBarView, didCloseTab index: Int)
    func tabBar(_ tabBar: TabBarView, didMoveTab fromIndex: Int, to toIndex: Int)
    func tabBar(_ tabBar: TabBarView, didRenameTab index: Int, to title: String?)
}

/// Tab buttons forward mouse-downs to the tab bar so it can distinguish a
/// click (select) from a horizontal drag (reorder).
private final class TabButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        (superview as? TabBarView)?.handleTabMouseDown(event, button: self)
    }
}

class TabBarView: NSView {
    weak var delegate: TabBarDelegate?

    private var tabs: [TabModel] = []
    private var activeTabIndex: Int = 0
    private var tabButtons: [NSButton] = []
    private var closeButtons: [NSButton] = []
    private var activeIndicators: [NSView] = []
    // Set on the main actor; invalidated in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var pulseTimer: Timer?
    private var workingPulseIsBright = false

    private let tabHeight: CGFloat = 32
    private let tabMinWidth: CGFloat = 120
    private let tabMaxWidth: CGFloat = 200
    private let closeButtonSize: CGFloat = 16
    private let tabSpacing: CGFloat = 1
    private let tabHorizontalPadding: CGFloat = 12
    private var lastTabWidth: CGFloat = 120

    /// The button being slid in an in-progress drag-reorder. Title refreshes
    /// from working agents dirty layout many times a second, and a layout pass
    /// snaps every button back to its slot — which froze the drag in place.
    /// repositionTabButtons skips this button while the gesture runs, and lays
    /// the others out at their preview slots (see previewSlot) so mid-drag
    /// refreshes reinforce the shifted arrangement instead of undoing it.
    private var draggingButton: NSButton?
    private var dragSourceIndex: Int?
    private var dragPreviewTarget: Int?
    /// The dragged tab's close button, hidden for the duration of the gesture
    /// (it would otherwise sit stranded at the origin slot).
    private var draggedCloseButton: NSButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        observeThemeChanges()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
        observeThemeChanges()
    }

    deinit {
        pulseTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func observeThemeChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .themeDidChange,
            object: nil
        )
    }

    @objc private func themeDidChange() {
        applyTheme()
        if !tabs.isEmpty {
            rebuildTabButtons()
        }
    }

    private func setupView() {
        wantsLayer = true
        applyTheme()
    }

    private func applyTheme() {
        applyBackground(enableBlur: true) // Default to blur enabled
    }

    func applyBackground(enableBlur: Bool) {
        let bgColor = Theme.shared.current.windowBackground
        // Tab bar is always opaque (no blur)
        layer?.backgroundColor = bgColor.cgColor
        layer?.isOpaque = true
    }

    /// Runs the working-tab "breathing" animation only while a tab is actually
    /// working. The old design ran a 2Hz timer for the whole app lifetime even
    /// with nothing working; now it's started on demand and stops itself once no
    /// working tab remains.
    private func ensurePulseTimer() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
            guard let self = self else { return }

            let workingIndices = self.tabs.indices.filter { self.tabs[$0].agentState == .working }
            guard !workingIndices.isEmpty else {
                // Nothing left to pulse — render the final (non-bright) state and
                // stop the timer until a tab starts working again.
                self.workingPulseIsBright = false
                self.pulseTimer?.invalidate()
                self.pulseTimer = nil
                return
            }

            self.workingPulseIsBright.toggle()
            // Refresh only the titles of working tabs; rebuilding every
            // button twice a second thrashes the view hierarchy.
            for index in workingIndices where index < self.tabButtons.count {
                self.tabButtons[index].attributedTitle = self.makeAttributedTitle(for: self.tabs[index])
            }
            }
        }
    }

    func updateTabs(_ tabs: [TabModel], activeIndex: Int) {
        // Pane titles, command status and agent state all push updates here, many
        // times a second under an active agent. Recreating the buttons each time
        // cancels an in-progress click (see handleTabMouseDown), so only a change
        // in tab count — which needs new buttons anyway — may rebuild.
        let countUnchanged = tabs.count == self.tabs.count && tabs.count == tabButtons.count
        self.tabs = tabs
        self.activeTabIndex = activeIndex
        if countUnchanged {
            refreshTabButtons()
        } else {
            rebuildTabButtons()
        }
        // Start pulsing when something is working; the timer stops itself when
        // nothing is.
        if tabs.contains(where: { $0.agentState == .working }) {
            ensurePulseTimer()
        }
    }

    /// Updates the existing buttons in place — titles, colors, tooltips, tags and
    /// the active indicator — without touching the view hierarchy. Callers must
    /// have verified the tab count is unchanged.
    private func refreshTabButtons() {
        let theme = Theme.shared.current

        for (index, tab) in tabs.enumerated() {
            let tabButton = tabButtons[index]
            tabButton.attributedTitle = makeAttributedTitle(for: tab)
            if let commandTooltip = tab.lastCommandTooltip {
                tabButton.toolTip = "\(tab.title)\n\(commandTooltip)"
            } else {
                tabButton.toolTip = tab.title
            }
            tabButton.tag = index

            if index == activeTabIndex {
                tabButton.layer?.backgroundColor = theme.activeTabBackground.cgColor
                tabButton.contentTintColor = theme.activeTabText
            } else {
                tabButton.layer?.backgroundColor = theme.controlBackground.cgColor
                tabButton.contentTintColor = theme.inactiveTabText
            }

            if index < closeButtons.count {
                closeButtons[index].tag = index
                closeButtons[index].contentTintColor = theme.secondaryText
            }
        }

        refreshActiveIndicator()
    }

    /// Moves (or creates) the single active-tab indicator to sit under whichever
    /// tab is active now. Frames come from the buttons themselves so this stays
    /// correct mid-drag, when a button is off its layout position.
    private func refreshActiveIndicator() {
        guard activeTabIndex >= 0, activeTabIndex < tabButtons.count else {
            activeIndicators.forEach { $0.removeFromSuperview() }
            activeIndicators.removeAll()
            return
        }

        let theme = Theme.shared.current
        let buttonFrame = tabButtons[activeTabIndex].frame
        let indicatorFrame = NSRect(x: buttonFrame.origin.x, y: 0, width: buttonFrame.width, height: 2)

        if let indicator = activeIndicators.first {
            indicator.frame = indicatorFrame
            indicator.layer?.backgroundColor = theme.activeTabBorder.cgColor
            return
        }

        let indicator = NSView(frame: indicatorFrame)
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = theme.activeTabBorder.cgColor
        indicator.layer?.cornerRadius = 1
        addSubview(indicator)
        activeIndicators.append(indicator)
    }

    private func rebuildTabButtons() {
        // A rebuild discards the buttons a drag gesture is tracking; drop the
        // gesture state with them so preview-slot math doesn't outlive it.
        clearDragState()

        // Remove existing buttons
        tabButtons.forEach { $0.removeFromSuperview() }
        closeButtons.forEach { $0.removeFromSuperview() }
        activeIndicators.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        closeButtons.removeAll()
        activeIndicators.removeAll()

        // Calculate tab width across the full bar (there is no new-tab button).
        let availableWidth = bounds.width
        let tabCount = CGFloat(tabs.count)
        var tabWidth = tabCount > 0 ? availableWidth / tabCount : tabMinWidth
        tabWidth = max(tabMinWidth, min(tabMaxWidth, tabWidth))
        lastTabWidth = tabWidth

        // Create tab buttons
        for (index, tab) in tabs.enumerated() {
            createTabButton(for: tab, at: index, width: tabWidth)
        }
    }

    private func createTabButton(for tab: TabModel, at index: Int, width: CGFloat) {
        let x = CGFloat(index) * (width + tabSpacing)
        let tabRect = NSRect(x: x, y: 0, width: width, height: tabHeight)

        // Tab button
        let tabButton = TabButton(frame: tabRect)
        tabButton.cell = TabButtonCell(textLeadingPadding: tabHorizontalPadding, textTrailingPadding: closeButtonSize + 18)

        let theme = Theme.shared.current
        tabButton.attributedTitle = makeAttributedTitle(for: tab)
        if let commandTooltip = tab.lastCommandTooltip {
            tabButton.toolTip = "\(tab.title)\n\(commandTooltip)"
        } else {
            tabButton.toolTip = tab.title
        }
        tabButton.bezelStyle = .regularSquare
        tabButton.isBordered = false
        tabButton.cell?.lineBreakMode = .byTruncatingMiddle
        tabButton.cell?.truncatesLastVisibleLine = true
        tabButton.cell?.wraps = false
        tabButton.tag = index

        // Style based on active state
        tabButton.wantsLayer = true
        tabButton.layer?.cornerRadius = 5
        tabButton.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // Round top corners only

        if index == activeTabIndex {
            // Active tab
            tabButton.layer?.backgroundColor = theme.activeTabBackground.cgColor
            tabButton.contentTintColor = theme.activeTabText
            tabButton.layer?.borderWidth = 0
        } else {
            // Inactive tab
            tabButton.layer?.backgroundColor = theme.controlBackground.cgColor
            tabButton.contentTintColor = theme.inactiveTabText
            tabButton.layer?.borderWidth = 0
        }

        // Close button
        let closeButtonX = x + width - closeButtonSize - 8
        let closeButtonY = (tabHeight - closeButtonSize) / 2
        let closeRect = NSRect(x: closeButtonX, y: closeButtonY,
                              width: closeButtonSize, height: closeButtonSize)

        let closeButton = NSButton(frame: closeRect)
        closeButton.title = "×"
        closeButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeButtonClicked(_:))
        closeButton.tag = index
        closeButton.contentTintColor = Theme.shared.current.secondaryText

        addSubview(tabButton)
        addSubview(closeButton)

        tabButtons.append(tabButton)
        closeButtons.append(closeButton)

        if index == activeTabIndex {
            let indicator = NSView(frame: NSRect(x: x, y: 0, width: width, height: 2))
            indicator.wantsLayer = true
            indicator.layer?.backgroundColor = theme.activeTabBorder.cgColor
            indicator.layer?.cornerRadius = 1
            addSubview(indicator)
            activeIndicators.append(indicator)
        }
    }

    private func makeAttributedTitle(for tab: TabModel) -> NSAttributedString {
        // Build title with attributed string for proper icon/color rendering
        let attributedTitle = NSMutableAttributedString()
        let titleParagraphStyle = NSMutableParagraphStyle()
        titleParagraphStyle.lineBreakMode = .byTruncatingMiddle
        titleParagraphStyle.alignment = .center

        // Agent state indicator
        let theme = Theme.shared.current
        switch tab.agentState {
        case .idle:
            break // No indicator
        case .working:
            appendAgentIndicator(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Agent Working",
                color: workingAgentIndicatorColor,
                to: attributedTitle
            )
        case .ready:
            appendAgentIndicator(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Agent Waiting",
                color: theme.green,
                to: attributedTitle
            )
        case .done:
            appendAgentIndicator(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Agent Done",
                color: theme.blue,
                to: attributedTitle
            )
        }

        // Failed-command indicator (from shell integration)
        if tab.lastCommandFailed {
            let failedText = NSAttributedString(string: "✗ ", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: theme.red
            ])
            attributedTitle.append(failedText)
        }

        // Dirty indicator
        if tab.isDirty {
            let dirtyText = NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 9)
            ])
            attributedTitle.append(dirtyText)
        }

        // Worktree marker: a muted branch glyph when the active pane's directory
        // is a linked git worktree, so worktree tabs read differently from the
        // primary checkout at a glance.
        if tab.activePane?.isInWorktree == true {
            appendAgentIndicator(
                systemSymbolName: "arrow.triangle.branch",
                accessibilityDescription: "In Git Worktree",
                color: AppTheme.mutedText,
                to: attributedTitle
            )
        }

        // Tab title
        let titleText = NSAttributedString(string: tab.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .paragraphStyle: titleParagraphStyle
        ])
        attributedTitle.append(titleText)

        return attributedTitle
    }

    private func appendAgentIndicator(
        systemSymbolName: String,
        accessibilityDescription: String,
        color: NSColor,
        to attributedTitle: NSMutableAttributedString
    ) {
        guard let image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: accessibilityDescription) else {
            attributedTitle.append(NSAttributedString(string: "* "))
            return
        }

        let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let coloredImage = image.withSymbolConfiguration(config) ?? image

        let attachment = NSTextAttachment()
        attachment.image = coloredImage
        attachment.bounds = NSRect(x: 0, y: -1, width: 8, height: 8)
        attributedTitle.append(NSAttributedString(attachment: attachment))
        attributedTitle.append(NSAttributedString(string: " "))
    }

    private var workingAgentIndicatorColor: NSColor {
        if workingPulseIsBright {
            return AppTheme.warning
        }

        return AppTheme.warning.blended(withFraction: 0.3, of: .black) ?? AppTheme.warning
    }

    @objc private func closeButtonClicked(_ sender: NSButton) {
        delegate?.tabBar(self, didCloseTab: sender.tag)
    }

    // MARK: - Click / drag-reorder tracking

    /// Runs a synchronous tracking loop: a mouse-up without much horizontal
    /// movement selects the tab; dragging slides the button and reorders on
    /// release.
    fileprivate func handleTabMouseDown(_ event: NSEvent, button: NSButton) {
        let index = button.tag
        let startPoint = convert(event.locationInWindow, from: nil)
        let originalX = button.frame.origin.x
        var dragging = false
        defer { clearDragState() }

        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                // Tracking aborted: snap everything back to layout positions.
                rebuildTabButtons()
                return
            }

            // The tab bar can still be rebuilt mid-gesture (a tab opening or
            // closing on the main queue during event tracking), which leaves the
            // captured button detached from the current layout.
            let buttonIsLive = !tabButtons.isEmpty
                && (button === tabButtons[safe: index] || button.superview === self)

            let point = convert(next.locationInWindow, from: nil)

            if next.type == .leftMouseUp {
                clearDragState()
                if dragging {
                    // A reorder can't be resolved against a stale button — the
                    // frame it was slid to no longer means anything.
                    guard buttonIsLive, index < tabs.count else {
                        rebuildTabButtons()
                        return
                    }
                    let target = dragTargetIndex(for: button)
                    if target != index {
                        delegate?.tabBar(self, didMoveTab: index, to: target)
                        // The delegate restyled the buttons for the new order;
                        // snap frames to match (the dragged button is still at
                        // its drop position).
                        repositionTabButtons()
                    } else {
                        rebuildTabButtons()
                    }
                } else if index < tabs.count {
                    // A plain click still selects the tab it started on, even if
                    // a rebuild invalidated the button underneath: dropping it
                    // silently made the user click twice.
                    delegate?.tabBar(self, didSelectTab: index)
                }
                return
            }

            guard buttonIsLive, index < tabs.count else {
                rebuildTabButtons()
                return
            }

            let deltaX = point.x - startPoint.x
            if dragging || abs(deltaX) > 6 {
                if !dragging {
                    dragging = true
                    draggingButton = button
                    dragSourceIndex = index
                    dragPreviewTarget = index
                    draggedCloseButton = closeButtons[safe: index]
                    draggedCloseButton?.isHidden = true
                    // Keep the dragged tab above its siblings while it slides.
                    button.removeFromSuperview()
                    addSubview(button)
                }
                let maxX = bounds.width - button.frame.width
                button.frame.origin.x = min(max(0, originalX + deltaX), max(0, maxX))

                // Live shift: as the drag crosses into a new slot, slide the
                // other tabs to where they would land if dropped here.
                let target = dragTargetIndex(for: button)
                if target != dragPreviewTarget {
                    dragPreviewTarget = target
                    applyDragPreviewShift()
                }
                // Keep the active-tab underline glued to its button, which may
                // be the one sliding under the cursor.
                refreshActiveIndicator()
            }
        }
    }

    private func dragTargetIndex(for button: NSButton) -> Int {
        guard !tabs.isEmpty else { return 0 }
        let slot = Int(round(button.frame.origin.x / (lastTabWidth + tabSpacing)))
        return min(max(0, slot), tabs.count - 1)
    }

    /// The slot a button at `index` (array order) should display at, given the
    /// in-flight drag: tabs between the drag's source and its current hover
    /// target shift one slot toward the vacated side. Identity outside a drag.
    private func previewSlot(for index: Int) -> Int {
        guard let source = dragSourceIndex, let target = dragPreviewTarget else { return index }
        if index == source { return target }
        if source < target && index > source && index <= target { return index - 1 }
        if target < source && index >= target && index < source { return index + 1 }
        return index
    }

    /// Animates every non-dragged tab (and its close button) to its preview
    /// slot for the current hover target.
    private func applyDragPreviewShift() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (index, button) in tabButtons.enumerated() where button !== draggingButton {
                let x = CGFloat(previewSlot(for: index)) * (lastTabWidth + tabSpacing)
                var frame = button.frame
                frame.origin.x = x
                button.animator().frame = frame
                if let closeButton = closeButtons[safe: index] {
                    var closeFrame = closeButton.frame
                    closeFrame.origin.x = x + frame.width - closeButtonSize - 8
                    closeButton.animator().frame = closeFrame
                }
            }
        }
    }

    private func clearDragState() {
        draggingButton = nil
        dragSourceIndex = nil
        dragPreviewTarget = nil
        draggedCloseButton?.isHidden = false
        draggedCloseButton = nil
    }

    // MARK: - Right-click menu (rename)

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let button = tabButtons.first(where: { $0.frame.contains(point) }) else {
            super.rightMouseDown(with: event)
            return
        }

        let menu = NSMenu()
        let renameItem = NSMenuItem(title: "Rename Tab…", action: #selector(renameTabMenuClicked(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.tag = button.tag
        menu.addItem(renameItem)

        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeTabMenuClicked(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.tag = button.tag
        menu.addItem(closeItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameTabMenuClicked(_ sender: NSMenuItem) {
        let index = sender.tag
        guard let tab = tabs[safe: index] else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to restore the automatic title."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.customTitle ?? ""
        field.placeholderString = tab.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        delegate?.tabBar(self, didRenameTab: index, to: name.isEmpty ? nil : name)
    }

    @objc private func closeTabMenuClicked(_ sender: NSMenuItem) {
        delegate?.tabBar(self, didCloseTab: sender.tag)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check if clicking on empty area (not on a tab or close button)
        let hitTab = tabButtons.first { $0.frame.contains(point) }
        let hitClose = closeButtons.first { $0.frame.contains(point) }

        if hitTab == nil && hitClose == nil {
            if event.clickCount == 2 {
                window?.performConfiguredTitlebarDoubleClickAction()
                return
            }

            // Clicking on empty tab bar area - allow window dragging
            window?.performDrag(with: event)
            return
        }

        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        // Only move existing buttons here. Rebuilding (remove/add subviews)
        // during a layout pass dirties constraints and re-enters layout,
        // which AppKit eventually kills with an NSInternalInconsistencyException
        // ("too many Update Constraints in Window passes").
        if !tabs.isEmpty {
            repositionTabButtons()
        }
    }

    /// Recomputes tab widths for the current bounds and updates frames of the
    /// existing buttons without touching the view hierarchy.
    private func repositionTabButtons() {
        let availableWidth = bounds.width
        let tabCount = CGFloat(tabs.count)
        var tabWidth = tabCount > 0 ? availableWidth / tabCount : tabMinWidth
        tabWidth = max(tabMinWidth, min(tabMaxWidth, tabWidth))
        lastTabWidth = tabWidth

        for (index, button) in tabButtons.enumerated() {
            let x = CGFloat(previewSlot(for: index)) * (tabWidth + tabSpacing)
            if button !== draggingButton {
                button.frame = NSRect(x: x, y: 0, width: tabWidth, height: tabHeight)
            }
            if index < closeButtons.count {
                closeButtons[index].frame = NSRect(
                    x: x + tabWidth - closeButtonSize - 8,
                    y: (tabHeight - closeButtonSize) / 2,
                    width: closeButtonSize,
                    height: closeButtonSize
                )
            }
        }

        // Frames may be off their array slots mid-drag; let the indicator
        // follow the active button wherever it currently sits.
        refreshActiveIndicator()
    }
}

private final class TabButtonCell: NSButtonCell {
    private let textLeadingPadding: CGFloat
    private let textTrailingPadding: CGFloat

    init(textLeadingPadding: CGFloat, textTrailingPadding: CGFloat) {
        self.textLeadingPadding = textLeadingPadding
        self.textTrailingPadding = textTrailingPadding
        super.init(textCell: "")
        lineBreakMode = .byTruncatingMiddle
        truncatesLastVisibleLine = true
        wraps = false
    }

    required init(coder: NSCoder) {
        self.textLeadingPadding = 12
        self.textTrailingPadding = 34
        super.init(coder: coder)
        lineBreakMode = .byTruncatingMiddle
        truncatesLastVisibleLine = true
        wraps = false
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var titleRect = super.titleRect(forBounds: rect)
        titleRect.origin.x = rect.minX + textLeadingPadding
        titleRect.size.width = max(0, rect.width - textLeadingPadding - textTrailingPadding)
        titleRect.size.height = rect.height
        return titleRect
    }
}

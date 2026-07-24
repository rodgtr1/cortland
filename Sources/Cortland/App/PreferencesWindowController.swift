import Cocoa
import CortlandProInterface
@preconcurrency import UserNotifications

class PreferencesWindowController: NSWindowController {
    private var config: Config
    private weak var mainWindowController: MainWindowController?

    // UI Elements
    private var contentView: NSView!
    private var tabViewController: PreferencesTabViewController!
    private var themeObserver: ThemeObserver?

    /// One size for every pane. Each tab's view controller reports this as its
    /// preferredContentSize, so switching tabs never resizes the window — the
    /// old NSTabView let wide panes (Approvals, Notifications) grow the window
    /// on selection while seven top tabs truncated their labels.
    static let paneSize = NSSize(width: 560, height: 500)
    static let selectedTabDefaultsKey = "PreferencesSelectedTab"

    // General Tab
    private var opacitySlider: NSSlider!
    private var opacityLabel: NSTextField!
    private var blurCheckbox: NSButton!
    private var restoreSessionCheckbox: NSButton!
    private var confirmCloseCheckbox: NSButton!
    private var rawConfigButton: NSButton!

    // Terminal Tab
    private var fontFamilyPopup: NSPopUpButton!
    private var fontSizeSlider: NSSlider!
    private var fontSizeLabel: NSTextField!
    private var boldIsBrightCheckbox: NSButton!
    private var paddingSlider: NSSlider!
    private var paddingLabel: NSTextField!
    private var shellIntegrationStatusLabel: NSTextField!
    private var shellIntegrationButton: NSButton!

    // Appearance Tab
    private var themePopup: NSPopUpButton!

    // Editor Tab
    private var fileOpenModePopup: NSPopUpButton!
    private var editorFontFamilyPopup: NSPopUpButton!
    private var editorFontSizeSlider: NSSlider!
    private var editorFontSizeLabel: NSTextField!
    private var wordWrapCheckbox: NSButton!
    private var showHiddenFilesCheckbox: NSButton!
    private var agentStatusLabels: [AgentIntegrationInstaller.AgentID: NSTextField] = [:]
    private var agentInstallButtons: [AgentIntegrationInstaller.AgentID: NSButton] = [:]

    // Approvals Tab
    private var approvalModePopup: NSPopUpButton!
    /// The three desk rules. Nil in a build with no approval desk, where they
    /// would be settings that quietly govern nothing — the config keys still
    /// round-trip, they just have no reader. See `docs/pro-split.md`.
    private var autoAllowField: NSTextField?
    private var alwaysAskField: NSTextField?
    private var worktreeAutoApproveCheckbox: NSButton?

    // Extras Tab
    private var arcadeEnabledCheckbox: NSButton!

    // Notifications Tab
    private var notificationsEnabledCheckbox: NSButton!
    private var notifyNeedsInputCheckbox: NSButton!
    private var notifyFinishedCheckbox: NSButton!
    private var notifyCommandFailedCheckbox: NSButton!
    private var notifyLongCommandCheckbox: NSButton!
    private var longCommandThresholdField: NSTextField!
    private var backgroundGraceField: NSTextField!

    init(config: Config, mainWindowController: MainWindowController? = nil) {
        self.config = config
        self.mainWindowController = mainWindowController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        setupWindow()
        setupUI()
        loadCurrentSettings()

        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
    }

    /// Re-theme the Preferences window itself when the theme changes (e.g. the
    /// user picks a theme from the Appearance tab while this window is open).
    private func applyThemeColors() {
        window?.backgroundColor = AppTheme.windowBackground
        contentView?.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        // Default every label to primary, then restore the secondary value
        // labels. Recolor per pane (not just contentView) because the tab
        // controller detaches unselected panes from the view hierarchy.
        for item in tabViewController.tabViewItems {
            guard let paneView = item.viewController?.view else { continue }
            paneView.wantsLayer = true
            paneView.layer?.backgroundColor = AppTheme.windowBackground.cgColor
            repaintBackgrounds(in: paneView)
            recolorLabels(in: paneView, color: AppTheme.primaryText)
        }
        [opacityLabel, fontSizeLabel, editorFontSizeLabel, shellIntegrationStatusLabel].forEach {
            $0?.textColor = AppTheme.secondaryText
        }
        agentStatusLabels.values.forEach { $0.textColor = AppTheme.secondaryText }
    }

    /// Repaint the container backgrounds a live theme switch would otherwise
    /// miss. Each pane is a scroll view whose own `backgroundColor`, clip view,
    /// and flipped document view were coloured once at setup — recolouring only
    /// the pane's outer layer left that scrolled area showing the old theme (a
    /// white body under a dark toolbar). Walks the whole subtree so nested
    /// scroll views repaint too.
    private func repaintBackgrounds(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.backgroundColor = AppTheme.windowBackground
            scroll.layer?.backgroundColor = AppTheme.windowBackground.cgColor
            scroll.contentView.backgroundColor = AppTheme.windowBackground
            scroll.documentView?.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        }
        for sub in view.subviews {
            repaintBackgrounds(in: sub)
        }
    }

    private func recolorLabels(in view: NSView?, color: NSColor) {
        guard let view else { return }
        for sub in view.subviews {
            if let label = sub as? NSTextField, !label.isEditable, !label.drawsBackground {
                label.textColor = color
            }
            recolorLabels(in: sub, color: color)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        guard let window = window else { return }

        window.title = "Preferences"
        window.delegate = self
        window.titlebarAppearsTransparent = false
        // Fixed width so the toolbar tabs and panes always fit; only the
        // height resizes (taller content scrolls either way).
        window.minSize = NSSize(width: Self.paneSize.width, height: 420)
        window.maxSize = NSSize(width: Self.paneSize.width, height: 1200)
        window.isMovableByWindowBackground = true
        window.backgroundColor = AppTheme.windowBackground
    }

    private func setupUI() {
        guard let window = window else { return }

        setupTabView()
        setupGeneralTab()
        setupTerminalTab()
        setupEditorTab()
        setupAgentsTab()
        setupApprovalsTab()
        setupNotificationsTab()
        setupAppearanceTab()
        setupExtrasTab()

        window.contentViewController = tabViewController
        contentView = tabViewController.view
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = AppTheme.windowBackground.cgColor

        // Reopen on the tab the user last had selected, then size and center
        // (contentViewController assignment above may have resized the frame).
        if let saved = UserDefaults.standard.string(forKey: Self.selectedTabDefaultsKey),
           let index = tabViewController.tabViewItems.firstIndex(where: { $0.identifier as? String == saved }) {
            tabViewController.selectedTabViewItemIndex = index
        }
        window.setContentSize(Self.paneSize)
        window.center()
        window.title = tabViewController.tabViewItems[safe: tabViewController.selectedTabViewItemIndex]?.label ?? "Preferences"
    }

    private func setupTabView() {
        tabViewController = PreferencesTabViewController()
        // Toolbar-style tabs (icon + label, like System Settings): they never
        // truncate the way seven-plus segmented top tabs did at this width.
        tabViewController.tabStyle = .toolbar
    }

    /// A themed pane whose content scrolls when it's taller than the tab area.
    /// Returns the scroll view (which becomes the tab's view) and the flipped
    /// document view the form builder lays out into. The document view is pinned
    /// to the scroll view's content width so it only ever scrolls vertically; its
    /// height comes from the form's `finish()` bottom constraint, so tall panes
    /// (e.g. Approvals, Notifications) become reachable instead of clipping.
    private func makeScrollingPane() -> (scroll: NSScrollView, content: NSView) {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.windowBackground
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = AppTheme.windowBackground.cgColor

        let content = FlippedView()
        content.wantsLayer = true
        content.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        return (scrollView, content)
    }

    /// Wrap a built pane view in a tab and append it. Call order here (in
    /// setupUI) is the visible tab order. Every pane reports the same
    /// preferredContentSize so tab switches never resize the window.
    private func addTab(_ view: NSView, identifier: String, label: String, symbol: String) {
        let paneController = NSViewController()
        paneController.view = view
        paneController.preferredContentSize = Self.paneSize
        let item = NSTabViewItem(viewController: paneController)
        item.identifier = identifier
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabViewController.addTabViewItem(item)
    }

    /// The right-aligned monospaced value label paired with a slider.
    private static func valueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = AppTheme.secondaryText
        label.alignment = .right
        return label
    }

    /// A secondary wrapping help/status label. `preferredWidth` opts into the
    /// low horizontal compression resistance the wide help blurbs need.
    private static func wrappingLabel(_ text: String, fontSize: CGFloat, maxLines: Int, preferredWidth: CGFloat? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize)
        label.textColor = AppTheme.secondaryText
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = maxLines
        if let preferredWidth {
            label.preferredMaxLayoutWidth = preferredWidth
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return label
    }

    private func setupGeneralTab() {
        let (generalView, generalContent) = makeScrollingPane()
        let form = PreferencesFormBuilder(container: generalContent)

        opacitySlider = NSSlider()
        opacitySlider.minValue = 0.3
        opacitySlider.maxValue = 1.0
        opacitySlider.numberOfTickMarks = 8
        opacitySlider.allowsTickMarkValuesOnly = false
        opacitySlider.target = self
        opacitySlider.action = #selector(opacitySliderChanged(_:))

        opacityLabel = Self.valueLabel("100%")

        blurCheckbox = NSButton(checkboxWithTitle: "Enable background blur", target: self, action: #selector(blurCheckboxChanged(_:)))
        blurCheckbox.font = NSFont.systemFont(ofSize: 13)

        restoreSessionCheckbox = NSButton(
            checkboxWithTitle: "Reopen previous tabs on launch (off starts with one tab at ~/)",
            target: self,
            action: #selector(restoreSessionChanged(_:))
        )
        restoreSessionCheckbox.font = NSFont.systemFont(ofSize: 13)

        confirmCloseCheckbox = NSButton(
            checkboxWithTitle: "Confirm before closing tabs and panes (⌘W / ⇧⌘W)",
            target: self,
            action: #selector(confirmCloseChanged(_:))
        )
        confirmCloseCheckbox.font = NSFont.systemFont(ofSize: 13)

        rawConfigButton = NSButton(title: "View/Edit Raw Config...", target: self, action: #selector(rawConfigButtonClicked(_:)))
        rawConfigButton.bezelStyle = .rounded

        form.fieldLabel("Window Opacity:", gapAbove: 30)
        form.sliderRow(opacitySlider, valueLabel: opacityLabel, gapAbove: 10)
        form.checkbox(blurCheckbox, gapAbove: 20)
        form.checkbox(restoreSessionCheckbox, gapAbove: 12)
        form.checkbox(confirmCloseCheckbox, gapAbove: 12)
        form.fieldLabel("Raw Config File:", gapAbove: 30)
        form.leadingControl(rawConfigButton, gapAbove: 10)
        form.finish()

        addTab(generalView, identifier: "general", label: "General", symbol: "gearshape")
    }

    private func setupTerminalTab() {
        let (terminalView, terminalContent) = makeScrollingPane()
        let form = PreferencesFormBuilder(container: terminalContent)

        fontFamilyPopup = NSPopUpButton()
        fontFamilyPopup.addItems(withTitles: terminalFontFamilies())
        fontFamilyPopup.target = self
        fontFamilyPopup.action = #selector(fontFamilyChanged(_:))

        fontSizeSlider = NSSlider()
        fontSizeSlider.minValue = 8
        fontSizeSlider.maxValue = 24
        fontSizeSlider.numberOfTickMarks = 17
        fontSizeSlider.allowsTickMarkValuesOnly = true
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(fontSizeSliderChanged(_:))

        fontSizeLabel = Self.valueLabel("13pt")

        boldIsBrightCheckbox = NSButton(
            checkboxWithTitle: "Use bright colors for bold text",
            target: self,
            action: #selector(boldIsBrightChanged(_:))
        )
        boldIsBrightCheckbox.font = NSFont.systemFont(ofSize: 13)

        paddingSlider = NSSlider()
        paddingSlider.minValue = 0
        paddingSlider.maxValue = 24
        paddingSlider.numberOfTickMarks = 13
        paddingSlider.allowsTickMarkValuesOnly = true
        paddingSlider.target = self
        paddingSlider.action = #selector(paddingSliderChanged(_:))

        paddingLabel = Self.valueLabel("8px")

        shellIntegrationStatusLabel = Self.wrappingLabel("", fontSize: 12, maxLines: 3)

        shellIntegrationButton = NSButton(
            title: "Install for zsh…",
            target: self,
            action: #selector(installShellIntegrationClicked(_:))
        )
        shellIntegrationButton.bezelStyle = .rounded

        form.fieldLabel("Font Family:", gapAbove: 30)
        form.leadingControl(fontFamilyPopup, gapAbove: 10, width: 200)
        form.fieldLabel("Font Size:", gapAbove: 30)
        form.sliderRow(fontSizeSlider, valueLabel: fontSizeLabel, gapAbove: 10)
        form.checkbox(boldIsBrightCheckbox, gapAbove: 24)
        form.fieldLabel("Content Padding:", gapAbove: 24)
        form.sliderRow(paddingSlider, valueLabel: paddingLabel, gapAbove: 10)
        form.fieldLabel("Shell Integration:", gapAbove: 30)
        form.fullWidth(shellIntegrationStatusLabel, gapAbove: 6)
        form.leadingControl(shellIntegrationButton, gapAbove: 10)
        form.finish()

        addTab(terminalView, identifier: "terminal", label: "Terminal", symbol: "terminal")
    }

    private func setupAgentsTab() {
        let (agentsView, agentsContent) = makeScrollingPane()
        let form = PreferencesFormBuilder(container: agentsContent)

        let blurbLabel = Self.wrappingLabel(
            "Wire up agent CLIs to report Working / Needs input / Done to the agents panel. Detected from each tool's config directory; safe to re-run.",
            fontSize: 12,
            maxLines: 3
        )
        form.fullWidth(blurbLabel, gapAbove: 20)

        for (index, agent) in AgentIntegrationInstaller.AgentID.allCases.enumerated() {
            let statusLabel = Self.wrappingLabel("", fontSize: 12, maxLines: 2)

            let installButton = NSButton(
                title: "Install",
                target: self,
                action: #selector(installAgentIntegrationClicked(_:))
            )
            installButton.bezelStyle = .rounded
            installButton.tag = index

            form.agentRow(name: agent.displayName, statusLabel: statusLabel, button: installButton, gapAbove: 22)

            agentStatusLabels[agent] = statusLabel
            agentInstallButtons[agent] = installButton
        }

        updateAgentIntegrationStatuses()
        form.finish()

        addTab(agentsView, identifier: "agents", label: "Agents", symbol: "sparkles")
    }

    private func setupApprovalsTab() {
        let (approvalsView, approvalsContent) = makeScrollingPane()
        let form = PreferencesFormBuilder(container: approvalsContent)

        approvalModePopup = NSPopUpButton()
        approvalModePopup.addItems(withTitles: [
            "Ask before changes",
            "Auto-approve workspace edits",
            "Auto (safety-reviewed)",
            "Full access (no prompts)"
        ])
        approvalModePopup.target = self
        approvalModePopup.action = #selector(approvalModeChanged(_:))

        let modeHelp = Self.wrappingLabel(
            "Controls Claude and Codex with matching intent. Ask gates edits; Workspace edits automatically inside the project; Auto sends broader actions to each agent's safety reviewer; Full access removes prompts and sandbox limits. Applies to the next agent launched, including in an open pane; running sessions keep their current permissions. Toggle workspace-edit auto with ⇧⌘A.",
            fontSize: 11,
            maxLines: 7,
            preferredWidth: 420
        )

        form.fieldLabel("Agent Permissions:", gapAbove: 30)
        form.leadingControl(approvalModePopup, gapAbove: 10, width: 240)
        form.fullWidth(modeHelp, gapAbove: 6)

        // The rules below are read by the approval desk and by nothing else, so
        // a build without one shows the permission mode (which every build
        // honors, because it is passed to the agent itself) and stops there.
        if ProFeatures.approvalDesk != nil {
            let autoAllow = NSTextField()
            autoAllow.placeholderString = "Sources/**, docs/**"
            autoAllow.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            autoAllow.target = self
            autoAllow.action = #selector(autoAllowChanged(_:))
            autoAllowField = autoAllow

            let autoAllowHelp = Self.wrappingLabel(
                "Approval-desk rule for Claude and Pi edits. Codex does not expose auto-applied edits to Cortland's diff desk.",
                fontSize: 11,
                maxLines: 3,
                preferredWidth: 420
            )

            let alwaysAsk = NSTextField()
            alwaysAsk.placeholderString = ".env, **/secrets/**, *.pem"
            alwaysAsk.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            alwaysAsk.target = self
            alwaysAsk.action = #selector(alwaysAskChanged(_:))
            alwaysAskField = alwaysAsk

            let alwaysAskHelp = Self.wrappingLabel(
                "Approval-desk rule for Claude and Pi. Highest precedence there, but it cannot override Codex's own sandbox/reviewer.",
                fontSize: 11,
                maxLines: 3,
                preferredWidth: 420
            )

            let worktreeAutoApprove = NSButton(
                checkboxWithTitle: "Auto-approve edits inside registered worktrees",
                target: self,
                action: #selector(worktreeAutoApproveChanged(_:))
            )
            worktreeAutoApprove.font = NSFont.systemFont(ofSize: 13)
            worktreeAutoApproveCheckbox = worktreeAutoApprove

            let worktreeAutoApproveHelp = Self.wrappingLabel(
                "For Claude and Pi's approval desk: edits inside the pane's registered worktree apply automatically. Codex workspace scope already follows the directory it launches in.",
                fontSize: 11,
                maxLines: 4,
                preferredWidth: 420
            )

            form.fieldLabel("Always Allow (comma-separated globs):", gapAbove: 22)
            form.fullWidth(autoAllow, gapAbove: 8)
            form.fullWidth(autoAllowHelp, gapAbove: 6)
            form.fieldLabel("Always Ask (comma-separated globs):", gapAbove: 22)
            form.fullWidth(alwaysAsk, gapAbove: 8)
            form.fullWidth(alwaysAskHelp, gapAbove: 6)
            form.checkbox(worktreeAutoApprove, gapAbove: 22)
            form.fullWidth(worktreeAutoApproveHelp, gapAbove: 6)
        } else {
            form.fullWidth(
                Self.wrappingLabel(
                    "Path rules that hold an edit for review — always-allow and always-ask globs, and auto-approval inside a worktree — belong to Cortland's approval desk, which this build does not include. Edits are decided by each agent's own prompt.",
                    fontSize: 11,
                    maxLines: 5,
                    preferredWidth: 420
                ),
                gapAbove: 22
            )
        }
        form.finish()

        addTab(approvalsView, identifier: "approvals", label: "Approvals", symbol: "checkmark.shield")
    }

    private func setupNotificationsTab() {
        let (notificationsView, notificationsContent) = makeScrollingPane()
        let form = PreferencesFormBuilder(container: notificationsContent)

        notificationsEnabledCheckbox = NSButton(
            checkboxWithTitle: "Enable macOS notifications",
            target: self,
            action: #selector(notificationsEnabledChanged(_:))
        )
        notificationsEnabledCheckbox.font = NSFont.systemFont(ofSize: 13)

        let masterHelp = Self.wrappingLabel(
            "Off by default. Cortland only notifies when it's not the active app, never steals focus, and plays no sound (leave quiet hours to macOS Focus). Clicking a notification opens that tab and pane. You'll be asked for permission the first time you turn one of these on.",
            fontSize: 11,
            maxLines: 6,
            preferredWidth: 420
        )

        notifyNeedsInputCheckbox = NSButton(
            checkboxWithTitle: "Agent needs input",
            target: self,
            action: #selector(notifyNeedsInputChanged(_:))
        )
        notifyNeedsInputCheckbox.font = NSFont.systemFont(ofSize: 13)

        notifyFinishedCheckbox = NSButton(
            checkboxWithTitle: "Agent finished",
            target: self,
            action: #selector(notifyFinishedChanged(_:))
        )
        notifyFinishedCheckbox.font = NSFont.systemFont(ofSize: 13)

        notifyCommandFailedCheckbox = NSButton(
            checkboxWithTitle: "Command failed (in a pane you weren't viewing)",
            target: self,
            action: #selector(notifyCommandFailedChanged(_:))
        )
        notifyCommandFailedCheckbox.font = NSFont.systemFont(ofSize: 13)

        notifyLongCommandCheckbox = NSButton(
            checkboxWithTitle: "Long-running command finished",
            target: self,
            action: #selector(notifyLongCommandChanged(_:))
        )
        notifyLongCommandCheckbox.font = NSFont.systemFont(ofSize: 13)

        longCommandThresholdField = Self.numberField(target: self, action: #selector(longCommandThresholdChanged(_:)))
        backgroundGraceField = Self.numberField(target: self, action: #selector(backgroundGraceChanged(_:)))

        let thresholdHelp = Self.wrappingLabel(
            "Seconds a command must run to count as long-running.",
            fontSize: 11,
            maxLines: 2,
            preferredWidth: 420
        )
        let graceHelp = Self.wrappingLabel(
            "Seconds Cortland must be in the background before completion and failure notifications fire (a quick tab-away won't ping). \"Agent needs input\" ignores this and fires as soon as Cortland is inactive.",
            fontSize: 11,
            maxLines: 4,
            preferredWidth: 420
        )

        form.checkbox(notificationsEnabledCheckbox, gapAbove: 30)
        form.fullWidth(masterHelp, gapAbove: 6)
        form.fieldLabel("Notify me when:", gapAbove: 24)
        form.checkbox(notifyNeedsInputCheckbox, gapAbove: 10)
        form.checkbox(notifyFinishedCheckbox, gapAbove: 10)
        form.checkbox(notifyCommandFailedCheckbox, gapAbove: 10)
        form.checkbox(notifyLongCommandCheckbox, gapAbove: 10)
        form.fieldLabel("Long-running threshold (seconds):", gapAbove: 24)
        form.leadingControl(longCommandThresholdField, gapAbove: 8, width: 80)
        form.fullWidth(thresholdHelp, gapAbove: 6)
        form.fieldLabel("Background grace (seconds):", gapAbove: 22)
        form.leadingControl(backgroundGraceField, gapAbove: 8, width: 80)
        form.fullWidth(graceHelp, gapAbove: 6)
        form.finish()

        addTab(notificationsView, identifier: "notifications", label: "Notifications", symbol: "bell")
    }

    /// A small right-aligned numeric text field for integer preferences.
    private static func numberField(target: AnyObject, action: Selector) -> NSTextField {
        let field = NSTextField()
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right
        field.target = target
        field.action = action
        return field
    }

    // Theme picker model: every available theme, then an "Auto" entry that
    // follows the macOS light/dark setting. Index aligns with themeMenuTitles.
    private var themeSelectionNames: [String] {
        Theme.shared.available.map { $0.name } + [Theme.autoSelection]
    }

    private var themeMenuTitles: [String] {
        Theme.shared.available.map { def in
            def.displayName + (def.appearance == .light ? " (Light)" : " (Dark)")
        } + ["Auto (Follow System)"]
    }

    private func setupAppearanceTab() {
        let (appearanceView, appearanceContent) = makeScrollingPane()
        let form = PreferencesFormBuilder(container: appearanceContent)

        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: themeMenuTitles)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))

        form.fieldLabel("Color Theme:", gapAbove: 30)
        form.leadingControl(themePopup, gapAbove: 10, width: 200)
        form.finish()

        addTab(appearanceView, identifier: "appearance", label: "Appearance", symbol: "paintbrush")
    }

    private func setupEditorTab() {
        let (editorView, editorContent) = makeScrollingPane()
        let form = PreferencesFormBuilder(container: editorContent)

        fileOpenModePopup = NSPopUpButton()
        fileOpenModePopup.addItems(withTitles: ["Terminal Editor", "Built-in Editor"])
        fileOpenModePopup.target = self
        fileOpenModePopup.action = #selector(fileOpenModeChanged(_:))

        editorFontFamilyPopup = NSPopUpButton()
        editorFontFamilyPopup.addItem(withTitle: Self.systemDefaultFontTitle)
        editorFontFamilyPopup.addItems(withTitles: terminalFontFamilies())
        editorFontFamilyPopup.target = self
        editorFontFamilyPopup.action = #selector(editorFontFamilyChanged(_:))

        editorFontSizeSlider = NSSlider()
        editorFontSizeSlider.minValue = 8
        editorFontSizeSlider.maxValue = 32
        editorFontSizeSlider.numberOfTickMarks = 25
        editorFontSizeSlider.allowsTickMarkValuesOnly = true
        editorFontSizeSlider.target = self
        editorFontSizeSlider.action = #selector(editorFontSizeChanged(_:))

        editorFontSizeLabel = Self.valueLabel("13pt")

        wordWrapCheckbox = NSButton(checkboxWithTitle: "Wrap long lines", target: self, action: #selector(wordWrapChanged(_:)))
        wordWrapCheckbox.font = NSFont.systemFont(ofSize: 13)

        showHiddenFilesCheckbox = NSButton(
            checkboxWithTitle: "Show hidden files in file tree (dimmed)",
            target: self,
            action: #selector(showHiddenFilesChanged(_:))
        )
        showHiddenFilesCheckbox.font = NSFont.systemFont(ofSize: 13)

        form.fieldLabel("File Tree Opens:", gapAbove: 30)
        form.leadingControl(fileOpenModePopup, gapAbove: 10, width: 200)
        form.fieldLabel("Font Family:", gapAbove: 24)
        form.leadingControl(editorFontFamilyPopup, gapAbove: 10, width: 200)
        form.fieldLabel("Text Size:", gapAbove: 24)
        form.sliderRow(editorFontSizeSlider, valueLabel: editorFontSizeLabel, gapAbove: 10)
        form.checkbox(wordWrapCheckbox, gapAbove: 24)
        form.checkbox(showHiddenFilesCheckbox, gapAbove: 12)
        form.finish()

        addTab(editorView, identifier: "editor", label: "Editor", symbol: "square.and.pencil")
    }

    private func setupExtrasTab() {
        let (extrasView, extrasContent) = makeScrollingPane()
        let form = PreferencesFormBuilder(container: extrasContent)

        arcadeEnabledCheckbox = NSButton(
            checkboxWithTitle: "Enable the arcade panel (⌃`)",
            target: self,
            action: #selector(arcadeEnabledChanged(_:))
        )
        arcadeEnabledCheckbox.font = NSFont.systemFont(ofSize: 13)

        let arcadeBlurb = Self.wrappingLabel(
            "Mini-games in a floating panel for the dead time while agents run. ⌃` toggles it; hiding pauses the game, and boards and best scores survive relaunches. While disabled, the shortcut passes through to the terminal.",
            fontSize: 12,
            maxLines: 4,
            preferredWidth: 420
        )

        form.fieldLabel("Arcade:", gapAbove: 30)
        form.checkbox(arcadeEnabledCheckbox, gapAbove: 10)
        form.fullWidth(arcadeBlurb, gapAbove: 6)
        form.finish()

        addTab(extrasView, identifier: "extras", label: "Extras", symbol: "puzzlepiece")
    }

    private func loadCurrentSettings() {
        // Load opacity
        opacitySlider.doubleValue = config.window.opacity
        updateOpacityLabel()

        // Load blur setting
        blurCheckbox.state = config.window.enableBlur ? .on : .off

        // Load session-restore setting
        restoreSessionCheckbox.state = config.behavior.restoreSession ? .on : .off

        // Load close-confirmation setting
        confirmCloseCheckbox.state = config.behavior.confirmClose ? .on : .off

        // Load font family. If the configured font isn't in the list, add it
        // so the popup always reflects what's actually in use.
        let currentFont = config.font.family
        if fontFamilyPopup.item(withTitle: currentFont) == nil {
            fontFamilyPopup.addItem(withTitle: currentFont)
        }
        fontFamilyPopup.selectItem(withTitle: currentFont)

        // Load font size
        fontSizeSlider.doubleValue = Double(config.font.size)
        updateFontSizeLabel()

        // Load bold-is-bright and padding
        boldIsBrightCheckbox.state = config.font.boldIsBright ? .on : .off
        paddingSlider.doubleValue = Double(config.window.padding)
        updatePaddingLabel()

        let editorConfig = config.editor ?? EditorConfig()
        fileOpenModePopup.selectItem(at: editorConfig.fileOpenMode == "builtin" ? 1 : 0)

        // Editor font family. Empty means system default; an unknown family is
        // added so the popup reflects what's actually configured.
        let editorFamily = editorConfig.fontFamily.trimmingCharacters(in: .whitespaces)
        if editorFamily.isEmpty {
            editorFontFamilyPopup.selectItem(withTitle: Self.systemDefaultFontTitle)
        } else {
            if editorFontFamilyPopup.item(withTitle: editorFamily) == nil {
                editorFontFamilyPopup.addItem(withTitle: editorFamily)
            }
            editorFontFamilyPopup.selectItem(withTitle: editorFamily)
        }

        editorFontSizeSlider.doubleValue = Double(editorConfig.fontSize)
        updateEditorFontSizeLabel()
        wordWrapCheckbox.state = editorConfig.wordWrap ? .on : .off
        showHiddenFilesCheckbox.state = editorConfig.showHiddenFiles ? .on : .off

        // Select the active theme (or "Auto") in the Appearance popup
        if let themeIndex = themeSelectionNames.firstIndex(of: config.theme.name) {
            themePopup.selectItem(at: themeIndex)
        } else {
            themePopup.selectItem(at: 0)
        }

        // Load approval settings (defaults when the section is absent).
        let approval = config.approval ?? ApprovalConfig()
        approvalModePopup.selectItem(at: Self.approvalModeIndex(approval.mode))
        autoAllowField?.stringValue = approval.autoAllow.joined(separator: ", ")
        alwaysAskField?.stringValue = approval.alwaysAsk.joined(separator: ", ")
        worktreeAutoApproveCheckbox?.state = approval.worktreeAutoApprove ? .on : .off

        // Load notification settings (defaults when the section is absent).
        let notifications = config.notifications ?? NotificationsConfig()
        notificationsEnabledCheckbox.state = notifications.enabled ? .on : .off
        notifyNeedsInputCheckbox.state = notifications.needsInput ? .on : .off
        notifyFinishedCheckbox.state = notifications.finished ? .on : .off
        notifyCommandFailedCheckbox.state = notifications.commandFailed ? .on : .off
        notifyLongCommandCheckbox.state = notifications.longRunningCommand ? .on : .off
        longCommandThresholdField.integerValue = notifications.longRunningThresholdSeconds
        backgroundGraceField.integerValue = notifications.backgroundGraceSeconds
        updateNotificationControlsEnabled()

        // Load extras settings (defaults when the section is absent).
        arcadeEnabledCheckbox.state = (config.arcade?.enabled ?? false) ? .on : .off

        updateShellIntegrationStatus()
    }

    /// Grey out the per-trigger toggles and numeric fields while the master
    /// switch is off, so the dependency is obvious.
    private func updateNotificationControlsEnabled() {
        let on = notificationsEnabledCheckbox.state == .on
        [notifyNeedsInputCheckbox, notifyFinishedCheckbox, notifyCommandFailedCheckbox,
         notifyLongCommandCheckbox].forEach { $0?.isEnabled = on }
        [longCommandThresholdField, backgroundGraceField].forEach { $0?.isEnabled = on }
    }

    private func updateShellIntegrationStatus() {
        if ShellIntegration.isInstalledInZshrc() {
            shellIntegrationStatusLabel.stringValue =
                "Installed in ~/.zshrc — prompt marks, exit-code indicators, and instant cwd tracking are active in new shells."
            shellIntegrationButton.isEnabled = false
            shellIntegrationButton.title = "Installed ✓"
        } else {
            shellIntegrationStatusLabel.stringValue =
                "Adds prompt navigation (⌘↑/⌘↓), failed-command indicators, and instant cwd tracking. Installs one line into ~/.zshrc."
            shellIntegrationButton.isEnabled = true
            shellIntegrationButton.title = "Install for zsh…"
        }
    }

    // MARK: - Actions

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        let opacity = sender.doubleValue
        mutateConfig { $0.window.opacity = opacity }
        updateOpacityLabel()
        applyOpacityChange()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let names = themeSelectionNames
        let index = sender.indexOfSelectedItem
        guard index >= 0 && index < names.count else { return }
        mutateConfig { $0.theme.name = names[index] }
        // Posts .themeDidChange, which every window observes to repaint live
        // (chrome + open terminals) and sets the matching NSApp appearance.
        Theme.shared.setSelection(names[index])
    }

    @objc private func blurCheckboxChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        mutateConfig { $0.window.enableBlur = enabled }
        showRestartAlert()
    }

    @objc private func restoreSessionChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        mutateConfig { $0.behavior.restoreSession = enabled }
    }

    @objc private func arcadeEnabledChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        mutateConfig {
            if $0.arcade == nil {
                $0.arcade = ArcadeConfig()
            }
            $0.arcade?.enabled = enabled
        }
    }

    @objc private func confirmCloseChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        mutateConfig { $0.behavior.confirmClose = enabled }
    }

    /// Popup title meaning "no family configured — use the system mono font".
    private static let systemDefaultFontTitle = "System Default"

    /// Font families suitable for the terminal: every installed fixed-pitch
    /// family, plus families whose name marks them as coding/Nerd fonts (the
    /// non-"Mono" Nerd Font variants report a proportional trait but are still
    /// usable), plus a few common names. Sorted and de-duplicated.
    private func terminalFontFamilies() -> [String] {
        let manager = NSFontManager.shared
        let fixedPitch = UInt(NSFontTraitMask.fixedPitchFontMask.rawValue)
        let nameHints = ["mono", "nerd", "code", "consol", "courier"]

        var families = Set<String>(["JetBrains Mono", "SF Mono", "Monaco", "Menlo"])

        for family in manager.availableFontFamilies {
            let lower = family.lowercased()
            if nameHints.contains(where: lower.contains) {
                families.insert(family)
                continue
            }
            if let members = manager.availableMembers(ofFontFamily: family),
               members.contains(where: { ($0.count > 3 ? ($0[3] as? UInt ?? 0) : 0) & fixedPitch != 0 }) {
                families.insert(family)
            }
        }

        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        if let selectedTitle = sender.selectedItem?.title {
            mutateConfig { $0.font.family = selectedTitle }
            applyFontChanges()
        }
    }

    @objc private func fontSizeSliderChanged(_ sender: NSSlider) {
        let size = Int(sender.doubleValue)
        mutateConfig { $0.font.size = size }
        updateFontSizeLabel()
        applyFontChanges()
    }

    @objc private func boldIsBrightChanged(_ sender: NSButton) {
        let on = sender.state == .on
        mutateConfig { $0.font.boldIsBright = on }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func paddingSliderChanged(_ sender: NSSlider) {
        let padding = Int(sender.doubleValue)
        mutateConfig { $0.window.padding = padding }
        updatePaddingLabel()
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func fileOpenModeChanged(_ sender: NSPopUpButton) {
        let mode = sender.indexOfSelectedItem == 1 ? "builtin" : "terminal"
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.fileOpenMode = mode }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func editorFontSizeChanged(_ sender: NSSlider) {
        let size = Int(sender.doubleValue)
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.fontSize = size }
        updateEditorFontSizeLabel()
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func editorFontFamilyChanged(_ sender: NSPopUpButton) {
        let title = sender.selectedItem?.title ?? Self.systemDefaultFontTitle
        let family = (title == Self.systemDefaultFontTitle) ? "" : title
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.fontFamily = family }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func wordWrapChanged(_ sender: NSButton) {
        let on = sender.state == .on
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.wordWrap = on }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func showHiddenFilesChanged(_ sender: NSButton) {
        let on = sender.state == .on
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.showHiddenFiles = on }
        mainWindowController?.applyRuntimeConfig(config)
    }

    /// Approval mode strings indexed to match the popup item order.
    private static let approvalModes = ApprovalMode.allCases.map(\.rawValue)

    private static func approvalModeIndex(_ mode: String) -> Int {
        approvalModes.firstIndex(of: ApprovalMode(configValue: mode).rawValue) ?? 0
    }

    @objc private func approvalModeChanged(_ sender: NSPopUpButton) {
        let mode = Self.approvalModes[safe: sender.indexOfSelectedItem] ?? "ask"
        mutateConfig { Self.ensuringApproval(&$0); $0.approval?.mode = mode }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func autoAllowChanged(_ sender: NSTextField) {
        let globs = Self.parseGlobs(sender.stringValue)
        mutateConfig { Self.ensuringApproval(&$0); $0.approval?.autoAllow = globs }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func alwaysAskChanged(_ sender: NSTextField) {
        let globs = Self.parseGlobs(sender.stringValue)
        mutateConfig { Self.ensuringApproval(&$0); $0.approval?.alwaysAsk = globs }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func worktreeAutoApproveChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        mutateConfig { Self.ensuringApproval(&$0); $0.approval?.worktreeAutoApprove = enabled }
        mainWindowController?.applyRuntimeConfig(config)
    }

    // MARK: - Notifications

    @objc private func notificationsEnabledChanged(_ sender: NSButton) {
        applyNotificationChange { $0.enabled = sender.state == .on }
        updateNotificationControlsEnabled()
    }

    @objc private func notifyNeedsInputChanged(_ sender: NSButton) {
        applyNotificationChange { $0.needsInput = sender.state == .on }
    }

    @objc private func notifyFinishedChanged(_ sender: NSButton) {
        applyNotificationChange { $0.finished = sender.state == .on }
    }

    @objc private func notifyCommandFailedChanged(_ sender: NSButton) {
        applyNotificationChange { $0.commandFailed = sender.state == .on }
    }

    @objc private func notifyLongCommandChanged(_ sender: NSButton) {
        applyNotificationChange { $0.longRunningCommand = sender.state == .on }
    }

    @objc private func longCommandThresholdChanged(_ sender: NSTextField) {
        let seconds = max(1, sender.integerValue)
        sender.integerValue = seconds
        applyNotificationChange { $0.longRunningThresholdSeconds = seconds }
    }

    @objc private func backgroundGraceChanged(_ sender: NSTextField) {
        let seconds = max(0, sender.integerValue)
        sender.integerValue = seconds
        applyNotificationChange { $0.backgroundGraceSeconds = seconds }
    }

    /// Persist a notification-config edit, push it to the running coordinator,
    /// and — if the change leaves at least one trigger active — verify the app
    /// can actually deliver: prompt if macOS has never asked, or point the user
    /// at System Settings if Cortland is blocked there. Checking only here (a
    /// user toggling a setting) keeps us from ever prompting at launch.
    private func applyNotificationChange(_ apply: (inout NotificationsConfig) -> Void) {
        mutateConfig {
            Self.ensuringNotifications(&$0)
            var n = $0.notifications ?? NotificationsConfig()
            apply(&n)
            $0.notifications = n
        }
        mainWindowController?.applyRuntimeConfig(config)
        if config.notifications?.anyTriggerActive == true {
            mainWindowController?.ensureNotificationAuthorization { [weak self] status in
                if status == .denied { self?.showNotificationsDeniedAlert() }
            }
        }
    }

    /// Cortland's notifications are switched off at the system level, so the
    /// toggles the user just enabled can't deliver anything. Say so once per
    /// Preferences session and offer the jump to the right System Settings pane.
    private var didWarnNotificationsDenied = false
    private func showNotificationsDeniedAlert() {
        guard !didWarnNotificationsDenied else { return }
        didWarnNotificationsDenied = true

        let alert = NSAlert()
        alert.messageText = "Notifications are off in System Settings"
        alert.informativeText = "macOS is blocking Cortland's notifications, so the alerts you just enabled won't appear. Allow them under System Settings > Notifications > Cortland."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        let openSettings = {
            let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
            NSWorkspace.shared.open(url)
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { openSettings() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }

    private static func ensuringNotifications(_ config: inout Config) {
        if config.notifications == nil {
            config.notifications = NotificationsConfig()
        }
    }

    /// Split a comma-separated glob list into trimmed, non-empty patterns.
    private static func parseGlobs(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @objc private func installShellIntegrationClicked(_ sender: NSButton) {
        ShellIntegration.installScripts()

        let alert = NSAlert()
        do {
            let added = try ShellIntegration.installInZshrc()
            alert.messageText = added ? "Shell Integration Installed" : "Already Installed"
            alert.informativeText = added
                ? "Added one line to ~/.zshrc. Open a new tab (or run `source ~/.zshrc`) to activate it. For bash, source ~/.config/cortland/shell-integration/cortland.bash from your ~/.bashrc."
                : "~/.zshrc already sources the Cortland shell integration."
            alert.alertStyle = .informational
        } catch {
            alert.messageText = "Installation Failed"
            alert.informativeText = "Could not modify ~/.zshrc: \(error.localizedDescription)"
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
        updateShellIntegrationStatus()
    }

    private func updateAgentIntegrationStatuses() {
        for agent in AgentIntegrationInstaller.AgentID.allCases {
            let status = AgentIntegrationInstaller.status(of: agent)
            agentStatusLabels[agent]?.stringValue = status.description

            let button = agentInstallButtons[agent]
            switch status {
            case .installed:
                button?.title = "Installed ✓"
                button?.isEnabled = false
            case .available:
                button?.title = "Install"
                button?.isEnabled = true
            case .notDetected, .helperMissing:
                button?.title = "Install"
                button?.isEnabled = false
            }
        }
    }

    @objc private func installAgentIntegrationClicked(_ sender: NSButton) {
        let agents = AgentIntegrationInstaller.AgentID.allCases
        guard sender.tag >= 0 && sender.tag < agents.count else { return }
        let agent = agents[sender.tag]

        let alert = NSAlert()
        do {
            try AgentIntegrationInstaller.install(agent)
            alert.messageText = "\(agent.displayName) Integration Installed"
            alert.informativeText = "Restart any running \(agent.displayName) sessions to pick up the change."
            alert.alertStyle = .informational
        } catch {
            alert.messageText = "Installation Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
        updateAgentIntegrationStatuses()
    }

    @objc private func rawConfigButtonClicked(_ sender: NSButton) {
        // Every control already persists on change, so there's nothing pending to
        // flush; writing our snapshot here would clobber on-disk edits. Loading
        // just recreates a default when the file is missing, without overwriting
        // an existing (or broken) one, so "Edit raw config" always opens a file.
        _ = Config.load()
        mainWindowController?.openConfigFile()
    }

    /// Set once we've warned the user that on-disk config is broken, so a
    /// stream of control changes doesn't stack a modal per click.
    private var didWarnBrokenConfig = false

    /// Apply a single-field change on top of the *latest* on-disk config, then
    /// persist and refresh our snapshot. Re-reading before writing means each
    /// control only rewrites the field the user just touched — concurrent
    /// external edits (or a ConfigWatcher reload) to *other* fields survive
    /// instead of being clobbered by this window's stale whole-file snapshot
    /// (M4). If the on-disk file failed to parse, nothing is written and the
    /// running config is left as-is, so a broken config isn't overwritten with
    /// defaults (M3); the user is told once why the change didn't stick.
    private func mutateConfig(_ apply: (inout Config) -> Void) {
        var fresh = Config.load()
        guard !fresh.loadDidFail else {
            warnBrokenConfigOnce()
            return
        }
        apply(&fresh)
        config = fresh
        fresh.save()
    }

    private func warnBrokenConfigOnce() {
        guard !didWarnBrokenConfig else { return }
        didWarnBrokenConfig = true
        let alert = NSAlert()
        alert.messageText = "Couldn't save your change"
        alert.informativeText =
            "~/.config/cortland/config.toml can't be parsed, so Cortland won't overwrite it and lose your existing settings. Fix or remove that file (a backup is at config.toml.bak), then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func ensuringEditor(_ config: inout Config) {
        if config.editor == nil {
            config.editor = EditorConfig()
        }
    }

    private static func ensuringApproval(_ config: inout Config) {
        if config.approval == nil {
            config.approval = ApprovalConfig()
        }
    }

    private func updateOpacityLabel() {
        let percentage = Int(opacitySlider.doubleValue * 100)
        opacityLabel.stringValue = "\(percentage)%"
    }

    private func updateFontSizeLabel() {
        let size = Int(fontSizeSlider.doubleValue)
        fontSizeLabel.stringValue = "\(size)pt"
    }

    private func updatePaddingLabel() {
        paddingLabel.stringValue = "\(Int(paddingSlider.doubleValue))px"
    }

    private func updateEditorFontSizeLabel() {
        editorFontSizeLabel.stringValue = "\(Int(editorFontSizeSlider.doubleValue))pt"
    }

    private func applyOpacityChange() {
        mainWindowController?.applyRuntimeConfig(config)
    }

    private func applyFontChanges() {
        // This would need to be implemented to update existing terminals
        // For now, changes will apply to new terminals
        Log.debug("Font changed to \(config.font.family) \(config.font.size)pt", category: "app")
    }

    private func showRestartAlert() {
        let alert = NSAlert()
        alert.messageText = "Restart Required"
        alert.informativeText = "Please restart Cortland for the blur setting to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
    }
}

/// A top-origin container so scroll-view content lays out from the top down
/// and scrolls naturally toward the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - NSWindowDelegate
extension PreferencesWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Nothing to flush: every control persists its own field on change via
        // mutateConfig. Writing the whole snapshot here would clobber any
        // external edits made while this window was open (M4).
    }
}

/// Toolbar-style tab controller that titles the window after the selected
/// tab (System Settings behavior) and remembers the selection so Preferences
/// reopens where the user left it.
private final class PreferencesTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem else { return }
        view.window?.title = tabViewItem.label
        if let identifier = tabViewItem.identifier as? String {
            UserDefaults.standard.set(identifier, forKey: PreferencesWindowController.selectedTabDefaultsKey)
        }
    }
}

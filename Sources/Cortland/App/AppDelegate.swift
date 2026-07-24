import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE process-wide. When an agent finishes and disconnects,
        // the app may still write its IPC response to the now-closed socket;
        // a raised SIGPIPE has no handler and kills the app with no crash
        // report (always "on agent conclusion"). With SIG_IGN, write() returns
        // -1/EPIPE instead and the sendResponse loop bails cleanly. This is
        // stronger than the per-socket SO_NOSIGPIPE, which was observed to
        // still leak the signal on the telemetry-report reply path.
        signal(SIGPIPE, SIG_IGN)

        // Log uncaught ObjC exceptions to the persistent log so production
        // crashes leave a trace (see ~/Library/Logs/Cortland/Cortland.log).
        NSSetUncaughtExceptionHandler { exception in
            Log.error("Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "no reason")\n\(exception.callStackSymbols.joined(separator: "\n"))", category: "crash")
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNum = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.info("App launching (version \(version) build \(buildNum))", category: "app")

        // Before anything reads or writes under ~/.config/cortland: carry over a
        // pre-rename ~/.config/sidekick directory, once. ShellIntegration below
        // would otherwise create the new directory and make the copy look done.
        ConfigMigration.migrateIfNeeded()

        // Set activation policy to regular app
        NSApp.setActivationPolicy(.regular)
        Log.debug("✅ Activation policy set", category: "app")

        // Keep the on-disk shell integration scripts in sync with this build
        ShellIntegration.installScripts()

        // Same idea for the CLI helpers the from-source installer copied into
        // ~/.local/bin: an app upgrade used to leave them behind, and every way
        // a stale helper fails is silent. Refreshes off the main thread.
        InstalledHelperRefresher.refreshOnLaunch()

        // ...and for the pane-orchestration skill the installers copied into the
        // agents' skills directories, so an upgraded app doesn't leave agents
        // reading last month's instructions for driving it.
        InstalledSkillRefresher.refreshOnLaunch()

        // Binaries and skills are files we own outright; hook *entries* live in
        // the user's own settings.json / config.toml, so this one only adds what
        // an already-installed integration is missing from the current contract,
        // and never bootstraps one. It is what makes "launch the new app and
        // you're done" true for someone who has no repo and no scripts.
        AgentIntegrationInstaller.reconcileOnLaunch()

        // Clear out yesterday's pasted-image temp files
        DispatchQueue.global(qos: .utility).async {
            ImagePasteStore.pruneOldFiles()
        }

        setupMenuBar()
        Log.debug("✅ Menu bar setup completed", category: "app")

        mainWindowController = MainWindowController()
        Log.debug("✅ MainWindowController created", category: "app")

        mainWindowController?.showWindow(nil)
        Log.debug("✅ showWindow called", category: "app")

        // Ensure window is visible and in front
        if let window = mainWindowController?.window {
            Log.debug("✅ Window exists: \(window)", category: "app")
            // Don't re-center here: MainWindowController already restored the
            // saved frame (or centered on first launch), and center() would
            // discard it, recentering the window on every relaunch.
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            Log.debug("✅ Window visibility calls completed", category: "app")
        } else {
            Log.error("❌ Window is nil!", category: "app")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ⌘Q path: the window is still open, so the close-button guard
        // (windowShouldClose) hasn't run — confirm here if agents are busy or an
        // editor holds unsaved edits. On the close-button path the window is
        // already gone by now, so we skip the check to avoid prompting twice.
        guard let controller = mainWindowController, controller.window?.isVisible == true else {
            return .terminateNow
        }
        return controller.confirmCloseWithUnsavedWork() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.saveSession()
        mainWindowController?.recordSessionCosts()
        IPCServer.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        // About Cortland
        let aboutItem = NSMenuItem(title: "About Cortland", action: nil, keyEquivalent: "")
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())

        // ⌘, is consumed by the key monitor as .preferences before menu
        // dispatch, so this item advertises the binding that actually fires;
        // "Edit Config File..." carries no shortcut rather than a dead one.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showPreferences), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        let editConfigItem = NSMenuItem(title: "Edit Config File...", action: #selector(AppDelegate.editConfigFile), keyEquivalent: "")
        editConfigItem.target = self
        appMenu.addItem(editConfigItem)

        appMenu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Cortland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)

        mainMenu.addItem(appMenuItem)

        // File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        // New Tab (no key equivalent - handled by event monitor in MainWindowController)
        let newTabItem = NSMenuItem(title: "New Terminal Tab", action: #selector(newTab), keyEquivalent: "")
        newTabItem.target = self
        fileMenu.addItem(newTabItem)

        // Close Pane (no key equivalent - handled by event monitor)
        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(closePane), keyEquivalent: "")
        closePaneItem.target = self
        fileMenu.addItem(closePaneItem)

        fileMenu.addItem(NSMenuItem.separator())

        // Save (no key equivalent - handled by event monitor)
        let saveItem = NSMenuItem(title: "Save", action: #selector(save), keyEquivalent: "")
        saveItem.target = self
        fileMenu.addItem(saveItem)

        mainMenu.addItem(fileMenuItem)

        // Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        // Undo / Redo (validated against the first responder's undo manager —
        // active in the editor and any text field, inert elsewhere).
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(NSMenuItem.separator())

        // Cut
        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(cutItem)

        // Copy
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(copyItem)

        // Paste
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(pasteItem)

        editMenu.addItem(NSMenuItem.separator())

        // Select All
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(selectAllItem)

        editMenu.addItem(NSMenuItem.separator())

        // Find submenu (drives the editor's built-in find bar; ⌘F is freed for
        // the editor via the first-responder check in MainWindowController).
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")

        let findItem = NSMenuItem(title: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        findMenu.addItem(findItem)

        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "g")
        findNextItem.tag = NSTextFinder.Action.nextMatch.rawValue
        findMenu.addItem(findNextItem)

        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "G")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.tag = NSTextFinder.Action.previousMatch.rawValue
        findMenu.addItem(findPrevItem)

        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)

        mainMenu.addItem(editMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        // Toggle Sidebar (no key equivalent - handled by event monitor)
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "")
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Quick Open (no key equivalent - handled by event monitor)
        let quickOpenItem = NSMenuItem(title: "Quick Open...", action: #selector(quickOpen), keyEquivalent: "")
        quickOpenItem.target = self
        viewMenu.addItem(quickOpenItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Activity Bar Panels (no key equivalents - handled by event monitor)
        let filesItem = NSMenuItem(title: "Show Files", action: #selector(showFilesPanel), keyEquivalent: "")
        filesItem.target = self
        viewMenu.addItem(filesItem)

        let gitItem = NSMenuItem(title: "Show Git", action: #selector(showGitPanel), keyEquivalent: "")
        gitItem.target = self
        viewMenu.addItem(gitItem)

        let searchItem = NSMenuItem(title: "Show Search", action: #selector(showSearchPanel), keyEquivalent: "")
        searchItem.target = self
        viewMenu.addItem(searchItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Auto-approve agent edits this session (checkmark reflects effective
        // state, including the [approval] config mode). No key equivalent: ⇧⌘A
        // is owned by the Agents panel (KeyboardCommandRouter), whose event
        // monitor intercepts the chord before menu dispatch, so a shortcut here
        // would be dead. It's also security-sensitive, so it stays a deliberate
        // menu action rather than a hotkey that could be toggled by accident.
        let autoApproveItem = NSMenuItem(title: "Auto-approve Agent Edits", action: #selector(toggleAutoApproveEdits), keyEquivalent: "")
        autoApproveItem.target = self
        viewMenu.addItem(autoApproveItem)

        mainMenu.addItem(viewMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        // Minimize
        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minimizeItem)

        // Close (no key equivalent - Cmd+W is handled by event monitor to close tabs)
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        windowMenu.addItem(closeItem)

        mainMenu.addItem(windowMenuItem)

        // Help Menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu

        // Keyboard Shortcuts
        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(showKeyboardShortcuts), keyEquivalent: "k")
        shortcutsItem.target = self
        helpMenu.addItem(shortcutsItem)

        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleAutoApproveEdits() {
        mainWindowController?.toggleAutoApproveEdits()
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutoApproveEdits) {
            menuItem.state = (mainWindowController?.shouldAutoApproveEdits ?? false) ? .on : .off
        }
        return true
    }

    @objc private func newTab() {
        mainWindowController?.createNewTab()
    }

    @objc private func closePane() {
        mainWindowController?.closeCurrentPane()
    }

    @objc private func save() {
        mainWindowController?.saveCurrentFile()
    }

    @objc private func toggleSidebar() {
        mainWindowController?.toggleSidebar()
    }

    @objc private func quickOpen() {
        mainWindowController?.showQuickOpen()
    }

    @objc private func showPreferences() {
        mainWindowController?.showPreferences()
    }

    @objc private func editConfigFile() {
        Log.debug("⌨️ editConfigFile action called", category: "app")
        mainWindowController?.openConfigFile()
    }

    @objc private func showFilesPanel() {
        mainWindowController?.showPanel(.files)
    }

    @objc private func showGitPanel() {
        mainWindowController?.showPanel(.git)
    }

    @objc private func showSearchPanel() {
        mainWindowController?.showPanel(.search)
    }

    @objc private func showKeyboardShortcuts() {
        mainWindowController?.showKeyboardShortcuts()
    }
}
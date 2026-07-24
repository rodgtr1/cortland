import Cocoa

/// Floating panel that hosts one `ArcadeGame` at a time, Quake-terminal
/// style: the toggle chord hides rather than destroys it, the game pauses
/// whenever the panel loses key status, and its state is persisted so a
/// half-played game survives both hiding and relaunching the app.
final class ArcadePanel: NSPanel, NSWindowDelegate {
    private static let frameAutosaveKey = "CortlandArcadePanel"

    private var currentGame: (any ArcadeGame)?
    private var currentGameID: String?
    private let containerView = NSView()
    private let gamePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let helpButton = NSButton(title: "How to Play  ⌘?", target: nil, action: nil)
    /// Header strip holding the game picker and always-visible help control.
    private let headerHeight: CGFloat = 34
    private var isShowingHelp = false

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: BlocksGameView.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Arcade"
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        delegate = self

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        contentView = containerView

        gamePicker.addItems(withTitles: ArcadeGameCatalog.games.map(\.title))
        gamePicker.target = self
        gamePicker.action = #selector(gamePickerChanged(_:))
        gamePicker.isHidden = ArcadeGameCatalog.games.count < 2
        containerView.addSubview(gamePicker)

        helpButton.bezelStyle = .rounded
        helpButton.controlSize = .small
        helpButton.font = .systemFont(ofSize: 11)
        helpButton.target = self
        helpButton.action = #selector(showHowToPlay)
        helpButton.toolTip = "Show directions for this game (⌘?)"
        helpButton.setAccessibilityLabel("How to Play")
        containerView.addSubview(helpButton)

        let saved = ArcadeStateStore.load()
        let entry = ArcadeGameCatalog.games.first { $0.id == saved?.selectedGameID }
            ?? ArcadeGameCatalog.games[0]
        loadGame(entry, savedState: saved?.gameStates[entry.id])

        // Panel hide/close paths persist explicitly; quitting with the panel
        // open would otherwise lose the run.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func appWillTerminate() {
        persist()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle(relativeTo parent: NSWindow?) {
        if isVisible {
            hideAndPersist()
        } else {
            show(relativeTo: parent)
        }
    }

    /// Swaps in a different catalog game, persisting the outgoing one first.
    func selectGame(id: String) {
        guard id != currentGameID,
              let entry = ArcadeGameCatalog.games.first(where: { $0.id == id }) else { return }
        currentGame?.pause()
        persist()
        loadGame(entry, savedState: ArcadeStateStore.load()?.gameStates[entry.id])
        if isVisible, let game = currentGame {
            makeFirstResponder(game.view)
        }
    }

    @objc private func gamePickerChanged(_ sender: NSPopUpButton) {
        guard let entry = ArcadeGameCatalog.games[safe: sender.indexOfSelectedItem] else { return }
        selectGame(id: entry.id)
    }

    private func loadGame(_ entry: ArcadeGameCatalog.Entry, savedState: Data?) {
        currentGame?.view.removeFromSuperview()
        let game = entry.make(savedState)
        game.onCloseRequested = { [weak self] in self?.hideAndPersist() }
        currentGame = game
        currentGameID = entry.id

        let gameSize = game.view.frame.size
        setContentSize(NSSize(width: gameSize.width, height: gameSize.height + headerHeight))
        // Manual layout (fixed-size panel): game fills the bottom, picker
        // strip sits above it.
        game.view.frame = NSRect(origin: .zero, size: gameSize)
        game.view.autoresizingMask = []
        containerView.addSubview(game.view)
        gamePicker.frame = NSRect(x: 10, y: gameSize.height + 6, width: 160, height: 24)
        helpButton.frame = NSRect(x: gameSize.width - 130, y: gameSize.height + 6, width: 120, height: 24)

        if let index = ArcadeGameCatalog.games.firstIndex(where: { $0.id == entry.id }) {
            gamePicker.selectItem(at: index)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        // ⌘? is physically ⌘⇧/ on standard keyboards. Also check the
        // produced character so the shortcut follows non-US keyboard layouts.
        if modifiers == [.command, .shift],
           (event.keyCode == 44 || event.characters == "?") {
            showHowToPlay()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func showHowToPlay() {
        guard !isShowingHelp,
              let currentGameID,
              let entry = ArcadeGameCatalog.games.first(where: { $0.id == currentGameID }) else { return }

        isShowingHelp = true
        currentGame?.willShowHelp()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "How to Play — \(entry.title)"
        alert.informativeText = entry.howToPlay
        alert.addButton(withTitle: "Back to Game")
        alert.beginSheetModal(for: self) { [weak self] _ in
            guard let self else { return }
            self.isShowingHelp = false
            if let game = self.currentGame {
                game.didDismissHelp()
                self.makeFirstResponder(game.view)
            }
        }
    }

    private func show(relativeTo parent: NSWindow?) {
        if !setFrameUsingName(Self.frameAutosaveKey) {
            if let parentFrame = parent?.frame {
                setFrameOrigin(NSPoint(
                    x: parentFrame.midX - frame.width / 2,
                    y: parentFrame.midY - frame.height / 2
                ))
            } else {
                center()
            }
        }
        makeKeyAndOrderFront(nil)
        if let game = currentGame {
            makeFirstResponder(game.view)
        }
        // No resume here: games open paused and wake on the first keypress,
        // so summoning the panel never costs a move.
    }

    private func hideAndPersist() {
        currentGame?.pause()
        persist()
        saveFrame(usingName: Self.frameAutosaveKey)
        orderOut(nil)
    }

    private func persist() {
        guard let currentGame, let currentGameID else { return }
        var saved = ArcadeStateStore.load() ?? ArcadeSaveFile(selectedGameID: nil, gameStates: [:])
        saved.selectedGameID = currentGameID
        saved.gameStates[currentGameID] = currentGame.encodeState()
        ArcadeStateStore.save(saved)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // An attached How to Play sheet temporarily becomes key. Its dedicated
        // lifecycle hooks handle timed play without applying hide semantics to
        // games such as Keysmith, where hiding abandons the current line.
        guard !isShowingHelp else { return }
        currentGame?.pause()
        persist()
    }

    func windowWillClose(_ notification: Notification) {
        currentGame?.pause()
        persist()
        saveFrame(usingName: Self.frameAutosaveKey)
    }
}

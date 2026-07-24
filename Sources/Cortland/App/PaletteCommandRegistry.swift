import Cocoa

/// The window-chrome operations the command palette and keyboard router drive.
/// MainWindowController stays the source of truth for these behaviors (they
/// touch its tab/pane/terminal state); `PaletteCommandRegistry` owns only the
/// command table and the palette panel, calling back through this seam — the
/// same host-protocol split as `TabHost`/`TabController`.
@MainActor
protocol PaletteCommandHost: AnyObject {
    /// Parent window the palette centers itself over.
    var paletteHostWindow: NSWindow? { get }

    // Tabs
    func createNewTabFromCommand()
    func selectTab(index: Int)
    func cycleTabs(forward: Bool)
    func closeActiveTab()
    func focusAgentAttentionTab()

    // Panes
    func splitActivePane(direction: SplitDirection)
    func focusAdjacentPane(forward: Bool)
    func closeCurrentPane()

    // Active terminal
    func jumpToPrompt(previous: Bool)
    func findInActiveTerminal()

    // Sidebar / panels
    func togglePanel(_ panel: SidebarPanel)
    func showPanel(_ panel: SidebarPanel)
    func toggleSidebar()
    func toggleHiddenFiles()

    // Files / misc
    func saveCurrentFile()
    func showQuickOpen()
    func showSessions()
    func showPreferences()
    func openConfigFile()

    // Extras
    /// Whether the optional arcade module is enabled in config ([arcade]
    /// enabled = true). Off by default; gates both the ⌃` chord and the
    /// palette entry.
    var isArcadeEnabled: Bool { get }

    // Skills
    /// Skill roots to scan for palette-tagged skills, in precedence order
    /// (user dir first, workspace dir last — later wins on a name collision).
    var paletteSkillRoots: [URL] { get }
    /// Types `text` into the focused terminal pane; when `submit`, follows
    /// with Enter so argument-less skills fire in one palette action.
    func sendToActiveTerminal(text: String, submit: Bool)
}

/// Owns the ⇧⌘P command palette and the `KeyboardCommand` dispatch table —
/// the routed action list and the switch that turns a command into a window
/// operation. Extracted from MainWindowController, which keeps the behaviors
/// behind `PaletteCommandHost`.
@MainActor
final class PaletteCommandRegistry {
    private weak var host: PaletteCommandHost?
    /// Retained so ⇧⌘P reuses one panel instead of stacking duplicates.
    private var commandPalette: CommandPalettePanel?
    /// Retained so ⌃` toggles one panel whose in-memory game state survives
    /// hide/show; recreating it per toggle would restart the game.
    private var arcadePanel: ArcadePanel?

    init(host: PaletteCommandHost) {
        self.host = host
    }

    func showCommandPalette() {
        guard let host, let window = host.paletteHostWindow else { return }

        if commandPalette == nil {
            commandPalette = CommandPalettePanel()
        }

        commandPalette?.show(relativeTo: window, actions: paletteActions())
    }

    /// The command-palette entries. Most route their action straight through
    /// `perform`, and all take their shortcut label from
    /// `KeyboardCommand.displayShortcut`, so the palette can't drift from the
    /// keyboard bindings the way the old hand-maintained ("⌘T") strings did.
    /// Panel-show entries keep a bespoke action because the keyboard command
    /// *toggles* the panel whereas the palette should always *show* it.
    private func paletteActions() -> [PaletteAction] {
        // (title, SF Symbol, command driving both the action and the shortcut label)
        let routed: [(String, String, KeyboardCommand)] = [
            ("New Tab", "plus.rectangle", .newTab),
            ("Close Tab", "xmark.rectangle", .closeTab),
            ("Split Pane Horizontally", "rectangle.split.2x1", .splitPane(.horizontal)),
            ("Split Pane Vertically", "rectangle.split.1x2", .splitPane(.vertical)),
            ("Find in Terminal", "magnifyingglass", .findInTerminal),
            ("Jump to Previous Prompt", "arrow.up.to.line", .jumpToPrompt(previous: true)),
            ("Jump to Next Prompt", "arrow.down.to.line", .jumpToPrompt(previous: false)),
            ("Quick Open File", "doc.text.magnifyingglass", .quickOpen),
            ("Recall Session", "clock.arrow.circlepath", .showSessions),
            ("Toggle Sidebar", "sidebar.left", .toggleSidebar),
            ("Toggle Hidden Files", "eye.slash", .toggleHiddenFiles),
            ("Zoom In", "plus.magnifyingglass", .zoomIn),
            ("Zoom Out", "minus.magnifyingglass", .zoomOut),
            ("Reset Zoom", "1.magnifyingglass", .zoomReset),
            ("Preferences", "gearshape", .preferences)
        ]

        var actions = routed.map { title, symbol, command in
            PaletteAction(title: title, subtitle: command.displayShortcut, symbolName: symbol) { [weak self] in
                self?.perform(command)
            }
        }

        // Panel-show entries: always show (not toggle), so keep explicit actions.
        let panels: [(String, String, SidebarPanel)] = [
            ("Show Files Panel", "folder", .files),
            ("Show Git Panel", "arrow.branch", .git),
            ("Show Search Panel", "magnifyingglass.circle", .search)
        ]
        actions.append(contentsOf: panels.map { title, symbol, panel in
            PaletteAction(title: title, subtitle: KeyboardCommand.showPanel(panel).displayShortcut, symbolName: symbol) { [weak self] in
                self?.host?.showPanel(panel)
            }
        })

        actions.append(
            PaletteAction(title: "Edit Config File", subtitle: "config.toml", symbolName: "doc.badge.gearshape") { [weak self] in
                self?.host?.openConfigFile()
            }
        )

        // Optional extras only appear while enabled in config.
        if host?.isArcadeEnabled == true {
            actions.append(
                PaletteAction(title: "Toggle Arcade", subtitle: KeyboardCommand.toggleArcade.displayShortcut, symbolName: "gamecontroller") { [weak self] in
                    self?.toggleArcade()
                }
            )
        }

        // Agent skills tagged `cortland-palette: true` in their SKILL.md.
        // The palette only types the slash command into the focused pane;
        // the skill itself runs in the agent CLI. Skills that take arguments
        // get a trailing space and the cursor stays in the pane; ones tagged
        // submit fire immediately.
        let skills = PaletteSkillScanner.scan(roots: host?.paletteSkillRoots ?? [])
        actions.append(contentsOf: skills.map { skill in
            PaletteAction(title: "Skill: \(skill.title)", subtitle: "/\(skill.name)", symbolName: "sparkles") { [weak self] in
                self?.host?.sendToActiveTerminal(
                    text: skill.submit ? "/\(skill.name)" : "/\(skill.name) ",
                    submit: skill.submit
                )
            }
        })
        return actions
    }

    func toggleArcade() {
        guard let host, host.isArcadeEnabled else { return }
        if arcadePanel == nil {
            arcadePanel = ArcadePanel()
        }
        arcadePanel?.toggle(relativeTo: host.paletteHostWindow)
    }

    func perform(_ command: KeyboardCommand) {
        guard let host else { return }
        switch command {
        case .cycleTabs(let forward):
            host.cycleTabs(forward: forward)
        case .showPanel(let panel):
            host.togglePanel(panel)
        case .closeCurrentPane:
            host.closeCurrentPane()
        case .splitPane(let direction):
            host.splitActivePane(direction: direction)
        case .newTab:
            host.createNewTabFromCommand()
        case .jumpToPrompt(let previous):
            host.jumpToPrompt(previous: previous)
        case .commandPalette:
            showCommandPalette()
        case .findInTerminal:
            host.findInActiveTerminal()
        case .toggleHiddenFiles:
            host.toggleHiddenFiles()
        case .closeTab:
            host.closeActiveTab()
        case .saveFile:
            host.saveCurrentFile()
        case .toggleSidebar:
            host.toggleSidebar()
        case .quickOpen:
            host.showQuickOpen()
        case .showSessions:
            host.showSessions()
        case .preferences:
            host.showPreferences()
        case .focusPane(let forward):
            host.focusAdjacentPane(forward: forward)
        case .selectTab(let index):
            host.selectTab(index: index)
        case .zoomIn:
            FontZoom.shared.zoomIn()
        case .zoomOut:
            FontZoom.shared.zoomOut()
        case .zoomReset:
            FontZoom.shared.reset()
        case .pasteIntoTerminal:
            break // handled in handleKeyDown
        case .focusAgentAttention:
            host.focusAgentAttentionTab()
        case .toggleArcade:
            toggleArcade()
        }
    }
}

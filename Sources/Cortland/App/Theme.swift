import Cocoa
import SwiftTerm

// MARK: - Role Vocabulary
//
// ThemeColors is the role vocabulary consumed by views (tabs, terminal chrome,
// status colors). It is theme-agnostic: the mapping from role → palette slot
// below is the same for every theme; only the underlying palette changes.

protocol ThemeColors {
    // UI Elements
    var windowBackground: NSColor { get }
    var controlBackground: NSColor { get }
    var textBackground: NSColor { get }

    // Text
    var primaryText: NSColor { get }
    var secondaryText: NSColor { get }
    var labelText: NSColor { get }

    // Accents
    var accent: NSColor { get }
    var border: NSColor { get }
    var separator: NSColor { get }

    // Tab colors
    var activeTabBackground: NSColor { get }
    var inactiveTabBackground: NSColor { get }
    var activeTabText: NSColor { get }
    var inactiveTabText: NSColor { get }
    var activeTabBorder: NSColor { get }

    // Terminal
    var terminalBackground: NSColor { get }
    var terminalForeground: NSColor { get }
    var terminalCursor: NSColor { get }

    // Syntax/Status
    var green: NSColor { get }
    var red: NSColor { get }
    var yellow: NSColor { get }
    var blue: NSColor { get }
}

/// Maps the ThemeColors roles onto a resolved palette. This is the same mapping
/// the old CatppuccinTheme used, so role colors are unchanged for Mocha.
/// De-emphasized text branches on appearance: overlay0 reads fine against dark
/// surfaces but washes out against light ones (~2:1 in Latte), so light themes
/// take those roles from the subtext ramp instead.
struct PaletteThemeColors: ThemeColors {
    let p: ResolvedPalette

    private var mutedText: NSColor { p.isLight ? p.subtext0 : p.overlay0 }

    var windowBackground: NSColor { p.mantle }
    var controlBackground: NSColor { p.crust }
    var textBackground: NSColor { p.base }

    var primaryText: NSColor { p.text }
    var secondaryText: NSColor { mutedText }
    var labelText: NSColor { p.text }

    var accent: NSColor { p.blue }
    var border: NSColor { p.surface1 }
    var separator: NSColor { p.surface1 }

    var activeTabBackground: NSColor { p.surface0 }
    var inactiveTabBackground: NSColor { p.crust }
    var activeTabText: NSColor { p.text }
    var inactiveTabText: NSColor { mutedText }
    var activeTabBorder: NSColor { p.blue }

    var terminalBackground: NSColor { p.base }
    var terminalForeground: NSColor { p.text }
    var terminalCursor: NSColor { p.rosewater }

    var green: NSColor { p.green }
    var red: NSColor { p.red }
    var yellow: NSColor { p.yellow }
    var blue: NSColor { p.blue }
}

// MARK: - Theme Engine

class Theme {
    static let shared = Theme()

    /// The resolved theme currently in effect (after auto resolution).
    private(set) var definition: ThemeDefinition
    private(set) var palette: ResolvedPalette
    private(set) var current: ThemeColors

    /// All selectable themes: built-ins plus any user JSON files.
    private(set) var available: [ThemeDefinition]

    /// What the user picked: a theme name, or "auto" to follow the system.
    static let autoSelection = "auto"
    private(set) var selection: String

    /// Convenience for the terminal's 16-color ANSI install.
    var ansiColors: [SwiftTerm.Color] { palette.ansi16 }

    private init() {
        let userThemes = Theme.loadUserThemes()
        self.available = ThemeDefinition.builtIns + userThemes
        self.selection = ThemeDefinition.catppuccinMocha.name
        let initial = ThemeDefinition.catppuccinMocha
        self.definition = initial
        self.palette = ResolvedPalette(initial.palette, appearance: initial.appearance)
        self.current = PaletteThemeColors(p: self.palette)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    /// Apply the selection stored in config (a theme name or "auto").
    func loadFromConfig(_ config: Config) {
        setSelection(config.theme.name)
    }

    /// Change the active selection and apply the resolved theme.
    func setSelection(_ name: String) {
        selection = name
        applyResolved()
    }

    private func applyResolved() {
        let resolved = resolve(selection)
        definition = resolved
        palette = ResolvedPalette(resolved.palette, appearance: resolved.appearance)
        current = PaletteThemeColors(p: palette)
        applyAppAppearance()
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }

    /// Resolve a selection string to a concrete theme.
    private func resolve(_ name: String) -> ThemeDefinition {
        if name == Theme.autoSelection {
            let wantDark = systemIsDark()
            if let match = available.first(where: { $0.appearance == (wantDark ? .dark : .light) }) {
                return match
            }
        }
        return available.first(where: { $0.name == name }) ?? ThemeDefinition.catppuccinMocha
    }

    private func applyAppAppearance() {
        guard let app = NSApp else { return }
        if selection == Theme.autoSelection {
            app.appearance = nil  // follow the system
        } else {
            app.appearance = NSAppearance(named: definition.appearance == .dark ? .darkAqua : .aqua)
        }
    }

    private func systemIsDark() -> Bool {
        if let appearance = NSApp?.effectiveAppearance,
           let match = appearance.bestMatch(from: [.aqua, .darkAqua]) {
            return match == .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    @objc private func systemAppearanceChanged() {
        guard selection == Theme.autoSelection else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyResolved()
        }
    }

    private static func loadUserThemes() -> [ThemeDefinition] {
        let dir = NSString(string: "~/.config/cortland/themes").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        let decoder = JSONDecoder()
        var themes: [ThemeDefinition] = []
        for file in files where file.hasSuffix(".json") {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let theme = try? decoder.decode(ThemeDefinition.self, from: data) else {
                Log.error("⚠️ Skipping unreadable theme file: \(file)", category: "theme")
                continue
            }
            // Don't let a user file shadow a built-in name.
            if ThemeDefinition.builtIns.contains(where: { $0.name == theme.name }) { continue }
            for violation in ThemeContrast.validate(theme) {
                Log.error("⚠️ Theme \(theme.name) fails contrast contract — \(violation)", category: "theme")
            }
            themes.append(theme)
        }
        return themes
    }
}

extension Notification.Name {
    static let themeDidChange = Notification.Name("themeDidChange")
}

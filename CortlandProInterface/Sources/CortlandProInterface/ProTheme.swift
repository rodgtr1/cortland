import AppKit

/// The chrome color roles Pro views paint with. The app owns the theme engine,
/// so it fills this in at launch and again on every theme change; Pro code
/// reads `ProTheme.colors` instead of reaching for the app's `AppTheme`.
///
/// Values rather than closures: views read a color when they build a cell, and
/// every Pro surface rebuilds its cells on reload, so refreshing the struct on
/// `themeDidChange` repaints them the same way `AppTheme` does today.
public struct ProThemeColors: Sendable {
    public var windowBackground: NSColor
    public var sidebarBackground: NSColor
    public var headerBackground: NSColor

    public var primaryText: NSColor
    public var secondaryText: NSColor
    public var mutedText: NSColor
    public var dimText: NSColor

    public var accent: NSColor
    public var success: NSColor
    public var warning: NSColor
    public var error: NSColor

    public var buttonBackground: NSColor
    public var selection: NSColor
    public var border: NSColor
    public var divider: NSColor

    public init(
        windowBackground: NSColor,
        sidebarBackground: NSColor,
        headerBackground: NSColor,
        primaryText: NSColor,
        secondaryText: NSColor,
        mutedText: NSColor,
        dimText: NSColor,
        accent: NSColor,
        success: NSColor,
        warning: NSColor,
        error: NSColor,
        buttonBackground: NSColor,
        selection: NSColor,
        border: NSColor,
        divider: NSColor
    ) {
        self.windowBackground = windowBackground
        self.sidebarBackground = sidebarBackground
        self.headerBackground = headerBackground
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.mutedText = mutedText
        self.dimText = dimText
        self.accent = accent
        self.success = success
        self.warning = warning
        self.error = error
        self.buttonBackground = buttonBackground
        self.selection = selection
        self.border = border
        self.divider = divider
    }

    /// System colors, used before the app has published its palette (and in
    /// unit tests, which build views without booting the theme engine).
    public static let systemFallback = ProThemeColors(
        windowBackground: .windowBackgroundColor,
        sidebarBackground: .underPageBackgroundColor,
        headerBackground: .controlBackgroundColor,
        primaryText: .labelColor,
        secondaryText: .secondaryLabelColor,
        mutedText: .tertiaryLabelColor,
        dimText: .quaternaryLabelColor,
        accent: .controlAccentColor,
        success: .systemGreen,
        warning: .systemYellow,
        error: .systemRed,
        buttonBackground: .controlColor,
        selection: .selectedContentBackgroundColor,
        border: .separatorColor,
        divider: .separatorColor
    )
}

/// The live palette, published by the app.
public enum ProTheme {
    public static var colors: ProThemeColors = .systemFallback
}

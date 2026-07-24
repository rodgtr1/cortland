import Cocoa
import SwiftTerm

// MARK: - Canonical Theme Schema
//
// A theme is the Catppuccin-style named palette (the same 26 slots every
// Catppuccin flavor publishes) plus an appearance flag and identity. The
// existing AppTheme / ThemeColors role mappings read from this palette, so a
// new theme only has to supply palette values — the role→color logic is shared.
//
// Built-in themes are defined in Swift (always available, no resource-bundle
// dependency). A JSON file with this exact shape dropped into
// ~/.config/cortland/themes/ decodes into the same type, so community palettes
// can be translated into our format without code changes.

enum ThemeAppearance: String, Codable {
    case light
    case dark
}

struct ThemeDefinition: Codable {
    let name: String          // stable id, e.g. "catppuccin-mocha"
    let displayName: String   // shown in Preferences, e.g. "Catppuccin Mocha"
    let appearance: ThemeAppearance
    let palette: ThemePalette
}

/// The 26 named Catppuccin slots. Same key names across all flavors, which is
/// what makes translating another flavor (or any palette using these names) a
/// drop-in.
struct ThemePalette: Codable {
    // Accent colors
    let rosewater: String
    let flamingo: String
    let pink: String
    let mauve: String
    let red: String
    let maroon: String
    let peach: String
    let yellow: String
    let green: String
    let teal: String
    let sky: String
    let sapphire: String
    let blue: String
    let lavender: String

    // Text ramp (lightest → muted)
    let text: String
    let subtext1: String
    let subtext0: String
    let overlay2: String
    let overlay1: String
    let overlay0: String

    // Surfaces (lightest → darkest in dark themes)
    let surface2: String
    let surface1: String
    let surface0: String
    let base: String
    let mantle: String
    let crust: String
}

/// Palette with hex strings resolved to NSColor once, so role lookups during
/// drawing don't re-parse hex on every access.
struct ResolvedPalette {
    let rosewater, flamingo, pink, mauve, red, maroon, peach, yellow, green, teal, sky, sapphire, blue, lavender: NSColor
    let text, subtext1, subtext0, overlay2, overlay1, overlay0: NSColor
    let surface2, surface1, surface0, base, mantle, crust: NSColor

    init(_ p: ThemePalette) {
        func c(_ hex: String) -> NSColor { NSColor(hex: hex) ?? .black }
        rosewater = c(p.rosewater); flamingo = c(p.flamingo); pink = c(p.pink)
        mauve = c(p.mauve); red = c(p.red); maroon = c(p.maroon); peach = c(p.peach)
        yellow = c(p.yellow); green = c(p.green); teal = c(p.teal); sky = c(p.sky)
        sapphire = c(p.sapphire); blue = c(p.blue); lavender = c(p.lavender)
        text = c(p.text); subtext1 = c(p.subtext1); subtext0 = c(p.subtext0)
        overlay2 = c(p.overlay2); overlay1 = c(p.overlay1); overlay0 = c(p.overlay0)
        surface2 = c(p.surface2); surface1 = c(p.surface1); surface0 = c(p.surface0)
        base = c(p.base); mantle = c(p.mantle); crust = c(p.crust)
    }

    /// Standard Catppuccin terminal mapping for the first 16 ANSI colors.
    /// Matches the palette that shipped hardcoded as ColorPalette.catppuccinMocha.
    var ansi16: [SwiftTerm.Color] {
        func tc(_ color: NSColor) -> SwiftTerm.Color {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return SwiftTerm.Color(
                red: UInt16((rgb.redComponent * 65535).rounded()),
                green: UInt16((rgb.greenComponent * 65535).rounded()),
                blue: UInt16((rgb.blueComponent * 65535).rounded())
            )
        }
        return [
            tc(surface1),  // black
            tc(red),       // red
            tc(green),     // green
            tc(yellow),    // yellow
            tc(blue),      // blue
            tc(pink),      // magenta
            tc(teal),      // cyan
            tc(subtext1),  // white
            tc(surface2),  // bright black
            tc(red),       // bright red
            tc(green),     // bright green
            tc(yellow),    // bright yellow
            tc(blue),      // bright blue
            tc(pink),      // bright magenta
            tc(teal),      // bright cyan
            tc(subtext0)   // bright white
        ]
    }
}

// MARK: - Built-in Themes

extension ThemeDefinition {
    /// The defining theme. Values are identical to the previous hardcoded
    /// Catppuccin Mocha palette, so its appearance is unchanged.
    static let catppuccinMocha = ThemeDefinition(
        name: "catppuccin-mocha",
        displayName: "Catppuccin Mocha",
        appearance: .dark,
        palette: ThemePalette(
            rosewater: "#f5e0dc", flamingo: "#f2cdcd", pink: "#f5c2e7", mauve: "#cba6f7",
            red: "#f38ba8", maroon: "#eba0ac", peach: "#fab387", yellow: "#f9e2af",
            green: "#a6e3a1", teal: "#94e2d5", sky: "#89dceb", sapphire: "#74c7ec",
            blue: "#89b4fa", lavender: "#b4befe",
            text: "#cdd6f4", subtext1: "#bac2de", subtext0: "#a6adc8",
            overlay2: "#9399b2", overlay1: "#7f849c", overlay0: "#6c7086",
            surface2: "#585b70", surface1: "#45475a", surface0: "#313244",
            base: "#1e1e2e", mantle: "#181825", crust: "#11111b"
        )
    )

    /// Light counterpart, derived from the official Catppuccin Latte palette.
    static let catppuccinLatte = ThemeDefinition(
        name: "catppuccin-latte",
        displayName: "Catppuccin Latte",
        appearance: .light,
        palette: ThemePalette(
            rosewater: "#dc8a78", flamingo: "#dd7878", pink: "#ea76cb", mauve: "#8839ef",
            red: "#d20f39", maroon: "#e64553", peach: "#fe640b", yellow: "#df8e1d",
            green: "#40a02b", teal: "#179299", sky: "#04a5e5", sapphire: "#209fb5",
            blue: "#1e66f5", lavender: "#7287fd",
            text: "#4c4f69", subtext1: "#5c5f77", subtext0: "#6c6f85",
            overlay2: "#7c7f93", overlay1: "#8c8fa1", overlay0: "#9ca0b0",
            surface2: "#acb0be", surface1: "#bcc0cc", surface0: "#ccd0da",
            base: "#eff1f5", mantle: "#e6e9ef", crust: "#dce0e8"
        )
    )

    /// Translated from Miguel Solorio's "Min Light" VS Code theme into our
    /// palette schema. A minimal, mostly-monochrome light theme.
    static let minLight = ThemeDefinition(
        name: "min-light",
        displayName: "Min Light",
        appearance: .light,
        palette: ThemePalette(
            rosewater: "#d75f5f", flamingo: "#dd7878", pink: "#a626a4", mauve: "#6f42c1",
            red: "#d32f2f", maroon: "#cd3131", peach: "#dd8500", yellow: "#b08500",
            green: "#22863a", teal: "#0c8b8b", sky: "#0288d1", sapphire: "#1565c0",
            blue: "#1976d2", lavender: "#6871ff",
            text: "#212121", subtext1: "#424242", subtext0: "#757575",
            overlay2: "#9e9e9e", overlay1: "#b0b0b0", overlay0: "#c2c3c5",
            surface2: "#d0d0d0", surface1: "#dddddd", surface0: "#eeeeee",
            base: "#ffffff", mantle: "#f6f6f6", crust: "#ececec"
        )
    )

    static let builtIns: [ThemeDefinition] = [catppuccinMocha, catppuccinLatte, minLight]
}

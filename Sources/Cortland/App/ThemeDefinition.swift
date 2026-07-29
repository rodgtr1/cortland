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
    let isLight: Bool

    init(_ p: ThemePalette, appearance: ThemeAppearance) {
        isLight = appearance == .light
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
    /// The gray slots depend on appearance: programs print black/bright-black
    /// expecting it to read against the background, so light themes take those
    /// from the subtext ramp (dark grays) and push the surface grays into the
    /// white slots — the same swap Catppuccin's official ANSI spec makes for
    /// Latte. Dark themes keep the mapping that shipped hardcoded as
    /// ColorPalette.catppuccinMocha.
    var ansi16: [SwiftTerm.Color] {
        func tc(_ color: NSColor) -> SwiftTerm.Color {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return SwiftTerm.Color(
                red: UInt16((rgb.redComponent * 65535).rounded()),
                green: UInt16((rgb.greenComponent * 65535).rounded()),
                blue: UInt16((rgb.blueComponent * 65535).rounded())
            )
        }
        let black = isLight ? subtext1 : surface1
        let brightBlack = isLight ? subtext0 : surface2
        let white = isLight ? surface2 : subtext1
        let brightWhite = isLight ? surface1 : subtext0
        return [
            tc(black),       // black
            tc(red),         // red
            tc(green),       // green
            tc(yellow),      // yellow
            tc(blue),        // blue
            tc(pink),        // magenta
            tc(teal),        // cyan
            tc(white),       // white
            tc(brightBlack), // bright black
            tc(red),         // bright red
            tc(green),       // bright green
            tc(yellow),      // bright yellow
            tc(blue),        // bright blue
            tc(pink),        // bright magenta
            tc(teal),        // bright cyan
            tc(brightWhite)  // bright white
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

    /// Official Catppuccin Frappé palette — the lower-contrast dark flavor.
    static let catppuccinFrappe = ThemeDefinition(
        name: "catppuccin-frappe",
        displayName: "Catppuccin Frappé",
        appearance: .dark,
        palette: ThemePalette(
            rosewater: "#f2d5cf", flamingo: "#eebebe", pink: "#f4b8e4", mauve: "#ca9ee6",
            red: "#e78284", maroon: "#ea999c", peach: "#ef9f76", yellow: "#e5c890",
            green: "#a6d189", teal: "#81c8be", sky: "#99d1db", sapphire: "#85c1dc",
            blue: "#8caaee", lavender: "#babbf1",
            text: "#c6d0f5", subtext1: "#b5bfe2", subtext0: "#a5adce",
            overlay2: "#949cbb", overlay1: "#838ba7", overlay0: "#737994",
            surface2: "#626880", surface1: "#51576d", surface0: "#414559",
            base: "#303446", mantle: "#292c3c", crust: "#232634"
        )
    )

    /// Official Catppuccin Macchiato palette — between Frappé and Mocha.
    static let catppuccinMacchiato = ThemeDefinition(
        name: "catppuccin-macchiato",
        displayName: "Catppuccin Macchiato",
        appearance: .dark,
        palette: ThemePalette(
            rosewater: "#f4dbd6", flamingo: "#f0c6c6", pink: "#f5bde6", mauve: "#c6a0f6",
            red: "#ed8796", maroon: "#ee99a0", peach: "#f5a97f", yellow: "#eed49f",
            green: "#a6da95", teal: "#8bd5ca", sky: "#91d7e3", sapphire: "#7dc4e4",
            blue: "#8aadf4", lavender: "#b7bdf8",
            text: "#cad3f5", subtext1: "#b8c0e0", subtext0: "#a5adcb",
            overlay2: "#939ab7", overlay1: "#8087a2", overlay0: "#6e738d",
            surface2: "#5b6078", surface1: "#494d64", surface0: "#363a4f",
            base: "#24273a", mantle: "#1e2030", crust: "#181926"
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
            overlay2: "#8e8e8e", overlay1: "#9e9e9e", overlay0: "#ababab",
            surface2: "#d0d0d0", surface1: "#dddddd", surface0: "#eeeeee",
            base: "#ffffff", mantle: "#f6f6f6", crust: "#ececec"
        )
    )

    // Mocha stays first: "auto" resolves to the first theme matching the
    // system appearance, so order here decides the auto dark/light defaults
    // (Mocha and Latte).
    static let builtIns: [ThemeDefinition] = [
        catppuccinMocha, catppuccinLatte, catppuccinFrappe, catppuccinMacchiato, minLight,
    ]
}

// MARK: - Contrast Contract
//
// What a palette must deliver for the shared role mapping to stay readable.
// The slots are named after Catppuccin's, and the contract matches how the
// roles and ANSI table consume them:
//
//   text     on base/mantle: primary text and terminal foreground — ≥ 6.5:1
//   subtext0 on base/mantle: secondary text (light themes), ANSI grays — ≥ 4:1
//   subtext1 on base:        ANSI black in light themes, white in dark — ≥ 4.5:1
//   overlay0 on base:        secondary text in dark themes only — ≥ 2.8:1
//
// Floors sit just under the official Catppuccin values (Latte binds the text
// and subtext checks: text/mantle 6.57, subtext0/base 4.37; Frappé, the
// deliberately soft flavor, binds overlay0 at 2.87), so real palettes pass
// and the failure mode this guards against — grays near 2:1 on a light
// background — is caught with room to spare.
//
// `validate` checks these and returns human-readable violations. Built-ins are
// held to it by ThemeContrastTests; user JSON themes get the same check at
// load, logged as warnings rather than rejected.
enum ThemeContrast {
    /// WCAG relative luminance.
    static func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func f(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * f(rgb.redComponent) + 0.7152 * f(rgb.greenComponent) + 0.0722 * f(rgb.blueComponent)
    }

    /// WCAG contrast ratio, 1...21.
    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Contract violations for a theme, empty when it passes.
    static func validate(_ definition: ThemeDefinition) -> [String] {
        let p = ResolvedPalette(definition.palette, appearance: definition.appearance)
        var checks: [(fg: NSColor, bg: NSColor, min: Double, what: String)] = [
            (p.text, p.base, 6.5, "text on base"),
            (p.text, p.mantle, 6.5, "text on mantle"),
            (p.subtext0, p.base, 4.3, "subtext0 on base"),
            (p.subtext0, p.mantle, 4.0, "subtext0 on mantle"),
            (p.subtext1, p.base, 4.5, "subtext1 on base"),
        ]
        if !p.isLight {
            checks.append((p.overlay0, p.base, 2.8, "overlay0 on base"))
        }
        return checks.compactMap { check in
            let r = ratio(check.fg, check.bg)
            guard r < check.min else { return nil }
            return String(format: "%@: %.2f:1, needs ≥ %.1f:1", check.what, r, check.min)
        }
    }
}

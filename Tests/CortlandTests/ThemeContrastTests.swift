import XCTest
@testable import Cortland

/// Holds every built-in theme to the contrast contract documented in
/// ThemeDefinition.swift, and pins the appearance-dependent pieces of the role
/// and ANSI mappings so a future theme can't quietly ship unreadable text.
@MainActor
final class ThemeContrastTests: XCTestCase {

    func testBuiltInThemesMeetContrastContract() {
        for theme in ThemeDefinition.builtIns {
            let violations = ThemeContrast.validate(theme)
            XCTAssertTrue(violations.isEmpty, "\(theme.name): \(violations.joined(separator: "; "))")
        }
    }

    /// The de-emphasized text roles must stay readable on the surfaces they are
    /// drawn over, in every theme: secondaryText on the window background and
    /// inactiveTabText on the inactive tab background. Floor of 3.1 sits under
    /// the current worst passing case (Frappé secondaryText at 3.22 — the
    /// deliberately soft flavor) and far above the ~2:1 failures this guards
    /// against.
    func testMutedTextRolesAreReadable() {
        for theme in ThemeDefinition.builtIns {
            let colors = PaletteThemeColors(p: ResolvedPalette(theme.palette, appearance: theme.appearance))
            let secondary = ThemeContrast.ratio(colors.secondaryText, colors.windowBackground)
            XCTAssertGreaterThanOrEqual(secondary, 3.1, "\(theme.name): secondaryText on windowBackground is \(secondary)")
            let inactiveTab = ThemeContrast.ratio(colors.inactiveTabText, colors.inactiveTabBackground)
            XCTAssertGreaterThanOrEqual(inactiveTab, 3.1, "\(theme.name): inactiveTabText on inactiveTabBackground is \(inactiveTab)")
        }
    }

    /// Terminal gray slots: whichever of black/white is the "readable text"
    /// side for the appearance must read against the terminal background. In
    /// light themes that's ANSI black and bright black (dim CLI hints,
    /// prompts); in dark themes, white and bright white. Floor of 4.3 admits
    /// official Latte (bright black at 4.37); before the appearance-aware
    /// mapping these slots sat at 1.6–1.9.
    func testAnsiGraySlotsAreReadable() {
        for theme in ThemeDefinition.builtIns {
            let palette = ResolvedPalette(theme.palette, appearance: theme.appearance)
            let ansi = palette.ansi16
            let readableSlots = palette.isLight ? [0, 8] : [7, 15]
            for slot in readableSlots {
                let color = NSColor(
                    srgbRed: CGFloat(ansi[slot].red) / 65535,
                    green: CGFloat(ansi[slot].green) / 65535,
                    blue: CGFloat(ansi[slot].blue) / 65535,
                    alpha: 1
                )
                let ratio = ThemeContrast.ratio(color, palette.base)
                XCTAssertGreaterThanOrEqual(ratio, 4.3, "\(theme.name): ANSI slot \(slot) on base is \(ratio)")
            }
        }
    }

    /// Mocha's mapping must not drift: it is the reference look, and the
    /// appearance-aware branches are supposed to leave dark themes untouched.
    func testMochaMappingUnchanged() {
        let palette = ResolvedPalette(ThemeDefinition.catppuccinMocha.palette, appearance: .dark)
        let colors = PaletteThemeColors(p: palette)
        XCTAssertEqual(colors.secondaryText, palette.overlay0)
        XCTAssertEqual(colors.inactiveTabText, palette.overlay0)
        // Black stays surface1, white stays subtext1 in dark themes.
        let ansi = palette.ansi16
        XCTAssertEqual(UInt16((palette.surface1.usingColorSpace(.sRGB)!.redComponent * 65535).rounded()), ansi[0].red)
        XCTAssertEqual(UInt16((palette.subtext1.usingColorSpace(.sRGB)!.redComponent * 65535).rounded()), ansi[7].red)
    }
}

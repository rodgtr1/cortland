import Cocoa
import CortlandTelemetryCore
import CortlandProInterface
#if CORTLAND_PRO
import CortlandPro
#endif

/// The app side of the free/Pro seam.
///
/// Two jobs, both run once at launch: publish the values the Pro layer needs
/// from the app (the theme palette, refreshed on every theme change), and —
/// only in an official build — hand the `ProFeatures` registry its
/// implementations. A public clone compiles this file with `CORTLAND_PRO`
/// undefined, so the registry stays empty and every feature takes its free
/// path.
enum ProBridge {
    /// Kept alive for the process lifetime so the palette follows theme changes.
    private static var themeObserver: ThemeObserver?

    static func bootstrap() {
        installLogSink()
        publishTheme()
        themeObserver = ThemeObserver { publishTheme() }

        #if CORTLAND_PRO
        CortlandPro.register()
        Log.info("Pro features registered", category: "app")
        #endif

        // Handed over after registration, so a provider is there to receive it.
        // Free builds register nothing and these are no-ops.
        ProFeatures.costReporting?.install(formatting: ProCostFormatting(
            cost: TelemetryFormat.cost,
            tokens: TelemetryFormat.compactTokens,
            shortModel: TelemetryFormat.shortModel
        ))
    }

    /// Pro code logs through `ProLog`; route it into the app's own log file so
    /// a Pro build produces one log, not two.
    private static func installLogSink() {
        ProLog.sink = { level, message, category in
            switch level {
            case .debug: Log.debug(message, category: category)
            case .info: Log.info(message, category: category)
            case .error: Log.error(message, category: category)
            }
        }
    }

    /// Mirrors `AppTheme`'s chrome roles into the seam. Pro views read
    /// `ProTheme.colors`; this keeps the two in step without giving the Pro
    /// package a view of the theme engine.
    private static func publishTheme() {
        ProTheme.colors = ProThemeColors(
            windowBackground: AppTheme.windowBackground,
            sidebarBackground: AppTheme.sidebarBackground,
            headerBackground: AppTheme.headerBackground,
            primaryText: AppTheme.primaryText,
            secondaryText: AppTheme.secondaryText,
            mutedText: AppTheme.mutedText,
            dimText: AppTheme.dimText,
            accent: AppTheme.accent,
            success: AppTheme.success,
            warning: AppTheme.warning,
            error: AppTheme.error,
            buttonBackground: AppTheme.buttonBackground,
            selection: AppTheme.selection,
            border: AppTheme.border,
            divider: AppTheme.divider
        )
    }
}

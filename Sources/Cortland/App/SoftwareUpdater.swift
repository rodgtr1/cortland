import Cocoa
import Sparkle

/// What `Info.plist` says about self-updating, read without touching Sparkle so
/// it can be checked against a plain dictionary in tests.
///
/// Both keys have to be there and well formed. A missing or malformed one is
/// not an error to shout about — an unbundled `swift run` build legitimately
/// has neither — it just means this build cannot update itself, and the menu
/// item says so by staying disabled.
nonisolated struct SoftwareUpdateSettings: Sendable, Equatable {
    let feedURL: String?
    let publicEDKey: String?

    init(infoDictionary: [String: Any]?) {
        feedURL = infoDictionary?["SUFeedURL"] as? String
        publicEDKey = infoDictionary?["SUPublicEDKey"] as? String
    }

    /// True when this build can check for updates: an https feed (Sparkle
    /// refuses plain http except on localhost) and a 32-byte Ed25519 public key.
    var isConfigured: Bool {
        unconfiguredReason == nil
    }

    /// Why updates are off, phrased for the log. `nil` when they are on.
    var unconfiguredReason: String? {
        guard let feedURL, !feedURL.isEmpty else {
            return "no SUFeedURL in Info.plist"
        }
        guard let url = URL(string: feedURL), let scheme = url.scheme?.lowercased() else {
            return "SUFeedURL is not a URL"
        }
        // Sparkle itself enforces this; catching it here keeps a typo from
        // becoming a runtime error dialog on someone's first launch.
        if scheme != "https" && !(scheme == "http" && (url.host == "localhost" || url.host == "127.0.0.1")) {
            return "SUFeedURL must be https (or http on localhost)"
        }
        guard let publicEDKey, !publicEDKey.isEmpty else {
            return "no SUPublicEDKey in Info.plist"
        }
        guard let decoded = Data(base64Encoded: publicEDKey), decoded.count == 32 else {
            return "SUPublicEDKey is not a base64 32-byte Ed25519 key"
        }
        return nil
    }
}

/// Owns the Sparkle updater for the app's lifetime.
///
/// Sparkle's defaults are kept as they come: it asks on first launch before
/// checking anything, checks on its own schedule after that, and always shows
/// the user the release notes and an Install button. Nothing installs silently.
final class SoftwareUpdater {
    static let shared = SoftwareUpdater()

    private var controller: SPUStandardUpdaterController?

    private init() {}

    /// Starts the updater if this build is configured for it. Safe to call once
    /// from `applicationDidFinishLaunching`; later calls are ignored.
    func start() {
        guard controller == nil else { return }

        let settings = SoftwareUpdateSettings(infoDictionary: Bundle.main.infoDictionary)
        if let reason = settings.unconfiguredReason {
            Log.info("Software updates off (\(reason))", category: "update")
            return
        }

        // startingUpdater: true kicks off Sparkle's own scheduling. The nil
        // delegates take Sparkle's stock UI and consent behavior.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        Log.info("Software updates on (feed \(settings.feedURL ?? "?"))", category: "update")
    }

    /// Whether "Check for Updates…" should be clickable. False in an unbundled
    /// or unconfigured build, and while a check is already running.
    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// The user asked for a check, so this one is never silent: Sparkle reports
    /// "you're up to date" as well as an available update.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}

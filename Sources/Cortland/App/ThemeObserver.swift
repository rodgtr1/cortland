import Foundation

/// Small helper that calls `handler` on the main queue whenever the active
/// theme changes. Hold one as a property; it removes its observer on deinit.
///
/// Usage:
///   themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
final class ThemeObserver {
    // Touched on the main actor during the observer's life and read once in the
    // nonisolated deinit at end-of-life (no other reference can exist then).
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init(_ handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .themeDidChange,
            object: nil,
            queue: .main
        ) { _ in
            // The observer is delivered on the main queue (queue: .main above),
            // so it's safe to run the main-actor handler synchronously here.
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

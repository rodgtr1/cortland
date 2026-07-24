import Foundation

/// App-wide terminal font zoom. All terminals share one scale factor so
/// Cmd+= / Cmd+- / Cmd+0 zoom every pane atomically, and new terminals
/// pick up the current scale.
final class FontZoom {
    static let shared = FontZoom()
    static let didChangeNotification = Notification.Name("FontZoomDidChange")

    private static let minScale: Double = 0.4
    private static let maxScale: Double = 4.0
    private static let step: Double = 1.1

    private(set) var scale: Double = 1.0

    private init() {}

    func zoomIn() {
        setScale(scale * Self.step)
    }

    func zoomOut() {
        setScale(scale / Self.step)
    }

    func reset() {
        setScale(1.0)
    }

    private func setScale(_ newScale: Double) {
        let clamped = min(Self.maxScale, max(Self.minScale, newScale))
        guard clamped != scale else { return }
        scale = clamped
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

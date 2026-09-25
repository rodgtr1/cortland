import Cocoa

/// The editor's clip view. With word wrap on, the text view must be exactly as
/// wide as the visible area and never scrolled sideways; otherwise the ruler
/// hides the first characters of every line and the right edge clips the last
/// ones. NSScrollView's autoresizing usually keeps the two in step, but the
/// ruler being added and the pane being split both re-tile the scroll view in
/// ways that let the document drift wider than the clip and scroll under the
/// ruler. This pins both.
final class EditorClipView: NSClipView {
    /// True when word wrap is on: the document is kept at the visible width and
    /// horizontal scrolling is disabled.
    var pinsDocumentToVisibleWidth = true {
        didSet {
            guard pinsDocumentToVisibleWidth else { return }
            matchDocumentWidth()
            scroll(to: NSPoint(x: 0, y: bounds.origin.y))
        }
    }

    // MARK: - No sideways scrolling

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        pinned(super.constrainBoundsRect(proposedBounds))
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: pinned(newOrigin))
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(pinned(newOrigin))
    }

    private func pinned(_ rect: NSRect) -> NSRect {
        var rect = rect
        rect.origin = pinned(rect.origin)
        return rect
    }

    private func pinned(_ point: NSPoint) -> NSPoint {
        pinsDocumentToVisibleWidth ? NSPoint(x: 0, y: point.y) : point
    }

    // MARK: - Document as wide as the clip, no wider

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        matchDocumentWidth()
    }

    override var documentView: NSView? {
        didSet { matchDocumentWidth() }
    }

    /// NSScrollView re-sizes the document itself while tiling (to its idea of
    /// the content size, which can disagree with this view's bounds while a
    /// ruler is being added or a pane is being split). Every document frame
    /// change comes through here, so correct it back to the visible width.
    override func viewFrameChanged(_ notification: Notification) {
        super.viewFrameChanged(notification)
        matchDocumentWidth()
    }

    private func matchDocumentWidth() {
        guard pinsDocumentToVisibleWidth,
              let document = documentView,
              bounds.width > 0,
              document.frame.width != bounds.width else { return }
        document.setFrameSize(NSSize(width: bounds.width, height: document.frame.height))
    }
}

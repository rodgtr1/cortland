import Cocoa

/// Lays out a preferences pane as a top-to-bottom run of rows inside a tab
/// view. Each `add…` helper pins its row below the previous one by the given
/// gap and advances an internal cursor, so a new preference is one or two row
/// calls instead of ~15 lines of manual constraints. The builder owns the
/// static field labels and the vertical stacking; the caller owns the
/// interactive controls (it wires targets/actions and reads them back in
/// loadCurrentSettings) and any wrapping help/status labels whose attributes
/// vary. The metrics below (20pt leading inset, 50pt value-label column, label
/// fonts) match the previous hand-written constraints, so the panes look
/// identical.
@MainActor
final class PreferencesFormBuilder {
    private let container: NSView
    /// Bottom edge of the last row added; the next row hangs off this.
    private var cursor: NSLayoutYAxisAnchor
    private let leadingInset: CGFloat = 20
    private let trailingInset: CGFloat = -20

    init(container: NSView) {
        self.container = container
        self.cursor = container.topAnchor
    }

    /// A bold field/section label. Created here because callers never reference
    /// these again; advances the cursor to its bottom.
    @discardableResult
    func fieldLabel(_ text: String, gapAbove: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = AppTheme.primaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: cursor, constant: gapAbove),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset)
        ])
        cursor = label.bottomAnchor
        return label
    }

    /// A leading-pinned control (popup, button), optionally a fixed width.
    @discardableResult
    func leadingControl(_ control: NSView, gapAbove: CGFloat, width: CGFloat? = nil) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        var constraints = [
            control.topAnchor.constraint(equalTo: cursor, constant: gapAbove),
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset)
        ]
        if let width {
            constraints.append(control.widthAnchor.constraint(equalToConstant: width))
        }
        NSLayoutConstraint.activate(constraints)
        cursor = control.bottomAnchor
        return control
    }

    /// A view pinned leading+trailing (a full-width text field, or a wrapping
    /// help/status label whose font and line count the caller set).
    @discardableResult
    func fullWidth(_ view: NSView, gapAbove: CGFloat) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: cursor, constant: gapAbove),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: trailingInset)
        ])
        cursor = view.bottomAnchor
        return view
    }

    /// A slider with a right-aligned value label in a fixed 50pt column, the
    /// label top-aligned to the slider.
    func sliderRow(_ slider: NSSlider, valueLabel: NSTextField, gapAbove: CGFloat) {
        slider.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(slider)
        container.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            slider.topAnchor.constraint(equalTo: cursor, constant: gapAbove),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
            slider.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -10),

            valueLabel.topAnchor.constraint(equalTo: slider.topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: trailingInset),
            valueLabel.widthAnchor.constraint(equalToConstant: 50)
        ])
        cursor = slider.bottomAnchor
    }

    /// Pin the last row's bottom to the container's bottom so the container has
    /// a defined fitting height. Required when the container is a scroll view's
    /// document view: without it the document has no intrinsic height and tall
    /// content clips instead of scrolling.
    func finish(gapBelow: CGFloat = 20) {
        NSLayoutConstraint.activate([
            container.bottomAnchor.constraint(equalTo: cursor, constant: gapBelow)
        ])
    }

    /// A single leading-pinned checkbox.
    @discardableResult
    func checkbox(_ button: NSButton, gapAbove: CGFloat) -> NSButton {
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: cursor, constant: gapAbove),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset)
        ])
        cursor = button.bottomAnchor
        return button
    }

    /// A name label with a trailing action button on the same baseline, and a
    /// wrapping status label beneath — the repeating row on the Agents tab.
    func agentRow(name: String, statusLabel: NSTextField, button: NSButton, gapAbove: CGFloat) {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = AppTheme.primaryText
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)
        container.addSubview(statusLabel)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: cursor, constant: gapAbove),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),

            button.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: trailingInset),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: trailingInset)
        ])
        cursor = statusLabel.bottomAnchor
    }
}

import Cocoa

/// One session row: an agent glyph, the (aiTitle-preferred) title, and a muted
/// subtitle of "agent · repo · relative age". Modeled on the palette's
/// `PaletteActionCellView`, using the published `ProTheme` colors.
///
/// Shared so the free teaser and the Pro recall panel render identical rows —
/// the Pro panel additionally passes a deep-search `snippet`.
public final class SessionRowCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = ProTheme.colors.accent

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = ProTheme.colors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = ProTheme.colors.mutedText
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    /// Configure the row. When a deep-search `snippet` is supplied, it replaces
    /// the usual "agent · repo · age" subtitle with the matching context so you
    /// can see *where* the phrase hit.
    public func configure(with record: SessionRecord, snippet: String? = nil) {
        let symbol = record.agent == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right"
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: record.agent.rawValue)
        titleLabel.stringValue = record.aiTitle ?? record.generatedTitle ?? record.title
        if let snippet, !snippet.isEmpty {
            subtitleLabel.stringValue = snippet
        } else {
            subtitleLabel.stringValue = Self.subtitle(for: record)
        }
    }

    /// "agent · repo · relative age", skipping whatever the record doesn't have.
    public static func subtitle(for record: SessionRecord) -> String {
        var parts: [String] = [record.agent.rawValue]
        if let repo = record.repo, !repo.isEmpty {
            parts.append(repo)
        }
        if let age = relativeAge(record.timestamp) {
            parts.append(age)
        }
        return parts.joined(separator: " · ")
    }

    private static func relativeAge(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ageFormatter.localizedString(for: date, relativeTo: Date())
    }
}

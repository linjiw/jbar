import AppKit
import JBarCore

/// One line of the results table: a real result, or an informational row.
enum PanelRow: Equatable {
    case result(ResultRow)
    /// "No matches for “query”" (dimmed, not selectable).
    case empty(query: String)
    /// First-run / empty-history hint with the key shortcuts (not selectable).
    case hint(String)
    /// Path-mode listing taking longer than ~300 ms.
    case loading
    /// A non-selectable action prompt, state, or response. Action rows never carry a path and
    /// cannot be opened/revealed/copied through the launcher result pipeline.
    case action(message: String, symbol: String)

    var result: ResultRow? {
        if case .result(let r) = self { return r }
        return nil
    }
    var isSelectable: Bool { result != nil }
}

/// `NSWorkspace.icon(forFile:)` results keyed by path, capped at 500 entries (DESIGN.md §7.2).
@MainActor
enum IconCache {
    static let iconSize: CGFloat = 32
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 500
        return c
    }()

    /// The Finder icon for `path` at `iconSize` points (generic document icon when the path is gone).
    static func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: iconSize, height: iconSize)
        cache.setObject(img, forKey: key)
        return img
    }

    /// Drop every cached icon (after an appearance change, for example).
    static func clear() { cache.removeAllObjects() }
}

/// Row container drawing the selection highlight (accent @ 18 %, 8 pt radius) and the hairline
/// that separates the app group from the file group.
final class ResultRowView: NSTableRowView {
    /// Draw a hairline along the top edge (set on the first non-app row after an app row).
    var drawsTopSeparator = false { didSet { if oldValue != drawsTopSeparator { needsDisplay = true } } }

    static let selectionAlpha: CGFloat = 0.18
    static let selectionRadius: CGFloat = 8

    /// AppKit can ask a freshly-created row to draw before the table has received its constrained
    /// size. `insetBy` turns a zero-sized placeholder into a negative rectangle, which produces
    /// runtime geometry faults even though the final row looks correct. Drawing is simply deferred
    /// until both dimensions are positive.
    nonisolated static func selectionRect(in bounds: NSRect) -> NSRect? {
        let rect = bounds.insetBy(dx: 8, dy: 2)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    nonisolated static func separatorRect(in bounds: NSRect, isFlipped: Bool) -> NSRect? {
        let width = bounds.width - 32
        guard width > 0, bounds.height >= 1 else { return nil }
        let y: CGFloat = isFlipped ? 0 : bounds.height - 1
        return NSRect(x: 16, y: y, width: width, height: 1)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none,
              let rect = Self.selectionRect(in: bounds) else { return }
        NSColor.controlAccentColor.withAlphaComponent(Self.selectionAlpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Self.selectionRadius, yRadius: Self.selectionRadius).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard drawsTopSeparator,
              let rect = Self.separatorRect(in: bounds, isFlipped: isFlipped) else { return }
        NSColor.separatorColor.setFill()
        rect.fill()
    }
}

/// Small rounded capsule with an uppercase kind label ("APP", "FOLDER", "PDF").
final class BadgeView: NSView {
    var text: String = "" {
        didSet { if oldValue != text { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }
    static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let height: CGFloat = 18
    private static let padding: CGFloat = 7

    override var intrinsicContentSize: NSSize {
        guard !text.isEmpty else { return .zero }
        let w = (text as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(w) + Self.padding * 2, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}

/// View-based cell: 32 pt icon, 15 pt name with matched characters bold+accent, dimmed trailing
/// parent path (≤ 45 % of the width, head-truncated) and a kind badge. Layout is manual (fast, no
/// Auto Layout churn while scrolling).
final class ResultCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("JBarResultCell")
    static let nameFont = NSFont.systemFont(ofSize: 15)
    static let nameBoldFont = NSFont.systemFont(ofSize: 15, weight: .bold)
    static let parentFont = NSFont.systemFont(ofSize: 12)
    static let maxParentFraction: CGFloat = 0.45

    let iconView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let parentLabel = NSTextField(labelWithString: "")
    let badge = BadgeView()

    /// Path of the row currently displayed (for debugging / tests).
    private(set) var path: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = Self.nameFont
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.maximumNumberOfLines = 1
        parentLabel.font = Self.parentFont
        parentLabel.textColor = .secondaryLabelColor
        parentLabel.lineBreakMode = .byTruncatingHead
        parentLabel.alignment = .right
        parentLabel.maximumNumberOfLines = 1
        for v in [iconView, nameLabel, parentLabel, badge] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Show a search result.
    func configure(with row: ResultRow) {
        path = row.path
        toolTip = row.path
        iconView.isHidden = false
        iconView.image = IconCache.icon(forPath: row.path)
        let matched = TextAnalyzer.characterIndices(display: row.name, matchedFoldedByteOffsets: row.matchedByteOffsets)
        nameLabel.attributedStringValue = Self.attributedName(row.name, matchedCharacterIndices: matched)
        nameLabel.textColor = .labelColor
        parentLabel.stringValue = row.parentDisplay
        parentLabel.isHidden = false
        badge.text = Self.badgeText(for: row)
        badge.isHidden = badge.text.isEmpty
        needsLayout = true
    }

    /// Show an informational message (empty state, hint, loading).
    func configure(message: String, symbol: String?) {
        path = nil
        toolTip = message
        if let s = symbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: nil) {
            iconView.isHidden = false
            iconView.image = img
            iconView.contentTintColor = .tertiaryLabelColor
        } else {
            iconView.isHidden = true
            iconView.image = nil
        }
        nameLabel.attributedStringValue = NSAttributedString(string: message, attributes: [
            .font: Self.nameFont, .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: Self.paragraphStyle(.byTruncatingTail),
        ])
        parentLabel.stringValue = ""
        parentLabel.isHidden = true
        badge.text = ""
        badge.isHidden = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let iconSize = IconCache.iconSize
        iconView.frame = NSRect(x: 14, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        let textX: CGFloat = iconView.isHidden ? 16 : 14 + iconSize + 10
        let rightEdge = bounds.width - 16
        var cursor = rightEdge
        if !badge.isHidden {
            // Clamp the badge so a name like "v1.2.some-very-long-thing" cannot eat the row.
            var bs = badge.intrinsicContentSize
            bs.width = min(bs.width, max(44, bounds.width * 0.22))
            badge.frame = NSRect(x: cursor - bs.width, y: (h - bs.height) / 2, width: bs.width, height: bs.height)
            cursor -= bs.width + 10
        }
        let available = max(0, cursor - textX)
        if !parentLabel.isHidden && !parentLabel.stringValue.isEmpty {
            // `attributedStringValue.size()` measures the glyphs only and comes out ~4–5 pt short of what
            // the field actually needs for its border/padding, which head-truncated short paths that had
            // room to spare ("/Applications" → "…pplications"). `fittingSize` asks the cell.
            let wanted = ceil(parentLabel.fittingSize.width)
            let pw = min(wanted, floor(available * Self.maxParentFraction))
            let ph = ceil(parentLabel.font?.pointSize ?? 12) + 6
            parentLabel.frame = NSRect(x: cursor - pw, y: (h - ph) / 2, width: pw, height: ph)
            cursor -= pw + 10
        }
        let nh = ceil(Self.nameFont.pointSize) + 8
        nameLabel.frame = NSRect(x: textX, y: (h - nh) / 2, width: max(0, cursor - textX), height: nh)
    }

    // MARK: - Helpers

    /// Badge text per DESIGN.md §7.2: APP / FOLDER / uppercase extension (empty when none).
    static func badgeText(for row: ResultRow) -> String {
        switch row.kind {
        case .app: return "APP"
        case .folder: return "FOLDER"
        default:
            let ext = (row.name as NSString).pathExtension
            guard !ext.isEmpty else { return "" }
            // A "extension" is only a useful label when it is short; anything longer is just a dot in the
            // file name ("report.final draft v2") and would render as a giant badge.
            guard ext.count <= 6 else { return "" }
            return ext.uppercased()
        }
    }

    /// Name with matched characters (Character indices) bold + accent-coloured, middle-truncated.
    static func attributedName(_ name: String, matchedCharacterIndices: [Int]) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle(.byTruncatingMiddle),
        ]
        let attr = NSMutableAttributedString(string: name, attributes: base)
        guard !matchedCharacterIndices.isEmpty else { return attr }
        let wanted = Set(matchedCharacterIndices)
        let hl: [NSAttributedString.Key: Any] = [.font: nameBoldFont, .foregroundColor: NSColor.controlAccentColor]
        for (ci, idx) in name.indices.enumerated() where wanted.contains(ci) {
            attr.addAttributes(hl, range: NSRange(idx..<name.index(after: idx), in: name))
        }
        return attr
    }

    private static func paragraphStyle(_ mode: NSLineBreakMode) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = mode
        return p
    }
}

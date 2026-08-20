import AppKit

/// The query field: borderless, 24 pt system font, no focus ring, placeholder
/// "Search apps and files". Key handling lives in `SearchPanel` (its `NSTextFieldDelegate`).
final class QueryField: NSTextField {
    static let fontSize: CGFloat = 24

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = NSFont.systemFont(ofSize: Self.fontSize, weight: .regular)
        textColor = .labelColor
        usesSingleLineMode = true
        maximumNumberOfLines = 1
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
        placeholderAttributedString = NSAttributedString(string: "Search apps and files", attributes: [
            .font: NSFont.systemFont(ofSize: Self.fontSize, weight: .regular),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
        setAccessibilityLabel("Search apps and files")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replace the text and put the caret at the end (used by Tab autocomplete).
    func setText(_ text: String) {
        stringValue = text
        if let editor = currentEditor() {
            // While the field is being edited (always, when the panel is open) the field editor owns the
            // visible string; assigning `stringValue` alone can leave the old text on screen. Push the new
            // text into the editor too, then put the caret at the end. This is the path Tab-autocomplete
            // uses, so without it "Tab into a folder" would appear to do nothing.
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    /// True when the field editor has a non-empty selection (⌘C then copies text, not the path).
    var hasTextSelection: Bool { (currentEditor()?.selectedRange.length ?? 0) > 0 }
}

/// Panel background: vibrancy material with rounded corners and a hairline border, flipped so the
/// panel can lay out top-down (the top edge stays fixed while the height follows the result count).
final class PanelBackgroundView: NSVisualEffectView {
    static let cornerRadius: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBorder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }

    private func updateBorder() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.borderWidth = 1 / max(scale, 1)
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            self?.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

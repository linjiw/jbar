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
        let editor = currentEditor()
        if let textView = editor as? NSTextView, textView.hasMarkedText() {
            // Replacing the query while an IME (for example Korean 2-Set) owns marked text must end
            // composition first. Otherwise the field editor can later apply its marked range to the new,
            // shorter string when the panel hides or Delete empties the query.
            textView.unmarkText()
        }
        stringValue = text
        if let editor {
            // While the field is being edited (always, when the panel is open) the field editor owns the
            // visible string; assigning `stringValue` alone can leave the old text on screen. Push the new
            // text into the editor too, then put the caret at the end. This is the path Tab-autocomplete
            // uses, so without it "Tab into a folder" would appear to do nothing.
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    /// Whether an input method currently owns uncommitted composition text in this field.
    var hasMarkedText: Bool { (currentEditor() as? NSTextView)?.hasMarkedText() == true }

    /// Commit an active composition before the panel temporarily leaves the screen. This preserves the
    /// query when `restoreQueryOnReopen` is enabled without leaving AppKit with a stale marked range.
    func commitMarkedText() {
        guard let editor = currentEditor() as? NSTextView, editor.hasMarkedText() else { return }
        editor.unmarkText()
        stringValue = editor.string
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

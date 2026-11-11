import AppKit
import NautKit

// Display math in Live Preview: a framed block the width of the text,
// edited in place. The source opens inside the block with the rendered
// equation, or what is wrong with it, underneath as it is typed.

/// A display equation as the note shows it: the rendered formula centred
/// in a framed box, so it reads as one block, with copy and edit buttons
/// under the pointer. While the block is edited, the cell only holds the
/// editor's room; the editor view draws itself on top.
final class MathBlockCell: NSTextAttachmentCell {
    /// nil while the block is edited.
    let picture: NSImage?
    let size: NSSize
    let element: Int

    /// Space around the formula inside the box.
    static let padding: CGFloat = 18
    static let radius: CGFloat = 12

    init(picture: NSImage?, size: NSSize, element: Int) {
        self.picture = picture
        self.size = size
        self.element = element
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func cellSize() -> NSSize { size }

    override func draw(withFrame frame: NSRect, in view: NSView?, characterIndex: Int, layoutManager: NSLayoutManager) {
        guard let picture else { return }
        Self.drawBox(frame)
        let side = min(picture.size.width, frame.width - 2 * Self.padding)
        let scale = side / max(picture.size.width, 1)
        let size = NSSize(width: side, height: picture.size.height * scale)
        picture.draw(
            in: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
        // Selected, it shows as selected, as a Notion block does.
        if (layoutManager as? LiveLayout)?.isSelected(characterIndex) == true {
            LiveLayout.drawSelectionRing(frame, radius: Self.radius)
        }
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {}

    override func wantsToTrackMouse() -> Bool { false }

    /// The frame code blocks have: the surface, a hairline edge.
    static func drawBox(_ frame: NSRect) {
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor(token: .surface).setFill()
        path.fill()
        NSColor(token: .edgeTop).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The equation's source, edited inside its block: TeX on top, the
/// rendered result or the error below, both updating as it is typed, as
/// Notion's equation blocks do. Esc or ⌘Return leaves it, and so do the
/// arrows past its first or last line.
@MainActor
final class MathBlockEditor: NSView, NSTextViewDelegate {
    enum Exit { case above, below, stay }

    let source = NSTextView()
    private let preview = NSImageView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let placeholder = NSTextField(labelWithString: "Type LaTeX to see preview")
    private let copyButton = NSButton()
    private let doneButton = NSButton()
    private var image: NSImage?

    var onChange: (String) -> Void = { _ in }
    var onExit: (Exit) -> Void = { _ in }
    var onCopy: () -> Void = {}

    private static let padding: CGFloat = 16
    private static let buttonSide: CGFloat = 28

    override var isFlipped: Bool { true }

    init(text: String, mono: NSFont) {
        super.init(frame: .zero)
        source.string = text
        source.font = mono
        source.textColor = NSColor(token: .fg)
        source.insertionPointColor = .themeCursor
        source.drawsBackground = false
        source.isRichText = false
        source.allowsUndo = true
        source.isAutomaticQuoteSubstitutionEnabled = false
        source.isAutomaticDashSubstitutionEnabled = false
        source.isAutomaticTextReplacementEnabled = false
        source.isAutomaticSpellingCorrectionEnabled = false
        source.textContainerInset = .zero
        source.textContainer?.lineFragmentPadding = 0
        source.textContainer?.widthTracksTextView = true
        source.isVerticallyResizable = false
        source.delegate = self
        addSubview(source)

        preview.imageScaling = .scaleProportionallyDown
        addSubview(preview)

        message.font = NSFont(descriptor: mono.fontDescriptor, size: mono.pointSize * 0.92) ?? mono
        message.textColor = Self.errorColor
        addSubview(message)

        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = NSColor(token: .fgDim)
        addSubview(placeholder)

        configure(copyButton, symbol: "square.on.square", help: "Copy TeX", action: #selector(copyClicked))
        configure(doneButton, symbol: "checkmark", help: "Done (⌘Return)", action: #selector(doneClicked))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The theme's red, so an error reads as one in any theme.
    private static var errorColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ThemeSelection.palette(dark: dark).swatches[1].nsColor
        }
    }

    private func configure(_ button: NSButton, symbol: String, help: String, action: Selector) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        button.contentTintColor = NSColor(token: .fgDim)
        button.toolTip = help
        button.target = self
        button.action = action
        addSubview(button)
    }

    @objc private func copyClicked() { onCopy() }
    @objc private func doneClicked() { onExit(.below) }

    /// What shows under the source: the rendered equation, or the first
    /// thing wrong with it. A render still on its way keeps the last one
    /// up, so the preview doesn't flash while typing.
    func show(preview new: NSImage?, error: String?) {
        if let new { image = new }
        let empty = source.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        message.stringValue = error ?? ""
        message.isHidden = error == nil
        preview.image = image
        preview.isHidden = error != nil || empty
        placeholder.isHidden = !empty || error != nil
        needsLayout = true
    }

    // MARK: Layout

    private var sourceHeight: CGFloat {
        guard let layout = source.layoutManager, let container = source.textContainer else { return 20 }
        layout.ensureLayout(for: container)
        let font = source.font ?? .systemFont(ofSize: 13)
        return max(ceil(layout.usedRect(for: container).height), ceil(font.ascender - font.descender + font.leading))
    }

    private var previewHeight: CGFloat {
        if !message.isHidden { return ceil(message.intrinsicContentSize.height) }
        if !preview.isHidden, let image { return min(ceil(image.size.height), 400) }
        return ceil(placeholder.intrinsicContentSize.height)
    }

    /// How tall the block is at `width`: the source, a rule, the preview.
    func height(for width: CGFloat) -> CGFloat {
        if source.frame.width != sourceWidth(width) {
            source.frame.size.width = sourceWidth(width)
        }
        let p = Self.padding
        return p + sourceHeight + p + 1 + p + previewHeight + p
    }

    private func sourceWidth(_ width: CGFloat) -> CGFloat {
        max(40, width - 2 * Self.padding - 2 * Self.buttonSide - 12)
    }

    override func layout() {
        super.layout()
        let p = Self.padding
        let w = bounds.width
        source.frame = NSRect(x: p, y: p, width: sourceWidth(w), height: sourceHeight)
        let side = Self.buttonSide
        doneButton.frame = NSRect(x: w - side - 10, y: 10, width: side, height: side)
        copyButton.frame = doneButton.frame.offsetBy(dx: -side - 2, dy: 0)
        let top = source.frame.maxY + p + 1 + p
        let h = previewHeight
        message.frame = NSRect(x: p, y: top, width: w - 2 * p, height: h)
        placeholder.frame = NSRect(x: p, y: top, width: w - 2 * p, height: h)
        if let image {
            let width = min(image.size.width * h / max(image.size.height, 1), w - 2 * p)
            preview.frame = NSRect(x: (w - width) / 2, y: top, width: width, height: h)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        MathBlockCell.drawBox(bounds)
        // The rule between the source and what it renders to.
        let y = source.frame.maxY + Self.padding
        NSColor(token: .line).setFill()
        NSRect(x: 1, y: y, width: bounds.width - 2, height: 1).fill()
    }

    // MARK: Editing

    func textDidChange(_ notification: Notification) {
        onChange(source.string)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let text = textView.string as NSString
        let caret = textView.selectedRange()
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onExit(.below)
        case #selector(NSResponder.insertNewline(_:)) where NSApp.currentEvent?.modifierFlags.contains(.command) == true:
            onExit(.below)
        case #selector(NSResponder.moveUp(_:))
            where caret.length == 0 && text.range(of: "\n", range: NSRange(location: 0, length: caret.location)).location == NSNotFound:
            onExit(.above)
        case #selector(NSResponder.moveDown(_:))
            where caret.length == 0 && text.range(of: "\n", range: NSRange(location: caret.location, length: text.length - caret.location)).location == NSNotFound:
            onExit(.below)
        default:
            return false
        }
        return true
    }
}

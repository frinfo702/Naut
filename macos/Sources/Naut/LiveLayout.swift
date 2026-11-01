import AppKit
import NautKit

// MARK: - Attributes

/// The look of each element, after page.css, set on the display text.
struct LiveStyle {
    let font: NSFont
    let mono: NSFont

    /// page.css's h1–h6 sizes, in em.
    static let headingScale: [CGFloat] = [2.6, 1.6, 1.25, 1, 1, 1]
    /// page.css pads code blocks 22px at the sides.
    static let codeInset: CGFloat = 22
    static let quoteInset: CGFloat = 18
    /// Room for a bullet, number or box before a list item's text.
    static let listInset: CGFloat = 26
    /// A nested list's step in, per indent.
    static let nestInset: CGFloat = 24

    var body: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor(token: .fgBody), .paragraphStyle: NSParagraphStyle.default]
    }

    /// Style all of `s`, which holds `p.display`.
    func style(_ p: LiveProjection, in s: NSTextStorage, attachment: (Int) -> NSTextAttachment?) {
        s.beginEditing()
        s.setAttributes(body, range: NSRange(location: 0, length: s.length))
        for i in p.elements.indices { apply(i, of: p, to: s, attachment: attachment) }
        s.endEditing()
    }

    /// Style element `index` of `p` in `s`, which holds `p.display`.
    func apply(_ index: Int, of p: LiveProjection, to s: NSTextStorage, attachment: (Int) -> NSTextAttachment?) {
        let e = p.elements[index]
        let display = p.display
        let fg = NSColor(token: .fg)
        let dim = NSColor(token: .fgDim)
        let range = p.displayRange(e.range)
        let content = p.displayRange(e.content)
        // The display paragraphs the element's lines became.
        let lines = p.displayLines(e.range)

        switch e.kind {
        case let .heading(level):
            let size = font.pointSize * Self.headingScale[level - 1]
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = level == 1 ? 0 : size * 0.6
            style.paragraphSpacing = size * 0.15
            s.addAttributes([.font: weighted(font, .medium, size: size), .foregroundColor: fg, .paragraphStyle: style], range: lines)
        case .strong:
            s.addAttribute(.foregroundColor, value: fg, range: range)
            convert(range, in: s) { weighted($0, .semibold, size: $0.pointSize) }
        case .emphasis:
            convert(range, in: s) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        case .strikethrough:
            s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: dim], range: range)
        case .code:
            s.addAttribute(.foregroundColor, value: fg, range: range)
            convert(range, in: s) { NSFont(descriptor: mono.fontDescriptor, size: $0.pointSize * 0.88) ?? $0 }
        case .link:
            s.addAttributes([.foregroundColor: fg, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: dim], range: range)
        case let .codeBlock(language):
            // The fences aren't in the display: the block's first and last
            // lines carry its margin and padding as paragraph spacing.
            let code = p.displayLines(e.content)
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = Self.codeInset
            style.headIndent = Self.codeInset
            style.tailIndent = -Self.codeInset
            s.addAttributes([.font: mono, .foregroundColor: fg, .paragraphStyle: style], range: code)
            let first = display.paragraphRange(for: NSRange(location: code.location, length: 0))
            let last = display.paragraphRange(for: NSRange(location: max(code.location, NSMaxRange(code) - 1), length: 0))
            let outside = LiveLayout.codeMargin + LiveLayout.codePadding
            change(first, in: s) { $0.paragraphSpacingBefore = outside }
            change(last, in: s) { $0.paragraphSpacing = outside }
            // libnaut's lexer, so the colours match the page's.
            let text = display.substring(with: content)
            for (r, c) in Highlight.spans(text, language: language) {
                s.addAttribute(.foregroundColor, value: Self.color(c), range: NSRange(location: content.location + r.location, length: r.length))
            }
        case .mathBlock, .table, .image:
            guard let at = p.attachment(of: index), let a = attachment(index) else { return }
            s.addAttribute(.attachment, value: a, range: NSRange(location: at, length: 1))
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = LiveLayout.blockMargin
            style.paragraphSpacing = LiveLayout.blockMargin
            if case .mathBlock = e.kind { style.alignment = .center }
            s.addAttribute(.paragraphStyle, value: style, range: display.paragraphRange(for: NSRange(location: at, length: 0)))
        case .math:
            guard let at = p.attachment(of: index), let a = attachment(index) else { return }
            s.addAttribute(.attachment, value: a, range: NSRange(location: at, length: 1))
        case .quote:
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = Self.quoteInset
            style.headIndent = Self.quoteInset
            s.addAttributes([.foregroundColor: dim, .paragraphStyle: style], range: lines)
        case .listItem:
            let style = NSMutableParagraphStyle()
            let indent = Self.indent(of: e, in: p.source)
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            s.addAttribute(.paragraphStyle, value: style, range: lines)
            // Done tasks fade.
            if LiveProjection.isTask(p.source, e.content), p.source.substring(with: NSRange(location: e.content.location + 1, length: 1)) != " " {
                s.addAttributes([.foregroundColor: dim, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: content)
            }
        }
    }

    /// Where a list item's text starts: room for its marker, and a step in
    /// per two spaces (or a tab) of its source indent.
    static func indent(of e: LiveMarkdown.Element, in source: NSString) -> CGFloat {
        let lead = source.substring(with: NSRange(location: e.range.location, length: e.markers[0].location - e.range.location))
        let level = lead.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        return CGFloat(level) * nestInset + listInset
    }

    /// page.css's .hl-* colours.
    private static func color(_ c: Highlight.Class) -> NSColor {
        switch c {
        case .keyword: NSColor(token: .synKeyword)
        case .string: NSColor(token: .synString)
        case .number: NSColor(token: .synNumber)
        case .comment: NSColor(token: .synComment)
        case .function, .variable: NSColor(token: .synAttr)
        }
    }

    /// Change the paragraph style over `r`, keeping what is set there.
    private func change(_ r: NSRange, in s: NSTextStorage, _ body: (NSMutableParagraphStyle) -> Void) {
        guard s.length > 0 else { return }
        let current = (s.attribute(.paragraphStyle, at: min(r.location, s.length - 1), effectiveRange: nil) as? NSParagraphStyle) ?? .default
        let style = current.mutableCopy() as! NSMutableParagraphStyle
        body(style)
        s.addAttribute(.paragraphStyle, value: style, range: r)
    }

    /// Change the font across a range that may already mix fonts, e.g.
    /// emphasis inside a heading.
    private func convert(_ range: NSRange, in s: NSTextStorage, _ f: (NSFont) -> NSFont) {
        guard range.length > 0 else { return }
        s.enumerateAttribute(.font, in: range) { value, r, _ in
            s.addAttribute(.font, value: f(value as? NSFont ?? font), range: r)
        }
    }

    private func weighted(_ font: NSFont, _ weight: NSFont.Weight, size: CGFloat) -> NSFont {
        let d = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: size) ?? font
    }
}

// MARK: - Attachments

/// Math, a table or a picture, drawn where its U+FFFC is. TextKit lays it
/// out as one glyph, so the caret goes before or after it, never inside.
final class LiveAttachmentCell: NSTextAttachmentCell {
    let picture: NSImage
    let size: NSSize
    let radius: CGFloat
    /// Where the picture's bottom sits against the baseline: inline math
    /// is centred on the text's x-height, blocks sit on the baseline.
    let baselineOffset: CGFloat

    init(picture: NSImage, size: NSSize, radius: CGFloat = 0, baselineOffset: CGFloat = 0) {
        self.picture = picture
        self.size = size
        self.radius = radius
        self.baselineOffset = baselineOffset
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func cellSize() -> NSSize { size }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: baselineOffset) }

    override func draw(withFrame frame: NSRect, in view: NSView?, characterIndex: Int, layoutManager: NSLayoutManager) {
        NSGraphicsContext.saveGraphicsState()
        if radius > 0 { NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip() }
        picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        // Selected, it shows as selected, as a Notion block does.
        let selection = layoutManager.firstTextView?.selectedRange() ?? NSRange(location: 0, length: 0)
        if selection.length > 0, NSLocationInRange(characterIndex, selection) {
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func wantsToTrackMouse() -> Bool { false }
}

// MARK: - Layout

/// Lays out the display text with page.css's line spacing and draws what
/// attributes can't: code block backgrounds, labels and copy buttons,
/// inline code backgrounds, quote bars, and list bullets, numbers and boxes.
final class LiveLayout: NSLayoutManager, NSLayoutManagerDelegate {
    /// What to draw, in display positions.
    struct State {
        struct Code {
            /// The display paragraphs of its lines.
            var lines: NSRange
            /// The first word of the fence's info string; empty if none.
            var language: String
            var element: Int

            /// What a language label says: the language, or a placeholder
            /// while there is none, as when editing the fence.
            var label: String { language.isEmpty ? "plain text" : language }
        }

        enum Marker {
            case bullet
            case number(String)
            case task(checked: Bool)
        }

        struct Item {
            /// The display position its text starts at.
            var location: Int
            var marker: Marker
            var element: Int
        }

        var code: [Code] = []
        var inlineCode: [NSRange] = []
        var quotes: [NSRange] = []
        var items: [Item] = []
    }

    var state = State()
    /// The code block the pointer is over, and whether it is over its copy
    /// button. The button shows only then, as on the page.
    var hoveredCode: Int?
    var hoveringButton = false
    /// The code block or equation whose copy button just copied, showing
    /// a check.
    var copiedCode: Int?
    /// Display equations: where each one's attachment is, and its element.
    var mathBlocks: [(at: Int, element: Int)] = []
    /// The equation under the pointer, and the button it is over.
    var hoveredMath: Int?
    var hoveredMathButton: MathBlockCell.Button?
    /// The text view's selection, in display positions, kept by the editor.
    var selection = NSRange(location: 0, length: 0)

    /// Body text's CSS line-height, from Settings.
    var lineHeight: Double = Store.Density.compact.lineHeight

    /// Space outside a code block's box, and padding inside it; the code
    /// lines' own spacing adds to the padding: page.css's 18px.
    static let codeMargin: CGFloat = 14
    static let codePadding: CGFloat = 12
    /// Space above and below a drawn block (math, table, picture).
    static let blockMargin: CGFloat = 14

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Lines

    /// Lines as tall as the line-height asks, with the text centred in
    /// them. The baseline and the used rect move together: the caret and
    /// the input method's window follow the used rect, so they stay the
    /// text's height and on it.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect rect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphs: NSRange
    ) -> Bool {
        let extra = self.extra(at: characterIndexForGlyph(at: glyphs.location))
        rect.pointee.size.height += extra
        used.pointee.origin.y += extra / 2
        baselineOffset.pointee += extra / 2
        return true
    }

    /// The empty line after a final newline. Same spacing, same caret.
    override func setExtraLineFragmentRect(_ rect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        let extra = self.extra(at: max(0, (textStorage?.length ?? 0) - 1))
        var rect = rect
        var used = usedRect
        rect.size.height += extra
        used.origin.y += extra / 2
        super.setExtraLineFragmentRect(rect, usedRect: used, textContainer: container)
    }

    /// The space a line-height adds to the font's own line, for the font
    /// at character `i`. From the font rather than the line's height, so
    /// a tall picture doesn't get a tall gap.
    private func extra(at i: Int) -> CGFloat {
        let font = self.font(at: i)
        return max(0, font.pointSize * lineHeight - defaultLineHeight(for: font))
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        guard let container = textContainers.first else { return super.drawBackground(forGlyphRange: glyphs, at: origin) }
        let visible = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        for block in state.code where NSIntersectionRange(block.lines, visible).length > 0 {
            guard let r = codeBlockRect(block.lines)?.offsetBy(dx: origin.x, dy: origin.y) else { continue }
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
            NSColor(token: .surface).setFill()
            path.fill()
            NSColor(token: .edgeTop).setStroke()
            path.lineWidth = 1
            path.stroke()
            // The copy button on hover, as on the page, and while the block
            // is edited. The language, which the fence would otherwise keep,
            // shows while the block is edited; clicking it edits the
            // language.
            let editing = editingCode?.element == block.element
            guard editing || block.element == hoveredCode || block.element == copiedCode else { continue }
            drawControls(for: block, editing: editing, at: origin)
        }

        // Inline code's pill: as tall as its own font around its baseline,
        // not the line, which inline math may have made taller.
        NSColor(token: .surfaceRaised).setFill()
        for code in state.inlineCode where NSIntersectionRange(code, visible).length > 0 {
            let g = glyphRange(forCharacterRange: code, actualCharacterRange: nil)
            let font = self.font(at: code.location)
            enumerateLineFragments(forGlyphRange: g) { rect, _, _, line, _ in
                let part = NSIntersectionRange(g, line)
                guard part.length > 0 else { return }
                let b = self.boundingRect(forGlyphRange: part, in: container)
                let baseline = rect.minY + self.location(forGlyphAt: part.location).y
                let r = NSRect(x: b.minX - 3, y: baseline - font.ascender - 2, width: b.width + 6, height: font.ascender - font.descender + 4)
                NSBezierPath(roundedRect: r.offsetBy(dx: origin.x, dy: origin.y), xRadius: 5, yRadius: 5).fill()
            }
        }

        NSColor(token: .line).setFill()
        for quote in state.quotes where NSIntersectionRange(quote, visible).length > 0 {
            guard let (top, bottom) = verticalExtent(of: quote) else { continue }
            NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y + top + 4, width: 2, height: bottom - top - 8).fill()
        }

        let composing = firstTextView?.hasMarkedText() == true
        let current = firstTextView?.selectedRange() ?? selection
        if !composing {
            SelectionPainter.draw(in: self, glyphRange: glyphs, at: origin)
        }
        // Once the selection is drawn here, don't let TextKit paint its
        // own (which runs a selected newline to the edge of the column).
        // With no selection, or while an input method composes, there is
        // nothing to suppress.
        if current.length == 0 || composing {
            super.drawBackground(forGlyphRange: glyphs, at: origin)
        }
    }

    override func drawGlyphs(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphs, at: origin)
        let visible = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for item in state.items where NSLocationInRange(item.location, visible) || item.location == NSMaxRange(visible) {
            guard let r = markerRect(item)?.offsetBy(dx: origin.x, dy: origin.y) else { continue }
            switch item.marker {
            case .bullet:
                NSColor(token: .fgDim).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.maxX - 9, y: r.midY - 2.5, width: 5, height: 5)).fill()
            case let .number(n):
                let s = NSAttributedString(string: n, attributes: [.font: font(at: item.location), .foregroundColor: NSColor(token: .fgDim)])
                s.draw(at: NSPoint(x: r.maxX - s.size().width - 4, y: r.midY - s.size().height / 2))
            case let .task(checked):
                drawBox(in: r, checked: checked)
            }
        }
    }

    private func drawBox(in r: NSRect, checked: Bool) {
        guard checked else {
            let outline = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
            outline.lineWidth = 1.5
            NSColor(token: .fgDim).setStroke()
            outline.stroke()
            return
        }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: r.minX + r.width * 0.24, y: r.minY + r.height * 0.52))
        tick.line(to: NSPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.72))
        tick.line(to: NSPoint(x: r.minX + r.width * 0.78, y: r.minY + r.height * 0.3))
        tick.lineWidth = 1.8
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        NSColor.white.setStroke()
        tick.stroke()
    }

    // MARK: Geometry

    /// The used rect of the line at display position `i`; past the last
    /// character, the empty line after a final newline.
    private func usedRect(at i: Int) -> NSRect? {
        guard let storage = textStorage else { return nil }
        if i >= storage.length, extraLineFragmentRect.height > 0 { return extraLineFragmentUsedRect }
        guard storage.length > 0 else { return nil }
        return lineFragmentUsedRect(forGlyphAt: glyphIndexForCharacter(at: min(i, storage.length - 1)), effectiveRange: nil)
    }

    /// A list item's marker: in the room its indent leaves before the
    /// text, centred on the text's x-height.
    func markerRect(_ item: State.Item) -> NSRect? {
        guard let used = usedRect(at: item.location), let container = textContainers.first else { return nil }
        let font = self.font(at: item.location)
        let indent = paragraphStyle(at: item.location)?.firstLineHeadIndent ?? LiveStyle.listInset
        let middle = used.minY + font.ascender - font.xHeight / 2
        let side = Self.boxSide(font)
        let right = container.lineFragmentPadding + indent - 8
        if case .task = item.marker {
            return NSRect(x: right - side, y: middle - side / 2, width: side, height: side)
        }
        return NSRect(x: right - LiveStyle.listInset, y: middle - side / 2, width: LiveStyle.listInset, height: side)
    }

    /// The task item whose box is at `point` (container coordinates).
    func task(at point: NSPoint) -> State.Item? {
        state.items.first { item in
            guard case .task = item.marker else { return false }
            return markerRect(item)?.insetBy(dx: -4, dy: -4).contains(point) ?? false
        }
    }

    /// A display equation's box, in container coordinates.
    func mathRect(at character: Int) -> NSRect? {
        guard let container = textContainers.first, let storage = textStorage, character < storage.length else { return nil }
        return boundingRect(forGlyphRange: glyphRange(forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil), in: container)
    }

    /// The equation and its button at `point`, if the pointer is on one.
    func mathButton(at point: NSPoint) -> (element: Int, button: MathBlockCell.Button)? {
        for block in mathBlocks {
            guard let rect = mathRect(at: block.at), rect.contains(point) else { continue }
            for (button, r) in MathBlockCell.buttons(in: rect) where r.contains(point) {
                return (block.element, button)
            }
        }
        return nil
    }

    /// An equation's copy and edit buttons, under the pointer or just
    /// after copying, as code blocks show theirs.
    func drawMathControls(for element: Int, in frame: NSRect) {
        guard hoveredMath == element || copiedCode == element else { return }
        for (button, rect) in MathBlockCell.buttons(in: frame) {
            let over = hoveredMath == element && hoveredMathButton == button
            if over {
                NSColor(token: .surfaceRaised).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            let copied = button == .copy && copiedCode == element
            let symbol = button == .edit ? "chevron.left.forwardslash.chevron.right" : copied ? "checkmark" : "square.on.square"
            Self.icon(symbol, color: NSColor(token: over || copied ? .fg : .fgDim), in: rect.insetBy(dx: 6, dy: 6))
        }
    }

    /// The code block whose language label is at `point`. The label is
    /// drawn only while the block is edited.
    func languageLabel(at point: NSPoint) -> State.Code? {
        guard let code = editingCode else { return nil }
        return labelRect(code)?.insetBy(dx: -6, dy: -4).contains(point) == true ? code : nil
    }

    /// The code block whose copy button is at `point`.
    func copyButton(at point: NSPoint) -> State.Code? {
        state.code.first { copyButtonRect($0)?.contains(point) ?? false }
    }

    /// The code block whose caret is inside: its language label shows.
    /// An empty block has no characters of its own; its caret is at its
    /// start. `selection` is the text view's, kept here by the editor.
    var editingCode: State.Code? {
        guard selection.length == 0 else { return nil }
        return state.code.first {
            $0.lines.length == 0
                ? selection.location == $0.lines.location
                : selection.location >= $0.lines.location && selection.location < NSMaxRange($0.lines)
        }
    }

    func codeBlockRect(_ lines: NSRange) -> NSRect? {
        guard let container = textContainers.first, let (top, bottom) = verticalExtent(of: lines) else { return nil }
        let pad = container.lineFragmentPadding
        return NSRect(x: pad, y: top, width: container.size.width - 2 * pad, height: bottom - top)
            .insetBy(dx: 0, dy: Self.codeMargin)
    }

    /// The copy button's rect: top right, on the first line's centre, so
    /// its icon lines up with the code.
    func copyButtonRect(_ block: State.Code) -> NSRect? {
        guard let box = codeBlockRect(block.lines) else { return nil }
        let side: CGFloat = 28
        let line = usedRect(at: block.lines.location)?.midY ?? box.minY + 4 + side / 2
        return NSRect(x: box.maxX - side - 10, y: line - side / 2, width: side, height: side)
    }

    /// The language label's rect: left of the copy button, on its line.
    func labelRect(_ block: State.Code) -> NSRect? {
        guard let button = copyButtonRect(block) else { return nil }
        let size = Self.label(block.label).size()
        return NSRect(x: button.minX - size.width - 10, y: button.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Top of a range's first line to the bottom of its last.
    private func verticalExtent(of range: NSRange) -> (CGFloat, CGFloat)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let first = min(range.location, storage.length - 1)
        let last = min(max(range.location, NSMaxRange(range) - 1), storage.length - 1)
        let top = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: first), effectiveRange: nil)
        let bottom = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: last), effectiveRange: nil)
        return (top.minY, bottom.maxY)
    }

    private func font(at i: Int) -> NSFont {
        guard let storage = textStorage, storage.length > 0 else { return .systemFont(ofSize: 13) }
        return storage.attribute(.font, at: min(i, storage.length - 1), effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
    }

    private func paragraphStyle(at i: Int) -> NSParagraphStyle? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        return storage.attribute(.paragraphStyle, at: min(i, storage.length - 1), effectiveRange: nil) as? NSParagraphStyle
    }

    static func boxSide(_ font: NSFont) -> CGFloat { (font.capHeight + 5).rounded() }

    /// The copy button and, beside it, the language label while editing.
    private func drawControls(for block: State.Code, editing: Bool, at origin: NSPoint) {
        if editing, let label = labelRect(block)?.offsetBy(dx: origin.x, dy: origin.y) {
            Self.label(block.label).draw(at: label.origin)
        }
        let showing = editing || block.element == hoveredCode || block.element == copiedCode
        guard showing, let rect = copyButtonRect(block)?.offsetBy(dx: origin.x, dy: origin.y) else { return }
        if block.element == hoveredCode, hoveringButton {
            NSColor(token: .surfaceRaised).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        let copied = block.element == copiedCode
        let color: ThemeToken = copied || (hoveringButton && block.element == hoveredCode) ? .fg : .fgDim
        Self.icon(copied ? "checkmark" : "square.on.square", color: NSColor(token: color), in: rect.insetBy(dx: 6, dy: 6))
    }

    /// A symbol tinted with `color`, centred in `rect`. Drawn rather than
    /// put in a button: the page's button is drawn by the layout too.
    static func icon(_ name: String, color: NSColor, in rect: NSRect) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let configuration = NSImage.SymbolConfiguration(paletteColors: [resolved])
            .applying(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private static func label(_ language: String) -> NSAttributedString {
        NSAttributedString(string: language, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(token: .fgDim),
        ])
    }
}

extension LiveLayout.State {
    /// What to draw for projection `p`.
    init(_ p: LiveProjection) {
        for (i, e) in p.elements.enumerated() {
            switch e.kind {
            case let .codeBlock(language):
                code.append(.init(lines: p.displayLines(e.content), language: language, element: i))
            case .code:
                inlineCode.append(p.displayRange(e.range))
            case .quote:
                quotes.append(p.displayLines(e.range))
            case .listItem:
                let marker = p.source.substring(with: e.markers[0])
                let kind: Marker = LiveProjection.isTask(p.source, e.content)
                    ? .task(checked: p.source.substring(with: NSRange(location: e.content.location + 1, length: 1)) != " ")
                    : "-*+".contains(marker) ? .bullet : .number(marker)
                items.append(.init(location: p.display(at: NSMaxRange(LiveProjection.prefix(of: e, in: p.source))), marker: kind, element: i))
            default:
                continue
            }
        }
    }
}

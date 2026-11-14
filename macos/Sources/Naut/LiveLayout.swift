import AppKit
import NautKit

// MARK: - Attributes

/// The look of each element, after page.css, set on the display text.
struct LiveStyle {
    let font: NSFont
    let mono: NSFont

    /// One colour object per token. A dynamic colour made anew each time
    /// never equals the last, and every run would look restyled. Only the
    /// main thread styles.
    nonisolated(unsafe) private static var colors: [ThemeToken: NSColor] = [:]
    static func color(_ token: ThemeToken) -> NSColor {
        if let c = colors[token] { return c }
        let c = NSColor(token: token)
        colors[token] = c
        return c
    }

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
        [.font: font, .foregroundColor: Self.color(.fgBody), .paragraphStyle: NSParagraphStyle.default]
    }

    /// Style all of `s`, which holds `p.display`.
    func style(_ p: LiveProjection, in s: NSMutableAttributedString, attachment: (Int) -> NSTextAttachment?) {
        s.beginEditing()
        s.setAttributes(body, range: NSRange(location: 0, length: s.length))
        for i in p.elements.indices { apply(i, of: p, to: s, attachment: attachment) }
        s.endEditing()
    }

    /// Style element `index` of `p` in `s`, which holds `p.display`.
    func apply(_ index: Int, of p: LiveProjection, to s: NSMutableAttributedString, attachment: (Int) -> NSTextAttachment?) {
        let e = p.elements[index]
        let display = p.display
        let fg = Self.color(.fg)
        let dim = Self.color(.fgDim)
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
        case .table:
            let ordinal = p.elements[..<index].count { if case .table = $0.kind { true } else { false } }
            styleTable(e, ordinal: ordinal, of: p, in: s)
        case .mathBlock, .image, .rule:
            guard let at = p.attachment(of: index), let a = attachment(index) else { return }
            s.addAttribute(.attachment, value: a, range: NSRange(location: at, length: 1))
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = LiveLayout.blockMargin
            style.paragraphSpacing = LiveLayout.blockMargin
            // Equations and pictures are centred, as on the page.
            if case .mathBlock = e.kind { style.alignment = .center }
            if case .image = e.kind { style.alignment = .center }
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

    /// A table's cells, a paragraph each, laid out as a grid: TextKit's
    /// text table, its columns equal, the header row raised and bold.
    private func styleTable(_ e: LiveMarkdown.Element, ordinal: Int, of p: LiveProjection, in s: NSMutableAttributedString) {
        let columns = max(1, e.cells.map(\.count).max() ?? 1)
        // The same table and cells from one styling to the next, so a
        // keystroke doesn't make every cell look restyled and laid out again.
        let key = "\(ordinal)|\(columns)|\(e.cells.count)"
        if Self.tables.count > 64 { Self.tables.removeAll() }
        let blocks = Self.tables[key] ?? makeTable(columns: columns, rows: e.cells.count)
        Self.tables[key] = blocks
        for (r, row) in e.cells.enumerated() {
            for (c, cell) in row.enumerated() where c < columns {
                let style = NSMutableParagraphStyle()
                style.textBlocks = [blocks[r * columns + c]]
                let paragraph = p.display.paragraphRange(for: NSRange(location: p.display(at: cell.location), length: 0))
                s.addAttribute(.paragraphStyle, value: style, range: paragraph)
                if r == 0 {
                    s.addAttribute(.foregroundColor, value: Self.color(.fg), range: paragraph)
                    convert(paragraph, in: s) { weighted($0, .semibold, size: $0.pointSize) }
                }
            }
        }
    }

    nonisolated(unsafe) private static var tables: [String: [NSTextTableBlock]] = [:]

    /// A table's cells, row by row.
    private func makeTable(columns: Int, rows: Int) -> [NSTextTableBlock] {
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        table.setWidth(LiveLayout.blockMargin, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(LiveLayout.blockMargin, type: .absoluteValueType, for: .margin, edge: .maxY)
        var blocks: [NSTextTableBlock] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(Self.color(.line))
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setValue(100 / CGFloat(columns), type: .percentageValueType, for: .width)
                if r == 0 { block.backgroundColor = Self.color(.surface) }
                blocks.append(block)
            }
        }
        return blocks
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
        case .keyword: color(.synKeyword)
        case .string: color(.synString)
        case .number: color(.synNumber)
        case .comment: color(.synComment)
        case .function, .variable: color(.synAttr)
        }
    }

    /// Change the paragraph style over `r`, keeping what is set there.
    private func change(_ r: NSRange, in s: NSMutableAttributedString, _ body: (NSMutableParagraphStyle) -> Void) {
        guard s.length > 0 else { return }
        let current = (s.attribute(.paragraphStyle, at: min(r.location, s.length - 1), effectiveRange: nil) as? NSParagraphStyle) ?? .default
        let style = current.mutableCopy() as! NSMutableParagraphStyle
        body(style)
        s.addAttribute(.paragraphStyle, value: style, range: r)
    }

    /// Change the font across a range that may already mix fonts, e.g.
    /// emphasis inside a heading.
    private func convert(_ range: NSRange, in s: NSMutableAttributedString, _ f: (NSFont) -> NSFont) {
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
        if (layoutManager as? LiveLayout)?.isSelected(characterIndex) == true {
            LiveLayout.drawSelectionRing(frame.insetBy(dx: -5, dy: -5), radius: radius + 4)
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

        struct Table {
            /// The display paragraphs of its cells.
            var lines: NSRange
            var element: Int
        }

        struct Quote {
            var lines: NSRange
            /// Whether its last line is an empty one ending the note: that
            /// line has no character, so its bar goes on the extra line
            /// fragment. Not just "its lines reach the end": `> xx` and
            /// an empty line after it reach it too, and the bar ran on
            /// down into the empty line that had left the quote.
            var endsEmpty: Bool
        }

        var code: [Code] = []
        var tables: [Table] = []
        var inlineCode: [NSRange] = []
        var quotes: [Quote] = []
        var items: [Item] = []
    }

    var state = State()
    /// The block under the pointer, by element, and the control of its
    /// chrome the pointer is on (`BlockChrome.swift`).
    var hovered: Int?
    var hoveredControl: Chrome.Control?
    /// The block whose copy button just copied, showing a check.
    var copiedCode: Int?
    /// The drawn blocks (equations, tables, pictures): where each one's
    /// attachment is, its element, and what it is.
    var atoms: [(at: Int, element: Int, kind: Chrome.Kind)] = []
    /// Where the drawn blocks are. Selected, they draw a ring of their own
    /// instead of the text's highlight.
    var blocks = IndexSet()
    /// While a block is dragged by its handle: the block, and the line it
    /// would land on (container y).
    var dragging: Int?
    var dropLine: CGFloat?
    /// The text view's selection, in display positions, kept by the editor.
    var selection = NSRange(location: 0, length: 0)

    /// The font text typed at the end of the note will have, kept by the
    /// editor. The empty line after a final newline is that tall.
    var endFont: NSFont?
    /// The indent of a line started at the end of the note, kept by the
    /// editor: an empty list item there has no character of its own to
    /// carry one, and the last character's is the line above's.
    var endIndent: CGFloat?

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

    /// The empty line after a final newline: as tall as the line its
    /// first character will make, wherever the caret is.
    ///
    /// TextKit sizes it by the typing attributes, which are the caret's:
    /// with the caret on a heading the line was a heading tall, and the
    /// page changed height as the caret moved, then again as the first
    /// key was typed at the end. Below a code block its gap was the
    /// code's, and it grew as that key went in.
    override func setExtraLineFragmentRect(_ rect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        var rect = rect
        var used = usedRect
        if let font = endFont {
            let text = defaultLineHeight(for: font)
            let extra = extra(for: font)
            rect.size.height = text + extra
            used.origin.y = rect.minY + extra / 2
            used.size.height = text
        } else {
            let extra = extra(at: max(0, (textStorage?.length ?? 0) - 1))
            rect.size.height += extra
            used.origin.y += extra / 2
        }
        super.setExtraLineFragmentRect(rect, usedRect: used, textContainer: container)
    }

    /// A quote's bar, in container coordinates: down its lines, and the
    /// empty line ending the note if that is one of them. Such a line has
    /// no character: it is the extra one after the last newline, as an
    /// empty list item's is, and its bar goes there.
    func quoteBar(_ q: State.Quote) -> NSRect? {
        guard let container = textContainers.first else { return nil }
        let end = q.endsEmpty ? endLine?.rect : nil
        var top: CGFloat, bottom: CGFloat
        if q.lines.length > 0, let (t, b) = verticalExtent(of: q.lines) { (top, bottom) = (t, b) } else if let end { (top, bottom) = (end.minY, end.maxY) } else { return nil }
        if let end { bottom = max(bottom, end.maxY) }
        return NSRect(x: container.lineFragmentPadding, y: top + 4, width: 2, height: bottom - top - 8)
    }

    /// The line after the last character, where text typed at the end
    /// goes: the extra line fragment. An empty note has none (TextKit
    /// leaves it zero), so a note that is only `- ` or `> ` had nowhere to
    /// draw its bullet or bar: there, the first line as it will be.
    var endLine: (rect: NSRect, used: NSRect)? {
        if extraLineFragmentRect.height > 0 { return (extraLineFragmentRect, extraLineFragmentUsedRect) }
        guard textStorage?.length == 0, let font = endFont, let container = textContainers.first else { return nil }
        let text = defaultLineHeight(for: font)
        let extra = extra(for: font)
        let rect = NSRect(x: 0, y: 0, width: container.size.width, height: text + extra)
        return (rect, NSRect(x: 0, y: extra / 2, width: 0, height: text))
    }

    /// The space a line-height adds to the font's own line, for the font
    /// at character `i`. From the font rather than the line's height, so
    /// a tall picture doesn't get a tall gap.
    private func extra(at i: Int) -> CGFloat {
        extra(for: font(at: i))
    }

    private func extra(for font: NSFont) -> CGFloat {
        max(0, font.pointSize * lineHeight - defaultLineHeight(for: font))
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
            // All of its lines selected, the block shows as selected, as a
            // drawn block does.
            if selection.length > 0, selection.location <= block.lines.location, NSMaxRange(selection) >= NSMaxRange(block.lines) - 1 {
                Self.drawSelectionRing(r, radius: 14)
            }
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
        let length = textStorage?.length ?? 0
        for q in state.quotes {
            let ending = q.endsEmpty && NSMaxRange(visible) >= length
            guard NSIntersectionRange(q.lines, visible).length > 0 || ending, let bar = quoteBar(q) else { continue }
            bar.offsetBy(dx: origin.x, dy: origin.y).fill()
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
                // On the text's baseline, as the text's own digits are.
                let font = font(at: item.location)
                let s = NSAttributedString(string: n, attributes: [.font: font, .foregroundColor: NSColor(token: .fgDim)])
                s.draw(at: NSPoint(x: r.maxX - s.size().width - 4, y: r.midY + font.xHeight / 2 - font.ascender))
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

    /// Whether the attachment at display `i` is in the selection, or
    /// under a modal cursor.
    func isSelected(_ i: Int) -> Bool {
        guard let view = firstTextView else { return false }
        let s = view.selectedRange()
        return s.length > 0 && NSLocationInRange(i, s) || (view as? LiveTextView)?.cursorBlock == i
    }

    /// The ring around a selected block: the accent colour, as Notion's
    /// and Linear's.
    static func drawSelectionRing(_ rect: NSRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    // MARK: Geometry

    /// The used rect of the line at display position `i`; past the last
    /// character, the empty line after a final newline.
    private func usedRect(at i: Int) -> NSRect? {
        guard let storage = textStorage else { return nil }
        if i >= storage.length, let end = endLine { return end.used }
        guard storage.length > 0 else { return nil }
        return lineFragmentUsedRect(forGlyphAt: glyphIndexForCharacter(at: min(i, storage.length - 1)), effectiveRange: nil)
    }

    /// The baseline of the line at display position `i`: where its first
    /// glyph sits, so a taller fallback font (Japanese, say) moves it too.
    /// An empty line's newline sits below the baseline, so there, and
    /// past the end, where text typed would sit: the font's own.
    private func baseline(at i: Int, used: NSRect, font: NSFont) -> CGFloat {
        guard let storage = textStorage, i < storage.length, (storage.string as NSString).character(at: i) != 0x0A else {
            return used.minY + defaultBaselineOffset(for: font)
        }
        let g = glyphIndexForCharacter(at: i)
        return lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY + location(forGlyphAt: g).y
    }

    /// A list item's marker: in the room its indent leaves before the
    /// text, centred on the text's x-height.
    func markerRect(_ item: State.Item) -> NSRect? {
        guard let used = usedRect(at: item.location), let container = textContainers.first, let storage = textStorage else { return nil }
        let atEnd = item.location >= storage.length
        let font = atEnd ? endFont ?? self.font(at: item.location) : self.font(at: item.location)
        let indent = (atEnd ? endIndent : paragraphStyle(at: item.location)?.firstLineHeadIndent) ?? LiveStyle.listInset
        let middle = baseline(at: item.location, used: used, font: font) - font.xHeight / 2
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

    /// A table's box: its cells' lines, with their padding and borders,
    /// across the text's width as the table is.
    func tableRect(_ lines: NSRange) -> NSRect? {
        guard let container = textContainers.first, let storage = textStorage, storage.length > 0 else { return nil }
        let chars = NSIntersectionRange(lines, NSRange(location: 0, length: storage.length))
        guard chars.length > 0 else { return nil }
        var box = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: chars, actualCharacterRange: nil)) { rect, _, _, _, _ in
            box = box.union(rect)
        }
        guard !box.isNull else { return nil }
        let pad = container.lineFragmentPadding
        return NSRect(x: pad, y: box.minY - 7, width: container.size.width - 2 * pad, height: box.height + 14)
    }

    func codeBlockRect(_ lines: NSRange) -> NSRect? {
        guard let container = textContainers.first, let (top, bottom) = verticalExtent(of: lines) else { return nil }
        let pad = container.lineFragmentPadding
        return NSRect(x: pad, y: top, width: container.size.width - 2 * pad, height: bottom - top)
            .insetBy(dx: 0, dy: Self.codeMargin)
    }

    /// Top of a range's first line to the bottom of its last.
    func verticalExtent(of range: NSRange) -> (CGFloat, CGFloat)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let first = min(range.location, storage.length - 1)
        let last = min(max(range.location, NSMaxRange(range) - 1), storage.length - 1)
        let top = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: first), effectiveRange: nil)
        let bottom = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: last), effectiveRange: nil)
        return (top.minY, bottom.maxY)
    }

    func font(at i: Int) -> NSFont {
        guard let storage = textStorage, storage.length > 0 else { return .systemFont(ofSize: 13) }
        return storage.attribute(.font, at: min(i, storage.length - 1), effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
    }

    private func paragraphStyle(at i: Int) -> NSParagraphStyle? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        return storage.attribute(.paragraphStyle, at: min(i, storage.length - 1), effectiveRange: nil) as? NSParagraphStyle
    }

    static func boxSide(_ font: NSFont) -> CGFloat { (font.capHeight + 5).rounded() }

    /// Display positions of a projection, moved past `range` of it having
    /// become `length` long. A position at the stretch's start stays: text
    /// put there (an item's first word, say) comes after it.
    struct Shift {
        let range: NSRange
        let length: Int

        func callAsFunction(_ i: Int) -> Int {
            i > range.location && i >= NSMaxRange(range) ? i + length - range.length : i
        }

        func callAsFunction(_ r: NSRange) -> NSRange {
            let start = self(r.location)
            return NSRange(location: start, length: max(0, self(NSMaxRange(r)) - start))
        }
    }

}

extension LiveLayout.State {
    /// The same, for the display with `range` of it now `length` long:
    /// what follows moves with it. An input method's text is in the
    /// display before it is in the source, and so before a projection
    /// says where things are.
    func adjusted(replacing range: NSRange, length: Int) -> Self {
        let move = LiveLayout.Shift(range: range, length: length)
        var s = self
        s.code = code.map { var c = $0; c.lines = move(c.lines); return c }
        s.tables = tables.map { var t = $0; t.lines = move(t.lines); return t }
        s.inlineCode = inlineCode.map(move.callAsFunction)
        s.quotes = quotes.map { var q = $0; q.lines = move(q.lines); return q }
        s.items = items.map { var item = $0; item.location = move(item.location); return item }
        return s
    }

    /// What to draw for projection `p`.
    init(_ p: LiveProjection) {
        for (i, e) in p.elements.enumerated() {
            switch e.kind {
            case let .codeBlock(language):
                code.append(.init(lines: p.displayLines(e.content), language: language, element: i))
            case .table:
                tables.append(.init(lines: p.displayLines(e.range), element: i))
            case .code:
                inlineCode.append(p.displayRange(e.range))
            case .quote:
                var lineStart = 0
                p.source.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: NSMaxRange(e.range), length: 0))
                let endsEmpty = NSMaxRange(e.range) == p.source.length && p.display(at: lineStart) == p.display.length
                quotes.append(.init(lines: p.displayLines(e.range), endsEmpty: endsEmpty))
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

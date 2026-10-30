import AppKit
import NautKit

// MARK: - Attributes

/// The look of each element, after page.css. Caret-independent: what
/// hides when is the layout's business.
struct LiveStyle {
    let font: NSFont
    let mono: NSFont

    /// page.css's h1–h6 sizes, in em.
    static let headingScale: [CGFloat] = [2.6, 1.6, 1.25, 1, 1, 1]
    /// page.css pads code blocks 22px at the sides.
    static let codeInset: CGFloat = 22
    static let quoteInset: CGFloat = 18

    var body: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor(token: .fgBody), .paragraphStyle: NSParagraphStyle.default]
    }

    func apply(_ e: LiveMarkdown.Element, to s: NSTextStorage) {
        let fg = NSColor(token: .fg)
        let dim = NSColor(token: .fgDim)
        switch e.kind {
        case let .heading(level):
            let size = font.pointSize * Self.headingScale[level - 1]
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = level == 1 ? 0 : size * 0.6
            p.paragraphSpacing = size * 0.15
            s.addAttributes([.font: weighted(font, .medium, size: size), .foregroundColor: fg, .paragraphStyle: p], range: e.scope)
        case .strong:
            s.addAttribute(.foregroundColor, value: fg, range: e.range)
            convert(e.range, in: s) { weighted($0, .semibold, size: $0.pointSize) }
        case .emphasis:
            convert(e.range, in: s) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        case .strikethrough:
            s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: dim], range: e.content)
        case .code, .math:
            s.addAttribute(.foregroundColor, value: fg, range: e.range)
            convert(e.range, in: s) { NSFont(descriptor: mono.fontDescriptor, size: $0.pointSize * 0.88) ?? $0 }
        case .link:
            s.addAttributes([.foregroundColor: fg, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: dim], range: e.content)
        case .codeBlock, .mathBlock, .table:
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = Self.codeInset
            p.headIndent = Self.codeInset
            p.tailIndent = -Self.codeInset
            s.addAttributes([.font: mono, .foregroundColor: fg, .paragraphStyle: p], range: e.scope)
            if case let .codeBlock(language) = e.kind {
                // libnaut's lexer, so the colours match the page's.
                let code = (s.string as NSString).substring(with: e.content)
                for (r, c) in Highlight.spans(code, language: language) {
                    s.addAttribute(.foregroundColor, value: Self.color(c), range: NSRange(location: e.content.location + r.location, length: r.length))
                }
            }
        case .image:
            s.addAttribute(.foregroundColor, value: dim, range: e.range)
        case .quote:
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = Self.quoteInset
            p.headIndent = Self.quoteInset
            s.addAttributes([.foregroundColor: dim, .paragraphStyle: p], range: e.scope)
        case .listItem where LiveEditing.isTask(s.string as NSString, e.content):
            // The text after the box hangs under itself; done tasks fade.
            let p = NSMutableParagraphStyle()
            p.headIndent = LiveLayout.boxSide(font) + 4 + ("  " as NSString).size(withAttributes: [.font: font]).width / 2
            s.addAttribute(.paragraphStyle, value: p, range: e.scope)
            if (s.string as NSString).substring(with: NSRange(location: e.content.location + 1, length: 1)) != " " {
                let text = NSRange(location: e.content.location + 4, length: e.content.length - 4)
                s.addAttributes([.foregroundColor: dim, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: text)
            }
        case .listItem:
            // A hanging indent, so wrapped lines start under the text.
            let prefix = (s.string as NSString).substring(with: NSRange(location: e.range.location, length: e.content.location - e.range.location))
            let p = NSMutableParagraphStyle()
            p.headIndent = (prefix as NSString).size(withAttributes: [.font: font]).width
            s.addAttribute(.paragraphStyle, value: p, range: e.scope)
        }
        for m in e.markers { s.addAttribute(.foregroundColor, value: dim, range: m) }
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

    /// Change the font across a range that may already mix fonts, e.g.
    /// emphasis inside a heading.
    private func convert(_ range: NSRange, in s: NSTextStorage, _ f: (NSFont) -> NSFont) {
        s.enumerateAttribute(.font, in: range) { value, r, _ in
            s.addAttribute(.font, value: f(value as? NSFont ?? font), range: r)
        }
    }

    private func weighted(_ font: NSFont, _ weight: NSFont.Weight, size: CGFloat) -> NSFont {
        let d = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: size) ?? font
    }
}

// MARK: - Layout

/// Lays the note out with its syntax hidden, and draws what attributes
/// can't: code block and inline code backgrounds, quote bars, bullets,
/// math, tables and pictures, and the selection of those.
final class LiveLayout: NSLayoutManager, NSLayoutManagerDelegate {
    /// What to hide and draw, from the parsed note. Indexes are characters.
    struct State {
        /// Characters laid out with no width and not drawn.
        var hidden = IndexSet()
        /// Inline math: the formula's first character is drawn as its
        /// image and the rest are hidden.
        var inlineMath: [Int: Block] = [:]
        /// Display math, tables and pictures, each drawn in its first line.
        var blocks: [Int: Block] = [:]
        /// Lines (by first character) with a set height: hidden fences
        /// become a code block's padding; blocks fold to their image.
        var lineHeights: [Int: CGFloat] = [:]
        var codeBlocks: [NSRange] = []
        var inlineCode: [NSRange] = []
        var quotes: [NSRange] = []
        /// List markers drawn as a bullet.
        var bullets: Set<Int> = []
        /// Code blocks' languages, by the block's first character.
        var languages: [Int: String] = [:]
        /// Task boxes, by their "[", and whether they're checked.
        var tasks: [Int: Bool] = [:]
    }

    struct Block {
        var image: NSImage
        /// Drawn at this size, fitted to the text's width.
        var size: NSSize
        var centered = false
        var radius: CGFloat = 0
        /// The source it stands for; selecting all of it selects the block.
        var zone: NSRange
    }

    var state = State()

    /// Body text's CSS line-height, from Settings.
    var lineHeight: Double = Store.Density.compact.lineHeight

    /// Extra space per line as a fraction of its text height, split above
    /// and below: a CSS line-height is against the font size, and a font's
    /// own line is about 1.2 of it.
    private var lineSpacing: CGFloat { max(0, lineHeight / 1.2 - 1) }
    /// A hidden fence's line is the space outside a code block and the
    /// padding inside it, so the box never touches the text around it.
    /// The code lines' own spacing adds to the padding: page.css's 18px.
    static let codeMargin: CGFloat = 14
    static let codePadding: CGFloat = 12
    /// Space above and below a drawn block (math, table, picture).
    static let blockMargin: CGFloat = 14

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Glyphs

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes chars: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange range: NSRange
    ) -> Int {
        let indexes = UnsafeBufferPointer(start: chars, count: range.length)
        guard let first = indexes.first, let last = indexes.last,
              state.hidden.intersects(integersIn: first..<last + 1) || !state.inlineMath.isEmpty || !state.bullets.isEmpty || !state.tasks.isEmpty
        else { return 0 }
        var out = Array(UnsafeBufferPointer(start: props, count: range.length))
        var touched = false
        for (i, c) in indexes.enumerated() {
            if state.inlineMath[c] != nil || state.hidden.contains(c) || state.bullets.contains(c) || state.tasks[c] != nil {
                out[i] = .controlCharacter
                touched = true
            }
        }
        guard touched else { return 0 }
        out.withUnsafeBufferPointer {
            setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: chars, font: font, forGlyphRange: range)
        }
        return range.length
    }

    /// Hidden characters lay out with no width and draw nothing. Not the
    /// null glyph: TextKit moves null glyphs at the start of a line onto
    /// the line before, so a hidden fence would no longer be its own line.
    /// Inline math's first character stands in for the formula: a space
    /// as wide as its image.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        if state.inlineMath[charIndex] != nil || state.bullets.contains(charIndex) || state.tasks[charIndex] != nil { return .whitespace }
        if state.hidden.contains(charIndex) { return .zeroAdvancement }
        return action
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment: NSRect,
        glyphPosition: NSPoint,
        characterIndex: Int
    ) -> NSRect {
        if let math = state.inlineMath[characterIndex] {
            return NSRect(origin: glyphPosition, size: NSSize(width: math.size.width, height: 1))
        }
        let font = textStorage?.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
        if state.tasks[characterIndex] != nil {
            return NSRect(origin: glyphPosition, size: NSSize(width: Self.boxSide(font) + 4, height: 1))
        }
        // As wide as the "-" it replaces, so the hanging indent still fits.
        return NSRect(origin: glyphPosition, size: NSSize(width: ("-" as NSString).size(withAttributes: [.font: font]).width, height: 1))
    }

    // MARK: Lines

    /// Taller lines with the text centred in them. The baseline and the
    /// used rect move together: the caret and the input method's window
    /// follow the used rect, so they stay the text's height and on it.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect rect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphs: NSRange
    ) -> Bool {
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        if let height = state.lineHeights[chars.location] {
            rect.pointee.size.height = height
            used.pointee.size.height = min(used.pointee.height, height)
            return true
        }
        var extra = used.pointee.height * lineSpacing
        for (c, math) in state.inlineMath where NSLocationInRange(c, chars) {
            extra = max(extra, math.size.height + 4 - used.pointee.height)
        }
        rect.pointee.size.height += extra
        used.pointee.origin.y += extra / 2
        baselineOffset.pointee += extra / 2
        return true
    }

    /// The empty line after a final newline. Same spacing, same caret.
    override func setExtraLineFragmentRect(_ rect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        let extra = usedRect.height * lineSpacing
        var rect = rect
        var used = usedRect
        rect.size.height += extra
        used.origin.y += extra / 2
        super.setExtraLineFragmentRect(rect, usedRect: used, textContainer: container)
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        guard let container = textContainers.first else { return super.drawBackground(forGlyphRange: glyphs, at: origin) }
        let visible = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let pad = container.lineFragmentPadding

        for block in state.codeBlocks where NSIntersectionRange(block, visible).length > 0 {
            guard let r = codeBlockRect(block)?.offsetBy(dx: origin.x, dy: origin.y) else { continue }
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
            NSColor(token: .surface).setFill()
            path.fill()
            NSColor(token: .edgeTop).setStroke()
            path.lineWidth = 1
            path.stroke()
            // The language, which the hidden fence would otherwise keep
            // out of sight; clicking it edits it.
            if let language = state.languages[block.location], let label = labelRect(block)?.offsetBy(dx: origin.x, dy: origin.y) {
                Self.label(language).draw(at: NSPoint(x: label.minX, y: label.minY))
            }
        }

        NSColor(token: .surfaceRaised).setFill()
        for code in state.inlineCode where NSIntersectionRange(code, visible).length > 0 {
            let g = glyphRange(forCharacterRange: code, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: g) { _, used, _, line, _ in
                let part = NSIntersectionRange(g, line)
                guard part.length > 0 else { return }
                let b = self.boundingRect(forGlyphRange: part, in: container)
                let r = NSRect(x: b.minX - 3, y: used.minY + 1, width: b.width + 6, height: used.height - 2)
                NSBezierPath(roundedRect: r.offsetBy(dx: origin.x, dy: origin.y), xRadius: 5, yRadius: 5).fill()
            }
        }

        NSColor(token: .line).setFill()
        for quote in state.quotes where NSIntersectionRange(quote, visible).length > 0 {
            guard let (top, bottom) = verticalExtent(of: quote) else { continue }
            NSRect(x: origin.x + pad, y: origin.y + top + 4, width: 2, height: bottom - top - 8).fill()
        }

        // Blocks drawn as images show their selection themselves: the
        // text view's highlight would cover only their hidden source.
        let selection = firstTextView?.selectedRange() ?? NSRange(location: 0, length: 0)
        if selection.length > 0 {
            NSColor.controlAccentColor.setStroke()
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            for (c, block) in state.blocks.merging(state.inlineMath, uniquingKeysWith: { a, _ in a })
            where NSLocationInRange(c, visible) && NSIntersectionRange(selection, block.zone) == block.zone {
                guard let r = rect(of: c)?.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -4) else { continue }
                let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
                path.lineWidth = 2
                path.fill()
                path.stroke()
            }
        }

        super.drawBackground(forGlyphRange: glyphs, at: origin)
    }

    /// No selection fill over a block's hidden source; the block draws its
    /// own highlight.
    override func fillBackgroundRectArray(_ rects: UnsafePointer<NSRect>, count: Int, forCharacterRange range: NSRange, color: NSColor) {
        let zones = state.blocks.values.map(\.zone) + state.inlineMath.values.map(\.zone)
        if zones.contains(where: { NSIntersectionRange($0, range).length > 0 || ($0.location <= range.location && range.location <= NSMaxRange($0)) && range.length == 0 }) { return }
        super.fillBackgroundRectArray(rects, count: count, forCharacterRange: range, color: color)
    }

    override func drawGlyphs(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphs, at: origin)
        guard let container = textContainers.first, let storage = textStorage else { return }
        let visible = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        for (c, math) in state.inlineMath where NSLocationInRange(c, visible) {
            if let r = rect(of: c) { draw(math.image, in: r, at: origin) }
        }

        for c in state.bullets where NSLocationInRange(c, visible) {
            let g = glyphIndexForCharacter(at: c)
            let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let at = location(forGlyphAt: g)
            let font = storage.attribute(.font, at: c, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
            let bullet = NSAttributedString(string: "•", attributes: [.font: font, .foregroundColor: NSColor(token: .fgDim)])
            let width = ("-" as NSString).size(withAttributes: [.font: font]).width
            let size = bullet.size()
            bullet.draw(at: NSPoint(x: origin.x + line.minX + at.x + (width - size.width) / 2, y: origin.y + line.minY + at.y - font.ascender))
        }

        for (c, checked) in state.tasks where NSLocationInRange(c, visible) {
            guard let r = taskRect(c) else { continue }
            let box = NSBezierPath(roundedRect: r.offsetBy(dx: origin.x, dy: origin.y), xRadius: 4, yRadius: 4)
            if checked {
                NSColor.controlAccentColor.setFill()
                box.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: origin.x + r.minX + r.width * 0.24, y: origin.y + r.minY + r.height * 0.52))
                tick.line(to: NSPoint(x: origin.x + r.minX + r.width * 0.43, y: origin.y + r.minY + r.height * 0.72))
                tick.line(to: NSPoint(x: origin.x + r.minX + r.width * 0.78, y: origin.y + r.minY + r.height * 0.3))
                tick.lineWidth = 1.8
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                NSColor.white.setStroke()
                tick.stroke()
            } else {
                let outline = NSBezierPath(roundedRect: r.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
                outline.lineWidth = 1.5
                NSColor(token: .fgDim).setStroke()
                outline.stroke()
            }
        }

        for (c, block) in state.blocks where NSLocationInRange(c, visible) {
            guard let r = rect(of: c) else { continue }
            NSGraphicsContext.saveGraphicsState()
            if block.radius > 0 {
                NSBezierPath(roundedRect: r.offsetBy(dx: origin.x, dy: origin.y), xRadius: block.radius, yRadius: block.radius).addClip()
            }
            draw(block.image, in: r, at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Geometry

    /// Where the block or inline math keyed `c` is drawn, in the container.
    func rect(of c: Int) -> NSRect? {
        guard let container = textContainers.first, c < (textStorage?.length ?? 0) else { return nil }
        let g = glyphIndexForCharacter(at: c)
        let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        if let block = state.blocks[c] {
            let x = block.centered ? (container.size.width - block.size.width) / 2 : container.lineFragmentPadding
            return NSRect(x: x, y: line.midY - block.size.height / 2, width: block.size.width, height: block.size.height)
        }
        if let math = state.inlineMath[c] {
            let at = location(forGlyphAt: g)
            // Centre on the text's x-height, where operators sit.
            let font = textStorage?.attribute(.font, at: c, effectiveRange: nil) as? NSFont
            let middle = line.minY + at.y - (font?.xHeight ?? 0) / 2
            return NSRect(x: line.minX + at.x, y: middle - math.size.height / 2, width: math.size.width, height: math.size.height)
        }
        return nil
    }

    /// The block or inline math at `point` (container coordinates), by
    /// its key.
    func atom(at point: NSPoint) -> Int? {
        let keys = Array(state.blocks.keys) + Array(state.inlineMath.keys)
        return keys.first { rect(of: $0)?.insetBy(dx: -2, dy: -2).contains(point) ?? false }
    }

    /// The task box at `point`, by its "[".
    func task(at point: NSPoint) -> Int? {
        state.tasks.keys.first { taskRect($0)?.insetBy(dx: -4, dy: -4).contains(point) ?? false }
    }

    func taskRect(_ c: Int) -> NSRect? {
        guard c < (textStorage?.length ?? 0), let font = textStorage?.attribute(.font, at: c, effectiveRange: nil) as? NSFont else { return nil }
        let g = glyphIndexForCharacter(at: c)
        let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let at = location(forGlyphAt: g)
        let side = Self.boxSide(font)
        let middle = line.minY + at.y - font.xHeight / 2
        return NSRect(x: line.minX + at.x, y: middle - side / 2, width: side, height: side)
    }

    static func boxSide(_ font: NSFont) -> CGFloat { (font.capHeight + 5).rounded() }

    /// The code block whose language label is at `point`, by its first
    /// character.
    func languageLabel(at point: NSPoint) -> Int? {
        state.codeBlocks.first { labelRect($0)?.insetBy(dx: -6, dy: -4).contains(point) ?? false }?.location
    }

    func codeBlockRect(_ block: NSRange) -> NSRect? {
        guard let container = textContainers.first, let (top, bottom) = verticalExtent(of: block) else { return nil }
        let pad = container.lineFragmentPadding
        return NSRect(x: pad, y: top, width: container.size.width - 2 * pad, height: bottom - top)
            .insetBy(dx: 0, dy: Self.codeMargin)
    }

    /// The language label's rect: top right, inside the padding.
    func labelRect(_ block: NSRange) -> NSRect? {
        guard let language = state.languages[block.location], let box = codeBlockRect(block) else { return nil }
        let size = Self.label(language).size()
        return NSRect(x: box.maxX - size.width - 14, y: box.minY + 8, width: size.width, height: size.height)
    }

    private static func label(_ language: String) -> NSAttributedString {
        NSAttributedString(string: language, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(token: .fgDim),
        ])
    }

    private func draw(_ image: NSImage, in rect: NSRect, at origin: NSPoint) {
        image.draw(in: rect.offsetBy(dx: origin.x, dy: origin.y), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Top of a range's first line to the bottom of its last, in the
    /// container.
    private func verticalExtent(of range: NSRange) -> (CGFloat, CGFloat)? {
        let g = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard g.length > 0 else { return nil }
        let top = lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
        let bottom = lineFragmentRect(forGlyphAt: NSMaxRange(g) - 1, effectiveRange: nil)
        return (top.minY, bottom.maxY)
    }

    // MARK: Editing

    /// Move the state with an edit of `edited` (its range after the edit),
    /// dropping whatever was inside the replaced text.
    func shift(edited: NSRange, delta: Int) {
        guard delta != 0 || edited.length > 0 else { return }
        let oldEnd = NSMaxRange(edited) - delta
        func move(_ i: Int) -> Int? {
            if i < edited.location { return i }
            if i >= oldEnd { return i + delta }
            return nil
        }
        func move(_ r: NSRange) -> NSRange? {
            guard let start = move(r.location) ?? (r.location < edited.location ? r.location : nil) else { return nil }
            let end = NSMaxRange(r) >= oldEnd ? NSMaxRange(r) + delta : min(NSMaxRange(r), edited.location)
            return end >= start ? NSRange(location: start, length: end - start) : nil
        }
        func move<V>(_ d: [Int: V]) -> [Int: V] {
            Dictionary(d.compactMap { k, v in move(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        }
        var s = state
        s.hidden = IndexSet(s.hidden.compactMap(move))
        s.inlineMath = move(s.inlineMath)
        s.blocks = move(s.blocks)
        s.lineHeights = move(s.lineHeights)
        s.codeBlocks = s.codeBlocks.compactMap(move)
        s.inlineCode = s.inlineCode.compactMap(move)
        s.quotes = s.quotes.compactMap(move)
        s.bullets = Set(s.bullets.compactMap(move))
        s.languages = move(s.languages)
        s.tasks = move(s.tasks)
        state = s
    }
}

extension LiveLayout.State {
    /// The state for `elements`: all syntax hidden, every block drawn.
    @MainActor
    init(elements: [LiveMarkdown.Element], string: NSString, font: NSFont, mono: NSFont, dark: Bool, width: CGFloat, baseURL: URL) {
        func lines(_ range: NSRange) -> [NSRange] {
            var out: [NSRange] = []
            string.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in out.append(line) }
            return out
        }
        func rendered(_ markdown: String, width: Double? = nil) -> NSImage? {
            LiveImages.shared.image(.init(markdown: markdown, width: width, size: font.pointSize, dark: dark))
        }
        func hide(_ r: NSRange) { hidden.insert(integersIn: Range(r)!) }
        // Fold every line to nothing but the first, which holds the
        // image. Newlines stay glyphs: they are what breaks lines.
        func fold(_ zone: NSRange, into image: NSImage, centered: Bool = false, radius: CGFloat = 0) {
            var zone = zone
            while zone.length > 0, string.character(at: NSMaxRange(zone) - 1) == 0x0A { zone.length -= 1 }
            for row in lines(zone) {
                hide(row)
                lineHeights[row.location] = 0.01
            }
            let size = image.size.width <= width ? image.size : NSSize(width: width, height: image.size.height * width / image.size.width)
            lineHeights[zone.location] = size.height + 2 * LiveLayout.blockMargin
            blocks[zone.location] = .init(image: image, size: size, centered: centered, radius: radius, zone: zone)
        }
        let small = NSFont(descriptor: mono.fontDescriptor, size: font.pointSize * 0.88) ?? mono

        for e in elements {
            switch e.kind {
            case let .codeBlock(language):
                codeBlocks.append(e.scope)
                languages[e.scope.location] = language.isEmpty ? "plain text" : language
                for m in e.markers {
                    hide(m)
                    lineHeights[m.location] = LiveLayout.codeMargin + LiveLayout.codePadding
                }
            case let .mathBlock(tex):
                // Drawn by WebKit; until then, and when empty, a placeholder.
                let image = tex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Self.placeholder("New equation", font: font)
                    : rendered("$$\n\(tex)\n$$") ?? Self.placeholder(tex, font: small)
                fold(e.range, into: image, centered: true)
            case .table:
                // Laid out to the text's width, as on the page, so its edges
                // line up with code blocks. The width only changes in windows
                // narrower than the measure.
                let source = string.substring(with: e.range)
                fold(e.range, into: rendered(source, width: width.rounded(.down)) ?? Self.placeholder(source, font: small))
            case let .image(source):
                let url = URL(string: source).flatMap { $0.scheme == nil ? nil : $0 }
                    ?? URL(filePath: source.removingPercentEncoding ?? source, relativeTo: baseURL)
                // page.css: img { border-radius: var(--radius-sm) }
                fold(e.range, into: LiveImages.shared.picture(url) ?? Self.placeholder("Image: \(source)", font: font), radius: 6)
            case let .math(tex):
                let image = rendered("$\(tex)$") ?? Self.placeholder(tex, font: small)
                hide(e.range)
                hidden.remove(e.range.location)
                inlineMath[e.range.location] = .init(image: image, size: image.size, zone: e.range)
            case .code:
                inlineCode.append(e.range)
                e.markers.forEach(hide)
            case .quote:
                quotes.append(e.scope)
                e.markers.forEach(hide)
            case .listItem:
                if LiveEditing.isTask(string, e.content) {
                    // A box instead of the bullet, as in Notion: "- " goes,
                    // "[" draws the box, " ]" goes.
                    hide(NSRange(location: e.range.location, length: e.content.location - e.range.location))
                    hide(NSRange(location: e.content.location + 1, length: 2))
                    tasks[e.content.location] = string.substring(with: NSRange(location: e.content.location + 1, length: 1)) != " "
                    continue
                }
                // Numbers stay; "-", "*" and "+" read as a bullet.
                let m = e.markers[0]
                if m.length == 1, "-*+".contains(string.substring(with: m)) { bullets.insert(m.location) }
            case .heading, .strong, .emphasis, .strikethrough, .link:
                e.markers.forEach(hide)
            }
        }
    }

    /// Dim text standing in for something not drawn yet.
    private static func placeholder(_ text: String, font: NSFont) -> NSImage {
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(token: .fgDim)])
        let size = s.boundingRect(with: NSSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin]).size
        return NSImage(size: NSSize(width: ceil(size.width) + 2, height: ceil(size.height)), flipped: true) { _ in
            s.draw(with: NSRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin])
            return true
        }
    }
}

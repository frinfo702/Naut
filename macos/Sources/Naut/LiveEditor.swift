import AppKit
import NautKit
import SwiftUI

/// One pane that is both source and page, like Obsidian's Live Preview.
/// The Markdown is styled as it will read; its syntax (`##`, `**`, link
/// targets, code fences) shows only where the caret is, and math is drawn
/// as on the page until the caret enters it. The file stays plain
/// Markdown: only drawing changes, never the characters.
///
/// Built on TextKit 1 because it can hide glyphs without touching the
/// text (glyph properties, WWDC 2018 "TextKit Best Practices") and lets the line-height delegate move the baseline and
/// the used rect together, which keeps the caret and the input method's
/// candidate window at the height of the text instead of the line.
///
/// ponytail: tables, images and syntax highlighting stay as source. Split
/// mode shows them rendered.
struct LiveEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let mono: NSFont
    let outline: [Heading]
    @Binding var scrollTarget: String?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = LiveLayout()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let view = LiveTextView(frame: .zero, textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = .width
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.insertionPointColor = NSColor(token: .fg)
        // Markdown wants the characters typed, not typographer's quotes.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.smartInsertDeleteEnabled = false
        view.delegate = context.coordinator
        storage.delegate = context.coordinator

        let c = context.coordinator
        c.view = view
        c.layout = layout
        view.appearanceChanged = { [weak c] in c?.refresh() }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? LiveTextView else { return }
        let c = context.coordinator
        var dirty = c.font != font || c.mono != mono
        c.font = font
        c.mono = mono
        // Only a different note gets here: edits already updated `text`.
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: 0, length: 0))
            // Undo would otherwise apply the last note's edits to this one.
            view.undoManager?.removeAllActions()
            dirty = true
        }
        if dirty { c.restyle() }

        if let id = scrollTarget {
            if let i = outline.firstIndex(where: { $0.id == id }) { c.scroll(toHeading: i) }
            DispatchQueue.main.async { scrollTarget = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        @Binding var text: String
        weak var view: LiveTextView?
        weak var layout: LiveLayout?
        var font = NSFont.systemFont(ofSize: Metrics.textFontSize)
        var mono = NSFont.monospacedSystemFont(ofSize: Metrics.editorFontSize, weight: .regular)

        private var elements: [LiveMarkdown.Element] = []
        /// Indexes into `elements` the caret is in.
        private var editing: Set<Int> = []
        private var observer: NSObjectProtocol?

        init(text: Binding<String>) {
            _text = text
            super.init()
            observer = NotificationCenter.default.addObserver(forName: MathImages.didRender, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        // MARK: Input

        func textDidChange(_ note: Notification) {
            guard let view else { return }
            text = view.string
            // While an input method is composing, its marked text carries
            // the composition's underline; restyling would wipe it. The
            // commit is another change, and restyles then.
            guard !view.hasMarkedText() else { return }
            restyle()
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let view, !view.hasMarkedText() else { return }
            updateEditing(invalidate: true)
        }

        /// Keep the layout state on the same characters as text moves
        /// under it: composing inserts text but skips `restyle`, and this
        /// runs before layout sees the edit.
        nonisolated func textStorage(
            _ storage: NSTextStorage,
            didProcessEditing mask: NSTextStorageEditActions,
            range: NSRange,
            changeInLength delta: Int
        ) {
            guard mask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                layout?.shift(edited: range, delta: delta)
            }
        }

        // MARK: Styling

        /// Parse and style the whole note.
        ///
        /// ponytail: every keystroke parses and styles every line. Fine for
        /// notes of a few thousand lines; restyle only edited paragraphs if
        /// long ones ever lag.
        func restyle() {
            guard let view, let storage = view.textStorage else { return }
            elements = LiveMarkdown.parse(storage.string)
            let style = LiveStyle(font: font, mono: mono)
            editing = []
            updateEditing(invalidate: false)
            storage.beginEditing()
            storage.setAttributes(style.body, range: NSRange(location: 0, length: storage.length))
            for e in elements { style.apply(e, to: storage) }
            storage.endEditing()
            if storage.length == 0 { view.typingAttributes = style.body }
        }

        /// Redo the layout state, e.g. when math images arrive or the
        /// appearance changes.
        func refresh() {
            guard let layout, let storage = view?.textStorage else { return }
            updateEditing(invalidate: false)
            let all = NSRange(location: 0, length: storage.length)
            layout.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
            view?.needsDisplay = true
        }

        /// Work out which elements the caret is in and what that hides.
        private func updateEditing(invalidate: Bool) {
            guard let view, let layout else { return }
            let string = view.string as NSString
            let selection = view.selectedRange()
            let caretLines = string.lineRange(for: selection)
            func isEditing(_ scope: NSRange) -> Bool {
                NSIntersectionRange(scope, caretLines).length > 0
                    || NSLocationInRange(selection.location, scope)
                    // The end of a last line with no newline after it.
                    || (selection.location == NSMaxRange(scope) && selection.location == string.length)
            }
            let now = Set(elements.indices.filter { isEditing(elements[$0].scope) })
            let changed = now.symmetricDifference(editing)
            editing = now
            layout.state = LiveLayout.State(elements: elements, editing: now, string: string, font: font, dark: view.effectiveAppearance.isDark)

            guard invalidate, !changed.isEmpty else { return }
            let range = changed.map { elements[$0].scope }.reduce(elements[changed.first!].scope, NSUnionRange)
            layout.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            view.needsDisplay = true
        }

        func scroll(toHeading index: Int) {
            // libnaut and LiveMarkdown both list headings in source order.
            let headings = elements.filter { if case .heading = $0.kind { true } else { false } }
            guard let view, let layout, let container = view.textContainer, index < headings.count else { return }
            let glyphs = layout.glyphRange(forCharacterRange: headings[index].range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            view.scroll(NSPoint(x: 0, y: max(0, rect.minY + view.textContainerOrigin.y - Metrics.editorInset)))
        }
    }
}

// MARK: - Text view

final class LiveTextView: NSTextView {
    var appearanceChanged: (() -> Void)?

    /// Keep lines to page.css's measure, centred, like the preview.
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let side = max(Metrics.editorInset, (size.width - Metrics.measure) / 2)
        if textContainerInset.width != side {
            textContainerInset = NSSize(width: side, height: Metrics.editorInset * 2)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

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
        case .codeBlock, .mathBlock:
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = Self.codeInset
            p.headIndent = Self.codeInset
            p.tailIndent = -Self.codeInset
            s.addAttributes([.font: mono, .foregroundColor: fg, .paragraphStyle: p], range: e.scope)
        case .quote:
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = Self.quoteInset
            p.headIndent = Self.quoteInset
            s.addAttributes([.foregroundColor: dim, .paragraphStyle: p], range: e.scope)
        case .listItem:
            // A hanging indent, so wrapped lines start under the text.
            let prefix = (s.string as NSString).substring(with: NSRange(location: e.range.location, length: e.content.location - e.range.location))
            let p = NSMutableParagraphStyle()
            p.headIndent = (prefix as NSString).size(withAttributes: [.font: font]).width
            s.addAttribute(.paragraphStyle, value: p, range: e.scope)
        }
        for m in e.markers { s.addAttribute(.foregroundColor, value: dim, range: m) }
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

/// Lays the note out with its syntax hidden or shown, and draws what
/// attributes can't: code block and inline code backgrounds, quote bars,
/// and math.
final class LiveLayout: NSLayoutManager, NSLayoutManagerDelegate {
    /// What the caret position means for layout. Indexes are characters.
    struct State {
        /// Characters laid out with no width and not drawn.
        var hidden = IndexSet()
        /// Inline math: the formula's first character is drawn as its
        /// image and the rest are hidden.
        var inlineMath: [Int: NSImage] = [:]
        /// Display math, drawn in the opening `$$` line.
        var blockMath: [Int: NSImage] = [:]
        /// Lines (by first character) with a set height: hidden fences
        /// become a code block's padding; math blocks fold to their image.
        var lineHeights: [Int: CGFloat] = [:]
        var codeBlocks: [NSRange] = []
        var inlineCode: [NSRange] = []
        var quotes: [NSRange] = []
        /// List markers drawn as a bullet.
        var bullets: Set<Int> = []
    }

    var state = State()

    /// Extra space per line as a fraction of its text height, split above
    /// and below: page.css sets 1.75 against a font's own ~1.2.
    static let lineSpacing: CGFloat = 0.45
    /// A hidden fence's line height, plus the outset below, is a code
    /// block's padding: page.css's 18px.
    static let codePadding: CGFloat = 12
    static let codeOutset: CGFloat = 6
    static let mathMargin: CGFloat = 10

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
              state.hidden.intersects(integersIn: first..<last + 1) || !state.inlineMath.isEmpty
        else { return 0 }
        var out = Array(UnsafeBufferPointer(start: props, count: range.length))
        var touched = false
        for (i, c) in indexes.enumerated() {
            if state.inlineMath[c] != nil || state.hidden.contains(c) || state.bullets.contains(c) {
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
        if state.inlineMath[charIndex] != nil || state.bullets.contains(charIndex) { return .whitespace }
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
        if let image = state.inlineMath[characterIndex] {
            return NSRect(origin: glyphPosition, size: NSSize(width: image.size.width, height: 1))
        }
        // As wide as the "-" it replaces, so the hanging indent still fits.
        let font = textStorage?.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
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
        var extra = used.pointee.height * Self.lineSpacing
        for (c, image) in state.inlineMath where NSLocationInRange(c, chars) {
            extra = max(extra, image.size.height + 4 - used.pointee.height)
        }
        rect.pointee.size.height += extra
        used.pointee.origin.y += extra / 2
        baselineOffset.pointee += extra / 2
        return true
    }

    /// The empty line after a final newline. Same spacing, same caret.
    override func setExtraLineFragmentRect(_ rect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        let extra = usedRect.height * Self.lineSpacing
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
        let width = container.size.width - 2 * pad

        for block in state.codeBlocks where NSIntersectionRange(block, visible).length > 0 {
            guard let (top, bottom) = verticalExtent(of: block) else { continue }
            let r = NSRect(x: origin.x + pad, y: origin.y + top, width: width, height: bottom - top)
                .insetBy(dx: 0, dy: -Self.codeOutset)
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
            NSColor(token: .surface).setFill()
            path.fill()
            NSColor(token: .edgeTop).setStroke()
            path.lineWidth = 1
            path.stroke()
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

        super.drawBackground(forGlyphRange: glyphs, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphs, at: origin)
        guard let container = textContainers.first, let storage = textStorage else { return }
        let visible = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        for (c, image) in state.inlineMath where NSLocationInRange(c, visible) {
            let g = glyphIndexForCharacter(at: c)
            let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let at = location(forGlyphAt: g)
            // Centre on the text's x-height, where operators sit.
            let font = storage.attribute(.font, at: c, effectiveRange: nil) as? NSFont
            let middle = line.minY + at.y - (font?.xHeight ?? 0) / 2
            draw(image, in: NSRect(x: line.minX + at.x, y: middle - image.size.height / 2, width: image.size.width, height: image.size.height), at: origin)
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

        for (c, image) in state.blockMath where NSLocationInRange(c, visible) {
            let line = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: c), effectiveRange: nil)
            let width = min(image.size.width, container.size.width)
            let x = (container.size.width - width) / 2
            draw(image, in: NSRect(x: x, y: line.midY - image.size.height / 2, width: width, height: image.size.height), at: origin)
        }
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
        s.blockMath = move(s.blockMath)
        s.lineHeights = move(s.lineHeights)
        s.codeBlocks = s.codeBlocks.compactMap(move)
        s.inlineCode = s.inlineCode.compactMap(move)
        s.quotes = s.quotes.compactMap(move)
        s.bullets = Set(s.bullets.compactMap(move))
        state = s
    }
}

extension LiveLayout.State {
    /// The state for `elements` with the caret in `editing`.
    @MainActor
    init(elements: [LiveMarkdown.Element], editing: Set<Int>, string: NSString, font: NSFont, dark: Bool) {
        func lines(_ range: NSRange) -> [NSRange] {
            var out: [NSRange] = []
            string.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in out.append(line) }
            return out
        }
        func math(_ tex: String, display: Bool) -> NSImage? {
            MathImages.shared.image(.init(tex: tex, display: display, size: font.pointSize, dark: dark))
        }

        for (i, e) in elements.enumerated() {
            let isEditing = editing.contains(i)
            switch e.kind {
            case .codeBlock:
                codeBlocks.append(e.scope)
                guard !isEditing else { continue }
                for m in e.markers {
                    hidden.insert(integersIn: Range(m)!)
                    lineHeights[m.location] = LiveLayout.codePadding
                }
            case let .mathBlock(tex):
                // Until the image is ready, or while editing, the source.
                guard !isEditing, let image = math(tex, display: true) else {
                    codeBlocks.append(e.scope)
                    continue
                }
                // Fold every line to nothing but the first, which holds the
                // image. Newlines stay glyphs: they are what breaks lines.
                for row in lines(e.scope) {
                    hidden.insert(integersIn: Range(row)!)
                    lineHeights[row.location] = 0.01
                }
                lineHeights[e.scope.location] = image.size.height + 2 * LiveLayout.mathMargin
                blockMath[e.scope.location] = image
            case let .math(tex):
                guard !isEditing, let image = math(tex, display: false) else {
                    inlineCode.append(e.range)
                    continue
                }
                hidden.insert(integersIn: Range(e.range)!)
                hidden.remove(e.range.location)
                inlineMath[e.range.location] = image
            case .code:
                inlineCode.append(e.range)
                if !isEditing { for m in e.markers { hidden.insert(integersIn: Range(m)!) } }
            case .quote:
                quotes.append(e.scope)
                if !isEditing { for m in e.markers { hidden.insert(integersIn: Range(m)!) } }
            case .listItem:
                // Numbers stay; "-", "*" and "+" read as a bullet.
                let m = e.markers[0]
                if !isEditing, m.length == 1, "-*+".contains(string.substring(with: m)) { bullets.insert(m.location) }
            case .heading, .strong, .emphasis, .strikethrough, .link:
                if !isEditing { for m in e.markers { hidden.insert(integersIn: Range(m)!) } }
            }
        }
    }
}

import AppKit
import NautKit
import SwiftUI

/// One pane that reads like the page and is edited in place, like Notion.
/// Markdown syntax is never shown: `## ` makes a heading as it is typed,
/// `**` wraps bold, Return continues a list, ``` or $$ then Return makes a
/// block. Math, tables and pictures are drawn; a click edits their source
/// in a popover.
///
/// The note's Markdown (`source`) is the truth. The text view holds only
/// its projection (`LiveProjection`): the text with the syntax left out
/// and each drawn block as one attachment. Any caret position the text
/// view can make is therefore a real one; nothing corrects it afterwards.
/// Each edit the text view asks for is turned into an edit of the source
/// (`LiveEditing`), the source is projected again, and only the part of
/// the display that changed is replaced.
///
/// TextKit 1, for the line-height delegate: it moves the baseline and the
/// used rect together, which keeps the caret and the input method's
/// candidate window at the height of the text instead of the line.
struct LiveEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let mono: NSFont
    /// CSS line-height of body text.
    let lineHeight: Double
    let outline: [Heading]
    /// Relative image paths resolve against this, as in the preview.
    let baseURL: URL
    /// The note's name, edited above the text as a Notion page's title.
    let title: String
    let rename: (String) -> Void
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
        // Undo is of the source, not of the display: see Coordinator.
        view.allowsUndo = false
        view.insertionPointColor = NSColor(token: .fg)
        // Markdown wants the characters typed, not typographer's quotes.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.smartInsertDeleteEnabled = false
        view.delegate = context.coordinator

        let c = context.coordinator
        c.view = view
        c.layout = layout
        view.history = c.history
        view.appearanceChanged = { [weak c] in c?.refresh() }
        view.widthChanged = { [weak c] in c?.refresh() }
        view.click = { [weak c] in c?.click(at: $0) ?? false }
        view.key = { [weak c] in c?.key($0) ?? false }
        view.copySource = { [weak c] in c?.markdown(of: $0) ?? "" }

        let title = NSTextField(string: "")
        title.isBordered = false
        title.drawsBackground = false
        title.focusRingType = .none
        title.isEditable = true
        title.usesSingleLineMode = false
        title.maximumNumberOfLines = 0
        title.lineBreakMode = .byWordWrapping
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.textColor = NSColor(token: .fg)
        title.delegate = context.coordinator
        view.titleField = title

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = LiveDocumentView(text: view, title: title)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = (scroll.documentView as? LiveDocumentView)?.text else { return }
        let c = context.coordinator
        var dirty = c.font != font || c.mono != mono || c.baseURL != baseURL
        if let layout = view.layoutManager as? LiveLayout, layout.lineHeight != lineHeight {
            layout.lineHeight = lineHeight
            dirty = true
        }
        c.font = font
        c.mono = mono
        c.baseURL = baseURL
        c.rename = rename
        c.showTitle(title)
        // Only another note, or a change from outside, gets here: our own
        // edits already set `text` to the source.
        if text != c.source, !view.hasMarkedText() {
            c.load(text)
            // A new, empty note starts at its title, as in Notion.
            if text.isEmpty { DispatchQueue.main.async { c.focusTitle(selectAll: true) } }
        } else if dirty {
            c.refresh()
        }

        if let id = scrollTarget {
            if let i = outline.firstIndex(where: { $0.id == id }) { c.scroll(toHeading: i) }
            DispatchQueue.main.async { scrollTarget = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
        @Binding var text: String
        weak var view: LiveTextView?
        weak var layout: LiveLayout?
        var font = NSFont.systemFont(ofSize: Metrics.textFontSize)
        var mono = NSFont.monospacedSystemFont(ofSize: Metrics.editorFontSize, weight: .regular)
        var baseURL = URL.documentsDirectory
        var rename: (String) -> Void = { _ in }

        /// The note's Markdown. The truth; the display is made from it.
        private(set) var source = ""
        /// What the text view holds, and how it maps back to `source`.
        private var projection = LiveProjection("")
        private var editing: LiveEditing { LiveEditing(projection) }

        /// Undo and redo of the source. The text view's own undo would
        /// replay edits of the display, which our re-projection rewrites.
        let history = UndoManager()
        /// When typing last registered an undo step: typing within a short
        /// while is one step, as in any editor.
        private var lastTyping: Date?

        /// Set while we change the display ourselves.
        private var applying = false
        /// Text the text view has put in the display that isn't in the
        /// source yet: typing, or an input method composing. `range` is in
        /// the display of `projection`, the one it started from; `length`
        /// is how long that stretch of the display is now; `selection` is
        /// the selection before it; `preferring`, the caret's source
        /// position then, if known.
        private var pending: (range: NSRange, length: Int, selection: NSRange, preferring: Int?)?
        /// The source position the caret is at, when we put it there and it
        /// hasn't moved since. The display can't tell "after bold text" from
        /// "after its closing `**`"; this can, so text typed next goes where
        /// the caret really is.
        private var caretSource: Int?

        /// The title as the store has it.
        private var title = ""
        private var observer: NSObjectProtocol?

        private var popover: SourcePopover?
        /// The source the popover edits, kept current as it edits.
        private var popoverRange = NSRange(location: 0, length: 0)
        /// The element it edits, and what to select when it closes.
        private var popoverKind: LiveMarkdown.Element.Kind?
        private var popoverReturn: NSRange?

        init(text: Binding<String>) {
            _text = text
            super.init()
            observer = NotificationCenter.default.addObserver(forName: LiveImages.didRender, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        // MARK: Source

        /// Show another note.
        func load(_ text: String) {
            closePopover()
            source = text
            pending = nil
            lastTyping = nil
            history.removeAllActions()
            render(select: NSRange(location: 0, length: 0))
        }

        /// Replace part of the source, as one undoable edit, and show it.
        /// `before` is the selection to restore on undo, if not the current.
        private func replace(_ range: NSRange, with string: String, select: NSRange, typing: Bool = false, before: NSRange? = nil) {
            remember(typing: typing, selection: before ?? view?.selectedRange() ?? NSRange(location: 0, length: 0))
            source = (source as NSString).replacingCharacters(in: range, with: string)
            text = source
            render(selectSource: select)
        }

        private func remember(typing: Bool, selection: NSRange) {
            let now = Date()
            if typing, let last = lastTyping, now.timeIntervalSince(last) < 1.5 {
                lastTyping = now
                return
            }
            lastTyping = typing ? now : nil
            let before = source
            history.registerUndo(withTarget: self) { $0.restore(before, selection: selection) }
        }

        private func restore(_ old: String, selection: NSRange) {
            let current = source
            let currentSelection = view?.selectedRange() ?? NSRange(location: 0, length: 0)
            history.registerUndo(withTarget: self) { $0.restore(current, selection: currentSelection) }
            lastTyping = nil
            source = old
            text = old
            render(select: selection)
        }

        // MARK: Display

        /// Project the source and bring the display, its look and what the
        /// layout draws up to date, then select `select` (display).
        private func render(select: NSRange? = nil, selectSource: NSRange? = nil) {
            guard let view, let storage = view.textStorage else { return }
            projection = LiveProjection(source)

            // Only the stretch that changed, so the text view keeps its
            // layout and scroll position for the rest.
            let old = storage.string as NSString
            let new = projection.display
            if !old.isEqual(to: new as String) {
                var head = 0
                while head < old.length, head < new.length, old.character(at: head) == new.character(at: head) { head += 1 }
                var tail = 0
                while tail < old.length - head, tail < new.length - head,
                      old.character(at: old.length - 1 - tail) == new.character(at: new.length - 1 - tail) { tail += 1 }
                applying = true
                storage.replaceCharacters(in: NSRange(location: head, length: old.length - head - tail),
                                          with: new.substring(with: NSRange(location: head, length: new.length - head - tail)))
                applying = false
            }
            style()

            if let selectSource {
                caretSource = selectSource.length == 0 ? selectSource.location : nil
                let start = projection.display(at: selectSource.location)
                place(NSRange(location: start, length: projection.display(at: NSMaxRange(selectSource)) - start))
            } else if let select {
                place(NSRange(location: min(select.location, new.length), length: min(select.length, new.length - min(select.location, new.length))))
            }
        }

        /// Style the display and tell the layout what to draw.
        private func style() {
            guard let view, let storage = view.textStorage, let layout else { return }
            LiveStyle(font: font, mono: mono).style(projection, in: storage) { attachment(for: $0) }
            layout.state = LiveLayout.State(projection)
            if let a = typingAttributes(at: view.selectedRange()) { view.typingAttributes = a }
            relayoutEnd()
        }

        /// Redo the look, e.g. when images arrive or the appearance, width
        /// or fonts change.
        func refresh() {
            guard let view, let layout, let storage = view.textStorage, !view.hasMarkedText() else { return }
            style()
            let all = NSRange(location: 0, length: storage.length)
            layout.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
            view.needsDisplay = true
        }

        /// Select `r`. Not scrolling: only an edit the user made scrolls to
        /// where it happened (`perform`), as the text view's own do.
        private func place(_ r: NSRange) {
            view?.setSelectedRange(r)
        }

        // MARK: Attachments

        /// Element `i` drawn: math and tables by WebKit, pictures from disk
        /// or the web; until then, and when empty, dim text in their place.
        private func attachment(for i: Int) -> NSTextAttachment? {
            guard let view else { return nil }
            let e = projection.elements[i]
            let dark = view.effectiveAppearance.isDark
            let width = view.textContainer.map { $0.size.width - 2 * $0.lineFragmentPadding } ?? Metrics.measure
            let small = NSFont(descriptor: mono.fontDescriptor, size: font.pointSize * 0.88) ?? mono
            func rendered(_ markdown: String, width: Double? = nil) -> NSImage? {
                LiveImages.shared.image(.init(markdown: markdown, width: width, size: font.pointSize, dark: dark))
            }
            func fitted(_ size: NSSize) -> NSSize {
                size.width <= width ? size : NSSize(width: width, height: size.height * width / size.width)
            }
            let cell: LiveAttachmentCell
            switch e.kind {
            case let .mathBlock(tex):
                let image = tex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Self.placeholder("New equation", font: font)
                    : rendered("$$\n\(tex)\n$$") ?? Self.placeholder(tex, font: small)
                cell = LiveAttachmentCell(picture: image, size: fitted(image.size))
            case .table:
                // Laid out to the text's width, as on the page, so its edges
                // line up with code blocks.
                let markdown = projection.source.substring(with: e.range)
                let image = rendered(markdown, width: width.rounded(.down)) ?? Self.placeholder(markdown, font: small)
                cell = LiveAttachmentCell(picture: image, size: fitted(image.size))
            case let .image(source):
                let url = URL(string: source).flatMap { $0.scheme == nil ? nil : $0 }
                    ?? URL(filePath: source.removingPercentEncoding ?? source, relativeTo: baseURL)
                let image = LiveImages.shared.picture(url) ?? Self.placeholder("Image: \(source)", font: font)
                // page.css: img { border-radius: var(--radius-sm) }
                cell = LiveAttachmentCell(picture: image, size: fitted(image.size), radius: 6)
            case let .math(tex):
                let image = rendered("$\(tex)$") ?? Self.placeholder(tex, font: small)
                // Centred on the text's x-height, where operators sit.
                cell = LiveAttachmentCell(picture: image, size: image.size, baselineOffset: font.xHeight / 2 - image.size.height / 2)
            default:
                return nil
            }
            let a = NSTextAttachment()
            a.attachmentCell = cell
            return a
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

        // MARK: Editing

        /// Every change the text view would make to the display comes here.
        /// Deleting is decided now, by the rules. Typing (and composing) is
        /// let into the display as it is, so the input method sees its own
        /// text, and taken into the source when it settles.
        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
            guard !applying, let string else { return true }
            if string.isEmpty, pending == nil, !view.hasMarkedText() {
                perform(editing.delete(range, selection: view.selectedRange()))
                return false
            }
            hold(range, string, selection: view.selectedRange())
            return true
        }

        /// Fold an edit of the display into `pending`. While an input method
        /// composes, its edits stay within the stretch it started, so the
        /// result is still one stretch of the original display.
        private func hold(_ r: NSRange, _ s: String, selection: NSRange) {
            let n = (s as NSString).length
            guard let p = pending else {
                pending = (r, n, selection, caretSource)
                return
            }
            // `r` is in the display as it is now; the stretch so far is
            // [p.range.location, p.range.location + p.length) of it, and
            // what follows it is shifted by its growth.
            let growth = p.length - p.range.length
            let start = min(r.location, p.range.location)
            let end = max(NSMaxRange(r), p.range.location + p.length)
            pending = (NSRange(location: start, length: end - growth - start), end - start - r.length + n, p.selection, p.preferring)
        }

        func textDidChange(_ note: Notification) {
            guard let view, !applying, let p = pending, !view.hasMarkedText() else { return }
            // Settled: take the stretch into the source, through the
            // projection it was typed into.
            pending = nil
            let typed = view.string as NSString
            let s = typed.substring(with: NSRange(location: p.range.location, length: min(p.length, typed.length - p.range.location)))
            perform(editing.type(s, over: p.range, preferring: p.preferring), typing: true, selection: p.selection)
        }

        private func perform(_ edit: LiveEditing.Edit, typing: Bool = false, selection: NSRange? = nil) {
            switch edit {
            case .none:
                // A refused edit may have left typed text in the display.
                render(select: view?.selectedRange())
            case let .select(r):
                place(r)
                view?.scrollRangeToVisible(r)
            case let .replace(r, s, select):
                replace(r, with: s, select: select, typing: typing, before: selection)
                if let view { view.scrollRangeToVisible(view.selectedRange()) }
                openIfInsideBlock(select)
            }
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !view.hasMarkedText() else { return false }
            let selection = view.selectedRange()
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Return on a selected block edits it.
                if selection.length == 1, let i = projection.attachments[selection.location] {
                    open(i)
                    return true
                }
                perform(editing.newline(selection, preferring: caretSource))
                return true
            case #selector(NSResponder.moveUp(_:)) where selection.length == 0 && onFirstLine():
                // Up from the first line goes to the title.
                focusTitle(selectAll: false)
                return true
            default:
                return false
            }
        }

        /// What text typed at the caret will look like: the attributes its
        /// first character gets once it is in the source and the note is
        /// styled again. Not the character before's, which is what the text
        /// view would take: on the empty line below a code block that is the
        /// code's last newline, and the caret sat indented as if in the code
        /// until a key was typed. An empty line has no character of its own,
        /// so TextKit lays it out, caret and all, with these.
        ///
        /// ponytail: parses and styles the note once more per caret move.
        /// Fine for notes of a few thousand lines; style only the paragraph
        /// it lands in if long ones ever lag.
        private func typingAttributes(at selection: NSRange) -> [NSAttributedString.Key: Any]? {
            guard selection.length == 0, NSMaxRange(selection) <= projection.display.length,
                  case let .replace(r, s, after) = editing.type("x", over: selection, preferring: caretSource)
            else { return nil }
            let typed = LiveProjection((source as NSString).replacingCharacters(in: r, with: s))
            let i = typed.display(at: after.location) - 1
            guard i >= 0, i < typed.display.length else { return nil }
            let storage = NSTextStorage(string: typed.display as String)
            LiveStyle(font: font, mono: mono).style(typed, in: storage) { _ in nil }
            var a = storage.attributes(at: i, effectiveRange: nil)
            a[.attachment] = nil
            return a
        }

        func textView(
            _ view: NSTextView,
            shouldChangeTypingAttributes old: [String: Any],
            toAttributes new: [NSAttributedString.Key: Any]
        ) -> [NSAttributedString.Key: Any] {
            // Composing keeps what it has: the input method draws with it.
            guard !applying, pending == nil, !view.hasMarkedText(), let a = typingAttributes(at: view.selectedRange()) else { return new }
            return a
        }

        /// TextKit lays out the empty line after a final newline with the
        /// typing attributes current when it lays out the end of the text,
        /// and doesn't again when they change. Measured: after a move to
        /// that line its rect was still the code's (indented, monospaced),
        /// or a heading's. So once the typing attributes are set (after the
        /// selection changes, not while they are being decided, when the
        /// old ones are still in force), lay the last paragraph out again.
        private func relayoutEnd() {
            guard let layout, let storage = view?.textStorage, storage.length > 0,
                  (storage.string as NSString).character(at: storage.length - 1) == 0x0A
            else { return }
            let last = (storage.string as NSString).paragraphRange(for: NSRange(location: storage.length - 1, length: 0))
            layout.invalidateLayout(forCharacterRange: last, actualCharacterRange: nil)
            view?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let view else { return }
            // Moved somewhere else: where it is in the source is the
            // display's to say again.
            if let at = caretSource, view.selectedRange() != NSRange(location: projection.display(at: at), length: 0) { caretSource = nil }
            relayoutEnd()
            // Selected blocks draw their own highlight.
            view.needsDisplay = true
        }

        func key(_ event: NSEvent) -> Bool {
            guard let view, !view.hasMarkedText() else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let selection = view.selectedRange()
            switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
            case ([.command], "b"): perform(editing.toggle(.strong, marker: "**", selection: selection))
            case ([.command], "i"): perform(editing.toggle(.emphasis, marker: "*", selection: selection))
            case ([.command], "e"): perform(editing.toggle(.code, marker: "`", selection: selection))
            case ([.command, .shift], "x"): perform(editing.toggle(.strikethrough, marker: "~~", selection: selection))
            case ([.command], "k"): link(selection)
            default: return false
            }
            return true
        }

        /// ⌘K: edit the URL of the link at the selection, or make the
        /// selection a link and ask for its URL.
        private func link(_ selection: NSRange) {
            let at = projection.sourceRange(selection)
            if let i = projection.elements.firstIndex(where: { $0.kind == .link && NSLocationInRange(at.location, $0.range) }) {
                open(i)
                return
            }
            let label = projection.source.substring(with: at)
            guard at.length > 0, !label.contains("\n") else { return }
            replace(at, with: "[\(label)]()", select: NSRange(location: at.location + 1, length: at.length))
            if let i = projection.elements.firstIndex(where: { $0.kind == .link && $0.range.location == at.location }) { open(i) }
        }

        /// The Markdown of display range `r`, for copying.
        func markdown(of r: NSRange) -> String {
            projection.source.substring(with: projection.sourceRange(r))
        }

        // MARK: Title

        func showTitle(_ title: String) {
            self.title = title
            guard let field = view?.titleField else { return }
            field.font = Self.titleFont(font)
            field.placeholderAttributedString = NSAttributedString(string: "Untitled", attributes: [
                .font: Self.titleFont(font), .foregroundColor: NSColor(token: .fgDim),
            ])
            // Not while it is being typed in.
            if field.currentEditor() == nil, field.stringValue != title { field.stringValue = title }
            view?.layoutTitle()
        }

        /// page.css's h1.page-title: 2.4em, semibold.
        static func titleFont(_ font: NSFont) -> NSFont {
            let d = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]])
            return NSFont(descriptor: d, size: font.pointSize * 2.4) ?? font
        }

        func focusTitle(selectAll: Bool) {
            guard let field = view?.titleField, field.window?.makeFirstResponder(field) == true else { return }
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = selectAll ? NSRange(location: 0, length: end) : NSRange(location: end, length: 0)
        }

        /// Whether the caret is on the first line of the text.
        private func onFirstLine() -> Bool {
            guard let view, let layout, let storage = view.textStorage else { return false }
            let p = view.selectedRange().location
            guard storage.length > 0 else { return true }
            if p == storage.length, (storage.string as NSString).character(at: p - 1) == 0x0A { return false }
            let first = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let here = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: min(p, storage.length - 1)), effectiveRange: nil)
            return here.minY <= first.minY
        }

        func controlTextDidChange(_ note: Notification) {
            // A long title wraps; the text moves down with it.
            view?.layoutTitle()
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = view?.titleField, field.stringValue != title else { return }
            rename(field.stringValue)
        }

        /// Return, Tab or down go to the text; Esc puts the title back.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let view else { return false }
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                view.titleField?.stringValue = title
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:)):
                break
            default:
                return false
            }
            view.window?.makeFirstResponder(view)
            place(NSRange(location: 0, length: 0))
            view.layoutTitle()
            return true
        }

        // MARK: Clicks and the popover

        func click(at point: NSPoint) -> Bool {
            guard let view, let layout, let container = view.textContainer else { return false }
            let p = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
            // A task's box checks and unchecks it.
            if let item = layout.task(at: p) {
                let e = projection.elements[item.element]
                let mark = NSRange(location: e.content.location + 1, length: 1)
                let checked = projection.source.substring(with: mark) != " "
                let selection = view.selectedRange()
                replace(mark, with: checked ? " " : "x", select: projection.sourceRange(selection))
                place(selection)
                return true
            }
            if let code = layout.languageLabel(at: p) {
                open(code.element)
                return true
            }
            // An attachment opens its source.
            let g = layout.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: nil)
            let c = layout.characterIndexForGlyph(at: g)
            if let i = projection.attachments[c], layout.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container).contains(p) {
                open(i)
                return true
            }
            return false
        }

        /// Opens the popover if an edit left the caret in a block: ``` or
        /// $$ and Return, or typing that completes a table.
        private func openIfInsideBlock(_ selection: NSRange) {
            guard popover == nil, selection.length == 0,
                  let atom = projection.atoms.first(where: { $0.isBlock && $0.range.location < selection.location && selection.location <= NSMaxRange($0.range) })
            else { return }
            open(atom.element, caret: selection.location)
        }

        /// Edit element `i`'s source in a popover; `caret` is a source
        /// position in it to start at.
        func open(_ i: Int, caret: Int? = nil) {
            guard let view, let layout, let container = view.textContainer, i < projection.elements.count else { return }
            let e = projection.elements[i]
            let s = projection.source
            let range: NSRange, multiline: Bool, title: String
            switch e.kind {
            case .mathBlock: (range, multiline, title) = (e.content, true, "Equation")
            case .math: (range, multiline, title) = (e.content, false, "Inline equation")
            case .table: (range, multiline, title) = (e.range, true, "Table")
            case .image: (range, multiline, title) = (e.content, false, "Image URL")
            case .link:
                // Between "](" and ")".
                let m = e.markers[1]
                (range, multiline, title) = (NSRange(location: m.location + 2, length: m.length - 3), false, "Link URL")
            case .codeBlock:
                // After the ``` of the opening fence.
                let fence = e.markers[0]
                let ticks = (s.substring(with: fence) as NSString).range(of: "^[ \\t]*[`~]{3}[ \\t]*", options: .regularExpression)
                (range, multiline, title) = (NSRange(location: fence.location + ticks.length, length: fence.length - ticks.length), false, "Language")
            default:
                return
            }

            var anchor = NSRect.zero
            if case .codeBlock = e.kind, let code = layout.state.code.first(where: { $0.element == i }) {
                anchor = layout.labelRect(code) ?? .zero
            } else {
                let shown = projection.attachment(of: i).map { NSRange(location: $0, length: 1) } ?? projection.displayRange(e.content)
                anchor = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: shown, actualCharacterRange: nil), in: container)
            }

            closePopover()
            popoverRange = range
            popoverKind = e.kind
            popoverReturn = view.selectedRange()
            let popover = SourcePopover(
                title: title,
                text: s.substring(with: range),
                multiline: multiline,
                font: mono,
                onChange: { [weak self] in self?.popoverChanged($0) },
                onClose: { [weak self] in self?.popoverClosed() }
            )
            self.popover = popover
            // A block shows as selected while it is edited.
            if let at = projection.attachment(of: i) { place(NSRange(location: at, length: 1)) }
            popover.show(
                relativeTo: anchor.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y),
                of: view,
                caret: caret.map { $0 - range.location }
            )
        }

        private func popoverChanged(_ text: String) {
            let selection = view?.selectedRange() ?? NSRange(location: 0, length: 0)
            replace(popoverRange, with: text, select: NSRange(location: popoverRange.location, length: 0))
            popoverRange.length = (text as NSString).length
            place(selection)
        }

        private func popoverClosed() {
            guard popover != nil, let view else { return }
            popover = nil
            view.window?.makeFirstResponder(view)
            // A block's: carry on below it, on a line made if it ends the
            // note. A link's or inline math's: after it. A language's: where
            // the caret was.
            if let atom = projection.atoms.first(where: { NSLocationInRange(popoverRange.location, $0.range) || $0.range.location == popoverRange.location }) {
                if atom.isBlock {
                    if NSMaxRange(atom.range) == projection.source.length {
                        replace(NSRange(location: projection.source.length, length: 0), with: "\n", select: NSRange(location: projection.source.length + 1, length: 0))
                    } else {
                        render(selectSource: NSRange(location: NSMaxRange(atom.range) + 1, length: 0))
                    }
                } else {
                    render(selectSource: NSRange(location: NSMaxRange(atom.range), length: 0))
                }
            } else if popoverKind == .link, let e = projection.elements.first(where: { $0.kind == .link && NSLocationInRange(popoverRange.location, $0.range) }) {
                render(selectSource: NSRange(location: NSMaxRange(e.range), length: 0))
            } else if let back = popoverReturn {
                place(back)
            }
        }

        func closePopover() {
            let p = popover
            popover = nil
            p?.close()
        }

        func scroll(toHeading index: Int) {
            // libnaut and LiveMarkdown both list headings in source order.
            let headings = projection.elements.filter { if case .heading = $0.kind { true } else { false } }
            guard let view, let layout, let container = view.textContainer, index < headings.count else { return }
            let glyphs = layout.glyphRange(forCharacterRange: projection.displayRange(headings[index].range), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            view.scroll(NSPoint(x: 0, y: max(0, rect.minY + view.textContainerOrigin.y - Metrics.editorInset)))
        }
    }
}

// MARK: - Text view

final class LiveTextView: NSTextView {
    var appearanceChanged: (() -> Void)?
    /// Tables and pictures are laid out to the text's width.
    var widthChanged: (() -> Void)?
    /// A click on something drawn; true if it was handled.
    var click: ((NSPoint) -> Bool)?
    /// Formatting shortcuts; true if handled.
    var key: ((NSEvent) -> Bool)?
    /// The Markdown behind a display range, for copying.
    var copySource: ((NSRange) -> String)?
    /// The source's undo history. Kept apart from the text view's own
    /// undo manager: the display is rewritten after each edit, so TextKit's
    /// undo actions would point into text that is no longer there.
    var history: UndoManager?

    /// The note's title, laid out above the text by `LiveDocumentView`.
    var titleField: NSTextField?

    func layoutTitle() {
        (superview as? LiveDocumentView)?.layoutContent()
    }

    /// Keep lines to page.css's measure, centred, like the preview.
    override func setFrameSize(_ size: NSSize) {
        let old = textContainer?.size.width
        super.setFrameSize(size)
        let side = max(Metrics.editorInset, (size.width - Metrics.measure) / 2)
        if textContainerInset.width != side {
            // Top and bottom: the gap below the title; the document adds
            // the rest of the room at the bottom.
            textContainerInset = NSSize(width: side, height: LiveDocumentView.titleGap)
        }
        if let old, textContainer?.size.width != old { widthChanged?() }
        // Taller or narrower text: the document follows.
        layoutTitle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, click?(convert(event.locationInWindow, from: nil)) == true { return }
        super.mouseDown(with: event)
    }

    // Before the main menu, whose ⌘E toggles the Split editor.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, key?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Copying copies the Markdown, not the text with its syntax left out.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let copySource, selectedRange().length > 0 else { return super.writeSelection(to: pboard, types: types) }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(copySource(selectedRange()), forType: .string)
    }
}

/// The scroll view's document: the title, then the text, stacked.
///
/// The title used to sit inside the text view, with an exclusion path
/// keeping the text out of its space. NSTextView then sized itself as if
/// that space weren't there and moved its container origin up to make
/// up for it, so once a note outgrew the window all of its text slid up
/// under the title. Two views, each with only its own content, have no
/// geometry to reconcile.
final class LiveDocumentView: NSView {
    let text: LiveTextView
    let title: NSTextField
    /// Between the title and the first line.
    static let titleGap: CGFloat = 20

    override var isFlipped: Bool { true }

    init(text: LiveTextView, title: NSTextField) {
        self.text = text
        self.title = title
        super.init(frame: .zero)
        autoresizingMask = .width
        addSubview(text)
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resizeSubviews(withOldSize old: NSSize) {
        super.resizeSubviews(withOldSize: old)
        layoutContent()
    }

    /// Title on top, aligned with the text's first column; the text view
    /// below it, at least tall enough to fill the window, so a click below
    /// the last line still lands in it.
    func layoutContent() {
        let top = Metrics.editorInset * 2
        let pad = text.textContainer?.lineFragmentPadding ?? 0
        let x = text.textContainerInset.width + pad
        let width = max(0, bounds.width - 2 * x)
        let height = ceil(title.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
        // The field's cell insets its text 2pt; line it up with the body.
        let titleFrame = NSRect(x: x - 2, y: top, width: width + 4, height: height)
        if title.frame != titleFrame { title.frame = titleFrame }

        let clip = enclosingScrollView?.contentView.bounds.height ?? 0
        let bottom = Metrics.editorInset * 2 - Self.titleGap
        text.minSize = NSSize(width: 0, height: max(0, clip - titleFrame.maxY - bottom))
        if text.frame.origin != NSPoint(x: 0, y: titleFrame.maxY) { text.setFrameOrigin(NSPoint(x: 0, y: titleFrame.maxY)) }
        if text.frame.width != bounds.width { text.setFrameSize(NSSize(width: bounds.width, height: max(text.frame.height, text.minSize.height))) }
        let size = NSSize(width: bounds.width, height: text.frame.maxY + bottom)
        if frame.size != size { setFrameSize(size) }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}


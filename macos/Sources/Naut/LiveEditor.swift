import AppKit
import NautKit
import SwiftUI

/// One pane that reads like the page and is edited in place, like Notion.
/// Markdown syntax is never shown: `## ` makes a heading as it is typed
/// and then hides, `**` wraps bold, Return continues a list, ``` or $$
/// then Return makes a block. Math, tables and pictures are always drawn;
/// a click edits their source in a popover. The file stays plain Markdown:
/// only drawing changes, never the characters. How the caret moves and
/// what deleting does around hidden syntax is `LiveEditing`, in NautKit.
///
/// Built on TextKit 1 because it can hide glyphs without touching the
/// text (glyph properties, WWDC 2018 "TextKit Best Practices") and lets
/// the line-height delegate move the baseline and the used rect together,
/// which keeps the caret and the input method's candidate window at the
/// height of the text instead of the line.
struct LiveEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let mono: NSFont
    /// CSS line-height of body text.
    let lineHeight: Double
    let outline: [Heading]
    /// Relative image paths resolve against this, as in the preview.
    let baseURL: URL
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
        view.widthChanged = { [weak c] in c?.refresh() }
        view.click = { [weak c] in c?.click(at: $0) ?? false }
        view.key = { [weak c] in c?.key($0) ?? false }
        view.adjustSelection = { [weak c] in c?.adjust(from: $0, to: $1) ?? $1 }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? LiveTextView else { return }
        let c = context.coordinator
        var dirty = c.font != font || c.mono != mono || c.baseURL != baseURL
        if let layout = view.layoutManager as? LiveLayout, layout.lineHeight != lineHeight {
            layout.lineHeight = lineHeight
            dirty = true
        }
        c.font = font
        c.mono = mono
        c.baseURL = baseURL
        // Only a different note gets here: edits already updated `text`.
        if view.string != text, !view.hasMarkedText() {
            c.closePopover()
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
        var baseURL = URL.documentsDirectory

        private var editing = LiveEditing(text: "", elements: [])
        private var observer: NSObjectProtocol?
        /// Set while applying our own edit, so the delegate lets it through.
        private var applying = false
        /// Set from a change being allowed until it lands: selection
        /// changes meanwhile are the text view's own and must not snap
        /// against the parse of the old text.
        private var changing = false
        /// Set while we place the caret ourselves.
        private var placing = false

        private var popover: SourcePopover?
        /// The source the popover edits, kept current as it edits.
        private var popoverRange = NSRange(location: 0, length: 0)
        /// Whether that source is a block's, so closing moves below it.
        private var popoverIsBlock = false
        /// Where the caret goes back to on closing, if not after the source.
        private var popoverReturn: NSRange?

        init(text: Binding<String>) {
            _text = text
            super.init()
            observer = NotificationCenter.default.addObserver(forName: LiveImages.didRender, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        // MARK: Text changes

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
            // Our own edits, input method composition, and attribute-only
            // changes go through as they are.
            guard !applying, let string, !view.hasMarkedText() else {
                changing = true
                return true
            }
            let edit = string.isEmpty
                ? editing.delete(range, selection: view.selectedRange())
                : editing.insert(range, string)
            guard edit != .allow else {
                changing = true
                return true
            }
            // Not from inside the text view's own change.
            DispatchQueue.main.async { self.apply(edit) }
            return false
        }

        func textDidChange(_ note: Notification) {
            guard let view else { return }
            changing = false
            text = view.string
            // While an input method is composing, its marked text carries
            // the composition's underline; restyling would wipe it. The
            // commit is another change, and restyles then.
            guard !view.hasMarkedText() else { return }
            restyle()
            // Typing that completes a table leaves the caret in it: carry on
            // in the popover.
            if !applying, popover == nil { openIfInside() }
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !view.hasMarkedText(), selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Return on a selected block edits it.
            let selection = view.selectedRange()
            if let zone = editing.zone(at: selection.location), selection == zone.range {
                open(zone.element)
                return true
            }
            let edit = editing.newline(selection)
            guard edit != .allow else { return false }
            apply(edit)
            return true
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

        // MARK: Selection

        /// The caret steps over hidden syntax instead of stopping in it.
        func textView(
            _ view: NSTextView,
            willChangeSelectionFromCharacterRanges old: [NSValue],
            toCharacterRanges new: [NSValue]
        ) -> [NSValue] {
            guard new.count == 1, let from = old.first?.rangeValue else { return new }
            return [NSValue(range: adjust(from: from, to: new[0].rangeValue))]
        }

        /// Where a selection moving from `from` to `to` should be instead.
        /// Asked by the delegate method above and, while the mouse is
        /// down, by the text view itself: it doesn't ask its delegate
        /// until the mouse comes up, and until then would draw the caret
        /// inside hidden syntax (above an equation, say) and then jump.
        func adjust(from: NSRange, to: NSRange) -> NSRange {
            guard !placing, !changing, let view, !view.hasMarkedText() else { return to }
            guard to.length == 0 else { return editing.expand(to) }
            let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            let motion: LiveEditing.Motion = NSApp.currentEvent.map { mouse.contains($0.type) } == true
                ? .nearest
                : to.location >= from.location ? .forward : .backward
            return NSRange(location: editing.snap(to.location, from: from.location, motion), length: 0)
        }

        func textViewDidChangeSelection(_ note: Notification) {
            // Selected blocks draw their own highlight.
            view?.needsDisplay = true
        }

        // MARK: Editing

        private func apply(_ edit: LiveEditing.Edit) {
            guard let view else { return }
            switch edit {
            case .allow, .ignore:
                return
            case let .select(r):
                place(r)
                view.scrollRangeToVisible(r)
            case let .replace(r, s, select):
                replace(r, with: s)
                place(select)
                openIfInside()
            }
        }

        /// Replace text as an undoable edit of the text view.
        private func replace(_ range: NSRange, with string: String) {
            guard let view, let storage = view.textStorage else { return }
            applying = true
            defer { applying = false }
            guard view.shouldChangeText(in: range, replacementString: string) else { return }
            storage.replaceCharacters(in: range, with: string)
            view.didChangeText()
        }

        private func place(_ r: NSRange) {
            placing = true
            view?.setSelectedRange(r)
            placing = false
        }

        func key(_ event: NSEvent) -> Bool {
            guard let view, !view.hasMarkedText() else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let selection = view.selectedRange()
            switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
            case ([.command], "b"): apply(editing.toggle(.strong, marker: "**", selection: selection))
            case ([.command], "i"): apply(editing.toggle(.emphasis, marker: "*", selection: selection))
            case ([.command], "e"): apply(editing.toggle(.code, marker: "`", selection: selection))
            case ([.command, .shift], "x"): apply(editing.toggle(.strikethrough, marker: "~~", selection: selection))
            case ([.command], "k"): link(selection)
            default: return false
            }
            return true
        }

        /// ⌘K: edit the URL of the link at the selection, or make the
        /// selection a link and ask for its URL.
        private func link(_ selection: NSRange) {
            if let i = editing.elements.firstIndex(where: { $0.kind == .link && NSLocationInRange(selection.location, $0.range) }) {
                open(i)
                return
            }
            let label = editing.text.substring(with: selection)
            guard selection.length > 0, !label.contains("\n") else { return }
            replace(selection, with: "[\(label)]()")
            if let i = editing.elements.firstIndex(where: { $0.kind == .link && $0.range.location == selection.location }) {
                open(i)
            }
        }

        // MARK: Popover

        func click(at point: NSPoint) -> Bool {
            guard let view, let layout else { return false }
            let p = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
            // A task's box checks and unchecks it.
            if let c = layout.task(at: p) {
                let mark = NSRange(location: c + 1, length: 1)
                replace(mark, with: editing.text.substring(with: mark) == " " ? "x" : " ")
                return true
            }
            if let c = layout.languageLabel(at: p), let i = editing.elements.firstIndex(where: { $0.scope.location == c }) {
                open(i)
                return true
            }
            // The layout keys what it draws by its first character.
            guard let c = layout.atom(at: p), let i = editing.atoms.first(where: { editing.elements[$0].range.location == c }) else { return false }
            open(i)
            return true
        }

        /// Opens the popover if the caret has ended up inside a block.
        private func openIfInside() {
            guard let view, view.selectedRange().length == 0 else { return }
            let p = view.selectedRange().location
            guard let zone = editing.zone(at: p) else { return }
            open(zone.element, caret: p)
        }

        /// Edit element `i`'s source in a popover.
        func open(_ i: Int, caret: Int? = nil) {
            guard let view, let layout, let container = view.textContainer, i < editing.elements.count else { return }
            let e = editing.elements[i]
            let t = editing.text
            let range: NSRange, multiline: Bool, title: String, anchor: NSRect
            var select = e.range
            switch e.kind {
            case .mathBlock:
                (range, multiline, title) = (e.content, true, "Equation")
            case .math:
                (range, multiline, title) = (e.content, false, "Inline equation")
            case .table:
                (range, multiline, title) = (e.range, true, "Table")
            case .image:
                (range, multiline, title) = (e.content, false, "Image URL")
            case .link:
                // Between "](" and ")".
                let m = e.markers[1]
                (range, multiline, title) = (NSRange(location: m.location + 2, length: m.length - 3), false, "Link URL")
                select = NSRange(location: NSMaxRange(e.range), length: 0)
            case .codeBlock:
                // After the ``` of the opening fence.
                let fence = e.markers[0]
                let ticks = (t.substring(with: fence) as NSString).range(of: "^[ \\t]*[`~]{3}[ \\t]*", options: .regularExpression)
                (range, multiline, title) = (NSRange(location: fence.location + ticks.length, length: fence.length - ticks.length), false, "Language")
                select = view.selectedRange()
            default:
                return
            }
            switch e.kind {
            case .codeBlock:
                anchor = layout.labelRect(e.scope) ?? .zero
            case .link:
                anchor = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: e.content, actualCharacterRange: nil), in: container)
            default:
                anchor = layout.rect(of: e.range.location) ?? .zero
                select = editing.zone(at: e.range.location)?.range ?? e.range
            }

            closePopover()
            popoverRange = range
            popoverIsBlock = editing.zone(at: e.range.location) != nil
            if case .codeBlock = e.kind { popoverReturn = view.selectedRange() } else { popoverReturn = nil }
            let popover = SourcePopover(
                title: title,
                text: t.substring(with: range),
                multiline: multiline,
                font: mono,
                onChange: { [weak self] in self?.popoverChanged($0) },
                onClose: { [weak self] in self?.popoverClosed() }
            )
            self.popover = popover
            // The block shows as selected while it is edited.
            place(select)
            popover.show(
                relativeTo: anchor.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y),
                of: view,
                caret: caret.map { $0 - range.location }
            )
        }

        private func popoverChanged(_ source: String) {
            replace(popoverRange, with: source)
            popoverRange.length = (source as NSString).length
            if popoverIsBlock, let zone = editing.zone(at: popoverRange.location) { place(zone.range) }
        }

        private func popoverClosed() {
            guard popover != nil, let view else { return }
            popover = nil
            view.window?.makeFirstResponder(view)
            // Carry on after what was edited: below a block, on a new line
            // if the block ends the note.
            if let back = popoverReturn {
                place(back)
                return
            }
            var caret = NSMaxRange(popoverRange)
            if popoverIsBlock, let zone = editing.zone(at: popoverRange.location) {
                if NSMaxRange(zone.range) == editing.text.length {
                    replace(NSRange(location: editing.text.length, length: 0), with: "\n")
                }
                caret = NSMaxRange(zone.range) + 1
            } else if let span = editing.inline.first(where: { NSLocationInRange(caret, $0) }) {
                // After a link's or an equation's closing syntax.
                caret = NSMaxRange(span)
            }
            place(NSRange(location: min(caret, editing.text.length), length: 0))
        }

        func closePopover() {
            let p = popover
            popover = nil
            p?.close()
        }

        // MARK: Styling

        /// Parse and style the whole note.
        ///
        /// ponytail: every keystroke parses and styles every line. Fine for
        /// notes of a few thousand lines; restyle only edited paragraphs if
        /// long ones ever lag.
        func restyle() {
            guard let view, let storage = view.textStorage else { return }
            let elements = LiveMarkdown.parse(storage.string)
            editing = LiveEditing(text: storage.string, elements: elements)
            let style = LiveStyle(font: font, mono: mono)
            updateLayout()
            storage.beginEditing()
            storage.setAttributes(style.body, range: NSRange(location: 0, length: storage.length))
            for e in elements { style.apply(e, to: storage) }
            storage.endEditing()
            if storage.length == 0 { view.typingAttributes = style.body }
        }

        /// Redo the layout state, e.g. when images arrive or the
        /// appearance or width changes.
        func refresh() {
            guard let layout, let storage = view?.textStorage else { return }
            updateLayout()
            let all = NSRange(location: 0, length: storage.length)
            layout.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
            view?.needsDisplay = true
        }

        private func updateLayout() {
            guard let view, let layout else { return }
            let width = view.textContainer.map { $0.size.width - 2 * $0.lineFragmentPadding } ?? Metrics.measure
            layout.state = LiveLayout.State(
                elements: editing.elements, string: editing.text, font: font, mono: mono,
                dark: view.effectiveAppearance.isDark, width: width, baseURL: baseURL
            )
        }

        func scroll(toHeading index: Int) {
            // libnaut and LiveMarkdown both list headings in source order.
            let headings = editing.elements.filter { if case .heading = $0.kind { true } else { false } }
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
    /// Tables and pictures are laid out to the text's width.
    var widthChanged: (() -> Void)?
    /// A click on something drawn rendered; true if it was handled.
    var click: ((NSPoint) -> Bool)?
    /// Formatting shortcuts; true if handled.
    var key: ((NSEvent) -> Bool)?
    /// The selection to make instead of one being made with the mouse.
    var adjustSelection: ((_ from: NSRange, _ to: NSRange) -> NSRange)?

    /// Keep lines to page.css's measure, centred, like the preview.
    override func setFrameSize(_ size: NSSize) {
        let old = textContainer?.size.width
        super.setFrameSize(size)
        let side = max(Metrics.editorInset, (size.width - Metrics.measure) / 2)
        if textContainerInset.width != side {
            textContainerInset = NSSize(width: side, height: Metrics.editorInset * 2)
        }
        if let old, textContainer?.size.width != old { widthChanged?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if stillSelecting, ranges.count == 1, let adjustSelection {
            ranges = [NSValue(range: adjustSelection(selectedRange(), ranges[0].rangeValue))]
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
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
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

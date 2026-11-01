import AppKit
import NautKit
import SwiftUI

/// The Split mode's Markdown source. An NSTextView rather than SwiftUI's
/// TextEditor so it can use the same modal engine and cursor as Live
/// Preview: Vim and Helix keys, and a block cursor when they ask for one.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let themeRevision: Int
    let keymap: EditorKeymap
    let cursorShape: CursorShape
    let cursorBlink: CursorBlink
    @Binding var mode: ModalMode

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, mode: $mode) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = SourceLayout()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let view = CursorTextView(frame: .zero, textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = .width
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.insertionPointColor = .themeCursor
        // SourceLayout paints the selection background, stopping at the
        // line's last character instead of carrying the newline across
        // the column.
        view.selectedTextAttributes = [
            .backgroundColor: NSColor.clear,
            .foregroundColor: NSColor.selectedTextColor,
        ]
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        // NSTextView adds 5pt of line padding; the other 19 make the
        // usual editor inset.
        view.textContainerInset = NSSize(width: Metrics.editorInset - 5, height: Metrics.editorInset)
        view.font = font
        view.textColor = NSColor(token: .fg)
        view.typingAttributes = [.font: font, .foregroundColor: NSColor(token: .fg)]
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.keymap = keymap
        view.cursorShape = cursorShape
        view.cursorBlink = cursorBlink
        view.modalMode = mode
        view.copyText = { $0.trimmingTrailingSpacesPerLine() }
        view.delegate = context.coordinator

        let c = context.coordinator
        c.view = view
        c.keymap = keymap
        c.modal.keymap = keymap
        view.modalKey = { [weak c] in c?.handleModal($0) ?? false }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CursorTextView else { return }
        let c = context.coordinator
        // Another note, or a change from outside; our own typing already
        // wrote the binding.
        if view.string != text, !view.hasMarkedText() {
            let selection = view.selectedRange()
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        if c.themeRevision != themeRevision || c.font != font {
            c.themeRevision = themeRevision
            c.font = font
            view.font = font
            view.textColor = NSColor(token: .fg)
            view.typingAttributes = [.font: font, .foregroundColor: NSColor(token: .fg)]
            view.updateCursorColor()
        }
        if c.keymap != keymap {
            c.keymap = keymap
            c.modal.keymap = keymap
            view.keymap = keymap
        }
        if mode != c.modal.mode { c.modal.reset() }
        if view.cursorShape != cursorShape { view.cursorShape = cursorShape }
        if view.cursorBlink != cursorBlink { view.cursorBlink = cursorBlink }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, ModalTarget {
        @Binding var text: String
        @Binding var mode: ModalMode
        weak var view: CursorTextView?
        var font = NSFont.monospacedSystemFont(ofSize: Metrics.editorFontSize, weight: .regular)
        var themeRevision = -1
        var keymap = EditorKeymap.normal
        let modal = ModalEngine(keymap: .normal)

        init(text: Binding<String>, mode: Binding<ModalMode>) {
            _text = text
            _mode = mode
            super.init()
            modal.attach(self)
        }

        func textDidChange(_ note: Notification) {
            guard let view else { return }
            text = view.string
            view.updateCursor()
        }

        func handleModal(_ event: NSEvent) -> Bool {
            guard keymap.isModal else { return false }
            return modal.handle(event)
        }

        // MARK: ModalTarget

        var modalText: NSString { (view?.string ?? "") as NSString }

        var modalSelection: NSRange {
            get { view?.selectedRange() ?? NSRange(location: 0, length: 0) }
            set { view?.setSelectedRange(newValue) }
        }

        var modalIsComposing: Bool { view?.hasMarkedText() ?? false }

        func modalDelete(_ range: NSRange, linewise: Bool) {
            replace(range, with: "", select: NSRange(location: range.location, length: 0))
        }

        func modalInsert(_ string: String, at position: Int) {
            replace(NSRange(location: position, length: 0), with: string)
        }

        func modalInsertLine(_ string: String, after: Bool) {
            guard let view else { return }
            let source = view.string as NSString
            let line = ModalText.lineRange(source, at: view.selectedRange().location)
            var position = after ? NSMaxRange(line) : line.location
            var text = string
            if after, position == source.length, source.length > 0,
               source.character(at: source.length - 1) != 0x0A {
                text = "\n" + text
            }
            if !after { position = line.location }
            replace(NSRange(location: position, length: 0), with: text, select: NSRange(location: position + (text as NSString).length - (string as NSString).length, length: 0))
        }

        func modalReplace(_ range: NSRange, with string: String) {
            replace(range, with: string)
        }

        func modalOpenLine(below: Bool) {
            guard let view else { return }
            let line = ModalText.lineContentRange(view.string as NSString, at: view.selectedRange().location)
            if below {
                replace(NSRange(location: NSMaxRange(line), length: 0), with: "\n")
            } else {
                replace(NSRange(location: line.location, length: 0), with: "\n", select: NSRange(location: line.location, length: 0))
            }
        }

        func modalYank(_ range: NSRange, linewise: Bool) -> String {
            guard let view, NSMaxRange(range) <= (view.string as NSString).length else { return "" }
            return (view.string as NSString).substring(with: range).trimmingTrailingSpacesPerLine()
        }

        func modalSource(_ range: NSRange, linewise: Bool) -> String {
            guard let view, NSMaxRange(range) <= (view.string as NSString).length else { return "" }
            return (view.string as NSString).substring(with: range)
        }

        func modalUndo() {
            view?.undoManager?.undo()
        }

        func modalRedo() {
            view?.undoManager?.redo()
        }

        func modalScrollToVisible() {
            guard let view else { return }
            view.scrollRangeToVisible(view.selectedRange())
        }

        func modalModeChanged(_ mode: ModalMode) {
            self.mode = mode
            view?.modalMode = mode
            view?.updateCursor()
        }

        private func replace(_ range: NSRange, with string: String, select: NSRange? = nil) {
            guard let view, let storage = view.textStorage else { return }
            guard range.location >= 0, NSMaxRange(range) <= storage.length else { return }
            guard view.shouldChangeText(in: range, replacementString: string) else { return }
            storage.replaceCharacters(in: range, with: string)
            let length = (string as NSString).length
            let caret = select ?? NSRange(location: range.location + length, length: 0)
            view.setSelectedRange(caret)
            view.didChangeText()
        }
    }
}

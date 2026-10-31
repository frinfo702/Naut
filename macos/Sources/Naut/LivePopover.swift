import AppKit

/// A small editor for the source of something the live editor draws
/// rendered: an equation's TeX, a table's Markdown, an image's or a
/// link's URL, a code block's language. Edits apply as they are typed, so
/// the note shows the result while it is written, like Notion's equation
/// editor. Esc, Return in a one-line field, or a click outside closes it.
@MainActor
final class SourcePopover: NSObject, NSPopoverDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private let popover = NSPopover()
    private let onChange: (String) -> Void
    private let onClose: () -> Void
    private var field: NSTextField?
    private var editor: NSTextView?

    init(title: String, text: String, multiline: Bool, font: NSFont, onChange: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onChange = onChange
        self.onClose = onClose
        super.init()

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let input: NSView
        if multiline {
            let scroll = NSTextView.scrollableTextView()
            let editor = scroll.documentView as! NSTextView
            editor.string = text
            editor.font = font
            editor.isRichText = false
            editor.allowsUndo = true
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.textContainerInset = NSSize(width: 6, height: 8)
            editor.backgroundColor = NSColor(token: .bg)
            editor.insertionPointColor = NSColor(token: .fg)
            editor.delegate = self
            self.editor = editor
            let lines = CGFloat(max(3, min(12, text.components(separatedBy: "\n").count + 1)))
            scroll.frame.size = NSSize(width: 460, height: lines * (font.ascender - font.descender + font.leading + 2) + 12)
            scroll.borderType = .noBorder
            scroll.autohidesScrollers = true
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 8
            scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = NSColor.separatorColor.cgColor
            input = scroll
        } else {
            let field = NSTextField(string: text)
            field.font = font
            field.delegate = self
            field.frame.size.width = 340
            self.field = field
            input = field
        }
        input.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            input.widthAnchor.constraint(equalToConstant: input.frame.width),
            input.heightAnchor.constraint(equalToConstant: multiline ? input.frame.height : 24),
        ])

        let hint = NSTextField(labelWithString: multiline ? "⌘Return or Esc to close" : "Return to close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        let done = NSButton(title: "Done", target: nil, action: nil)
        done.bezelStyle = .push
        done.controlSize = .small
        done.keyEquivalent = multiline ? "\r" : ""
        done.keyEquivalentModifierMask = .command
        let footer = NSStackView(views: [hint, NSView(), done])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: input.frame.width).isActive = true

        let stack = NSStackView(views: [heading, input, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        let controller = NSViewController()
        controller.view = stack
        controller.preferredContentSize = stack.fittingSize
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        done.target = self
        done.action = #selector(doneClicked)
    }

    @objc private func doneClicked() { close() }

    /// Show below `rect` of `view`, with the caret at `caret` in the source.
    func show(relativeTo rect: NSRect, of view: NSView, caret: Int?) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        if let editor {
            editor.window?.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: min(caret ?? (editor.string as NSString).length, (editor.string as NSString).length), length: 0))
        } else if let field {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) { onClose() }

    func textDidChange(_ notification: Notification) {
        if let editor { onChange(editor.string) }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field { onChange(field.stringValue) }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        close()
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        close()
        return true
    }
}

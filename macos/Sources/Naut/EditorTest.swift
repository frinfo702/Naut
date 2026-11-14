import AppKit
import NautKit
import SwiftUI

/// `Naut --editor-test` drives a Live Preview editor of its own, in its
/// own window, through the commands the keyboard sends (typing, Backspace,
/// Return, Tab, the arrows, ⌘A, undo), and fails unless each leaves the
/// Markdown and the selection where a block editor would.
///
/// A case is the note before, the keys, and the note after. `‸` is the
/// caret and `«…»` the selection, both written in the Markdown: where
/// they are in the editor follows from the projection, so a case reads
/// as what the user sees happen to their note. No note on disk is opened
/// or changed.
@MainActor
enum EditorTest {
    nonisolated static var isEnabled: Bool { CommandLine.arguments.contains("--editor-test") }
#if DEBUG

    enum Key {
        case type(String)
        case command(Selector)
        /// An input method composing `marked`, then committing `text`.
        case compose(String, String)
        case selectAll, undo
        /// A key with ⌘ (and `shift`), by virtual key code, as the
        /// keyboard sends it before the menus see it.
        case shortcut(String, keyCode: UInt16, shift: Bool)

        static let backspace = Key.command(#selector(NSResponder.deleteBackward(_:)))
        static let delete = Key.command(#selector(NSResponder.deleteForward(_:)))
        static let enter = Key.command(#selector(NSResponder.insertNewline(_:)))
        static let tab = Key.command(#selector(NSResponder.insertTab(_:)))
        static let backtab = Key.command(#selector(NSResponder.insertBacktab(_:)))
        static let left = Key.command(#selector(NSResponder.moveLeft(_:)))
        static let right = Key.command(#selector(NSResponder.moveRight(_:)))
        static let up = Key.command(#selector(NSResponder.moveUp(_:)))
        static let down = Key.command(#selector(NSResponder.moveDown(_:)))
    }

    static let picture = "![x](none.png)"

    /// (name, before, keys, after)
    static let cases: [(String, String, [Key], String)] = [
        // Typing makes syntax, and the caret stays after what was typed.
        ("heading as typed", "‸", [.type("#"), .type(" "), .type("T")], "# T‸"),
        ("bold as typed", "a ‸", [.type("*"), .type("*"), .type("b"), .type("*"), .type("*"), .type("c")], "a **b**c‸"),
        ("typing continues bold", "**b‸**", [.type("c")], "**bc‸**"),
        ("return continues a list", "- a‸", [.enter], "- a\n- ‸"),
        ("return on an empty item ends the list", "- a\n- ‸", [.enter], "- a\n‸"),
        ("return after an ended list stays out of it", "4. a\n5. ‸", [.enter, .enter], "4. a\n\n‸"),
        ("return splits a line", "ab‸cd", [.enter], "ab\n‸cd"),
        ("``` return makes a code block", "```‸", [.enter], "```\n‸\n```"),
        ("brackets make a checklist", "‸", [.type("["), .type("]"), .type(" "), .type("a")], "- [ ] a‸"),
        ("dashes make a divider", "a\n‸", [.type("-"), .type("-"), .type("-"), .type("b")], "a\n---\nb‸"),
        ("underscores and Space make a divider", "a\n‸", [.type("_"), .type("_"), .type("_"), .type(" "), .type("b")], "a\n---\nb‸"),
        ("> alone is text", "‸", [.type(">"), .type("a")], ">a‸"),
        ("> and Space make a quote", "‸", [.type(">"), .type(" "), .type("a")], "> a‸"),
        ("> and Space below a quote, one space", "> q\n‸", [.type(">"), .type(" "), .type("a")], "> q\n> a‸"),
        ("|-- makes a table, typed into", "‸", [.type("|"), .type("-"), .type("-"), .type("a")],
         "| a‸ |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |\n"),
        ("typing in a cell", "| a‸ | b |\n| - | - |", [.type("x")], "| ax‸ | b |\n| - | - |"),
        ("tab goes to the next cell", "| a‸ | b |\n| - | - |", [.tab], "| a | «b» |\n| - | - |"),
        ("tab past the last cell adds a row", "| a | b‸ |\n| - | - |", [.tab, .type("c")], "| a | b |\n| - | - |\n| c‸ |  |\n"),
        ("return goes to the cell below", "| a‸ | b |\n| - | - |\n| c | d |", [.enter], "| a | b |\n| - | - |\n| «c» | d |"),
        ("return below a table makes an empty line, not a row", "| a | b |\n| - | - |\n‸", [.enter, .type("x")], "| a | b |\n| - | - |\n\nx‸"),
        ("> and Space on the last line shows as a quote", "a\n‸", [.type(">"), .type(" ")], "a\n> ‸"),
        ("backspace at a cell's start keeps the table", "| a | ‸b |\n| - | - |", [.backspace], "| a | ‸b |\n| - | - |"),

        // Linear's shortcuts.
        ("⇧⌘8 makes a list", "a‸\nb", [.shortcut("8", keyCode: 0x1C, shift: true)], "- a‸\nb"),
        ("⇧⌘8 again ends it", "- a‸", [.shortcut("8", keyCode: 0x1C, shift: true)], "a‸"),
        ("⇧⌘9 numbers the lines", "«a\nb»", [.shortcut("9", keyCode: 0x19, shift: true)], "1. «a\n2. b»"),
        ("⇧⌘7 makes a checklist", "a‸", [.shortcut("7", keyCode: 0x1A, shift: true)], "- [ ] a‸"),
        ("⌘Return checks it", "- [ ] a‸", [.shortcut("\r", keyCode: 0x24, shift: false)], "- [x] a‸"),
        ("⇧⌘S strikes through", "«a»", [.shortcut("s", keyCode: 0x01, shift: true)], "~~«a»~~"),
        ("⇧⌘\\ makes a code block", "a\n‸", [.shortcut("\\", keyCode: 0x2A, shift: true), .type("x")], "a\n```\nx‸\n```"),
        ("typing in a code block", "```\n‸\n```", [.type("x"), .enter, .type("y")], "```\nx\ny‸\n```"),

        // Backspace.
        ("backspace deletes a character", "ab‸", [.backspace], "a‸"),
        ("backspace deletes an emoji whole", "a👍‸", [.backspace], "a‸"),
        ("backspace at a heading's start", "a\n# ‸T", [.backspace], "a\n‸T"),
        ("backspace at the note's start", "# ‸T", [.backspace], "‸T"),
        ("backspace then joins the lines", "a\n# ‸T", [.backspace, .backspace], "a‸T"),
        ("backspace outdents, then unlists, then joins", "- a\n  - ‸b", [.backspace], "- a\n- ‸b"),
        ("backspace unlists", "- a\n- ‸b", [.backspace], "- a\n‸b"),
        ("backspace on a quote", "> ‸q", [.backspace], "‸q"),
        ("backspace through a span takes its markers", "**ab**‸", [.backspace, .backspace], "‸"),
        ("backspace on an empty code block", "a\n```\n‸\n```\nb", [.backspace], "a\n‸\nb"),
        ("backspace below a code block", "```\nc\n```\n‸b", [.backspace], "```\nc‸\n```\nb"),
        ("backspace below a picture selects it", "\(picture)\n‸b", [.backspace], "«\(picture)»\nb"),
        ("backspace again deletes it", "\(picture)\n‸b", [.backspace, .backspace], "‸b"),
        ("backspace on the empty line below a picture", "a\n\(picture)\n‸", [.backspace], "a\n«\(picture)»"),
        ("backspace over a selection into code", "a«b\n```\nco»de\n```\nz", [.backspace], "a‸de\nz"),

        // Forward delete.
        ("delete joins a heading", "a‸\n# T", [.delete], "a‸T"),
        ("delete joins lines", "a‸\nb", [.delete], "a‸b"),

        // Blocks are selected, not entered.
        ("right onto a picture", "a‸\n\(picture)\nb", [.right], "a\n«\(picture)»\nb"),
        ("right off a picture", "a‸\n\(picture)\nb", [.right, .right], "a\n\(picture)\n‸b"),
        ("left onto a picture", "a\n\(picture)\n‸b", [.left], "a\n«\(picture)»\nb"),
        ("left off a picture", "a\n\(picture)\n‸b", [.left, .left], "a‸\n\(picture)\nb"),
        ("down onto a picture", "a‸\n\(picture)\nb", [.down], "a\n«\(picture)»\nb"),
        ("down off a picture", "a‸\n\(picture)\nb", [.down, .down], "a\n\(picture)\nb‸"),
        ("up onto a picture", "a\n\(picture)\n‸b", [.up], "a\n«\(picture)»\nb"),
        ("up off a picture", "a\n\(picture)\n‸b", [.up, .up], "‸a\n\(picture)\nb"),
        ("right off the last block makes a line", "«\(picture)»", [.right], "\(picture)\n‸"),
        ("down off the last block makes a line", "«$$\nx\n$$»", [.down], "$$\nx\n$$\n‸"),
        ("typing replaces a selected block", "a\n«\(picture)»\nb", [.type("z")], "a\nz‸\nb"),
        ("backspace deletes a selected block", "a\n«\(picture)»\nb", [.backspace], "a\n‸b"),
        ("between two blocks", "«\(picture)»\n\(picture)", [.right], "\(picture)\n«\(picture)»"),
        // Between two blocks that touch, up or down makes a line for the
        // caret, gone again if left empty.
        ("up from code under an equation", "$$\nx\n$$\n```\n‸c\n```", [.up], "$$\nx\n$$\n‸\n```\nc\n```"),
        ("typing keeps the line", "$$\nx\n$$\n```\n‸c\n```", [.up, .type("y")], "$$\nx\n$$\ny‸\n```\nc\n```"),
        ("down from the line takes it away", "$$\nx\n$$\n```\n‸c\n```", [.up, .down], "$$\nx\n$$\n```\n‸c\n```"),
        ("up from the line takes it away", "$$\nx\n$$\n```\n‸c\n```", [.up, .up], "«$$\nx\n$$»\n```\nc\n```"),
        ("down from an equation over code", "«$$\nx\n$$»\n```\nc\n```", [.down], "$$\nx\n$$\n‸\n```\nc\n```"),
        ("down from code over a picture", "```\na\n‸b\n```\n\(picture)", [.down], "```\na\nb\n```\n‸\n\(picture)"),
        ("up from a picture under a picture", "\(picture)\n«\(picture)»", [.up], "\(picture)\n‸\n\(picture)"),
        ("up inside code stays in it", "$$\nx\n$$\n```\na\n‸b\n```", [.up], "$$\nx\n$$\n```\n‸a\nb\n```"),

        // Tab.
        ("tab nests an item", "- a\n- ‸b", [.tab], "- a\n  - ‸b"),
        ("shift-tab unnests it", "- a\n  - ‸b", [.backtab], "- a\n- ‸b"),
        ("tab in a paragraph does nothing", "a‸b", [.tab], "a‸b"),
        ("tab indents code", "```\n‸x\n```", [.tab], "```\n    ‸x\n```"),

        // ⌘A.
        ("select all in a code block", "a\n```\nco‸de\n```", [.selectAll], "a\n```\n«code»\n```"),
        ("select all twice", "a\n```\nco‸de\n```", [.selectAll, .selectAll], "«a\n```\ncode\n»```"),
        ("select all, delete, delete", "a\n```\nco‸de\n```\nb", [.selectAll, .backspace, .backspace], "a\n‸\nb"),

        // An input method composes in place and commits where it began.
        ("composing in a paragraph", "a‸b", [.compose("にほん", "日本")], "a日本‸b"),
        ("composing at a heading's start", "# ‸T", [.compose("にほん", "日本")], "# 日本‸T"),
        ("composing in an empty item", "- a\n- ‸", [.compose("にほん", "日本"), .enter], "- a\n- 日本\n- ‸"),
        ("composing after bold", "**太**‸", [.compose("じ", "字")], "**太字‸**"),
        ("composing in code", "```\n‸\n```", [.compose("にほん", "日本")], "```\n日本‸\n```"),
        ("composing over a selected block", "a\n«\(picture)»\nb", [.compose("にほん", "日本")], "a\n日本‸\nb"),
        ("composing below a block", "\(picture)\n‸", [.compose("にほん", "日本"), .backspace, .backspace, .backspace], "«\(picture)»"),

        // Undo puts back the text and the selection.
        ("undo a backspace", "a\n# ‸T", [.backspace, .undo], "a\n# ‸T"),
        ("undo a block's deletion", "a\n«\(picture)»\nb", [.backspace, .undo], "a\n«\(picture)»\nb"),
    ]

    final class Model: ObservableObject {
        @Published var text = ""
        @Published var keymap = EditorKeymap.normal
        @Published var displayLines = false
    }

    private struct Host: View {
        @ObservedObject var model: Model
        @State private var mode = ModalMode.normal

        var body: some View {
            LiveEditor(
                text: $model.text,
                font: .systemFont(ofSize: 15),
                mono: .monospacedSystemFont(ofSize: 13, weight: .regular),
                lineHeight: 1.6,
                outline: [],
                baseURL: FileManager.default.temporaryDirectory,
                title: "Editor test",
                themeRevision: 0,
                keymap: model.keymap,
                displayLineMotion: model.displayLines,
                cursorShape: .match,
                cursorBlink: .normal,
                mode: $mode,
                note: URL(filePath: "/editor-test"),
                rename: { _ in },
                focusRequest: nil,
                focus: {},
                scrollTarget: .constant(nil)
            )
        }
    }

    /// The Markdown without its marks, and the selection they stand for.
    static func parse(_ marked: String) -> (text: String, selection: NSRange) {
        let s = marked as NSString
        let caret = s.range(of: "‸")
        if caret.location != NSNotFound {
            return (s.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
        }
        let open = s.range(of: "«").location
        let text = s.replacingOccurrences(of: "«", with: "") as NSString
        let close = text.range(of: "»").location
        return (text.replacingOccurrences(of: "»", with: ""), NSRange(location: open, length: close - open))
    }

    /// `text` with the display selection `r` marked in it.
    static func mark(_ text: String, _ r: NSRange) -> String {
        let p = LiveProjection(text)
        guard NSMaxRange(r) <= p.display.length else { return text + " [selection \(r) out of bounds]" }
        if r.length == 0 {
            return (text as NSString).replacingCharacters(in: NSRange(location: p.insertion(at: r.location).position, length: 0), with: "‸")
        }
        let s = p.sourceRange(r)
        let closed = (text as NSString).replacingCharacters(in: NSRange(location: NSMaxRange(s), length: 0), with: "»")
        return (closed as NSString).replacingCharacters(in: NSRange(location: s.location, length: 0), with: "«")
    }

    /// `--editor-test --play note keys out.png`: the note (`‸` the caret),
    /// then the keys typed, `⏎` Return, `⇥` Tab, `⌫` Backspace, and text
    /// after `【` left composing, as an input method's; prints the
    /// Markdown and saves the window, to see a case before writing it.
    static func play(_ note: String, keys: String, shot: String, model: Model, editor: LiveEditor.Coordinator, body: LiveTextView) async -> Never {
        let start = parse(note.replacingOccurrences(of: "\\n", with: "\n"))
        model.text = start.text
        editor.load(start.text)
        body.setSelectedRange(LiveProjection(start.text).displayRange(start.selection))
        try? await Task.sleep(for: .milliseconds(300))
        let parts = keys.split(separator: "【", maxSplits: 1, omittingEmptySubsequences: false)
        for c in parts[0] {
            switch c {
            case "⏎": body.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            case "⇥": body.doCommand(by: #selector(NSResponder.insertTab(_:)))
            case "⌫": body.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            default: body.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        if parts.count > 1 {
            let marked = String(parts[1])
            body.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        try? await Task.sleep(for: .milliseconds(500))
        body.testShowInsertionIndicator()
        print("play: \(mark(editor.source, body.selectedRange()).debugDescription)")
        if let view = body.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: shot))
        }
        exit(0)
    }

    /// `--editor-test --bench note.md`: the time from a key to the page
    /// drawn again, typing into the middle of that note.
    static func bench(_ path: String, model: Model, editor: LiveEditor.Coordinator, body: LiveTextView) -> Never {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail(["bench: can't read \(path)"]) }
        model.text = text
        editor.load(text)
        body.layoutManager?.ensureLayout(for: body.textContainer!)
        let middle = (body.string as NSString).paragraphRange(for: NSRange(location: body.string.utf16.count / 2, length: 0))
        body.setSelectedRange(NSRange(location: NSMaxRange(middle) - 1, length: 0))
        var times: [Double] = []
        for c in "the quick brown fox jumps over the lazy dog " {
            let start = DispatchTime.now().uptimeNanoseconds
            body.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0))
            body.layoutManager?.ensureLayout(for: body.textContainer!)
            body.displayIfNeeded()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        print(String(format: "bench: %d keys, median %.1f ms, p90 %.1f ms, max %.1f ms", times.count, times[times.count / 2], times[times.count * 9 / 10], times.last!))
        exit(0)
    }

    static func run() async {
        let model = Model()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        guard let body = window.contentView?.firstDescendant(LiveTextView.self),
              let editor = body.delegate as? LiveEditor.Coordinator
        else { fail(["no live editor"]) }
        if let i = CommandLine.arguments.firstIndex(of: "--play"), i + 3 < CommandLine.arguments.count {
            await play(CommandLine.arguments[i + 1], keys: CommandLine.arguments[i + 2], shot: CommandLine.arguments[i + 3], model: model, editor: editor, body: body)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--bench"), i + 1 < CommandLine.arguments.count {
            bench(CommandLine.arguments[i + 1], model: model, editor: editor, body: body)
        }
        window.makeFirstResponder(body)

        var failures: [String] = []
        for (name, before, keys, after) in cases {
            let start = parse(before)
            model.text = start.text
            editor.load(start.text)
            let p = LiveProjection(start.text)
            body.setSelectedRange(p.displayRange(start.selection))
            body.layoutManager?.ensureLayout(for: body.textContainer!)
            for key in keys {
                switch key {
                case let .type(s): body.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
                case let .command(selector): body.doCommand(by: selector)
                case let .compose(marked, text):
                    let none = NSRange(location: NSNotFound, length: 0)
                    for end in 1...marked.count {
                        let part = String(marked.prefix(end))
                        body.setMarkedText(part, selectedRange: NSRange(location: (part as NSString).length, length: 0), replacementRange: none)
                    }
                    body.insertText(text, replacementRange: none)
                case .selectAll: body.selectAll(nil)
                case .undo: body.history?.undo()
                case let .shortcut(c, keyCode, shift):
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: keyCode)
                    if let event { _ = body.performKeyEquivalent(with: event) }
                }
            }
            let want = parse(after)
            let wanted = mark(want.text, LiveProjection(want.text).displayRange(want.selection))
            let got = mark(editor.source, body.selectedRange())
            if got != wanted || body.string != LiveProjection(editor.source).display as String {
                failures.append("\(name): \(before.debugDescription) → \(got.debugDescription), not \(wanted.debugDescription)")
            }
        }
        // A list's bullets stay on their items: an empty one ending the
        // note, and every one while an input method composes elsewhere,
        // its text in the display before it is in the source.
        let none = NSRange(location: NSNotFound, length: 0)
        for (name, before, typed) in [("new item", "a\n‸", "- "), ("empty note", "‸", "- "), ("empty note, a task", "‸", "[] "), ("composing above a list", "‸x\n\n- one\n- two", "")] {
            let start = parse(before)
            model.text = start.text
            editor.load(start.text)
            body.setSelectedRange(LiveProjection(start.text).displayRange(start.selection))
            if !typed.isEmpty { for c in typed { body.insertText(String(c), replacementRange: none) } }
            for marked in ["", "に", "にほ"] {
                if !marked.isEmpty { body.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0), replacementRange: none) }
                let layout = body.layoutManager as! LiveLayout
                let text = body.string as NSString
                for item in layout.state.items {
                    let rect = layout.markerRect(item) ?? .zero
                    let line = item.location >= text.length ? layout.endLine?.rect ?? .zero : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: item.location), effectiveRange: nil)
                    if item.location > 0 && text.character(at: item.location - 1) != 0x0A || rect.maxX <= 0 || !(line.minY...line.maxY).contains(rect.midY) {
                        failures.append("bullets, \(name) with \(marked.debugDescription) marked: the item at \(item.location) of \(text.debugDescription) draws at \(rect)")
                    }
                }
            }
            body.unmarkText()
        }
        // A quote's bar is on its lines and no others: an empty one
        // ending the note has one; the empty line left after it doesn't.
        for (name, before, keys, lines) in [
            ("> and Space in an empty note", "‸", "> ", 1), ("> and Space below a line", "a\n‸", "> ", 1),
            ("Return twice leaves the quote", "> xx‸", "\r\r", 1), ("Return once stays in it", "> xx‸", "\r", 2),
        ] {
            let start = parse(before)
            model.text = start.text
            editor.load(start.text)
            body.setSelectedRange(LiveProjection(start.text).displayRange(start.selection))
            for c in keys { if c == "\r" { body.doCommand(by: #selector(NSResponder.insertNewline(_:))) } else { body.insertText(String(c), replacementRange: none) } }
            let layout = body.layoutManager as! LiveLayout
            let height = layout.endLine?.rect.height ?? 0
            let bars = layout.state.quotes.compactMap(layout.quoteBar)
            let covered = bars.reduce(0) { $0 + $1.height + 8 }
            if bars.isEmpty || abs(covered - CGFloat(lines) * height) > height / 2 {
                failures.append("quote bar, \(name): \(editor.source.debugDescription) draws \(bars) for \(lines) line(s) of \(height)")
            }
        }
        // A line with a small formula in it is a line like the others:
        // as tall, its baseline as far down. The formula's picture was
        // of its paragraph's whole line box, leading and all, and
        // whatever it reached past the text was added to the line
        // rather than taken from the line's own leading: the line stood
        // taller and its text lower than its neighbours'.
        do {
            let layout = body.layoutManager as! LiveLayout
            func firstLine() -> (height: CGFloat, baseline: CGFloat) {
                layout.ensureLayout(for: body.textContainer!)
                return (layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height, layout.location(forGlyphAt: 0).y)
            }
            model.text = "a b"
            editor.load("a b")
            let plain = firstLine()
            model.text = "a $E=mc^2$ b"
            editor.load("a $E=mc^2$ b")
            let key = LiveImages.Key(markdown: "$E=mc^2$", width: nil, size: layout.font(at: 0).pointSize, dark: body.effectiveAppearance.isDark)
            for _ in 0..<100 where LiveImages.shared.depth(key) == nil {
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(100))
            let math = firstLine()
            if LiveImages.shared.depth(key) == nil || math != plain {
                failures.append("inline math: its line is \(math.height) tall, the baseline \(math.baseline) down; a plain line \(plain.height) and \(plain.baseline)\(LiveImages.shared.depth(key) == nil ? " (the formula was not drawn)" : "")")
            }
        }
        // Composing on a line inline math has made taller: the input
        // method draws its underline and puts its candidates by the rect
        // the view gives it, which is the line's used rect. That is the
        // text's, as on a plain line: as tall, as far below the baseline.
        do {
            let layout = body.layoutManager as! LiveLayout
            /// The input method's rect for the text composed: its height,
            /// and how far below the baseline it ends.
            func composed() -> (height: CGFloat, depth: CGFloat, line: CGFloat) {
                body.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
                defer { body.unmarkText() }
                let marked = body.markedRange()
                let screen = body.firstRect(forCharacterRange: marked, actualRange: nil)
                let rect = body.convert(body.window!.convertFromScreen(screen), from: nil)
                let glyph = layout.glyphIndexForCharacter(at: marked.location)
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = body.textContainerOrigin.y + line.minY + layout.location(forGlyphAt: glyph).y
                return (rect.height, rect.maxY - baseline, line.height)
            }
            model.text = "a "
            editor.load("a ")
            body.setSelectedRange(NSRange(location: 2, length: 0))
            let plain = composed()
            let start = parse("a $\\dfrac{\\dfrac{a}{b}}{c}$ ‸")
            model.text = start.text
            editor.load(start.text)
            body.setSelectedRange(LiveProjection(start.text).displayRange(start.selection))
            for _ in 0..<100 where layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height < plain.line + 8 {
                try? await Task.sleep(for: .milliseconds(30))
            }
            let math = composed()
            if math.line < plain.line + 8 || abs(math.height - plain.height) > 0.5 || abs(math.depth - plain.depth) > 0.5 {
                failures.append("composing beside inline math: the input method's rect is \(math.height) tall and ends \(math.depth) below the baseline, on a plain line \(plain.height) and \(plain.depth); the line is \(math.line) tall, a plain one \(plain.line)")
            }
        }
        // A display equation is edited inside its block; Esc carries on
        // below it.
        let math = "a\n$$\nx\n$$\nb"
        model.text = math
        editor.load(math)
        body.editFirstMath?()
        if let inner = body.firstDescendant(MathBlockEditor.self) {
            inner.source.insertText(" y", replacementRange: NSRange(location: NSNotFound, length: 0))
            if editor.source != "a\n$$\nx y\n$$\nb" { failures.append("equation: typing gave \(editor.source.debugDescription)") }
            inner.source.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            if body.firstDescendant(MathBlockEditor.self) != nil { failures.append("equation: Esc did not close it") }
            if window.firstResponder !== body { failures.append("equation: Esc did not return to the text") }
            if body.selectedRange() != NSRange(location: 4, length: 0) { failures.append("equation: Esc left the selection at \(body.selectedRange())") }
        } else {
            failures.append("equation: the editor did not open")
        }
        // Below an equation that ends the note, the empty line starts at
        // the left, as below text. TextKit lays that line out as the
        // caret's text when the caret is on it and as the last
        // character's when not, and Down makes the line before the caret
        // is there: it was centred, as the equation is. Down from inside
        // the equation first, then from the block: the second found the
        // typing attributes as the first left them, and so no reason to
        // lay the line out again.
        do {
            let layout = body.layoutManager as! LiveLayout
            func endX() async -> CGFloat {
                try? await Task.sleep(for: .milliseconds(100))
                return layout.extraLineFragmentUsedRect.minX
            }
            model.text = "a\n"
            editor.load("a\n")
            body.setSelectedRange(NSRange(location: 2, length: 0))
            let plain = await endX()
            let ending = "a\n\n$$\ne=mc\n$$"
            model.text = ending
            editor.load(ending)
            body.editFirstMath?()
            if let inner = body.firstDescendant(MathBlockEditor.self) {
                inner.source.setSelectedRange(NSRange(location: 4, length: 0))
                inner.source.doCommand(by: #selector(NSResponder.moveDown(_:)))
            }
            let inside = await endX()
            if editor.source != ending + "\n" || body.selectedRange() != NSRange(location: 5, length: 0) || inside != plain {
                failures.append("below an equation: Down inside it gave \(editor.source.debugDescription), the caret at \(body.selectedRange()), its line starting at \(inside), below text at \(plain)")
            }
            model.text = ending
            editor.load(ending)
            body.setSelectedRange(NSRange(location: 3, length: 1))
            body.doCommand(by: #selector(NSResponder.moveDown(_:)))
            let below = await endX()
            if editor.source != ending + "\n" || body.selectedRange() != NSRange(location: 5, length: 0) || below != plain {
                failures.append("below an equation: Down on it gave \(editor.source.debugDescription), the caret at \(body.selectedRange()), its line starting at \(below), below text at \(plain)")
            }
        }
        // Helix: the cursor sits on a block, which shows as selected; `d`
        // deletes it; in insert mode it is selected as with standard keys.
        model.keymap = .helix
        try? await Task.sleep(for: .milliseconds(300))
        func press(_ characters: String, keyCode: UInt16 = 0) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ) else { return }
            _ = body.modalKey?(event)
        }
        let blocks = "a\n\(picture)\nb"
        model.text = blocks
        editor.load(blocks)
        body.setSelectedRange(NSRange(location: 0, length: 0))
        press("j")
        if body.selectedRange() != NSRange(location: 2, length: 0) || body.cursorBlock != 2 {
            failures.append("helix: j left the cursor at \(body.selectedRange()), block \(String(describing: body.cursorBlock))")
        }
        press("i")
        body.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        body.doCommand(by: #selector(NSResponder.moveRight(_:)))
        if body.selectedRange() != NSRange(location: 2, length: 1) { failures.append("helix: insert mode did not select the block (\(body.selectedRange()))") }
        press("\u{1b}", keyCode: 53)
        if body.selectedRange() != NSRange(location: 2, length: 0) || body.cursorBlock != 2 {
            failures.append("helix: Esc left \(body.selectedRange()), block \(String(describing: body.cursorBlock))")
        }
        press("d")
        if editor.source != "a\nb" { failures.append("helix: d on a block gave \(editor.source.debugDescription)") }
        // j and k between two blocks that touch make a line for the cursor,
        // gone again once it leaves the line empty.
        let touching = "$$\nx\n$$\n```\nc\n```"
        let gapped = "$$\nx\n$$\n\n```\nc\n```"
        model.text = touching
        editor.load(touching)
        body.setSelectedRange(NSRange(location: 0, length: 0))
        press("j")
        if editor.source != gapped || body.selectedRange() != NSRange(location: 2, length: 0) {
            failures.append("helix: j off an equation onto code gave \(editor.source.debugDescription) at \(body.selectedRange())")
        }
        press("j")
        if editor.source != touching || body.selectedRange() != NSRange(location: 2, length: 0) {
            failures.append("helix: j off the line gave \(editor.source.debugDescription) at \(body.selectedRange())")
        }
        press("k")
        if editor.source != gapped || body.selectedRange() != NSRange(location: 2, length: 0) {
            failures.append("helix: k off code onto an equation gave \(editor.source.debugDescription) at \(body.selectedRange())")
        }
        press("k")
        if editor.source != touching || body.selectedRange() != NSRange(location: 0, length: 0) {
            failures.append("helix: k off the line gave \(editor.source.debugDescription) at \(body.selectedRange())")
        }
        press("j")
        press("i")
        body.insertText("y", replacementRange: body.selectedRange())
        press("\u{1b}", keyCode: 53)
        if editor.source != "$$\nx\n$$\ny\n```\nc\n```" { failures.append("helix: typing on the line gave \(editor.source.debugDescription)") }
        // Move by display line: j and k step through a wrapped line, as
        // gj and gk do, and leave it for the next source line at its end.
        model.keymap = .vim
        model.displayLines = true
        try? await Task.sleep(for: .milliseconds(300))
        let wrapped = String(repeating: "word ", count: 80) + "end\nnext"
        model.text = wrapped
        editor.load(wrapped)
        body.layoutManager?.ensureLayout(for: body.textContainer!)
        body.setSelectedRange(NSRange(location: 0, length: 0))
        press("j")
        let newline = (wrapped as NSString).range(of: "\n").location
        let down = body.selectedRange().location
        if down == 0 || down >= newline { failures.append("display lines: j went to \(down), not within the wrapped line") }
        press("k")
        if body.selectedRange().location != 0 { failures.append("display lines: k went to \(body.selectedRange().location), not 0") }
        press("G")
        press("k")
        let up = body.selectedRange().location
        if up >= newline || up < newline - 200 { failures.append("display lines: k from the next line went to \(up), not the wrapped line's last row") }
        // Helix keeps the column too, rather than stopping at the row's end.
        model.keymap = .helix
        try? await Task.sleep(for: .milliseconds(300))
        body.setSelectedRange(NSRange(location: 12, length: 0))
        press("j")
        let rows = { (p: Int) -> CGFloat in
            let layout = body.layoutManager!
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: p), effectiveRange: nil).minY
        }
        let column = { (p: Int) -> CGFloat in
            let layout = body.layoutManager!
            return layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: p)).x
        }
        let helixDown = body.selectedRange().location
        if rows(helixDown) <= rows(12) || abs(column(helixDown) - column(12)) > 12 {
            failures.append("display lines: helix j went from 12 to \(helixDown), not the same column a row down")
        }
        // Past a short row and a blank line, j comes back to the column
        // it started from, as Helix's goal column does; on wide Japanese
        // characters it doesn't creep left a character a row.
        let paragraphs = String(repeating: "wrapped words ", count: 14) + "end\n\n" + String(repeating: "more words ", count: 30)
        let japanese = String(repeating: "折り返しのある行を何度も書いてテストする。", count: 12)
        for (sample, presses) in [(paragraphs, 4), (japanese, 4)] {
            model.text = sample
            editor.load(sample)
            body.layoutManager?.ensureLayout(for: body.textContainer!)
            body.setSelectedRange(NSRange(location: 30, length: 0))
            for _ in 0..<presses { press("j") }
            let p = body.selectedRange().location
            if abs(column(p) - column(30)) > 16 || rows(p) <= rows(30) {
                failures.append("display lines: \(presses) j from 30 went to \(p), x \(column(p)), not x \(column(30))")
            }
        }
        // j onto a row that a wrap starts mid-word lands on that row's
        // first character and draws the caret there, not at the end of
        // the row above; gl and gh stop at the row's ends.
        let prose = "この issue は ISSUE-1924 と、その追加実験 ISSUE-1925 の報告である。関係を部品のプログラムとして定義で与え、カメラの姿勢を入れれば、視点に依存する関係が解けるかを測った。" + japanese
        model.text = prose
        editor.load(prose)
        body.layoutManager?.ensureLayout(for: body.textContainer!)
        body.setSelectedRange(NSRange(location: 0, length: 0))
        press("j")
        let second = body.selectedRange().location
        body.updateInsertionPointStateAndRestartTimer(true)
        body.display()
        if second == 0 || abs(column(second) - column(0)) > 1 || rows(second) <= rows(0) {
            failures.append("display lines: j from 0 went to \(second), x \(column(second)), not the next row's start")
        } else if abs(body.testInsertionRect.minY - body.textContainerOrigin.y - rows(second)) > 8 {
            failures.append("display lines: the caret at \(second) was drawn at y \(body.testInsertionRect.minY), not on its row at \(rows(second))")
        }
        body.setSelectedRange(NSRange(location: 0, length: 0))
        press("g"); press("l")
        if body.selectedRange().location != second - 1 { failures.append("display lines: gl went to \(body.selectedRange().location), not \(second - 1)") }
        press("g"); press("h")
        if body.selectedRange().location != 0 { failures.append("display lines: gh went to \(body.selectedRange().location), not 0") }
        model.keymap = .vim
        model.displayLines = false
        try? await Task.sleep(for: .milliseconds(300))
        model.text = wrapped
        editor.load(wrapped)
        body.setSelectedRange(NSRange(location: 0, length: 0))
        press("j")
        if body.selectedRange().location != newline + 1 { failures.append("source lines: j went to \(body.selectedRange().location), not \(newline + 1)") }
        if !failures.isEmpty { fail(failures) }
        if let i = CommandLine.arguments.firstIndex(of: "--shots"), i + 1 < CommandLine.arguments.count {
            await shoot(model, editor, body, into: URL(filePath: CommandLine.arguments[i + 1]))
        }
        print("editor test: \(cases.count) cases passed")
        exit(0)
    }

    /// `--shots dir` also saves the window with each kind of block
    /// selected, to look at: "it passes" is not "it looks right".
    private static func shoot(_ model: Model, _ editor: LiveEditor.Coordinator, _ body: LiveTextView, into dir: URL) async {
        let icon = Bundle.main.url(forResource: "Naut", withExtension: "icns")?.path ?? "/System/Library/CoreServices/DefaultDesktop.heic"
        let note = "## Blocks\n\nA paragraph with **bold**, `code` and $e^{i\\pi}$.\n\n```swift\nlet x = 1\nprint(x)\n```\n\n![p](\(icon))\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n$$\n\\int_0^1 x\\,dx\n$$\n\n- one\n  - two\n"
        model.text = note
        editor.load(note)
        try? await Task.sleep(for: .seconds(2.5))
        let p = LiveProjection(note)
        let display = p.display as String
        let blocks = p.attachments.filter { p.elements[$0.value].kind.isBlockAtom }.keys.sorted()
        let code = (p.display as NSString).range(of: "let x = 1\nprint(x)")
        var shots: [(String, NSRange)] = [("caret", NSRange(location: 3, length: 0)), ("code", code), ("text", NSRange(location: 0, length: (display as NSString).length))]
        for (i, at) in blocks.enumerated() { shots.append(("block\(i)", NSRange(location: at, length: 1))) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let view = body.window?.contentView else { return }
        for (name, r) in shots {
            body.setSelectedRange(r)
            if r.length == 1 { body.scrollRangeToVisible(NSRange(location: r.location, length: min(4, (body.string as NSString).length - r.location))) }
                        try? await Task.sleep(for: .milliseconds(200))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
        }
    }

    private static func fail(_ messages: [String]) -> Never {
        for m in messages { FileHandle.standardError.write(Data("naut: editor test failed: \(m)\n".utf8)) }
        exit(1)
    }
#endif
}

private extension NSView {
    func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        for view in subviews {
            if let match = view as? T ?? view.firstDescendant(type) { return match }
        }
        return nil
    }
}

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

    private final class Model: ObservableObject {
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

    static func run() async {
        let model = Model()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(500))
        guard let body = window.contentView?.firstDescendant(LiveTextView.self),
              let editor = body.delegate as? LiveEditor.Coordinator
        else { fail(["no live editor"]) }
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
                }
            }
            let want = parse(after)
            let wanted = mark(want.text, LiveProjection(want.text).displayRange(want.selection))
            let got = mark(editor.source, body.selectedRange())
            if got != wanted || body.string != LiveProjection(editor.source).display as String {
                failures.append("\(name): \(before.debugDescription) → \(got.debugDescription), not \(wanted.debugDescription)")
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
            body.testShowInsertionIndicator()
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

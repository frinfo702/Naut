import NautKit
import Foundation
import Testing

@Test func rendersMarkdownThroughLibnaut() {
    #expect(Markdown.render("**日本語**").html == "<p><strong>日本語</strong></p>\n")
}

@Test func outlineDecodes() {
    #expect(Markdown.render("# A\n## B").outline.map(\.id) == ["a", "b"])
}

@Test func pageEscapesTitle() {
    #expect(Markdown.page("x", title: "<t>", toc: true).contains("<title>&lt;t&gt;</title>"))
}

@Test func publishErrorsCarryTheMessage() async {
    let cf = Cloudflare(accountID: "bad", apiToken: "t")
    await #expect(throws: PublishError.self) {
        try await cf.provision(workdir: .temporaryDirectory)
    }
}

@Test(arguments: ThemeToken.allCases, [true, false])
func everyThemeTokenIsAColour(token: ThemeToken, dark: Bool) {
    #expect(token.color(dark: dark) != nil, "\(token.rawValue) missing from page.css")
}

@Test func tokenValuesComeFromTheStylesheet() {
    // Components cross the C API as Float, so compare loosely.
    #expect(abs((ThemeToken.bg.color(dark: true)?.red ?? 0) - 0x10 / 255) < 0.001)
    #expect((ThemeToken.edgeTop.color(dark: true)?.alpha ?? 1) < 1)
}

@Test func liveMarkdownFindsSyntax() {
    let src = "## Title\nsome **bold** and `a*b*` and $x_1$ costs $5\n$$\na_n\n$$\n```\n# not a heading\n```\n- [link](u)"
    let ns = src as NSString
    let els = LiveMarkdown.parse(src)
    func text(_ r: NSRange) -> String { ns.substring(with: r) }

    let heading = els.first { $0.kind == .heading(level: 2) }
    #expect(heading.map { text($0.content) } == "Title")
    #expect(heading.map { $0.markers.map(text) } == ["## "])

    #expect(els.filter { $0.kind == .strong }.map { text($0.content) } == ["bold"])
    // Emphasis inside code stays code.
    #expect(els.filter { $0.kind == .emphasis }.isEmpty)
    #expect(els.contains { $0.kind == .math(tex: "x_1") })
    // "$5" is a price, not math.
    #expect(els.filter { if case .math = $0.kind { true } else { false } }.count == 1)

    let block = els.first { $0.kind == .mathBlock(tex: "a_n") }
    #expect(block.map { $0.markers.map(text) } == ["$$", "$$"])

    let code = els.first { $0.kind == .codeBlock(language: "") }
    #expect(code.map { text($0.content) } == "# not a heading")
    #expect(!els.contains { $0.kind == .heading(level: 1) })

    let link = els.first { $0.kind == .link }
    #expect(link.map { text($0.content) } == "link")
    #expect(link.map { $0.markers.map(text) } == ["[", "](u)"])
    #expect(els.contains { $0.kind == .listItem })
}

@Test func liveMarkdownUnclosedFenceIsText() {
    // Otherwise typing ``` turns the rest of the note into code.
    #expect(LiveMarkdown.parse("```\na\nb").isEmpty)
}

@Test func liveMarkdownFindsTablesAndImages() {
    let src = "| a | b |\n|:--|--:|\n| 1 | 2 |\n\n![alt](pics/x.png \"t\")\ntext ![inline](y.png)\n```zig\nx\n```"
    let els = LiveMarkdown.parse(src)
    let table = els.first { $0.kind == .table }
    #expect(table.map { (src as NSString).substring(with: $0.range) } == "| a | b |\n|:--|--:|\n| 1 | 2 |")
    #expect(els.contains { $0.kind == .image(url: "pics/x.png", width: nil) })
    // Only an image alone on its line is drawn.
    #expect(!els.contains { $0.kind == .image(url: "y.png", width: nil) })
    #expect(els.contains { $0.kind == .codeBlock(language: "zig") })
}

@Test func highlightSpansAreUTF16() {
    // "é" is two UTF-8 bytes and one UTF-16 unit.
    let spans = Highlight.spans("// é\nconst x = 1;", language: "zig")
    #expect(spans.map(\.class) == [.comment, .keyword, .number])
    #expect(spans.first?.range == NSRange(location: 0, length: 4))
    #expect(spans[1].range == NSRange(location: 5, length: 5))
    #expect(Highlight.spans("x", language: "nope").isEmpty)
}

// MARK: - Live projection and editing

/// Notes with each kind of hidden syntax, side by side and at both ends:
/// where mapping between what is shown and the Markdown goes wrong, if it
/// does.
private let notes = [
    "## Title\nbody **bold** and *em* and `code` and [link](u) end",
    "a\n```zig\nlet x\n```\nafter",
    // A fence ending the note, with no newline after it: the caret used
    // to land on the hidden fence.
    "a\n```\ncode\n```",
    "```\ncode\n```\n",
    "- one\n- [ ] two\n1. three\n> quote",
    "x $m$ y\n$$\nt\n$$\nz",
    "$$\nt\n$$",
    "| a | b |\n| - | - |\n| 1 | 2 |\ntail",
    "![p](i.png)\nnext",
    "**b**",
    "",
    "日本語の**太字**と`コード`。\n## 見出し",
    "- a\n  - nested\n- [ ] ",
    "```\n\n```\n$$\nx\n$$\n| a |\n| - |\n![i](p.png)",
    "and*em* and a__b__c and ~~s~~",
    "> q\n\n```sh\nls $HOME\n```\n\n- [x] done",
]

private func apply(_ edit: LiveEditing.Edit, to text: String) -> (text: String, selection: NSRange)? {
    guard case let .replace(r, s, selection) = edit else { return nil }
    return ((text as NSString).replacingCharacters(in: r, with: s), selection)
}

private func caret(_ i: Int) -> NSRange { NSRange(location: i, length: 0) }

@Test func liveProjectionLeavesSyntaxOut() {
    #expect(LiveProjection("## Title\nsome **bold** [link](u)").display == "Title\nsome bold link")
    #expect(LiveProjection("a\n```zig\nlet x\n```\nb").display == "a\nlet x\nb")
    #expect(LiveProjection("- one\n- [x] two").display == "one\ntwo")
    let math = LiveProjection("x $m$ y\n$$\nt\n$$\nz")
    #expect(math.display == "x \u{FFFC} y\n\u{FFFC}\nz")
    #expect(math.attachments.count == 2)
}

/// The guarantee Live Preview gives: wherever the caret can be, a typed
/// letter shows up right there, and the caret right after it. Only beside
/// a block, which owns its line, does it go on a line of its own.
@Test(arguments: notes)
func liveTypingLandsAtTheCaret(note: String) throws {
    let before = LiveProjection(note)
    for p in 0...before.display.length {
        let edit = LiveEditing(before).type("ж", over: caret(p))
        let (text, selection) = try #require(apply(edit, to: note))
        let after = LiveProjection(text)
        let shown = after.display as String
        let at = (after.display as NSString).range(of: "ж").location
        #expect(shown.replacingOccurrences(of: "ж", with: "") == before.display as String
            || shown.replacingOccurrences(of: "ж", with: "") == (before.display as NSString).replacingCharacters(in: caret(p), with: "\n"),
            "\(note.debugDescription) at \(p): \(shown.debugDescription)")
        #expect(at == p || at == p + 1, "\(note.debugDescription) at \(p): ж at \(at)")
        #expect(after.display(at: selection.location) == at + 1, "\(note.debugDescription) at \(p): caret")
    }
}

/// Deleting any shown character other than a newline or an attachment
/// takes exactly that character.
@Test(arguments: notes)
func liveDeletingTakesTheCharacter(note: String) throws {
    let before = LiveProjection(note)
    for i in 0..<before.display.length {
        let c = before.display.character(at: i)
        guard c != 0x0A, c != LiveProjection.attachmentCharacter else { continue }
        let edit = LiveEditing(before).delete(NSRange(location: i, length: 1), selection: caret(i + 1))
        let (text, selection) = try #require(apply(edit, to: note))
        let after = LiveProjection(text)
        #expect(after.display as String == before.display.replacingCharacters(in: NSRange(location: i, length: 1), with: ""),
                "\(note.debugDescription) deleting \(i)")
        #expect(after.display(at: selection.location) == i)
    }
}

@Test(arguments: notes)
func liveMappingRoundTrips(note: String) {
    let p = LiveProjection(note)
    for i in 0...p.display.length {
        #expect(p.display(at: p.insertion(at: i).position) == i, "\(note.debugDescription) at \(i)")
    }
}

/// Backspace at the start of a line's text takes the line's syntax, a
/// nested item one level out first; at the start of the note too, where
/// there is no character to delete.
@Test func liveBackspaceAtALineStartTakesItsSyntax() {
    func backspaced(_ s: String, at p: Int) -> String? { LiveEditing(text: s).backspace(at: p).flatMap { apply($0, to: s)?.text } }
    #expect(backspaced("a\n## Title", at: 2) == "a\nTitle")
    #expect(backspaced("## Title", at: 0) == "Title")
    #expect(backspaced("> q", at: 0) == "q")
    #expect(backspaced("- a\n  - b", at: 2) == "- a\n- b")
    #expect(backspaced("- a\n- b", at: 2) == "- a\nb")
    #expect(backspaced("- [ ] t", at: 0) == "t")
    // An empty code block goes; one with code stays.
    #expect(backspaced("a\n```\n\n```\nb", at: 2) == "a\n\nb")
    #expect(backspaced("```\ncode\n```", at: 0) == nil)
    // Anywhere else backspace just deletes.
    #expect(backspaced("## Title", at: 1) == nil)
    #expect(backspaced("plain", at: 0) == nil)
}

/// Forward delete at the end of the line above a heading joins the two.
@Test func liveDeletingTheNewlineBeforeAHeadingJoinsIt() {
    let note = "a\n## Title"
    #expect(apply(LiveEditing(text: note).delete(NSRange(location: 1, length: 1), selection: caret(1)), to: note)?.text == "aTitle")
}

/// A selection that takes one fence of a code block takes the other, and
/// one of all of a block's lines takes the block: no unpaired ``` shows.
@Test func liveDeletingAcrossACodeFenceKeepsFencesPaired() throws {
    let note = "ab\n```\ncode\n```\nyz"
    let e = LiveEditing(text: note)
    #expect(e.projection.display == "ab\ncode\nyz")
    // "b\nco": from the text above into the code.
    let above = try #require(apply(e.delete(NSRange(location: 1, length: 4), selection: NSRange(location: 1, length: 4)), to: note))
    #expect(above.text == "ade\nyz")
    #expect(above.selection == caret(1))
    // "de\ny": from the code into the text below.
    let below = try #require(apply(e.delete(NSRange(location: 5, length: 4), selection: NSRange(location: 5, length: 4)), to: note))
    #expect(below.text == "ab\ncoz")
    #expect(below.selection == caret(5))
    // "code\n": all of the block's lines.
    let all = try #require(apply(e.delete(NSRange(location: 3, length: 5), selection: NSRange(location: 3, length: 5)), to: note))
    #expect(all.text == "ab\nyz")
    #expect(all.selection == caret(3))
    // "code": its text only leaves the block, empty.
    #expect(apply(e.delete(NSRange(location: 3, length: 4), selection: NSRange(location: 3, length: 4)), to: note)?.text == "ab\n```\n\n```\nyz")
}

/// Backspace on the empty line below a block takes the line and selects
/// the block, as in Notion.
@Test func liveDeletingABlankLineBesideABlockSelectsTheBlock() throws {
    let note = "![p](i.png)\n\nb"
    let done = try #require(apply(LiveEditing(text: note).delete(NSRange(location: 1, length: 1), selection: caret(2)), to: note))
    #expect(done.text == "![p](i.png)\nb")
    #expect(done.selection == NSRange(location: 0, length: 11))
}

@Test func liveTabNestsListItems() throws {
    func tabbed(_ s: String, _ r: NSRange, outdent: Bool = false) -> String? { LiveEditing(text: s).indent(r, outdent: outdent).flatMap { apply($0, to: s)?.text } }
    #expect(tabbed("- a\n- b", caret(2)) == "- a\n  - b")
    #expect(tabbed("- a\n  - b", caret(2), outdent: true) == "- a\n- b")
    // Both items of a selection; the first can't nest under nothing.
    #expect(tabbed("- a\n- b\n- c", NSRange(location: 2, length: 3)) == "- a\n  - b\n  - c")
    #expect(LiveEditing(text: "- a").indent(caret(0), outdent: false) == LiveEditing.Edit.none)
    // Code indents; a paragraph has nothing to do.
    #expect(tabbed("```\nx\n```", caret(0)) == "```\n    x\n```")
    #expect(LiveEditing(text: "plain").indent(caret(0), outdent: false) == nil)
    let e = try #require(LiveEditing(text: "- a\n- b").indent(caret(3), outdent: false))
    #expect(apply(e, to: "- a\n- b")?.selection == caret(9))
}

/// A fence closed on the next line has no line for a caret: it is text.
@Test func liveMarkdownEmptyFencePairIsText() {
    #expect(LiveProjection("```\n```\nx").display == "```\n```\nx")
}

@Test func liveDeletingABlockSelectsItFirst() {
    let e = LiveEditing(text: "a\n$$\nt\n$$\nb")
    // Display "a\n￼\nb": backspace after the block selects it…
    #expect(e.delete(NSRange(location: 2, length: 1), selection: caret(3)) == .select(NSRange(location: 2, length: 1)))
    // …and with it selected, deletes it with its line.
    #expect(e.delete(NSRange(location: 2, length: 1), selection: NSRange(location: 2, length: 1)) == .replace(NSRange(location: 2, length: 8), with: "", selection: caret(2)))
    // Backspace at the start of "b" joins it to the block's line: select.
    #expect(e.delete(NSRange(location: 3, length: 1), selection: caret(4)) == .select(NSRange(location: 2, length: 1)))
}

@Test func liveDeletingBelowACodeBlock() {
    // A blank line below the block goes; the fence stays whole.
    let blank = LiveEditing(text: "```\nc\n```\n\nb")
    #expect(blank.projection.display == "c\n\nb")
    #expect(apply(blank.delete(NSRange(location: 1, length: 1), selection: caret(2)), to: "```\nc\n```\n\nb")?.text == "```\nc\n```\nb")
    // Otherwise the caret moves to the end of the code.
    let next = LiveEditing(text: "```\nc\n```\nb")
    #expect(next.delete(NSRange(location: 1, length: 1), selection: caret(2)) == .select(caret(1)))
}

/// Backspace on an empty list item directly below a code block removes
/// its bullet. The closing fence and its newline are hidden, so the only
/// displayed newline is the code's last line; deleting it used to move
/// the caret to the end of the code instead of removing the bullet.
@Test func liveDeletingAnEmptyListItemBelowACodeBlockRemovesTheBullet() throws {
    let note = "```plain text\nrex server start --tailscale\n```\n- "
    let p = LiveProjection(note)
    #expect(p.display == "rex server start --tailscale\n")
    let edit = try #require(LiveEditing(p).backspace(at: p.display.length))
    let done = try #require(apply(edit, to: note))
    let expected = "```plain text\nrex server start --tailscale\n```\n"
    #expect(done.text == expected)
    #expect(done.selection == caret((expected as NSString).length))
}

@Test func liveReturnMakesBlocksAndContinuesLists() {
    func returned(_ s: String, at p: Int) -> String? { apply(LiveEditing(text: s).newline(caret(p)), to: s)?.text }
    #expect(returned("```zig", at: 6) == "```zig\n\n```")
    #expect(returned("$$", at: 2) == "$$\n\n$$")
    #expect(returned("- a", at: 1) == "- a\n- ")
    #expect(returned("9. a", at: 1) == "9. a\n10. ")
    #expect(returned("- [x] a", at: 1) == "- [x] a\n- [ ] ")
    // An empty item ends the list. (Display "a\n": the second item.)
    #expect(returned("- a\n- ", at: 2) == "- a\n")
    // An empty last line leaves a code block. (Display "a\n".)
    #expect(returned("```\na\n\n```", at: 2) == "```\na\n```\n")
}

/// After typing `**太**` the caret is after the closing `**` in the source,
/// though the display can't show the difference: Return goes there, not
/// inside the bold. Found by typing it through the text view.
@Test func liveReturnAfterAClosedSpanStaysOutsideIt() {
    let e = LiveEditing(text: "x **b**")
    // Display "x b", caret 3. Known to be after the markers (source 7):
    #expect(apply(e.newline(caret(3), preferring: 7), to: "x **b**")?.text == "x **b**\n")
    // Not known: a newline still never goes inside the span.
    #expect(apply(e.newline(caret(3)), to: "x **b**")?.text == "x **b**\n")
    // Typing a letter goes where the caret is known to be, or else
    // continues the bold.
    #expect(apply(e.type("c", over: caret(3), preferring: 7), to: "x **b**")?.text == "x **b**c")
    #expect(apply(e.type("c", over: caret(3)), to: "x **b**")?.text == "x **bc**")
}

/// Return at the end of a code block's last line leaves an empty last
/// line in the block: it is one of the block's display lines, so it is
/// drawn in the box. Found by typing it.
@Test func liveCodeBlockLinesIncludeAnEmptyLastLine() {
    let note = "```\ncode\n```"
    let returned = apply(LiveEditing(text: note).newline(caret(4)), to: note)
    #expect(returned?.text == "```\ncode\n\n```")
    let p = LiveProjection(returned!.text)
    #expect(p.display == "code\n\n")
    let code = p.elements.first { if case .codeBlock = $0.kind { true } else { false } }!
    #expect(p.displayLines(code.content) == NSRange(location: 0, length: 6))
    // The caret after Return is on that line, inside the block.
    #expect(p.display(at: returned!.selection.location) == 5)
}

@Test func liveToggleWrapsAndUnwraps() {
    let e = LiveEditing(text: "say hi there")
    #expect(e.toggle(.strong, marker: "**", selection: NSRange(location: 3, length: 4)) == .replace(NSRange(location: 4, length: 2), with: "**hi**", selection: NSRange(location: 6, length: 2)))
    // Display "say hi there"; "hi" is at 4 in the display.
    let b = LiveEditing(text: "say **hi** there")
    #expect(b.toggle(.strong, marker: "**", selection: NSRange(location: 4, length: 2)) == .replace(NSRange(location: 4, length: 6), with: "hi", selection: NSRange(location: 4, length: 2)))
}

// MARK: - Themes

@Test func everyThemePaintsEveryToken() {
    for theme in ThemePalette.allThemes {
        for token in ThemeToken.allCases {
            #expect(theme.colors[token] != nil, "\(theme.name) is missing \(token.rawValue)")
        }
        #expect(theme.swatches.count == 8, "\(theme.name) needs eight swatches")
        #expect(ThemePalette.named(theme.id, dark: theme.dark) == theme)
    }
    #expect(Set(ThemePalette.allThemes.map(\.id)).count == ThemePalette.allThemes.count)
}

@Test func builtInNautMatchesTheStylesheet() {
    for (theme, dark) in [(ThemePalette.nautLight, false), (ThemePalette.nautDark, true)] {
        for token in ThemeToken.allCases {
            guard let css = token.color(dark: dark), let value = theme.color(token) else {
                Issue.record("\(theme.name) is missing \(token.rawValue)")
                continue
            }
            // Components cross the C API as Float, so compare loosely.
            #expect(abs(css.red - value.red) < 0.002, "\(theme.name) \(token.rawValue) red")
            #expect(abs(css.green - value.green) < 0.002, "\(theme.name) \(token.rawValue) green")
            #expect(abs(css.blue - value.blue) < 0.002, "\(theme.name) \(token.rawValue) blue")
            #expect(abs(css.alpha - value.alpha) < 0.002, "\(theme.name) \(token.rawValue) alpha")
        }
    }
}

@Test(arguments: ThemePalette.allThemes.map(\.id))
func themesKeepTextLegible(id: String) {
    let theme = ThemePalette.allThemes.first { $0.id == id }!
    let bg = theme.colors[.bg]!
    func contrast(_ color: ThemeColor) -> Double {
        (max(color.luminance, bg.luminance) + 0.05) / (min(color.luminance, bg.luminance) + 0.05)
    }
    #expect(contrast(theme.colors[.fg]!) >= 4.5, "\(theme.name) body text")
    #expect(contrast(theme.colors[.fgBody]!) >= 4.5, "\(theme.name) ink")
    #expect(contrast(theme.colors[.fgDim]!) >= 3.0, "\(theme.name) dim text")
    #expect(contrast(theme.cursor) >= 3.0, "\(theme.name) cursor")
    for token in [ThemeToken.synKeyword, .synString, .synAttr, .synNumber] {
        #expect(contrast(theme.colors[token]!) >= 3.0, "\(theme.name) \(token.rawValue)")
    }
}

// MARK: - Modal editing

@Test func modalTextFindsLines() {
    let text = "one two\nthree four\n" as NSString
    #expect(ModalText.lineRange(text, at: 0) == NSRange(location: 0, length: 8))
    #expect(ModalText.lineContentRange(text, at: 0) == NSRange(location: 0, length: 7))
    #expect(ModalText.lineRange(text, at: 8) == NSRange(location: 8, length: 11))
    // The empty line after a final newline is a line of its own.
    #expect(ModalText.lineRange(text, at: text.length) == NSRange(location: text.length, length: 0))
    #expect(ModalText.firstNonBlank("  x" as NSString, at: 0) == 2)
    #expect(ModalText.lastCharacter(text, at: 0) == 6)
    #expect(ModalText.lastCharacter(text, at: 8) == 17)
    #expect(ModalText.linewiseRange(text, from: 0, lines: 2) == NSRange(location: 0, length: 19))
    #expect(ModalText.linewiseRange(text, from: 0, lines: 9) == NSRange(location: 0, length: 19))
}

@Test func modalTextMovesByWord() {
    let text = "one two\nthree four\n" as NSString
    #expect(ModalText.nextWordStart(text, from: 0) == 4)
    #expect(ModalText.nextWordStart(text, from: 4) == 8)
    #expect(ModalText.previousWordStart(text, from: 8) == 4)
    #expect(ModalText.previousWordStart(text, from: 4) == 0)
    #expect(ModalText.wordEnd(text, from: 0) == 2)
    #expect(ModalText.wordEnd(text, from: 4) == 6)
    #expect(ModalText.wordRunEnd(text, from: 4) == 7)
    #expect(ModalText.wordRunEnd(text, from: 7) == 13)
    #expect(ModalText.wordRunStart(text, from: 7) == 8)
    #expect(ModalText.wordRunStart(text, from: 4) == 4)
    // Punctuation is its own word, as in Vim.
    let punct = "foo.bar baz" as NSString
    #expect(ModalText.nextWordStart(punct, from: 0) == 3)
    #expect(ModalText.nextWordStart(punct, from: 3) == 4)
    // Japanese runs move as one word.
    let japanese = "日本語 の 太字" as NSString
    #expect(ModalText.nextWordStart(japanese, from: 0) == 4)
    #expect(ModalText.wordEnd(japanese, from: 0) == 2)
}

@Test func modalModeAndKeymapsReadWell() {
    #expect(EditorKeymap.normal.isModal == false)
    #expect(EditorKeymap.vim.isModal && EditorKeymap.helix.isModal)
    #expect(ModalMode.visualLine.title == "VISUAL LINE")
    #expect(ModalMode.selectLine.isLinewise)
    #expect(ModalMode.insert.isVisual == false)
}

/// A code block followed by a blank line: the blank line is outside the
/// block, so it must not take the code indentation. Its caret used to be
/// indented as if it were still code.
@Test func liveCodeBlockDoesNotOwnTheBlankLineAfterIt() {
    let note = "```python\na = np.linspace([1, 3, 5])\n```\n\nafter"
    let p = LiveProjection(note)
    let code = p.elements.first { if case .codeBlock = $0.kind { true } else { false } }!
    let lines = p.displayLines(code.content)
    #expect(p.display.substring(with: lines) == "a = np.linspace([1, 3, 5])\n")
}

@Test func liveCodeBlockDoesNotOwnATrailingBlankLine() {
    let note = "```python\na = np.linspace([1, 3, 5])\n```\n\n"
    let p = LiveProjection(note)
    #expect(p.display == "a = np.linspace([1, 3, 5])\n\n")
    let code = p.elements.first { if case .codeBlock = $0.kind { true } else { false } }!
    let lines = p.displayLines(code.content)
    #expect(p.display.substring(with: lines) == "a = np.linspace([1, 3, 5])\n")
}

// MARK: - Clipboard

@Test func copiedMarkdownRestoresHiddenSyntax() {
    let heading = LiveProjection("## Heading\n")
    #expect(heading.display == "Heading\n")
    #expect(heading.copiedMarkdown(for: NSRange(location: 0, length: 7)) == "## Heading")

    let bold = LiveProjection("say **bold** there")
    #expect(bold.display == "say bold there")
    #expect(bold.copiedMarkdown(for: NSRange(location: 4, length: 4)) == "**bold**")

    let code = LiveProjection("before\n```zig\nconst x = 1;\n```\nafter")
    // Display "before\nconst x = 1;\nafter"; the code line starts at 7.
    #expect(code.copiedMarkdown(for: NSRange(location: 7, length: 12)) == "```zig\nconst x = 1;\n```\n")
}

@Test func copiedMarkdownTrimsTrailingWhitespacePerLine() {
    let p = LiveProjection("## Heading   \nline two\t\nplain  \n")
    let all = NSRange(location: 0, length: p.display.length)
    #expect(p.copiedMarkdown(for: all) == "## Heading\nline two\nplain\n")
}

@Test func copiedMarkdownOfPartOfASpanIsJustThePart() {
    let p = LiveProjection("say **bold** there")
    // Display "say bold there"; select "bo".
    #expect(p.copiedMarkdown(for: NSRange(location: 4, length: 2)) == "bo")
}

@Test func copiedMarkdownRestoresLinksAndListMarkers() {
    let link = LiveProjection("see [docs](https://x) now")
    #expect(link.display == "see docs now")
    #expect(link.copiedMarkdown(for: NSRange(location: 4, length: 4)) == "[docs](https://x)")

    let list = LiveProjection("- item one\n- item two")
    #expect(list.display == "item one\nitem two")
    #expect(list.copiedMarkdown(for: NSRange(location: 0, length: 8)) == "- item one")
}

@Test func noteSearchCountsAndCutsASnippet() throws {
    let text = "# Notes\n\n## 結果\n\nIntro line.\n注釈者のカメラの lookat は正解にある。Camera again.\n"
    let match = try #require(NoteSearch.match("camera", title: "Camera log", text: text))
    #expect(match.count == 2) // title + "Camera again"; カメラ is another word
    #expect(match.section == "結果")
    #expect(match.snippet.contains("Camera again"))
    #expect(NoteSearch.match("カメラ", title: "", text: text)?.snippet.hasPrefix("注釈者") == true)
    #expect(NoteSearch.match("zzz", title: "a", text: text) == nil)
}

@Test func noteSearchSkipsCommentsInCodeBlocks() {
    let text = "## 手法\n\n```python\n# project onto the floor\nf = 1\n```\n\ncamera here\n"
    #expect(NoteSearch.match("camera", title: "", text: text)?.section == "手法")
    let tilde = "## A\n~~~\n# not a heading\n```\n# still code\n~~~\ncamera\n"
    #expect(NoteSearch.match("camera", title: "", text: tilde)?.section == "A")
}

@Test func texErrorsNameTheMistake() {
    #expect(TeXErrors.messages("a_n = \\nn") == ["Undefined control sequence: \\nn"])
    #expect(TeXErrors.messages("x^2 + \\frac{1}{2}").isEmpty)
    #expect(TeXErrors.messages("a }").first?.hasPrefix("Unexpected") == true)
}

@Test func liveTypingDollarsMakesAClosedEquation() {
    // The second `$` on a line of its own closes the block right away, so
    // the text below isn't taken into it; the caret goes inside.
    let open = "a\n\n$\n\n## 1\n\n$$\nx\n$$"
    #expect(apply(LiveEditing(text: open).type("$", over: caret(4)), to: open)?.text == "a\n\n$$\n\n$$\n\n## 1\n\n$$\nx\n$$")
    // Closing a block left open above, by hand: just the `$`.
    let closing = "$$\nx\n$"
    #expect(apply(LiveEditing(text: closing).type("$", over: caret(6)), to: closing)?.text == "$$\nx\n$$")
    // Not mid-line, where `$$` is text.
    let inline = "cost $"
    #expect(apply(LiveEditing(text: inline).type("$", over: caret(6)), to: inline)?.text == "cost $$")
}

@Test(arguments: KeySound.allCases)
func everyKeySoundHasItsRecordings(sound: KeySound) {
    let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../KeySounds")
    for code: UInt16 in [0, 12, 18, 6, 49, 36, 51, 123] {
        for down in [true, false] {
            guard let file = sound.file(keyCode: code, down: down) else {
                #expect(sound == .off); continue
            }
            let path = root.appending(path: file + ".mp3").standardizedFileURL.path
            #expect(FileManager.default.fileExists(atPath: path), "\(path)")
        }
    }
}

@Test func imagesCarryAWidth() {
    #expect(LiveMarkdown.parse("![shot|320](a.png)").first?.kind == .image(url: "a.png", width: 320))
    #expect(LiveMarkdown.parse("![a|b](a.png)").first?.kind == .image(url: "a.png", width: nil))
    let note = "x\n![shot|320](a.png)\ny"
    #expect(apply(LiveEditing(text: note).resizeImage(0, width: 200), to: note)?.text == "x\n![shot|200](a.png)\ny")
    #expect(apply(LiveEditing(text: note).resizeImage(0, width: nil), to: note)?.text == "x\n![shot](a.png)\ny")
}

@Test func pastedBlocksGetALineOfTheirOwn() {
    func paste(_ s: String, at p: Int) -> String? { apply(LiveEditing(text: s).insertBlock("![](i.png)", over: caret(p)), to: s)?.text }
    #expect(paste("ab", at: 1) == "a\n![](i.png)\nb")
    #expect(paste("ab", at: 2) == "ab\n![](i.png)\n")
    #expect(paste("a\n", at: 2) == "a\n![](i.png)\n")
    #expect(paste("", at: 0) == "![](i.png)\n")
}

@Test func blocksMoveByWholeLines() {
    let note = "a\n$$\nx\n$$\nb\nc"
    let math = NSRange(location: 2, length: 8) // "$$\nx\n$$\n"
    func move(to p: Int) -> String? { apply(LiveEditing(text: note).moveBlock(math, to: p), to: note)?.text }
    #expect(move(to: 0) == "$$\nx\n$$\na\nb\nc")
    #expect(move(to: 12) == "a\nb\n$$\nx\n$$\nc")
    // To the end of a note with no final newline.
    #expect(move(to: 13) == "a\nb\nc\n$$\nx\n$$")
    // Onto itself: nothing.
    #expect(LiveEditing(text: note).moveBlock(math, to: 10) == .none)
    // The last line, moved up, leaves no empty line behind.
    let last = "a\n![](i.png)"
    #expect(apply(LiveEditing(text: last).moveBlock(NSRange(location: 2, length: 10), to: 0), to: last)?.text == "![](i.png)\na")
    // Dropped inside a code block: above it.
    let code = "```\nk\n```\n![](i.png)"
    #expect(apply(LiveEditing(text: code).moveBlock(NSRange(location: 10, length: 10), to: 4), to: code)?.text == "![](i.png)\n```\nk\n```")
}

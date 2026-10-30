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
    #expect(els.contains { $0.kind == .image(url: "pics/x.png") })
    // Only an image alone on its line is drawn.
    #expect(!els.contains { $0.kind == .image(url: "y.png") })
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

@Test func liveDeletingIntoAHeadingMakesAParagraph() {
    // Backspace at the start of "Title" deletes the newline before it.
    let e = LiveEditing(text: "a\n## Title")
    #expect(e.delete(NSRange(location: 1, length: 1), selection: caret(2)) == .replace(NSRange(location: 2, length: 3), with: "", selection: caret(2)))
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

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

// MARK: - Live editing

private func editing(_ s: String) -> LiveEditing { LiveEditing(text: s, elements: LiveMarkdown.parse(s)) }
private func caret(_ i: Int) -> NSRange { NSRange(location: i, length: 0) }

@Test func caretStepsOverHiddenSyntax() {
    let e = editing("a **b** c")
    // Right from "a " onto the opening "**" steps past it.
    #expect(e.snap(2, from: 1, .forward) == 4)
    #expect(e.snap(3, from: 2, .forward) == 4)
    // Left from "b" steps back over it.
    #expect(e.snap(3, from: 4, .backward) == 2)
    // A click inside a marker lands on the nearer edge.
    #expect(e.snap(6, from: 0, .nearest) == 5)
}

@Test func caretNeverEntersAHeadingPrefixOrABlock() {
    let h = editing("x\n## Title")
    // Down onto the hidden "## " lands after it; left from the title goes up.
    #expect(h.snap(2, from: 0, .forward) == 5)
    #expect(h.snap(4, from: 5, .backward) == 1)
    #expect(h.snap(2, from: 9, .backward) == 5)

    let m = editing("a\n$$\nx\n$$\nb")
    // The block is lines 2 to 4 (2..<9); stepping into it from either side
    // comes out the other.
    #expect(m.snap(2, from: 1, .forward) == 10)
    #expect(m.snap(9, from: 10, .backward) == 1)
}

@Test func deletingTurnsHeadingsIntoParagraphs() {
    let e = editing("## Title")
    #expect(e.delete(NSRange(location: 2, length: 1), selection: caret(3)) == .replace(NSRange(location: 0, length: 3), with: "", select: caret(0)))
}

@Test func deletingAHiddenMarkerDeletesTheLetterBehindIt() {
    let e = editing("**ab** c")
    // Backspace right after the closing "**" deletes "b".
    #expect(e.delete(NSRange(location: 5, length: 1), selection: caret(6)) == .replace(NSRange(location: 3, length: 1), with: "", select: caret(3)))
    // The last letter takes the markers with it.
    // So does deleting it from inside.
    #expect(editing("**a** c").delete(NSRange(location: 2, length: 1), selection: caret(3)) == .replace(NSRange(location: 0, length: 5), with: "", select: caret(0)))
    let one = editing("**a** c")
    #expect(one.delete(NSRange(location: 4, length: 1), selection: caret(5)) == .replace(NSRange(location: 0, length: 5), with: "", select: caret(0)))
}

@Test func deletingIntoABlockSelectsItFirst() {
    let e = editing("$$\nx\n$$\nb")
    // Backspace at the start of "b" selects the equation; with it selected,
    // the text view deletes it.
    #expect(e.delete(NSRange(location: 7, length: 1), selection: caret(8)) == .select(NSRange(location: 0, length: 7)))
    #expect(e.delete(NSRange(location: 0, length: 7), selection: NSRange(location: 0, length: 7)) == .allow)
    // An empty line below goes without touching the block.
    let blank = editing("$$\nx\n$$\n\nb")
    #expect(blank.delete(NSRange(location: 7, length: 1), selection: caret(8)) == .allow)
}

@Test func returnMakesBlocksAndContinuesLists() {
    #expect(editing("```zig").newline(caret(6)) == .replace(caret(6), with: "\n\n```", select: caret(7)))
    #expect(editing("$$").newline(caret(2)) == .replace(caret(2), with: "\n\n$$", select: caret(3)))
    #expect(editing("- a").newline(caret(3)) == .replace(caret(3), with: "\n- ", select: caret(6)))
    #expect(editing("9. a").newline(caret(4)) == .replace(caret(4), with: "\n10. ", select: caret(9)))
    #expect(editing("- [x] a").newline(caret(7)) == .replace(caret(7), with: "\n- [ ] ", select: caret(14)))
    // An empty item ends the list.
    #expect(editing("- a\n- ").newline(caret(6)) == .replace(NSRange(location: 4, length: 2), with: "", select: caret(4)))
    // An empty last line leaves a code block.
    #expect(editing("```\na\n\n```").newline(caret(6)) == .replace(NSRange(location: 6, length: 4), with: "```\n", select: caret(10)))
}

@Test func toggleWrapsAndUnwraps() {
    let e = editing("say hi there")
    #expect(e.toggle(.strong, marker: "**", selection: NSRange(location: 3, length: 4)) == .replace(NSRange(location: 4, length: 2), with: "**hi**", select: NSRange(location: 6, length: 2)))
    let b = editing("say **hi** there")
    #expect(b.toggle(.strong, marker: "**", selection: NSRange(location: 6, length: 2)) == .replace(NSRange(location: 4, length: 6), with: "hi", select: NSRange(location: 4, length: 2)))
}

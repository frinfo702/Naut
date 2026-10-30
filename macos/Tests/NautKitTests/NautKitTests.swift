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

@Test func liveMarkdownUnclosedFenceRunsToTheEnd() {
    let els = LiveMarkdown.parse("```\na\nb")
    #expect(els.count == 1)
    #expect(els[0].kind == .codeBlock(language: "") && els[0].scope.length == 7)
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

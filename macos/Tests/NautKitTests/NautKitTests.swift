import NautKit
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

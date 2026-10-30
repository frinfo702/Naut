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

@Test func tokensResolveForBothSchemes() {
    // Components cross the C API as Float, so compare loosely.
    #expect(abs((Tokens.color("--bg", dark: true)?.red ?? 0) - 0x10 / 255) < 0.001)
    #expect(Tokens.color("--edge-top", dark: true)?.alpha ?? 0 > 0)
    #expect(Tokens.color("--bg", dark: false) != nil)
    #expect(Tokens.color("--nope", dark: true) == nil)
}

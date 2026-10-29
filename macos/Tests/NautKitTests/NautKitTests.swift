import NautKit
import Testing

@Test func rendersMarkdownThroughLibnaut() {
    #expect(Markdown.html("**日本語**") == "<p><strong>日本語</strong></p>\n")
}

@Test func outlineDecodes() {
    #expect(Markdown.outline("# A\n## B").map(\.id) == ["a", "b"])
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

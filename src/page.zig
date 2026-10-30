//! A complete HTML page for a note.
//!
//! The app preview and the published web page are the same document. The
//! app loads it once and then only swaps the inner HTML of `<main>` as the
//! user types (see `naut.enhance` in page.js), so the stylesheet and
//! script here are the single source of truth for how a note looks.
//!
//! The page is self-contained: math is MathML and code is highlighted at
//! render time, so nothing is fetched and it works offline.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const markdown = @import("markdown.zig");

const css = @embedFile("page.css");

/// The stylesheet, for reading design tokens with the css module.
pub const stylesheet = css;
const js = @embedFile("page.js");

pub const Options = struct {
    /// Shown in the browser tab and at the top of the outline.
    title: []const u8,
    /// Render the outline sidebar. The app has a native one, so it turns
    /// this off; published pages turn it on.
    toc: bool = true,
};

/// Write a complete page. `alloc` should be an arena; nothing is freed
/// individually.
pub fn write(alloc: Allocator, w: *Writer, src: []const u8, opts: Options) markdown.Error!void {
    // Render the body first: the outline needs the headings.
    var body: Writer.Allocating = .init(alloc);
    var r: markdown.Renderer = .init(alloc);
    try r.render(&body.writer, src);

    try w.writeAll("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n" ++
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try markdown.escape(w, opts.title);
    try w.writeAll("</title>\n<style>\n" ++ css ++ "</style>\n<script>\n" ++ js ++
        "</script>\n</head>\n<body>\n<div class=\"page\">\n");

    if (opts.toc) {
        try w.writeAll("<nav class=\"toc\"><a class=\"title\" href=\"#\">");
        try markdown.escape(w, opts.title);
        try w.writeAll("</a>\n<ul>\n");
        for (r.headings.items) |h| {
            // Only second-level headings: the first is usually the title
            // and deeper ones make the tree noisy.
            if (h.level != 2) continue;
            try w.writeAll("<li><a href=\"#");
            try markdown.escape(w, h.id);
            try w.writeAll("\">");
            try markdown.escape(w, h.text);
            try w.writeAll("</a></li>\n");
        }
        try w.writeAll("</ul></nav>\n");
    }

    try w.writeAll("<main>\n");
    try w.writeAll(body.written());
    try w.writeAll("</main>\n</div>\n</body>\n</html>\n");
}

test "page: escapes title and links headings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    try write(arena.allocator(), &out.writer, "# T\n## Sub", .{ .title = "<x>" });
    const html = out.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<title>&lt;x&gt;</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<li><a href=\"#sub\">Sub</a></li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2 id=\"sub\">Sub</h2>") != null);
}

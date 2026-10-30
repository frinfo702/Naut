//! C API. See include/naut.h for the contract; this file only adapts it.
//!
//! Every string we return is allocated with the C allocator and must be
//! released with naut_string_free. Each call builds its own arena and Io,
//! so all functions are safe to call from any thread concurrently.

const std = @import("std");
const naut = @import("main.zig");

const log = std.log.scoped(.c);

const String = extern struct {
    ptr: ?[*]u8,
    len: usize,

    const empty: String = .{ .ptr = null, .len = 0 };

    /// Copy `s` into C-allocator memory. On OOM returns empty, which the
    /// caller sees as an empty string; we'd rather show nothing than crash
    /// the app.
    fn dupe(s: []const u8) String {
        const copy = std.heap.c_allocator.dupe(u8, s) catch return empty;
        return .{ .ptr = copy.ptr, .len = copy.len };
    }
};

const PageOptions = extern struct {
    title: ?[*]const u8,
    title_len: usize,
    toc: bool,
};

const Cloudflare = extern struct {
    account_id: [*:0]const u8,
    api_token: [*:0]const u8,

    fn credentials(self: *const Cloudflare) naut.cloudflare.Credentials {
        return .{
            .account_id = std.mem.span(self.account_id),
            .api_token = std.mem.span(self.api_token),
        };
    }
};

/// A design token from page.css as a colour, so the native app draws its
/// chrome from the same palette as the rendered page. False when the token
/// doesn't exist or isn't a colour.
export fn naut_theme_color(name: [*:0]const u8, dark: bool, out: *naut.css.Color) bool {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Parsing per call keeps this stateless and thread-safe. The sheet is
    // a few KB and callers look each token up once.
    const sheet = naut.css.Sheet.parse(alloc, naut.page.stylesheet) catch return false;
    const color = sheet.color(alloc, std.mem.span(name), if (dark) .dark else .light) catch return false;
    out.* = color orelse return false;
    return true;
}

fn slice(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

export fn naut_string_free(s: String) void {
    if (s.ptr) |p| std.heap.c_allocator.free(p[0..s.len]);
}

/// One parse for both outputs: the app needs the HTML and the headings on
/// every keystroke, and parsing twice was half the cost of typing.
export fn naut_render(src: ?[*]const u8, len: usize, html: *String, outline_json: *String) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    html.* = .empty;
    outline_json.* = .dupe("[]");

    var out: std.Io.Writer.Allocating = .init(alloc);
    var r: naut.markdown.Renderer = .init(alloc);
    r.render(&out.writer, slice(src, len)) catch |err| {
        log.warn("(naut_render) err={t}", .{err});
        return;
    };
    html.* = .dupe(out.written());

    var json: std.Io.Writer.Allocating = .init(alloc);
    std.json.Stringify.value(r.headings.items, .{}, &json.writer) catch return;
    naut_string_free(outline_json.*);
    outline_json.* = .dupe(json.written());
}

export fn naut_render_page(src: ?[*]const u8, len: usize, opts: *const PageOptions) String {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    naut.page.write(arena.allocator(), &out.writer, slice(src, len), .{
        .title = slice(opts.title, opts.title_len),
        .toc = opts.toc,
    }) catch |err| {
        log.warn("(naut_render_page) err={t}", .{err});
        return .empty;
    };
    return .dupe(out.written());
}

/// Run one publishing operation with its own arena and Io, and turn the
/// result or the diagnostic into an owned string.
fn runPublish(out: *String, comptime f: anytype, args: anytype) bool {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var diag: std.Io.Writer.Allocating = .init(alloc);
    const result = @call(.auto, f, .{ alloc, io } ++ args ++ .{&diag.writer}) catch |err| {
        if (diag.written().len == 0) diag.writer.print("{t}", .{err}) catch {};
        out.* = .dupe(diag.written());
        return false;
    };

    if (@TypeOf(result) == void) {
        out.* = .empty;
    } else {
        var json: std.Io.Writer.Allocating = .init(alloc);
        std.json.Stringify.value(result, .{}, &json.writer) catch {
            out.* = .empty;
            return false;
        };
        out.* = .dupe(json.written());
    }
    return true;
}

export fn naut_cloudflare_provision(cf: *const Cloudflare, workdir: [*:0]const u8, out: *String) bool {
    return runPublish(out, naut.cloudflare.provision, .{ cf.credentials(), std.mem.span(workdir) });
}

export fn naut_cloudflare_put(
    cf: *const Cloudflare,
    namespace_id: [*:0]const u8,
    key: [*:0]const u8,
    value: ?[*]const u8,
    value_len: usize,
    out: *String,
) bool {
    return runPublish(out, naut.cloudflare.put, .{
        cf.credentials(), std.mem.span(namespace_id), std.mem.span(key), slice(value, value_len),
    });
}

export fn naut_cloudflare_delete(
    cf: *const Cloudflare,
    namespace_id: [*:0]const u8,
    key: [*:0]const u8,
    out: *String,
) bool {
    return runPublish(out, naut.cloudflare.delete, .{
        cf.credentials(), std.mem.span(namespace_id), std.mem.span(key),
    });
}

test "c: render returns html and outline" {
    const src = "# A\n## B";
    var html: String = undefined;
    var outline: String = undefined;
    naut_render(src.ptr, src.len, &html, &outline);
    defer naut_string_free(html);
    defer naut_string_free(outline);
    try std.testing.expectEqualStrings("<h1 id=\"a\">A</h1>\n<h2 id=\"b\">B</h2>\n", html.ptr.?[0..html.len]);
    try std.testing.expectEqualStrings(
        \\[{"level":1,"text":"A","id":"a"},{"level":2,"text":"B","id":"b"}]
    , outline.ptr.?[0..outline.len]);
}

test "c: theme colors come from page.css" {
    // Which tokens the app needs is ThemeToken's business (NautKit tests
    // check each one); here we only check the plumbing.
    var bg: naut.css.Color = undefined;
    try std.testing.expect(naut_theme_color("--bg", true, &bg));
    try std.testing.expectApproxEqAbs(0x10.0 / 255.0, bg.r, 0.001);
    try std.testing.expect(naut_theme_color("--bg", false, &bg));
    try std.testing.expect(!naut_theme_color("--font", true, &bg));
    try std.testing.expect(!naut_theme_color("--nope", true, &bg));
}

test "c: publish reports invalid input without touching the network" {
    const cf: Cloudflare = .{ .account_id = "nope", .api_token = "t" };
    var out: String = undefined;
    try std.testing.expect(!naut_cloudflare_put(&cf, "ns", "k", null, 0, &out));
    defer naut_string_free(out);
    try std.testing.expectStringStartsWith(out.ptr.?[0..out.len], "Account ID");
}

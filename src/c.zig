//! C API. See include/folio.h for the contract; this file only adapts it.
//!
//! Every string we return is allocated with the C allocator and must be
//! released with folio_string_free. Each call builds its own arena and Io,
//! so all functions are safe to call from any thread concurrently.

const std = @import("std");
const folio = @import("main.zig");

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

    fn credentials(self: *const Cloudflare) folio.cloudflare.Credentials {
        return .{
            .account_id = std.mem.span(self.account_id),
            .api_token = std.mem.span(self.api_token),
        };
    }
};

fn slice(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

export fn folio_string_free(s: String) void {
    if (s.ptr) |p| std.heap.c_allocator.free(p[0..s.len]);
}

export fn folio_render_html(src: ?[*]const u8, len: usize) String {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    var r: folio.markdown.Renderer = .init(arena.allocator());
    r.render(&out.writer, slice(src, len)) catch |err| {
        log.warn("(folio_render_html) err={t}", .{err});
        return .empty;
    };
    return .dupe(out.written());
}

export fn folio_render_page(src: ?[*]const u8, len: usize, opts: *const PageOptions) String {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    folio.page.write(arena.allocator(), &out.writer, slice(src, len), .{
        .title = slice(opts.title, opts.title_len),
        .toc = opts.toc,
    }) catch |err| {
        log.warn("(folio_render_page) err={t}", .{err});
        return .empty;
    };
    return .dupe(out.written());
}

export fn folio_outline_json(src: ?[*]const u8, len: usize) String {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Rendering is the only parser we have; the HTML is discarded.
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var r: folio.markdown.Renderer = .init(alloc);
    r.render(&discard.writer, slice(src, len)) catch |err| {
        log.warn("(folio_outline_json) err={t}", .{err});
        return .dupe("[]");
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    std.json.Stringify.value(r.headings.items, .{}, &out.writer) catch return .dupe("[]");
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

export fn folio_cloudflare_provision(cf: *const Cloudflare, workdir: [*:0]const u8, out: *String) bool {
    return runPublish(out, folio.cloudflare.provision, .{ cf.credentials(), std.mem.span(workdir) });
}

export fn folio_cloudflare_put(
    cf: *const Cloudflare,
    namespace_id: [*:0]const u8,
    key: [*:0]const u8,
    value: ?[*]const u8,
    value_len: usize,
    out: *String,
) bool {
    return runPublish(out, folio.cloudflare.put, .{
        cf.credentials(), std.mem.span(namespace_id), std.mem.span(key), slice(value, value_len),
    });
}

export fn folio_cloudflare_delete(
    cf: *const Cloudflare,
    namespace_id: [*:0]const u8,
    key: [*:0]const u8,
    out: *String,
) bool {
    return runPublish(out, folio.cloudflare.delete, .{
        cf.credentials(), std.mem.span(namespace_id), std.mem.span(key),
    });
}

test "c: outline json" {
    const src = "# A\n## B";
    const s = folio_outline_json(src.ptr, src.len);
    defer folio_string_free(s);
    try std.testing.expectEqualStrings(
        \\[{"level":1,"text":"A","id":"a"},{"level":2,"text":"B","id":"b"}]
    , s.ptr.?[0..s.len]);
}

test "c: publish reports invalid input without touching the network" {
    const cf: Cloudflare = .{ .account_id = "nope", .api_token = "t" };
    var out: String = undefined;
    try std.testing.expect(!folio_cloudflare_put(&cf, "ns", "k", null, 0, &out));
    defer folio_string_free(out);
    try std.testing.expectStringStartsWith(out.ptr.?[0..out.len], "Account ID");
}

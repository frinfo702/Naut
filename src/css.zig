//! Reading design tokens out of CSS.
//!
//! page.css is the single source of truth for how Naut looks. The web
//! page uses it directly; the native app reads the same custom properties
//! through this module so its chrome (sidebar, search field) matches the
//! rendered note without a second hand-copied palette that drifts.
//!
//! This is a parser for stylesheets we write, not a CSS engine. It
//! understands rules, comments, strings, `@media (prefers-color-scheme:
//! ...)` blocks, custom properties on `:root`, `var()` with fallbacks, and
//! colours (hex, rgb()/rgba() in both comma and space syntax, a few
//! keywords). Selectors other than `:root` and all other at-rules are
//! skipped. Anything malformed is skipped rather than reported: the
//! stylesheet is embedded at build time and covered by tests, so a parse
//! error here means a test failure, not a user problem.
//!
//! This module has no dependencies on the rest of naut and is exported as
//! its own Zig module, `css`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Scheme = enum { dark, light };

/// A custom property declaration in document order.
pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    /// null applies to every scheme; set inside a prefers-color-scheme
    /// media block.
    scheme: ?Scheme,
};

pub const Sheet = struct {
    /// Slices into the source; the source must outlive the sheet.
    variables: []const Variable,

    /// Parse `src`. Only allocates the variable list.
    pub fn parse(alloc: Allocator, src: []const u8) Allocator.Error!Sheet {
        var vars: std.ArrayList(Variable) = .empty;
        var p: Parser = .{ .src = src };
        try p.block(alloc, &vars, null, false);
        return .{ .variables = vars.items };
    }

    /// The raw value of a custom property for `scheme`, before var()
    /// substitution. Later declarations win, as in the cascade; scheme
    /// blocks only win for their own scheme.
    pub fn raw(self: Sheet, name: []const u8, scheme: Scheme) ?[]const u8 {
        var i = self.variables.len;
        while (i > 0) {
            i -= 1;
            const v = self.variables[i];
            if (!std.mem.eql(u8, v.name, name)) continue;
            if (v.scheme) |s| if (s != scheme) continue;
            return v.value;
        }
        return null;
    }

    /// The value of a custom property with every `var()` substituted.
    /// Cycles and runaway nesting resolve to null.
    pub fn resolve(self: Sheet, alloc: Allocator, name: []const u8, scheme: Scheme) Allocator.Error!?[]const u8 {
        return self.resolveDepth(alloc, name, scheme, 0);
    }

    fn resolveDepth(self: Sheet, alloc: Allocator, name: []const u8, scheme: Scheme, depth: u8) Allocator.Error!?[]const u8 {
        // Deep enough for any real token chain, shallow enough that a
        // cycle (--a: var(--b); --b: var(--a)) ends quickly.
        if (depth > 16) return null;
        const value = self.raw(name, scheme) orelse return null;
        return self.substitute(alloc, value, scheme, depth);
    }

    fn substitute(self: Sheet, alloc: Allocator, value: []const u8, scheme: Scheme, depth: u8) Allocator.Error!?[]const u8 {
        const start = std.mem.indexOf(u8, value, "var(") orelse return value;
        const close = matchingParen(value, start + 3) orelse return null;
        const inner = value[start + 4 .. close];

        const comma = std.mem.indexOfScalar(u8, inner, ',');
        const ref = std.mem.trim(u8, inner[0 .. comma orelse inner.len], " \t\n");
        const replacement = try self.resolveDepth(alloc, ref, scheme, depth + 1) orelse fallback: {
            const c = comma orelse return null;
            break :fallback try self.substitute(alloc, std.mem.trim(u8, inner[c + 1 ..], " \t\n"), scheme, depth + 1) orelse return null;
        };

        const joined = try std.mem.concat(alloc, u8, &.{ value[0..start], replacement, value[close + 1 ..] });
        // There may be more var() after this one.
        return self.substitute(alloc, joined, scheme, depth + 1);
    }

    /// A custom property parsed as a colour.
    pub fn color(self: Sheet, alloc: Allocator, name: []const u8, scheme: Scheme) Allocator.Error!?Color {
        const value = try self.resolve(alloc, name, scheme) orelse return null;
        return Color.parse(value);
    }
};

fn matchingParen(s: []const u8, open: usize) ?usize {
    assert(s[open] == '(');
    var depth: usize = 0;
    for (s[open..], open..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    /// Parse rules until `}` (when `nested`) or end of input.
    fn block(p: *Parser, alloc: Allocator, vars: *std.ArrayList(Variable), scheme: ?Scheme, nested: bool) Allocator.Error!void {
        while (true) {
            p.skipTrivia();
            if (p.pos >= p.src.len) return;
            if (p.src[p.pos] == '}') {
                p.pos += 1;
                if (nested) return;
                continue; // stray brace at top level
            }

            const prelude_start = p.pos;
            const brace = p.scanTo("{;") orelse return;
            const prelude = std.mem.trim(u8, p.src[prelude_start..brace], " \t\r\n");
            p.pos = brace + 1;
            if (p.src[brace] == ';') continue; // @import and friends

            if (std.mem.startsWith(u8, prelude, "@media")) {
                // Only colour-scheme queries matter; anything else (width
                // breakpoints) has no meaning for the native app.
                const s: ?Scheme = if (std.mem.indexOf(u8, prelude, "prefers-color-scheme: light") != null or
                    std.mem.indexOf(u8, prelude, "prefers-color-scheme:light") != null)
                    .light
                else if (std.mem.indexOf(u8, prelude, "prefers-color-scheme: dark") != null or
                    std.mem.indexOf(u8, prelude, "prefers-color-scheme:dark") != null)
                    .dark
                else
                    null;
                if (s == null) {
                    p.skipBlock();
                } else {
                    try p.block(alloc, vars, s, true);
                }
                continue;
            }
            if (prelude.len > 0 and prelude[0] == '@') {
                p.skipBlock();
                continue;
            }

            if (isRoot(prelude)) {
                try p.declarations(alloc, vars, scheme);
            } else {
                p.skipBlock();
            }
        }
    }

    /// Read `name: value;` pairs up to the closing `}`, keeping custom
    /// properties.
    fn declarations(p: *Parser, alloc: Allocator, vars: *std.ArrayList(Variable), scheme: ?Scheme) Allocator.Error!void {
        while (true) {
            p.skipTrivia();
            if (p.pos >= p.src.len) return;
            if (p.src[p.pos] == '}') {
                p.pos += 1;
                return;
            }
            const start = p.pos;
            const end = p.scanTo(";}") orelse p.src.len;
            const decl = p.src[start..end];
            p.pos = if (end < p.src.len and p.src[end] == ';') end + 1 else end;

            const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
            const name = std.mem.trim(u8, decl[0..colon], " \t\r\n");
            if (!std.mem.startsWith(u8, name, "--")) continue;
            const value = std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
            try vars.append(alloc, .{ .name = name, .value = value, .scheme = scheme });
        }
    }

    /// Skip whitespace and comments.
    fn skipTrivia(p: *Parser) void {
        while (p.pos < p.src.len) {
            if (std.ascii.isWhitespace(p.src[p.pos])) {
                p.pos += 1;
            } else if (std.mem.startsWith(u8, p.src[p.pos..], "/*")) {
                p.pos = if (std.mem.indexOfPos(u8, p.src, p.pos + 2, "*/")) |e| e + 2 else p.src.len;
            } else return;
        }
    }

    /// Position of the first of `chars` at nesting level zero, skipping
    /// strings, comments and parentheses (so `url(a;b)` is one token).
    fn scanTo(p: *const Parser, chars: []const u8) ?usize {
        var i = p.pos;
        var parens: usize = 0;
        while (i < p.src.len) : (i += 1) {
            const c = p.src[i];
            if (c == '"' or c == '\'') {
                i = std.mem.indexOfScalarPos(u8, p.src, i + 1, c) orelse return null;
            } else if (std.mem.startsWith(u8, p.src[i..], "/*")) {
                i = (std.mem.indexOfPos(u8, p.src, i + 2, "*/") orelse return null) + 1;
            } else if (c == '(') {
                parens += 1;
            } else if (c == ')') {
                parens -|= 1;
            } else if (parens == 0 and std.mem.indexOfScalar(u8, chars, c) != null) {
                return i;
            }
        }
        return null;
    }

    /// Skip to just past the `}` matching an already-consumed `{`.
    fn skipBlock(p: *Parser) void {
        var depth: usize = 1;
        while (p.pos < p.src.len) {
            const end = p.scanTo("{}") orelse {
                p.pos = p.src.len;
                return;
            };
            p.pos = end + 1;
            if (p.src[end] == '{') {
                depth += 1;
            } else {
                depth -= 1;
                if (depth == 0) return;
            }
        }
    }
};

/// True for a selector list containing `:root` on its own.
fn isRoot(prelude: []const u8) bool {
    var it = std.mem.splitScalar(u8, prelude, ',');
    while (it.next()) |sel| {
        if (std.mem.eql(u8, std.mem.trim(u8, sel, " \t\r\n"), ":root")) return true;
    }
    return false;
}

/// sRGB, components in 0...1.
pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub fn parse(value: []const u8) ?Color {
        const v = std.mem.trim(u8, value, " \t\r\n");
        if (v.len == 0) return null;
        if (v[0] == '#') return hex(v[1..]);
        if (std.ascii.eqlIgnoreCase(v, "transparent")) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (std.ascii.eqlIgnoreCase(v, "white")) return .{ .r = 1, .g = 1, .b = 1, .a = 1 };
        if (std.ascii.eqlIgnoreCase(v, "black")) return .{ .r = 0, .g = 0, .b = 0, .a = 1 };
        if (std.ascii.startsWithIgnoreCase(v, "rgb")) return rgb(v);
        return null;
    }

    fn hex(digits: []const u8) ?Color {
        var n: [8]u8 = undefined;
        switch (digits.len) {
            // #rgb and #rgba double each digit.
            3, 4 => for (digits, 0..) |d, i| {
                n[i * 2] = d;
                n[i * 2 + 1] = d;
            },
            6, 8 => @memcpy(n[0..digits.len], digits),
            else => return null,
        }
        const len: usize = if (digits.len <= 4) digits.len * 2 else digits.len;
        if (len == 6) {
            n[6] = 'f';
            n[7] = 'f';
        }
        var c: [4]f32 = undefined;
        for (0..4) |i| {
            const byte = std.fmt.parseInt(u8, n[i * 2 .. i * 2 + 2], 16) catch return null;
            c[i] = @as(f32, @floatFromInt(byte)) / 255;
        }
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    }

    /// `rgb(1 2 3 / 0.5)`, `rgba(1, 2, 3, 50%)` and the like.
    fn rgb(v: []const u8) ?Color {
        const open = std.mem.indexOfScalar(u8, v, '(') orelse return null;
        if (v[v.len - 1] != ')') return null;
        var parts: [4][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, v[open + 1 .. v.len - 1], " ,/\t");
        while (it.next()) |tok| {
            if (n == 4) return null;
            parts[n] = tok;
            n += 1;
        }
        if (n < 3) return null;
        var c: [4]f32 = .{ 0, 0, 0, 1 };
        for (parts[0..n], 0..) |part, i| {
            const pct = std.mem.endsWith(u8, part, "%");
            const num = std.fmt.parseFloat(f32, if (pct) part[0 .. part.len - 1] else part) catch return null;
            const scale: f32 = if (pct) 100 else if (i == 3) 1 else 255;
            c[i] = std.math.clamp(num / scale, 0, 1);
        }
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    }
};

// --- Tests ------------------------------------------------------------------

const test_sheet =
    \\/* tokens */
    \\:root {
    \\  --bg: #10120f;
    \\  --edge: rgb(255 255 255 / 0.16);
    \\  --alias: var(--bg);
    \\  --font: "A; B", sans-serif;
    \\  --missing: var(--nope, #fff);
    \\  --cycle-a: var(--cycle-b);
    \\  --cycle-b: var(--cycle-a);
    \\}
    \\body { color: red; background: url(a;b); }
    \\@media (max-width: 10px) { :root { --bg: #000; } }
    \\@media (prefers-color-scheme: light) {
    \\  :root { --bg: #fbfbf9; }
    \\}
    \\@font-face { src: url(x) }
    \\:root, .x { --late: #abc; }
;

test "css: scheme overrides only apply to their scheme" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sheet = try Sheet.parse(arena.allocator(), test_sheet);
    try std.testing.expectEqualStrings("#10120f", sheet.raw("--bg", .dark).?);
    try std.testing.expectEqualStrings("#fbfbf9", sheet.raw("--bg", .light).?);
    try std.testing.expectEqualStrings("#abc", sheet.raw("--late", .dark).?);
    try std.testing.expectEqualStrings("\"A; B\", sans-serif", sheet.raw("--font", .dark).?);
}

test "css: var resolution with fallback and cycles" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const sheet = try Sheet.parse(alloc, test_sheet);
    try std.testing.expectEqualStrings("#fbfbf9", (try sheet.resolve(alloc, "--alias", .light)).?);
    try std.testing.expectEqualStrings("#fff", (try sheet.resolve(alloc, "--missing", .dark)).?);
    try std.testing.expect(try sheet.resolve(alloc, "--cycle-a", .dark) == null);
}

test "css: colors" {
    const eq = std.testing.expectApproxEqAbs;
    const c = Color.parse("rgb(255 255 255 / 0.16)").?;
    try eq(1, c.r, 0.001);
    try eq(0.16, c.a, 0.001);
    const d = Color.parse("rgba(0, 128, 255, 50%)").?;
    try eq(128.0 / 255.0, d.g, 0.001);
    try eq(0.5, d.a, 0.001);
    const e = Color.parse("#10120f").?;
    try eq(0x12.0 / 255.0, e.g, 0.001);
    try eq(1, e.a, 0.001);
    try eq(0xaa.0 / 255.0, Color.parse("#abc8").?.r, 0.001);
    try eq(0x88.0 / 255.0, Color.parse("#abc8").?.a, 0.001);
    try std.testing.expect(Color.parse("#12345") == null);
    try std.testing.expect(Color.parse("rgb(1 2)") == null);
    try std.testing.expect(Color.parse("hsl(1 2 3)") == null);
}

test "css: malformed input does not crash" {
    const src = ":root { --a: var(--b; } @media (prefers-color-scheme: dark) { :root { --x: \"unterminated } } /* open";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (0..src.len + 1) |n| {
        const sheet = try Sheet.parse(arena.allocator(), src[0..n]);
        _ = try sheet.resolve(arena.allocator(), "--a", .dark);
    }
}

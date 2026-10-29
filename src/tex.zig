//! TeX math to MathML.
//!
//! Browsers render MathML natively (WebKit always has, Chromium since
//! 109), so converting at render time means published pages and the app
//! preview need no JavaScript and no math fonts of their own. KaTeX was
//! the alternative; it is ~300KB of script plus fonts per page.
//!
//! This covers the LaTeX people write in notes: scripts, fractions,
//! roots, Greek, operators and relations, \left/\right, accents, font
//! commands, \text, and the matrix/cases/aligned environments. It is not
//! TeX: there are no macros, no \def, and no layout beyond what MathML
//! gives us. Unknown commands render as an inline <merror> so a typo is
//! visible instead of silently dropped.
//!
//! The converter is a recursive descent parser that writes as it goes.
//! The only buffering is for a base that turns out to carry scripts
//! (`x^2` must become <msup> around the already-parsed `x`), which uses
//! the caller's allocator; an arena is expected.
//!
//! This module has no dependencies on the rest of naut and is exported as
//! its own Zig module, `tex`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = Writer.Error || Allocator.Error;

/// Write `src` as a `<math>` element. `display` selects block layout
/// (centered, limits above and below large operators).
pub fn render(alloc: Allocator, w: *Writer, src: []const u8, display: bool) Error!void {
    var p: Parser = .{ .alloc = alloc, .src = src, .display = display };
    try w.writeAll(if (display) "<math display=\"block\">" else "<math>");
    try w.writeAll("<mrow>");
    // At the top level a stray `}` or `&` is a user error; keep going
    // so the rest of the formula still renders.
    while (true) {
        try p.row(w);
        if (p.eof()) break;
        if (p.startsWith("\\\\")) {
            p.pos += 2;
        } else if (p.peek() == '\\') {
            // A stray \right or \end.
            const start = p.pos;
            p.pos += 1;
            while (!p.eof() and std.ascii.isAlphabetic(p.peek())) p.pos += 1;
            try unknown(w, p.src[start..p.pos]);
        } else {
            try w.writeAll("<merror><mtext>");
            try escape(w, p.src[p.pos .. p.pos + 1]);
            try w.writeAll("</mtext></merror>");
            p.pos += 1;
        }
    }
    try w.writeAll("</mrow></math>");
}

const Variant = enum { normal_italic, upright, bold, double_struck, script, fraktur, sans, mono };

/// What the last atom was, for choosing script layout.
const Kind = enum {
    ordinary,
    /// \sum, \lim and friends: limits go above and below in display mode.
    limits,
    /// \int: scripts always go to the side.
    nolimits,
};

const Parser = struct {
    alloc: Allocator,
    src: []const u8,
    pos: usize = 0,
    display: bool,
    variant: Variant = .normal_italic,
    /// Guards against stack overflow on adversarial input like 10k `{`.
    depth: u16 = 0,

    const max_depth = 256;

    fn eof(p: *const Parser) bool {
        return p.pos >= p.src.len;
    }

    fn peek(p: *const Parser) u8 {
        return if (p.eof()) 0 else p.src[p.pos];
    }

    fn startsWith(p: *const Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], s);
    }

    fn skipSpace(p: *Parser) void {
        while (!p.eof() and std.ascii.isWhitespace(p.src[p.pos])) p.pos += 1;
    }

    /// Parse atoms until something that ends a row: `}`, `&`, `\\`,
    /// `\right`, `\end`, or end of input. The terminator is not consumed.
    fn row(p: *Parser, w: *Writer) Error!void {
        while (true) {
            p.skipSpace();
            if (p.eof()) return;
            switch (p.peek()) {
                '}', '&' => return,
                '\\' => if (p.startsWith("\\\\") or p.startsWithCommand("right") or p.startsWithCommand("end")) return,
                else => {},
            }
            try p.scripted(w);
        }
    }

    fn startsWithCommand(p: *const Parser, name: []const u8) bool {
        const rest = p.src[p.pos..];
        if (rest.len < name.len + 1 or rest[0] != '\\') return false;
        if (!std.mem.eql(u8, rest[1 .. name.len + 1], name)) return false;
        return rest.len == name.len + 1 or !std.ascii.isAlphabetic(rest[name.len + 1]);
    }

    /// One atom plus any `^` and `_` after it.
    fn scripted(p: *Parser, w: *Writer) Error!void {
        var base: Writer.Allocating = .init(p.alloc);
        const kind = try p.atom(&base.writer, false);

        var sub: ?[]const u8 = null;
        var sup: ?[]const u8 = null;
        var limits = kind == .limits and p.display;
        while (true) {
            p.skipSpace();
            if (p.startsWithCommand("limits")) {
                p.pos += "\\limits".len;
                limits = true;
                continue;
            }
            if (p.startsWithCommand("nolimits")) {
                p.pos += "\\nolimits".len;
                limits = false;
                continue;
            }
            const c = p.peek();
            if (c == '\'') {
                // Primes are superscripts: f' is f^{\prime}.
                var n: usize = 0;
                while (p.peek() == '\'') : (p.pos += 1) n += 1;
                const primes = [_][]const u8{ "′", "″", "‴" };
                sup = try std.fmt.allocPrint(p.alloc, "<mo>{s}</mo>", .{primes[@min(n, 3) - 1]});
                continue;
            }
            if (c != '^' and c != '_') break;
            p.pos += 1;
            var script: Writer.Allocating = .init(p.alloc);
            try p.arg(&script.writer);
            if (c == '^') sup = script.written() else sub = script.written();
        }

        const b = base.written();
        if (sub == null and sup == null) return w.writeAll(b);
        const tags: [3][]const u8 = if (limits)
            .{ "munder", "mover", "munderover" }
        else
            .{ "msub", "msup", "msubsup" };
        const tag = if (sup == null) tags[0] else if (sub == null) tags[1] else tags[2];
        try w.print("<{s}>{s}", .{ tag, b });
        if (sub) |s| try w.writeAll(s);
        if (sup) |s| try w.writeAll(s);
        try w.print("</{s}>", .{tag});
    }

    /// A command or group argument: `{...}` as an <mrow>, or a single
    /// token. `\frac12` is ½, so a bare digit argument is one digit.
    fn arg(p: *Parser, w: *Writer) Error!void {
        p.skipSpace();
        _ = try p.atom(w, true);
    }

    /// Parse a `{...}` group (or a single token) and return its raw
    /// source without rendering it. For \text and \begin names.
    fn rawArg(p: *Parser) []const u8 {
        p.skipSpace();
        if (p.peek() != '{') {
            if (p.eof()) return "";
            p.pos += 1;
            return p.src[p.pos - 1 .. p.pos];
        }
        var depth: usize = 0;
        const start = p.pos + 1;
        while (!p.eof()) : (p.pos += 1) {
            switch (p.src[p.pos]) {
                '\\' => p.pos += 1,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        p.pos += 1;
                        return p.src[start .. p.pos - 1];
                    }
                },
                else => {},
            }
        }
        return p.src[start..];
    }

    fn atom(p: *Parser, w: *Writer, single: bool) Error!Kind {
        if (p.depth >= max_depth) {
            p.pos = p.src.len;
            try w.writeAll("<merror><mtext>too deeply nested</mtext></merror>");
            return .ordinary;
        }
        p.depth += 1;
        defer p.depth -= 1;

        p.skipSpace();
        if (p.eof()) {
            // A trailing `^` or `\frac{a}` with no argument: render an
            // empty row so the MathML stays well formed.
            try w.writeAll("<mrow></mrow>");
            return .ordinary;
        }

        const c = p.src[p.pos];
        switch (c) {
            '{' => {
                p.pos += 1;
                try w.writeAll("<mrow>");
                try p.row(w);
                try w.writeAll("</mrow>");
                if (p.peek() == '}') p.pos += 1;
                return .ordinary;
            },
            '\\' => return p.command(w),
            '0'...'9', '.' => {
                const start = p.pos;
                p.pos += 1;
                if (!single) {
                    while (!p.eof() and (std.ascii.isDigit(p.peek()) or
                        (p.peek() == '.' and p.pos + 1 < p.src.len and std.ascii.isDigit(p.src[p.pos + 1])))) p.pos += 1;
                }
                const num = p.src[start..p.pos];
                if (std.mem.eql(u8, num, ".")) {
                    try w.writeAll("<mo>.</mo>");
                } else {
                    try p.writeVariant(w, "mn", num);
                }
                return .ordinary;
            },
            'a'...'z', 'A'...'Z' => {
                p.pos += 1;
                try p.writeVariant(w, "mi", p.src[p.pos - 1 .. p.pos]);
                return .ordinary;
            },
            '}', '&', '^', '_' => {
                // Only reachable as a missing argument ("x^}"). Leave the
                // character for the caller.
                try w.writeAll("<mrow></mrow>");
                return .ordinary;
            },
            '~' => {
                p.pos += 1;
                try w.writeAll("<mspace width=\"0.25em\"></mspace>");
                return .ordinary;
            },
            else => {
                // Operators and anything else, one UTF-8 sequence at a time.
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const end = @min(p.pos + len, p.src.len);
                const s = p.src[p.pos..end];
                p.pos = end;
                const text = switch (c) {
                    '-' => "−",
                    '*' => "∗",
                    else => s,
                };
                const tag = if (c < 0x80) "mo" else "mi";
                // Bare brackets keep their natural size, as in TeX; only
                // \left/\right and \big stretch. MathML would otherwise
                // stretch them to the tallest thing in the row.
                const fence = switch (c) {
                    '(', ')', '[', ']', '|', '/' => true,
                    else => false,
                };
                try w.print("<{s}{s}>", .{ tag, if (fence) " stretchy=\"false\"" else "" });
                try escape(w, text);
                try w.print("</{s}>", .{tag});
                return .ordinary;
            },
        }
    }

    /// Letters and digits honour the current font command. Single letters
    /// in the default variant are left for the browser to italicise.
    fn writeVariant(p: *Parser, w: *Writer, tag: []const u8, s: []const u8) Error!void {
        switch (p.variant) {
            .normal_italic => {
                try w.print("<{s}>", .{tag});
                try escape(w, s);
            },
            .upright => {
                try w.print("<{s} mathvariant=\"normal\">", .{tag});
                try escape(w, s);
            },
            else => {
                // MathML Core only supports mathvariant="normal", so other
                // styles use the Unicode Mathematical Alphanumeric Symbols.
                try w.print("<{s} mathvariant=\"normal\">", .{tag});
                for (s) |ch| try writeStyled(w, p.variant, ch);
            },
        }
        try w.print("</{s}>", .{tag});
    }

    fn command(p: *Parser, w: *Writer) Error!Kind {
        assert(p.peek() == '\\');
        p.pos += 1;
        if (p.eof()) {
            try w.writeAll("<mo>\\</mo>");
            return .ordinary;
        }

        // Control symbols: \, \{ \% and friends are one character.
        if (!std.ascii.isAlphabetic(p.peek())) {
            const ch = p.src[p.pos];
            p.pos += 1;
            switch (ch) {
                ',' => try w.writeAll("<mspace width=\"0.1667em\"></mspace>"),
                ':', '>' => try w.writeAll("<mspace width=\"0.2222em\"></mspace>"),
                ';' => try w.writeAll("<mspace width=\"0.2778em\"></mspace>"),
                '!' => try w.writeAll("<mspace width=\"-0.1667em\"></mspace>"),
                ' ' => try w.writeAll("<mspace width=\"0.25em\"></mspace>"),
                '|' => try w.writeAll("<mo>‖</mo>"),
                '{', '}', '%', '$', '#', '&', '_' => {
                    try w.writeAll("<mo>");
                    try escape(w, &.{ch});
                    try w.writeAll("</mo>");
                },
                else => try unknown(w, p.src[p.pos - 2 .. p.pos]),
            }
            return .ordinary;
        }

        const start = p.pos;
        while (!p.eof() and std.ascii.isAlphabetic(p.peek())) p.pos += 1;
        const name = p.src[start..p.pos];

        if (symbols.get(name)) |s| {
            switch (s.kind) {
                .ident => try w.print("<mi>{s}</mi>", .{s.text}),
                .upright => try w.print("<mi mathvariant=\"normal\">{s}</mi>", .{s.text}),
                .op => try w.print("<mo>{s}</mo>", .{s.text}),
                .large => try w.print("<mo largeop=\"true\" movablelimits=\"true\">{s}</mo>", .{s.text}),
                .integral => try w.print("<mo largeop=\"true\">{s}</mo>", .{s.text}),
                // A thin space after the name, so \sin x is not "sinx".
                .func => try w.print("<mi>{s}</mi><mspace width=\"0.1667em\"></mspace>", .{name}),
                .func_limits => try w.print("<mo movablelimits=\"true\" form=\"prefix\">{s}</mo>", .{s.text}),
                .space => try w.print("<mspace width=\"{s}\"></mspace>", .{s.text}),
            }
            return switch (s.kind) {
                .large, .func_limits => .limits,
                .integral => .nolimits,
                else => .ordinary,
            };
        }

        if (accents.get(name)) |accent| {
            const tag = if (accent.under) "munder" else "mover";
            const attr = if (accent.under) "accentunder" else "accent";
            try w.print("<{s} {s}=\"true\">", .{ tag, attr });
            try p.arg(w);
            try w.print("<mo stretchy=\"{s}\">{s}</mo></{s}>", .{
                if (accent.stretchy) "true" else "false", accent.text, tag,
            });
            return .ordinary;
        }

        if (fonts.get(name)) |variant| {
            const saved = p.variant;
            p.variant = variant;
            defer p.variant = saved;
            try p.arg(w);
            return .ordinary;
        }

        if (std.mem.eql(u8, name, "frac") or std.mem.eql(u8, name, "dfrac") or
            std.mem.eql(u8, name, "tfrac") or std.mem.eql(u8, name, "cfrac"))
        {
            const style: ?[]const u8 = switch (name[0]) {
                'd', 'c' => "true",
                't' => "false",
                else => null,
            };
            if (style) |s| try w.print("<mstyle displaystyle=\"{s}\">", .{s});
            try w.writeAll("<mfrac>");
            try p.arg(w);
            try p.arg(w);
            try w.writeAll("</mfrac>");
            if (style != null) try w.writeAll("</mstyle>");
            return .ordinary;
        }

        if (std.mem.eql(u8, name, "binom")) {
            try w.writeAll("<mrow><mo>(</mo><mfrac linethickness=\"0\">");
            try p.arg(w);
            try p.arg(w);
            try w.writeAll("</mfrac><mo>)</mo></mrow>");
            return .ordinary;
        }

        if (std.mem.eql(u8, name, "sqrt")) {
            p.skipSpace();
            if (p.peek() == '[') {
                // \sqrt[n]{x}: the index is everything up to `]`.
                p.pos += 1;
                var index: Writer.Allocating = .init(p.alloc);
                try index.writer.writeAll("<mrow>");
                // Stop at anything that ends a row too: atom() leaves `}`
                // and `&` unconsumed, so waiting only for `]` would spin.
                while (!p.eof()) switch (p.peek()) {
                    ']', '}', '&' => break,
                    else => try p.scripted(&index.writer),
                };
                try index.writer.writeAll("</mrow>");
                if (p.peek() == ']') p.pos += 1;
                try w.writeAll("<mroot>");
                try p.arg(w);
                try w.writeAll(index.written());
                try w.writeAll("</mroot>");
            } else {
                try w.writeAll("<msqrt>");
                try p.arg(w);
                try w.writeAll("</msqrt>");
            }
            return .ordinary;
        }

        if (std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "textrm") or
            std.mem.eql(u8, name, "mbox") or std.mem.eql(u8, name, "textnormal"))
        {
            try w.writeAll("<mtext>");
            try escape(w, p.rawArg());
            try w.writeAll("</mtext>");
            return .ordinary;
        }

        if (std.mem.eql(u8, name, "operatorname")) {
            try w.writeAll("<mi mathvariant=\"normal\">");
            try escape(w, p.rawArg());
            try w.writeAll("</mi>");
            return .ordinary;
        }

        if (std.mem.eql(u8, name, "left")) return p.leftRight(w);

        if (std.mem.eql(u8, name, "big") or std.mem.eql(u8, name, "Big") or
            std.mem.eql(u8, name, "bigg") or std.mem.eql(u8, name, "Bigg") or
            std.mem.eql(u8, name, "bigl") or std.mem.eql(u8, name, "bigr") or
            std.mem.eql(u8, name, "Bigl") or std.mem.eql(u8, name, "Bigr"))
        {
            const size = switch (name.len) {
                3, 4 => if (name[0] == 'b') "1.2em" else "1.8em",
                else => if (name[0] == 'b') "2.4em" else "3em",
            };
            const delim = p.delimiter();
            try w.print("<mo stretchy=\"true\" minsize=\"{s}\" maxsize=\"{s}\">", .{ size, size });
            try escape(w, delim);
            try w.writeAll("</mo>");
            return .ordinary;
        }

        if (std.mem.eql(u8, name, "begin")) return p.environment(w);

        // \displaystyle and \textstyle switch the rest of the group.
        if (std.mem.eql(u8, name, "displaystyle") or std.mem.eql(u8, name, "textstyle")) {
            try w.print("<mstyle displaystyle=\"{s}\"><mrow>", .{if (name[0] == 'd') "true" else "false"});
            try p.row(w);
            try w.writeAll("</mrow></mstyle>");
            return .ordinary;
        }

        try unknown(w, p.src[start - 1 .. p.pos]);
        return .ordinary;
    }

    /// The delimiter after \left, \right or \big. "." means none.
    fn delimiter(p: *Parser) []const u8 {
        p.skipSpace();
        if (p.eof()) return "";
        if (p.peek() == '\\') {
            const start = p.pos;
            p.pos += 1;
            if (!p.eof() and !std.ascii.isAlphabetic(p.peek())) {
                p.pos += 1;
            } else {
                while (!p.eof() and std.ascii.isAlphabetic(p.peek())) p.pos += 1;
            }
            const name = p.src[start + 1 .. p.pos];
            if (name.len == 1) return switch (name[0]) {
                '{' => "{",
                '}' => "}",
                '|' => "‖",
                else => "",
            };
            if (symbols.get(name)) |s| return s.text;
            return "";
        }
        p.pos += 1;
        const d = p.src[p.pos - 1 .. p.pos];
        return if (std.mem.eql(u8, d, ".")) "" else d;
    }

    fn leftRight(p: *Parser, w: *Writer) Error!Kind {
        const open = p.delimiter();
        try w.writeAll("<mrow><mo fence=\"true\" stretchy=\"true\">");
        try escape(w, open);
        try w.writeAll("</mo>");
        try p.row(w);
        // Anything else that ended the row (`}`, `&`, `\\`, end of input)
        // means a missing \right; close with no delimiter and let the
        // caller handle the terminator.
        const close = if (p.startsWithCommand("right")) close: {
            p.pos += "\\right".len;
            break :close p.delimiter();
        } else "";
        try w.writeAll("<mo fence=\"true\" stretchy=\"true\">");
        try escape(w, close);
        try w.writeAll("</mo></mrow>");
        return .ordinary;
    }

    fn environment(p: *Parser, w: *Writer) Error!Kind {
        const name = p.rawArg();
        const env = environments.get(name) orelse {
            try unknown(w, name);
            return .ordinary;
        };
        // array takes a column spec like {cc|l}; we don't draw rules, so
        // it is only consumed.
        if (std.mem.eql(u8, name, "array")) _ = p.rawArg();

        try w.writeAll("<mrow>");
        if (env.open.len > 0) try w.print("<mo fence=\"true\" stretchy=\"true\">{s}</mo>", .{env.open});
        try w.print("<mtable{s}>", .{env.attrs});

        var done = false;
        while (!done) {
            try w.writeAll("<mtr>");
            while (true) {
                try w.writeAll("<mtd><mrow>");
                try p.row(w);
                try w.writeAll("</mrow></mtd>");
                if (p.peek() == '&') {
                    p.pos += 1;
                    continue;
                }
                break;
            }
            try w.writeAll("</mtr>");

            if (p.startsWith("\\\\")) {
                p.pos += 2;
                // A trailing \\ before \end adds no row.
                p.skipSpace();
                if (p.startsWithCommand("end")) done = true;
            } else {
                done = true;
            }
            if (p.peek() == '}') {
                // Unbalanced brace inside the environment; skip it.
                p.pos += 1;
                done = false;
            }
            if (p.eof()) break;
        }
        if (p.startsWithCommand("end")) {
            p.pos += "\\end".len;
            _ = p.rawArg();
        }

        try w.writeAll("</mtable>");
        if (env.close.len > 0) try w.print("<mo fence=\"true\" stretchy=\"true\">{s}</mo>", .{env.close});
        try w.writeAll("</mrow>");
        return .ordinary;
    }
};

fn unknown(w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeAll("<merror><mtext>");
    try escape(w, name);
    try w.writeAll("</mtext></merror>");
}

fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

/// Map an ASCII letter or digit to its Mathematical Alphanumeric Symbol.
/// Several double-struck, script and fraktur capitals predate that block
/// and live in Letterlike Symbols instead, hence the exception tables.
fn writeStyled(w: *Writer, variant: Variant, c: u8) Writer.Error!void {
    const upper: ?u21, const lower: ?u21, const digit: ?u21 = switch (variant) {
        .bold => .{ 0x1D400, 0x1D41A, 0x1D7CE },
        .double_struck => .{ 0x1D538, 0x1D552, 0x1D7D8 },
        .script => .{ 0x1D49C, 0x1D4B6, null },
        .fraktur => .{ 0x1D504, 0x1D51E, null },
        .sans => .{ 0x1D5A0, 0x1D5BA, 0x1D7E2 },
        .mono => .{ 0x1D670, 0x1D68A, 0x1D7F6 },
        .normal_italic, .upright => .{ null, null, null },
    };

    const exception: ?u21 = switch (variant) {
        .double_struck => switch (c) {
            'C' => 0x2102, 'H' => 0x210D, 'N' => 0x2115, 'P' => 0x2119,
            'Q' => 0x211A, 'R' => 0x211D, 'Z' => 0x2124, else => null,
        },
        .script => switch (c) {
            'B' => 0x212C, 'E' => 0x2130, 'F' => 0x2131, 'H' => 0x210B, 'I' => 0x2110,
            'L' => 0x2112, 'M' => 0x2133, 'R' => 0x211B, 'e' => 0x212F, 'g' => 0x210A,
            'o' => 0x2134, else => null,
        },
        .fraktur => switch (c) {
            'C' => 0x212D, 'H' => 0x210C, 'I' => 0x2111, 'R' => 0x211C, 'Z' => 0x2128, else => null,
        },
        else => null,
    };

    const cp: ?u21 = exception orelse switch (c) {
        'A'...'Z' => if (upper) |b| b + (c - 'A') else null,
        'a'...'z' => if (lower) |b| b + (c - 'a') else null,
        '0'...'9' => if (digit) |b| b + (c - '0') else null,
        else => null,
    };

    const point = cp orelse return escape(w, &.{c});
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(point, &buf) catch unreachable;
    try w.writeAll(buf[0..n]);
}

const Symbol = struct {
    kind: enum { ident, upright, op, large, integral, func, func_limits, space },
    text: []const u8,
};

fn sym(kind: @FieldType(Symbol, "kind"), text: []const u8) Symbol {
    return .{ .kind = kind, .text = text };
}

const symbols: std.StaticStringMap(Symbol) = .initComptime(.{
    // Greek lowercase: italic identifiers.
    .{ "alpha", sym(.ident, "α") },     .{ "beta", sym(.ident, "β") },         .{ "gamma", sym(.ident, "γ") },
    .{ "delta", sym(.ident, "δ") },     .{ "epsilon", sym(.ident, "ϵ") },      .{ "varepsilon", sym(.ident, "ε") },
    .{ "zeta", sym(.ident, "ζ") },      .{ "eta", sym(.ident, "η") },          .{ "theta", sym(.ident, "θ") },
    .{ "vartheta", sym(.ident, "ϑ") },  .{ "iota", sym(.ident, "ι") },         .{ "kappa", sym(.ident, "κ") },
    .{ "lambda", sym(.ident, "λ") },    .{ "mu", sym(.ident, "μ") },           .{ "nu", sym(.ident, "ν") },
    .{ "xi", sym(.ident, "ξ") },        .{ "pi", sym(.ident, "π") },           .{ "varpi", sym(.ident, "ϖ") },
    .{ "rho", sym(.ident, "ρ") },       .{ "varrho", sym(.ident, "ϱ") },       .{ "sigma", sym(.ident, "σ") },
    .{ "varsigma", sym(.ident, "ς") },  .{ "tau", sym(.ident, "τ") },          .{ "upsilon", sym(.ident, "υ") },
    .{ "phi", sym(.ident, "ϕ") },       .{ "varphi", sym(.ident, "φ") },       .{ "chi", sym(.ident, "χ") },
    .{ "psi", sym(.ident, "ψ") },       .{ "omega", sym(.ident, "ω") },
    // Greek uppercase: upright by convention.
    .{ "Gamma", sym(.upright, "Γ") },   .{ "Delta", sym(.upright, "Δ") },      .{ "Theta", sym(.upright, "Θ") },
    .{ "Lambda", sym(.upright, "Λ") },  .{ "Xi", sym(.upright, "Ξ") },         .{ "Pi", sym(.upright, "Π") },
    .{ "Sigma", sym(.upright, "Σ") },   .{ "Upsilon", sym(.upright, "Υ") },    .{ "Phi", sym(.upright, "Φ") },
    .{ "Psi", sym(.upright, "Ψ") },     .{ "Omega", sym(.upright, "Ω") },
    // Other identifiers.
    .{ "infty", sym(.upright, "∞") },   .{ "partial", sym(.upright, "∂") },    .{ "nabla", sym(.upright, "∇") },
    .{ "hbar", sym(.ident, "ℏ") },      .{ "ell", sym(.ident, "ℓ") },          .{ "emptyset", sym(.upright, "∅") },
    .{ "varnothing", sym(.upright, "∅") }, .{ "aleph", sym(.upright, "ℵ") },   .{ "Re", sym(.upright, "ℜ") },
    .{ "Im", sym(.upright, "ℑ") },      .{ "angle", sym(.upright, "∠") },      .{ "triangle", sym(.upright, "△") },
    .{ "prime", sym(.op, "′") },        .{ "dots", sym(.op, "…") },            .{ "ldots", sym(.op, "…") },
    .{ "cdots", sym(.op, "⋯") },        .{ "vdots", sym(.op, "⋮") },           .{ "ddots", sym(.op, "⋱") },
    // Binary operators.
    .{ "pm", sym(.op, "±") },           .{ "mp", sym(.op, "∓") },              .{ "times", sym(.op, "×") },
    .{ "div", sym(.op, "÷") },          .{ "cdot", sym(.op, "⋅") },            .{ "ast", sym(.op, "∗") },
    .{ "star", sym(.op, "⋆") },         .{ "circ", sym(.op, "∘") },            .{ "bullet", sym(.op, "∙") },
    .{ "oplus", sym(.op, "⊕") },        .{ "ominus", sym(.op, "⊖") },          .{ "otimes", sym(.op, "⊗") },
    .{ "cup", sym(.op, "∪") },          .{ "cap", sym(.op, "∩") },             .{ "setminus", sym(.op, "∖") },
    .{ "wedge", sym(.op, "∧") },        .{ "land", sym(.op, "∧") },            .{ "vee", sym(.op, "∨") },
    .{ "lor", sym(.op, "∨") },          .{ "neg", sym(.op, "¬") },             .{ "lnot", sym(.op, "¬") },
    // Relations.
    .{ "leq", sym(.op, "≤") },          .{ "le", sym(.op, "≤") },              .{ "geq", sym(.op, "≥") },
    .{ "ge", sym(.op, "≥") },           .{ "neq", sym(.op, "≠") },             .{ "ne", sym(.op, "≠") },
    .{ "approx", sym(.op, "≈") },       .{ "equiv", sym(.op, "≡") },           .{ "sim", sym(.op, "∼") },
    .{ "simeq", sym(.op, "≃") },        .{ "cong", sym(.op, "≅") },            .{ "propto", sym(.op, "∝") },
    .{ "ll", sym(.op, "≪") },           .{ "gg", sym(.op, "≫") },              .{ "in", sym(.op, "∈") },
    .{ "notin", sym(.op, "∉") },        .{ "ni", sym(.op, "∋") },              .{ "subset", sym(.op, "⊂") },
    .{ "supset", sym(.op, "⊃") },       .{ "subseteq", sym(.op, "⊆") },        .{ "supseteq", sym(.op, "⊇") },
    .{ "mid", sym(.op, "∣") },          .{ "parallel", sym(.op, "∥") },        .{ "perp", sym(.op, "⊥") },
    .{ "forall", sym(.op, "∀") },       .{ "exists", sym(.op, "∃") },          .{ "nexists", sym(.op, "∄") },
    .{ "models", sym(.op, "⊨") },       .{ "vdash", sym(.op, "⊢") },           .{ "coloneqq", sym(.op, "≔") },
    // Arrows.
    .{ "to", sym(.op, "→") },           .{ "rightarrow", sym(.op, "→") },      .{ "leftarrow", sym(.op, "←") },
    .{ "gets", sym(.op, "←") },         .{ "leftrightarrow", sym(.op, "↔") },  .{ "Rightarrow", sym(.op, "⇒") },
    .{ "Leftarrow", sym(.op, "⇐") },    .{ "Leftrightarrow", sym(.op, "⇔") },  .{ "implies", sym(.op, "⟹") },
    .{ "impliedby", sym(.op, "⟸") },    .{ "iff", sym(.op, "⟺") },             .{ "mapsto", sym(.op, "↦") },
    .{ "longrightarrow", sym(.op, "⟶") }, .{ "longleftarrow", sym(.op, "⟵") }, .{ "uparrow", sym(.op, "↑") },
    .{ "downarrow", sym(.op, "↓") },    .{ "hookrightarrow", sym(.op, "↪") },
    // Delimiters.
    .{ "langle", sym(.op, "⟨") },       .{ "rangle", sym(.op, "⟩") },          .{ "lvert", sym(.op, "|") },
    .{ "rvert", sym(.op, "|") },        .{ "vert", sym(.op, "|") },            .{ "lVert", sym(.op, "‖") },
    .{ "rVert", sym(.op, "‖") },        .{ "Vert", sym(.op, "‖") },            .{ "lfloor", sym(.op, "⌊") },
    .{ "rfloor", sym(.op, "⌋") },       .{ "lceil", sym(.op, "⌈") },           .{ "rceil", sym(.op, "⌉") },
    .{ "lbrace", sym(.op, "{") },       .{ "rbrace", sym(.op, "}") },
    // Large operators.
    .{ "sum", sym(.large, "∑") },       .{ "prod", sym(.large, "∏") },         .{ "coprod", sym(.large, "∐") },
    .{ "bigcup", sym(.large, "⋃") },    .{ "bigcap", sym(.large, "⋂") },       .{ "bigoplus", sym(.large, "⨁") },
    .{ "bigotimes", sym(.large, "⨂") }, .{ "bigvee", sym(.large, "⋁") },       .{ "bigwedge", sym(.large, "⋀") },
    .{ "int", sym(.integral, "∫") },    .{ "iint", sym(.integral, "∬") },      .{ "iiint", sym(.integral, "∭") },
    .{ "oint", sym(.integral, "∮") },
    // Function names: upright, scripts to the side.
    .{ "sin", sym(.func, "") },         .{ "cos", sym(.func, "") },            .{ "tan", sym(.func, "") },
    .{ "sec", sym(.func, "") },         .{ "csc", sym(.func, "") },            .{ "cot", sym(.func, "") },
    .{ "arcsin", sym(.func, "") },      .{ "arccos", sym(.func, "") },         .{ "arctan", sym(.func, "") },
    .{ "sinh", sym(.func, "") },        .{ "cosh", sym(.func, "") },           .{ "tanh", sym(.func, "") },
    .{ "log", sym(.func, "") },         .{ "ln", sym(.func, "") },             .{ "lg", sym(.func, "") },
    .{ "exp", sym(.func, "") },         .{ "dim", sym(.func, "") },            .{ "ker", sym(.func, "") },
    .{ "deg", sym(.func, "") },         .{ "arg", sym(.func, "") },            .{ "hom", sym(.func, "") },
    // Function names that take limits in display mode.
    .{ "lim", sym(.func_limits, "lim") }, .{ "liminf", sym(.func_limits, "lim inf") },
    .{ "limsup", sym(.func_limits, "lim sup") }, .{ "max", sym(.func_limits, "max") },
    .{ "min", sym(.func_limits, "min") }, .{ "sup", sym(.func_limits, "sup") },
    .{ "inf", sym(.func_limits, "inf") }, .{ "det", sym(.func_limits, "det") },
    .{ "gcd", sym(.func_limits, "gcd") }, .{ "Pr", sym(.func_limits, "Pr") },
    .{ "argmax", sym(.func_limits, "arg max") }, .{ "argmin", sym(.func_limits, "arg min") },
    // Spaces.
    .{ "quad", sym(.space, "1em") },    .{ "qquad", sym(.space, "2em") },
    .{ "thinspace", sym(.space, "0.1667em") }, .{ "enspace", sym(.space, "0.5em") },
});

const Accent = struct { text: []const u8, stretchy: bool = false, under: bool = false };

const accents: std.StaticStringMap(Accent) = .initComptime(.{
    .{ "hat", Accent{ .text = "^" } },
    .{ "widehat", Accent{ .text = "^", .stretchy = true } },
    .{ "tilde", Accent{ .text = "~" } },
    .{ "widetilde", Accent{ .text = "~", .stretchy = true } },
    .{ "bar", Accent{ .text = "¯" } },
    .{ "overline", Accent{ .text = "‾", .stretchy = true } },
    .{ "underline", Accent{ .text = "‾", .stretchy = true, .under = true } },
    .{ "vec", Accent{ .text = "→" } },
    .{ "overrightarrow", Accent{ .text = "→", .stretchy = true } },
    .{ "dot", Accent{ .text = "˙" } },
    .{ "ddot", Accent{ .text = "¨" } },
    .{ "acute", Accent{ .text = "´" } },
    .{ "grave", Accent{ .text = "`" } },
    .{ "check", Accent{ .text = "ˇ" } },
    .{ "breve", Accent{ .text = "˘" } },
    .{ "overbrace", Accent{ .text = "⏞", .stretchy = true } },
    .{ "underbrace", Accent{ .text = "⏟", .stretchy = true, .under = true } },
});

const fonts: std.StaticStringMap(Variant) = .initComptime(.{
    .{ "mathrm", .upright },     .{ "rm", .upright },        .{ "mathit", .normal_italic },
    .{ "mathbf", .bold },        .{ "bf", .bold },           .{ "boldsymbol", .bold },
    .{ "mathbb", .double_struck }, .{ "Bbb", .double_struck }, .{ "mathcal", .script },
    .{ "mathscr", .script },     .{ "mathfrak", .fraktur },  .{ "mathsf", .sans },
    .{ "mathtt", .mono },
});

const Environment = struct {
    open: []const u8 = "",
    close: []const u8 = "",
    attrs: []const u8 = "",
};

const aligned_attrs = " columnalign=\"right left right left right left\" columnspacing=\"0 1em 0 1em 0\" displaystyle=\"true\"";

const environments: std.StaticStringMap(Environment) = .initComptime(.{
    .{ "matrix", Environment{} },
    .{ "smallmatrix", Environment{} },
    .{ "array", Environment{} },
    .{ "pmatrix", Environment{ .open = "(", .close = ")" } },
    .{ "bmatrix", Environment{ .open = "[", .close = "]" } },
    .{ "Bmatrix", Environment{ .open = "{", .close = "}" } },
    .{ "vmatrix", Environment{ .open = "|", .close = "|" } },
    .{ "Vmatrix", Environment{ .open = "‖", .close = "‖" } },
    .{ "cases", Environment{ .open = "{", .attrs = " columnalign=\"left left\"" } },
    .{ "aligned", Environment{ .attrs = aligned_attrs } },
    .{ "align", Environment{ .attrs = aligned_attrs } },
    .{ "align*", Environment{ .attrs = aligned_attrs } },
    .{ "split", Environment{ .attrs = aligned_attrs } },
    .{ "gathered", Environment{ .attrs = " displaystyle=\"true\"" } },
    .{ "gather", Environment{ .attrs = " displaystyle=\"true\"" } },
    .{ "gather*", Environment{ .attrs = " displaystyle=\"true\"" } },
});

// --- Tests ------------------------------------------------------------------

fn expectMath(src: []const u8, display: bool, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    try render(arena.allocator(), &out.writer, src, display);
    const html = out.written();
    const prefix = if (display) "<math display=\"block\"><mrow>" else "<math><mrow>";
    try std.testing.expectStringStartsWith(html, prefix);
    try std.testing.expectStringEndsWith(html, "</mrow></math>");
    try std.testing.expectEqualStrings(expected, html[prefix.len .. html.len - "</mrow></math>".len]);
}

test "tex: identifiers numbers operators" {
    try expectMath("x + 12.5 - y", false, "<mi>x</mi><mo>+</mo><mn>12.5</mn><mo>−</mo><mi>y</mi>");
    try expectMath("f(x)", false, "<mi>f</mi><mo stretchy=\"false\">(</mo><mi>x</mi><mo stretchy=\"false\">)</mo>");
    try expectMath("\\sin x", false, "<mi>sin</mi><mspace width=\"0.1667em\"></mspace><mi>x</mi>");
}

test "tex: scripts" {
    try expectMath("x^2_i", false, "<msubsup><mi>x</mi><mi>i</mi><mn>2</mn></msubsup>");
    try expectMath("e^{i\\pi}", false, "<msup><mi>e</mi><mrow><mi>i</mi><mi>π</mi></mrow></msup>");
    try expectMath("f'", false, "<msup><mi>f</mi><mo>′</mo></msup>");
}

test "tex: frac with single-token arguments" {
    try expectMath("\\frac12", false, "<mfrac><mn>1</mn><mn>2</mn></mfrac>");
    try expectMath("\\frac{a}{b+c}", false, "<mfrac><mrow><mi>a</mi></mrow><mrow><mi>b</mi><mo>+</mo><mi>c</mi></mrow></mfrac>");
}

test "tex: sum takes limits only in display" {
    try expectMath("\\sum_{i}^n", true,
        "<munderover><mo largeop=\"true\" movablelimits=\"true\">∑</mo><mrow><mi>i</mi></mrow><mi>n</mi></munderover>");
    try expectMath("\\sum_i", false, "<msub><mo largeop=\"true\" movablelimits=\"true\">∑</mo><mi>i</mi></msub>");
    try expectMath("\\int_0^1", true, "<msubsup><mo largeop=\"true\">∫</mo><mn>0</mn><mn>1</mn></msubsup>");
}

test "tex: sqrt and root" {
    try expectMath("\\sqrt{x}", false, "<msqrt><mrow><mi>x</mi></mrow></msqrt>");
    try expectMath("\\sqrt[3]{x}", false, "<mroot><mrow><mi>x</mi></mrow><mrow><mn>3</mn></mrow></mroot>");
}

test "tex: left right" {
    try expectMath("\\left( x \\right]", false,
        "<mrow><mo fence=\"true\" stretchy=\"true\">(</mo><mi>x</mi><mo fence=\"true\" stretchy=\"true\">]</mo></mrow>");
    try expectMath("\\left\\{ x \\right.", false,
        "<mrow><mo fence=\"true\" stretchy=\"true\">{</mo><mi>x</mi><mo fence=\"true\" stretchy=\"true\"></mo></mrow>");
}

test "tex: fonts" {
    try expectMath("\\mathbb{R}\\mathbf{v}\\mathrm{d}x", false,
        "<mrow><mi mathvariant=\"normal\">ℝ</mi></mrow><mrow><mi mathvariant=\"normal\">𝐯</mi></mrow>" ++
            "<mrow><mi mathvariant=\"normal\">d</mi></mrow><mi>x</mi>");
}

test "tex: text is escaped" {
    try expectMath("\\text{a<b & c}", false, "<mtext>a&lt;b &amp; c</mtext>");
}

test "tex: matrix" {
    try expectMath("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", false,
        "<mrow><mo fence=\"true\" stretchy=\"true\">(</mo><mtable>" ++
            "<mtr><mtd><mrow><mi>a</mi></mrow></mtd><mtd><mrow><mi>b</mi></mrow></mtd></mtr>" ++
            "<mtr><mtd><mrow><mi>c</mi></mrow></mtd><mtd><mrow><mi>d</mi></mrow></mtd></mtr>" ++
            "</mtable><mo fence=\"true\" stretchy=\"true\">)</mo></mrow>");
}

test "tex: unknown command is visible" {
    try expectMath("\\foo x", false, "<merror><mtext>\\foo</mtext></merror><mi>x</mi>");
}

test "tex: html in input is escaped" {
    try expectMath("a<b>c", false, "<mi>a</mi><mo>&lt;</mo><mi>b</mi><mo>&gt;</mo><mi>c</mi>");
}

test "tex: malformed input does not crash" {
    const cases = [_][]const u8{
        "}",        "{",          "x^",         "\\frac{a}", "\\left(",  "\\right)",   "\\begin{matrix} a &",
        "\\sqrt[",  "\\",         "\\begin{x}", "&&\\\\",    "x_{y^{z", "\\text{a",  "\\left\\",
        "\\big",    "''''",       "\\end{x}",   "^_^_",      "\\mathbb", "\\begin",  "\\sum\\limits",
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |src| {
        for (0..src.len + 1) |n| {
            var out: Writer.Allocating = .init(arena.allocator());
            try render(arena.allocator(), &out.writer, src[0..n], true);
        }
    }
    // Regression: an unclosed root index inside a group or cell spun
    // forever because `}` and `&` were never consumed.
    for ([_][]const u8{ "{\\sqrt[3}", "\\sqrt[n & m]", "\\begin{matrix}\\sqrt[a&b\\end{matrix}" }) |src| {
        var o: Writer.Allocating = .init(arena.allocator());
        try render(arena.allocator(), &o.writer, src, false);
    }

    // Deep nesting is bounded rather than overflowing the stack.
    const deep: [10000]u8 = @splat('{');
    var out: Writer.Allocating = .init(arena.allocator());
    try render(arena.allocator(), &out.writer, &deep, false);
}

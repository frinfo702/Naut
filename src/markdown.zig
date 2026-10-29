//! Markdown to HTML.
//!
//! This is a deliberately small renderer: the subset people actually write
//! in notes (CommonMark blocks and inlines, GFM tables, task lists and
//! strikethrough) plus TeX math. It is not a full CommonMark
//! implementation. The emphasis rules in particular use "find the next
//! matching delimiter" rather than the spec's delimiter stack, which is
//! wrong for some pathological nestings and right for everything a person
//! types on purpose.
//!
//! The renderer never copies the source. Container blocks (block quotes,
//! list items) are rendered by recursing over a list of line slices that
//! point into the original input with their prefixes cut off.
//!
//! Raw HTML in the source is escaped, never passed through. Rendered pages
//! get published to the web, so a note must not be able to inject script.
//! For the same reason link destinations with a scheme other than http,
//! https or mailto are replaced with "#".
//!
//! Math and code are finished here too: `$x$` becomes MathML via the `tex`
//! module and fenced code is coloured by the `highlight` module. The
//! output needs no script to display correctly.

const std = @import("std");
const tex = @import("tex");
const highlight = @import("highlight");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// A heading found while rendering. Collected so the app can build an
/// outline without parsing the document twice.
pub const Heading = struct {
    /// 1 through 6.
    level: u3,
    /// Heading text with inline markup characters removed. Owned by the
    /// Renderer's allocator.
    text: []const u8,
    /// The `id` attribute written on the heading element. Unique within
    /// the document. Owned by the Renderer's allocator.
    id: []const u8,
};

pub const Renderer = struct {
    /// Used for the line lists of container blocks and for headings.
    /// An arena is the expected allocator: nothing is freed individually.
    alloc: Allocator,

    /// Every heading in document order.
    headings: std.ArrayList(Heading) = .empty,

    /// Number of times each heading slug has been used, so duplicates
    /// get "-1", "-2" suffixes like GitHub does.
    slugs: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(alloc: Allocator) Renderer {
        return .{ .alloc = alloc };
    }

    /// Render a whole document as an HTML fragment.
    pub fn render(self: *Renderer, w: *Writer, src: []const u8) Error!void {
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            try lines.append(self.alloc, std.mem.trimEnd(u8, line, "\r"));
        }
        try self.blocks(w, lines.items, false);
    }

    /// Render a sequence of blocks. `tight` is set inside tight list
    /// items, where paragraphs are written without `<p>`.
    fn blocks(self: *Renderer, w: *Writer, lines: []const []const u8, tight: bool) Error!void {
        var i: usize = 0;
        while (i < lines.len) {
            const line = lines[i];
            const t = trimIndent(line);

            if (isBlank(line)) {
                i += 1;
                continue;
            }

            if (atxHeading(t)) |h| {
                try self.heading(w, h.level, h.text);
                i += 1;
                continue;
            }

            if (isRule(t)) {
                try w.writeAll("<hr>\n");
                i += 1;
                continue;
            }

            if (fence(t)) |f| {
                i = try self.fencedCode(w, lines, i, f);
                continue;
            }

            if (std.mem.eql(u8, std.mem.trim(u8, t, " "), "$$")) {
                i = try self.displayMath(w, lines, i);
                continue;
            }

            if (t.len > 0 and t[0] == '>') {
                i = try self.blockquote(w, lines, i);
                continue;
            }

            if (listMarker(line) != null) {
                i = try self.list(w, lines, i);
                continue;
            }

            if (i + 1 < lines.len and isTableRow(t) and tableDelimiter(lines[i + 1]) != null) {
                i = try self.table(w, lines, i);
                continue;
            }

            i = try self.paragraph(w, lines, i, tight);
        }
    }

    fn heading(self: *Renderer, w: *Writer, level: u3, text: []const u8) Error!void {
        assert(level >= 1 and level <= 6);
        const plain = try stripMarkup(self.alloc, text);
        const id = try self.uniqueSlug(plain);
        try self.headings.append(self.alloc, .{ .level = level, .text = plain, .id = id });

        try w.print("<h{d} id=\"", .{level});
        try escape(w, id);
        try w.writeAll("\">");
        try self.inlines(w, text);
        try w.print("</h{d}>\n", .{level});
    }

    fn uniqueSlug(self: *Renderer, text: []const u8) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        for (text) |c| switch (c) {
            'A'...'Z' => try buf.append(self.alloc, c + 32),
            'a'...'z', '0'...'9', '-', '_' => try buf.append(self.alloc, c),
            ' ' => try buf.append(self.alloc, '-'),
            // Keep non-ASCII (UTF-8 continuation and lead bytes) so
            // Japanese headings get readable ids. Browsers accept them.
            0x80...0xff => try buf.append(self.alloc, c),
            else => {},
        };
        if (buf.items.len == 0) try buf.appendSlice(self.alloc, "section");

        const gop = try self.slugs.getOrPut(self.alloc, buf.items);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
            return buf.items;
        }
        // The suffixed form can collide too ("# a-1" then "# a" twice),
        // so keep counting until it is free, and reserve what we pick.
        while (true) {
            gop.value_ptr.* += 1;
            const candidate = try std.fmt.allocPrint(self.alloc, "{s}-{d}", .{ buf.items, gop.value_ptr.* });
            const taken = try self.slugs.getOrPut(self.alloc, candidate);
            if (taken.found_existing) continue;
            taken.value_ptr.* = 0;
            return candidate;
        }
    }

    fn fencedCode(self: *Renderer, w: *Writer, lines: []const []const u8, start: usize, fence_: Fence) Error!usize {
        var f = fence_;
        f.indent = indentOf(lines[start]);
        var body: std.ArrayList(u8) = .empty;
        var i = start + 1;
        while (i < lines.len) : (i += 1) {
            if (closesFence(trimIndent(lines[i]), f)) {
                i += 1;
                break;
            }
            if (i > start + 1) try body.append(self.alloc, '\n');
            // Content is de-indented by the fence's own indentation.
            try body.appendSlice(self.alloc, cutIndent(lines[i], f.indent));
        }
        // An unclosed fence runs to the end of the document, per spec.

        const info = std.mem.trim(u8, f.info, " ");
        // Only the first word is the language, like GitHub.
        const lang = info[0 .. std.mem.indexOfScalar(u8, info, ' ') orelse info.len];

        if (std.mem.eql(u8, lang, "math")) {
            try self.math(w, body.items, true);
            return i;
        }

        if (lang.len > 0) {
            try w.writeAll("<pre><code class=\"language-");
            try escape(w, lang);
            try w.writeAll("\">");
        } else {
            try w.writeAll("<pre><code>");
        }
        if (highlight.find(lang)) |l| {
            try highlight.render(w, l, body.items);
        } else {
            try escape(w, body.items);
        }
        try w.writeAll("</code></pre>\n");
        return i;
    }

    fn displayMath(self: *Renderer, w: *Writer, lines: []const []const u8, start: usize) Error!usize {
        // Lines may come from a block quote with their prefixes cut, so
        // they are not contiguous in the source; join them.
        var body: std.ArrayList(u8) = .empty;
        var i = start + 1;
        while (i < lines.len) : (i += 1) {
            if (std.mem.eql(u8, std.mem.trim(u8, lines[i], " "), "$$")) {
                i += 1;
                break;
            }
            try body.appendSlice(self.alloc, lines[i]);
            try body.append(self.alloc, '\n');
        }
        try self.math(w, body.items, true);
        return i;
    }

    fn math(self: *Renderer, w: *Writer, src: []const u8, display: bool) Error!void {
        if (display) try w.writeAll("<div class=\"math\">");
        try tex.render(self.alloc, w, src, display);
        if (display) try w.writeAll("</div>\n");
    }

    fn blockquote(self: *Renderer, w: *Writer, lines: []const []const u8, start: usize) Error!usize {
        var inner: std.ArrayList([]const u8) = .empty;
        var i = start;
        while (i < lines.len) : (i += 1) {
            const t = trimIndent(lines[i]);
            if (t.len == 0 or t[0] != '>') break;
            var rest = t[1..];
            if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            try inner.append(self.alloc, rest);
        }
        assert(i > start);

        try w.writeAll("<blockquote>\n");
        try self.blocks(w, inner.items, false);
        try w.writeAll("</blockquote>\n");
        return i;
    }

    fn list(self: *Renderer, w: *Writer, lines: []const []const u8, start: usize) Error!usize {
        const first = listMarker(lines[start]).?;
        const ordered = first.ordered;

        // Collect items first so we know whether the list is loose (any
        // blank line between items or inside an item) before writing.
        const Item = struct { lines: []const []const u8, task: ?bool };
        var items: std.ArrayList(Item) = .empty;
        var loose = false;

        var i = start;
        while (i < lines.len) {
            const m = listMarker(lines[i]) orelse break;
            if (m.ordered != ordered) break;

            var body: std.ArrayList([]const u8) = .empty;
            var content = lines[i][m.content..];
            var task: ?bool = null;
            if (taskBox(content)) |checked| {
                task = checked;
                content = content[3..];
                if (content.len > 0 and content[0] == ' ') content = content[1..];
            }
            try body.append(self.alloc, content);
            i += 1;

            // Continuation: lines indented at least to the content column,
            // and blank lines followed by such a line. Anything else ends
            // the item. Unindented non-blank lines directly after a
            // paragraph are lazy continuations of it.
            while (i < lines.len) {
                const line = lines[i];
                if (isBlank(line)) {
                    var j = i + 1;
                    while (j < lines.len and isBlank(lines[j])) j += 1;
                    if (j < lines.len and indentOf(lines[j]) >= m.content) {
                        loose = true;
                        while (i < j) : (i += 1) try body.append(self.alloc, "");
                        continue;
                    }
                    // Blank followed by the next item of this list: loose.
                    if (j < lines.len) {
                        if (listMarker(lines[j])) |n| {
                            if (n.ordered == ordered and indentOf(lines[j]) < m.content) loose = true;
                        }
                    }
                    break;
                }
                if (indentOf(line) >= m.content) {
                    try body.append(self.alloc, cutIndent(line, m.content));
                    i += 1;
                    continue;
                }
                if (listMarker(line) != null or startsBlock(trimIndent(line))) break;
                try body.append(self.alloc, line);
                i += 1;
            }

            try items.append(self.alloc, .{ .lines = body.items, .task = task });

            // Skip blanks between items; the loop above already noted
            // whether they make the list loose.
            while (i < lines.len and isBlank(lines[i])) i += 1;
        }
        assert(items.items.len > 0);

        if (ordered and first.number != 1) {
            try w.print("<ol start=\"{d}\">\n", .{first.number});
        } else {
            try w.writeAll(if (ordered) "<ol>\n" else "<ul>\n");
        }
        for (items.items) |item| {
            if (item.task) |checked| {
                try w.writeAll(if (checked)
                    "<li class=\"task\"><input type=\"checkbox\" checked disabled> "
                else
                    "<li class=\"task\"><input type=\"checkbox\" disabled> ");
            } else {
                try w.writeAll("<li>");
            }
            try self.blocks(w, item.lines, !loose);
            try w.writeAll("</li>\n");
        }
        try w.writeAll(if (ordered) "</ol>\n" else "</ul>\n");
        return i;
    }

    fn table(self: *Renderer, w: *Writer, lines: []const []const u8, start: usize) Error!usize {
        var align_buf: [64]Align = undefined;
        const aligns = tableDelimiter(lines[start + 1]).?;
        const ncols = @min(aligns.len, align_buf.len);
        for (0..ncols) |c| align_buf[c] = aligns.get(c);

        try w.writeAll("<div class=\"table\"><table>\n<thead>\n");
        try self.tableRow(w, lines[start], "th", align_buf[0..ncols]);
        try w.writeAll("</thead>\n<tbody>\n");
        var i = start + 2;
        while (i < lines.len and !isBlank(lines[i]) and isTableRow(trimIndent(lines[i]))) : (i += 1) {
            try self.tableRow(w, lines[i], "td", align_buf[0..ncols]);
        }
        try w.writeAll("</tbody>\n</table></div>\n");
        return i;
    }

    fn tableRow(self: *Renderer, w: *Writer, line: []const u8, tag: []const u8, aligns: []const Align) Error!void {
        try w.writeAll("<tr>");
        var cells = CellIterator.init(line);
        for (aligns) |a| {
            const cell = cells.next() orelse "";
            switch (a) {
                .none => try w.print("<{s}>", .{tag}),
                else => try w.print("<{s} style=\"text-align:{s}\">", .{ tag, @tagName(a) }),
            }
            try self.inlines(w, cell);
            try w.print("</{s}>", .{tag});
        }
        try w.writeAll("</tr>\n");
    }

    fn paragraph(self: *Renderer, w: *Writer, lines: []const []const u8, start: usize, tight: bool) Error!usize {
        var i = start + 1;
        while (i < lines.len) : (i += 1) {
            const t = trimIndent(lines[i]);
            if (isBlank(lines[i]) or startsBlock(t) or listMarker(lines[i]) != null) break;
        }
        assert(i > start);

        if (!tight) try w.writeAll("<p>");
        for (lines[start..i], 0..) |line, n| {
            const is_last = n == i - start - 1;
            const content = trimIndent(line);
            // Two trailing spaces or a trailing backslash is a hard break.
            if (!is_last and std.mem.endsWith(u8, content, "  ")) {
                try self.inlines(w, std.mem.trimEnd(u8, content, " "));
                try w.writeAll("<br>\n");
            } else if (!is_last and std.mem.endsWith(u8, content, "\\")) {
                try self.inlines(w, content[0 .. content.len - 1]);
                try w.writeAll("<br>\n");
            } else {
                try self.inlines(w, std.mem.trimEnd(u8, content, " "));
                if (!is_last) try w.writeByte('\n');
            }
        }
        try w.writeAll(if (tight) "\n" else "</p>\n");
        return i;
    }

    /// Render inline content.
    fn inlines(self: *Renderer, w: *Writer, text: []const u8) Error!void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            switch (c) {
                '\\' => if (i + 1 < text.len and isPunct(text[i + 1])) {
                    try escapeByte(w, text[i + 1]);
                    i += 2;
                    continue;
                },

                '`' => if (codeSpan(text, i)) |span| {
                    try w.writeAll("<code>");
                    try escape(w, span.content);
                    try w.writeAll("</code>");
                    i = span.end;
                    continue;
                },

                '$' => if (inlineMath(text, i)) |span| {
                    try self.math(w, span.content, false);
                    i = span.end;
                    continue;
                },

                '*', '_', '~' => if (emphasis(text, i)) |span| {
                    const tag: []const u8 = switch (span.kind) {
                        .em => "em",
                        .strong => "strong",
                        .strong_em => "strong><em",
                        .del => "del",
                    };
                    const close: []const u8 = switch (span.kind) {
                        .em => "em",
                        .strong => "strong",
                        .strong_em => "em></strong",
                        .del => "del",
                    };
                    try w.print("<{s}>", .{tag});
                    try self.inlines(w, span.content);
                    try w.print("</{s}>", .{close});
                    i = span.end;
                    continue;
                },

                '!' => if (i + 1 < text.len and text[i + 1] == '[') {
                    if (link(text, i + 1)) |l| {
                        try w.writeAll("<img src=\"");
                        try escapeUrl(w, l.url);
                        try w.writeAll("\" alt=\"");
                        try escape(w, try stripMarkup(self.alloc, l.label));
                        try w.writeByte('"');
                        try writeTitle(w, l.title);
                        try w.writeByte('>');
                        i = l.end;
                        continue;
                    }
                },

                '[' => if (link(text, i)) |l| {
                    try w.writeAll("<a href=\"");
                    try escapeUrl(w, l.url);
                    try w.writeByte('"');
                    try writeTitle(w, l.title);
                    try w.writeByte('>');
                    try self.inlines(w, l.label);
                    try w.writeAll("</a>");
                    i = l.end;
                    continue;
                },

                '<' => if (autolink(text, i)) |l| {
                    try w.writeAll("<a href=\"");
                    try escapeUrl(w, l.url);
                    try w.writeAll("\">");
                    try escape(w, l.url);
                    try w.writeAll("</a>");
                    i = l.end;
                    continue;
                },

                else => {},
            }

            try escapeByte(w, c);
            i += 1;
        }
    }
};

pub const Error = Writer.Error || Allocator.Error;

// --- Block helpers ----------------------------------------------------------

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| switch (c) {
        ' ' => n += 1,
        '\t' => n += 4 - (n % 4),
        else => break,
    };
    return n;
}

/// Strip up to three spaces of indentation, the amount CommonMark allows
/// before a block marker.
fn trimIndent(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < 3 and i < line.len and line[i] == ' ') i += 1;
    return line[i..];
}

/// Remove `n` columns of leading whitespace. A tab counts as one column
/// here; mixing tabs and spaces inside list items is rare enough that we
/// do not track tab stops.
fn cutIndent(line: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    while (i < n and i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[i..];
}

fn startsBlock(t: []const u8) bool {
    if (t.len == 0) return false;
    return atxHeading(t) != null or isRule(t) or fence(t) != null or t[0] == '>' or
        std.mem.eql(u8, std.mem.trim(u8, t, " "), "$$");
}

const AtxHeading = struct { level: u3, text: []const u8 };

fn atxHeading(t: []const u8) ?AtxHeading {
    var n: usize = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < t.len and t[n] != ' ' and t[n] != '\t') return null;

    var text = std.mem.trim(u8, t[n..], " \t");
    // Optional closing sequence: "## Title ##".
    const closing = std.mem.trimEnd(u8, text, "#");
    if (closing.len == 0) {
        text = closing;
    } else if (closing.len < text.len and closing[closing.len - 1] == ' ') {
        text = std.mem.trimEnd(u8, closing, " ");
    }
    return .{ .level = @intCast(n), .text = text };
}

fn isRule(t: []const u8) bool {
    if (t.len == 0) return false;
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var count: usize = 0;
    for (t) |x| {
        if (x == c) {
            count += 1;
        } else if (x != ' ' and x != '\t') {
            return false;
        }
    }
    return count >= 3;
}

const Fence = struct {
    char: u8,
    len: usize,
    indent: usize,
    info: []const u8,
};

fn fence(t: []const u8) ?Fence {
    if (t.len < 3 or (t[0] != '`' and t[0] != '~')) return null;
    const c = t[0];
    var n: usize = 0;
    while (n < t.len and t[n] == c) n += 1;
    if (n < 3) return null;
    const info = t[n..];
    // Backtick fences may not have backticks in the info string, otherwise
    // "```inline```" on its own line would open a block.
    if (c == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    // indent is filled in by the caller, which has the untrimmed line.
    return .{ .char = c, .len = n, .indent = 0, .info = info };
}

fn closesFence(t: []const u8, f: Fence) bool {
    var n: usize = 0;
    while (n < t.len and t[n] == f.char) n += 1;
    return n >= f.len and std.mem.trim(u8, t[n..], " \t").len == 0;
}

const ListMarker = struct {
    ordered: bool,
    number: u32,
    /// Column where the item content starts.
    content: usize,
};

fn listMarker(line: []const u8) ?ListMarker {
    const indent = indentOf(line);
    if (indent > 3) return null;
    const t = trimIndent(line);
    if (t.len == 0) return null;

    if (t[0] == '-' or t[0] == '*' or t[0] == '+') {
        // "- - -" and "***" are rules, not lists.
        if (isRule(t)) return null;
        if (t.len == 1) return .{ .ordered = false, .number = 0, .content = indent + 1 };
        if (t[1] != ' ' and t[1] != '\t') return null;
        return .{ .ordered = false, .number = 0, .content = indent + 2 };
    }

    var n: usize = 0;
    while (n < t.len and n < 9 and std.ascii.isDigit(t[n])) n += 1;
    if (n == 0 or n >= t.len) return null;
    if (t[n] != '.' and t[n] != ')') return null;
    if (n + 1 < t.len and t[n + 1] != ' ') return null;
    const number = std.fmt.parseInt(u32, t[0..n], 10) catch return null;
    // "1." at the end of a line has no space, so content starts right
    // after the marker.
    const space: usize = if (n + 1 < t.len) 1 else 0;
    return .{ .ordered = true, .number = number, .content = indent + n + 1 + space };
}

/// `[ ]` or `[x]` at the start of a list item, followed by space or end.
fn taskBox(content: []const u8) ?bool {
    if (content.len < 3 or content[0] != '[' or content[2] != ']') return null;
    if (content.len > 3 and content[3] != ' ') return null;
    return switch (content[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => null,
    };
}

const Align = enum { none, left, center, right };

const Aligns = struct {
    line: []const u8,
    len: usize,

    fn get(self: Aligns, idx: usize) Align {
        var it = CellIterator.init(self.line);
        var n: usize = 0;
        while (it.next()) |cell| : (n += 1) {
            if (n != idx) continue;
            const l = cell.len > 0 and cell[0] == ':';
            const r = cell.len > 0 and cell[cell.len - 1] == ':';
            return if (l and r) .center else if (r) .right else if (l) .left else .none;
        }
        return .none;
    }
};

fn isTableRow(t: []const u8) bool {
    return std.mem.indexOfScalar(u8, t, '|') != null;
}

/// Parse a GFM delimiter row like `| :--- | ---: |`.
fn tableDelimiter(line: []const u8) ?Aligns {
    const t = trimIndent(line);
    if (!isTableRow(t)) return null;
    var it = CellIterator.init(t);
    var n: usize = 0;
    while (it.next()) |cell| : (n += 1) {
        if (cell.len == 0) return null;
        for (cell) |c| if (c != '-' and c != ':') return null;
        if (std.mem.indexOfScalar(u8, cell, '-') == null) return null;
    }
    if (n == 0) return null;
    return .{ .line = t, .len = n };
}

/// Splits a table row on unescaped pipes, ignoring the optional leading
/// and trailing pipe. Pipes inside code spans are not special-cased.
const CellIterator = struct {
    rest: []const u8,

    fn init(line: []const u8) CellIterator {
        var t = std.mem.trim(u8, line, " \t");
        if (t.len > 0 and t[0] == '|') t = t[1..];
        if (t.len > 0 and t[t.len - 1] == '|' and !(t.len > 1 and t[t.len - 2] == '\\')) t = t[0 .. t.len - 1];
        return .{ .rest = t };
    }

    fn next(self: *CellIterator) ?[]const u8 {
        if (self.rest.len == 0) return null;
        var i: usize = 0;
        while (i < self.rest.len) : (i += 1) {
            if (self.rest[i] == '\\') {
                i += 1;
            } else if (self.rest[i] == '|') {
                const cell = self.rest[0..i];
                self.rest = self.rest[i + 1 ..];
                // Keep a trailing empty cell reachable: "a|" yields "a", "".
                if (self.rest.len == 0) self.rest = " ";
                return std.mem.trim(u8, cell, " \t");
            }
        }
        const cell = self.rest;
        self.rest = "";
        return std.mem.trim(u8, cell, " \t");
    }
};

// --- Inline helpers ---------------------------------------------------------

const Span = struct { content: []const u8, end: usize };

fn codeSpan(text: []const u8, start: usize) ?Span {
    var n: usize = 0;
    while (start + n < text.len and text[start + n] == '`') n += 1;
    var i = start + n;
    while (i < text.len) {
        if (text[i] != '`') {
            i += 1;
            continue;
        }
        var m: usize = 0;
        while (i + m < text.len and text[i + m] == '`') m += 1;
        if (m == n) {
            var content = text[start + n .. i];
            // One leading and trailing space is stripped so `` `x` `` works.
            if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ' and
                std.mem.trim(u8, content, " ").len > 0)
            {
                content = content[1 .. content.len - 1];
            }
            return .{ .content = content, .end = i + m };
        }
        i += m;
    }
    return null;
}

/// `$...$` math. To keep "costs $5 and $10" as text, the opening `$` must
/// not be followed by whitespace, the closing `$` must not be preceded by
/// whitespace, and must not be followed by a digit (Pandoc's rule).
fn inlineMath(text: []const u8, start: usize) ?Span {
    assert(text[start] == '$');
    const open = start + 1;
    if (open >= text.len or text[open] == ' ' or text[open] == '$') return null;
    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => i += 1,
            '$' => {
                if (text[i - 1] == ' ') return null;
                if (i + 1 < text.len and std.ascii.isDigit(text[i + 1])) return null;
                return .{ .content = text[open..i], .end = i + 1 };
            },
            else => {},
        }
    }
    return null;
}

const Emphasis = struct {
    kind: enum { em, strong, strong_em, del },
    content: []const u8,
    end: usize,
};

fn emphasis(text: []const u8, start: usize) ?Emphasis {
    const c = text[start];
    var n: usize = 0;
    while (start + n < text.len and text[start + n] == c) n += 1;

    if (c == '~') {
        if (n != 2) return null;
    } else {
        n = @min(n, 3);
    }

    const open = start + n;
    // Left-flanking: the run must be followed by non-whitespace.
    if (open >= text.len or std.ascii.isWhitespace(text[open])) return null;
    // Intraword underscores ("snake_case_name") are not emphasis.
    if (c == '_' and start > 0 and std.ascii.isAlphanumeric(text[start - 1])) return null;

    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => {
                i += 1;
                continue;
            },
            // Skip code spans so `*` inside code never closes emphasis.
            '`' => {
                if (codeSpan(text, i)) |span| i = span.end - 1;
                continue;
            },
            else => {},
        }
        if (text[i] != c) continue;
        var m: usize = 0;
        while (i + m < text.len and text[i + m] == c) m += 1;
        // Right-flanking: preceded by non-whitespace, and the run is
        // long enough to close what we opened.
        if (m >= n and !std.ascii.isWhitespace(text[i - 1])) {
            if (c == '_' and i + n < text.len and std.ascii.isAlphanumeric(text[i + n])) {
                i += m - 1;
                continue;
            }
            return .{
                .kind = if (c == '~') .del else switch (n) {
                    1 => .em,
                    2 => .strong,
                    else => .strong_em,
                },
                .content = text[open..i],
                .end = i + n,
            };
        }
        i += m - 1;
    }
    return null;
}

const Link = struct {
    label: []const u8,
    url: []const u8,
    title: ?[]const u8,
    end: usize,
};

/// `[label](url "title")` starting at the `[`.
fn link(text: []const u8, start: usize) ?Link {
    assert(text[start] == '[');
    var depth: usize = 0;
    var i = start;
    const close = while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => i += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) break i;
            },
            else => {},
        }
    } else return null;

    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    var j = close + 2;
    var parens: usize = 0;
    const dest_end = while (j < text.len) : (j += 1) {
        switch (text[j]) {
            '\\' => j += 1,
            '(' => parens += 1,
            ')' => {
                if (parens == 0) break j;
                parens -= 1;
            },
            else => {},
        }
    } else return null;

    var dest = std.mem.trim(u8, text[close + 2 .. dest_end], " ");
    var title: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, dest, ' ')) |sp| {
        const t = std.mem.trim(u8, dest[sp..], " ");
        if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') title = t[1 .. t.len - 1];
        dest = dest[0..sp];
    }
    if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];

    return .{
        .label = text[start + 1 .. close],
        .url = dest,
        .title = title,
        .end = dest_end + 1,
    };
}

fn autolink(text: []const u8, start: usize) ?Link {
    const end = std.mem.indexOfScalarPos(u8, text, start, '>') orelse return null;
    const url = text[start + 1 .. end];
    if (std.mem.indexOfAny(u8, url, " <") != null) return null;
    if (!std.mem.startsWith(u8, url, "http://") and
        !std.mem.startsWith(u8, url, "https://") and
        !std.mem.startsWith(u8, url, "mailto:")) return null;
    return .{ .label = url, .url = url, .title = null, .end = end + 1 };
}

fn writeTitle(w: *Writer, title: ?[]const u8) Writer.Error!void {
    const t = title orelse return;
    try w.writeAll(" title=\"");
    try escape(w, t);
    try w.writeByte('"');
}

fn isPunct(c: u8) bool {
    return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
}

/// Remove inline markup characters for plain-text uses (outline, alt).
fn stripMarkup(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| switch (c) {
        '*', '_', '`', '~', '\\' => {},
        else => try out.append(alloc, c),
    };
    return out.items;
}

// --- Escaping ---------------------------------------------------------------

pub fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| try escapeByte(w, c);
}

fn escapeByte(w: *Writer, c: u8) Writer.Error!void {
    switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    }
}

/// Write a link destination, refusing schemes that can run code.
/// Anything with a scheme other than http, https or mailto becomes "#".
/// Relative URLs and fragments pass through.
fn escapeUrl(w: *Writer, url: []const u8) Writer.Error!void {
    if (std.mem.indexOfScalar(u8, url, ':')) |colon| {
        const slash = std.mem.indexOfAny(u8, url, "/?#") orelse url.len;
        // A colon after the first "/", "?" or "#" is not a scheme
        // separator ("a/b:c" and "#x:y" are relative).
        if (colon < slash) {
            const scheme = url[0..colon];
            const allowed = std.ascii.eqlIgnoreCase(scheme, "http") or
                std.ascii.eqlIgnoreCase(scheme, "https") or
                std.ascii.eqlIgnoreCase(scheme, "mailto");
            if (!allowed) return w.writeByte('#');
        }
    }
    try escape(w, url);
}

// --- Tests ------------------------------------------------------------------

fn expectHtml(src: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var r: Renderer = .init(arena.allocator());
    try r.render(&out.writer, src);
    if (expected.ptr == expectAny.ptr) return;
    try std.testing.expectEqualStrings(expected, out.written());
}

test "markdown: headings get unique ids" {
    try expectHtml("# Hello World\n## Hello World\n## Hello World ##",
        \\<h1 id="hello-world">Hello World</h1>
        \\<h2 id="hello-world-1">Hello World</h2>
        \\<h2 id="hello-world-2">Hello World</h2>
        \\
    );
}

test "markdown: japanese heading id" {
    try expectHtml("## 数式", "<h2 id=\"数式\">数式</h2>\n");
}

test "markdown: paragraph inlines" {
    try expectHtml("a **b** *c* `d` ~~e~~ ***f***",
        "<p>a <strong>b</strong> <em>c</em> <code>d</code> <del>e</del> <strong><em>f</em></strong></p>\n");
}

test "markdown: intraword underscore is literal" {
    try expectHtml("snake_case_name", "<p>snake_case_name</p>\n");
}

test "markdown: star inside code does not close emphasis" {
    try expectHtml("*a `*` b*", "<p><em>a <code>*</code> b</em></p>\n");
}

test "markdown: raw html is escaped" {
    try expectHtml("<script>alert(1)</script>", "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n");
}

test "markdown: javascript links are neutralised" {
    try expectHtml("[x](javascript:alert(1)) [y](https://a.b) [z](./c:d)",
        "<p><a href=\"#\">x</a> <a href=\"https://a.b\">y</a> <a href=\"./c:d\">z</a></p>\n");
}

test "markdown: images and autolinks" {
    try expectHtml("![a *b*](i.png \"t\") <https://x.y>",
        "<p><img src=\"i.png\" alt=\"a b\" title=\"t\"> <a href=\"https://x.y\">https://x.y</a></p>\n");
}

test "markdown: inline math and dollars" {
    try expectHtml("$a<b$ costs $5 and $10",
        "<p><math><mrow><mi>a</mi><mo>&lt;</mo><mi>b</mi></mrow></math> costs $5 and $10</p>\n");
}

test "markdown: display math" {
    try expectHtml("$$\nx\n$$", "<div class=\"math\"><math display=\"block\"><mrow><mi>x</mi></mrow></math></div>\n");
}

test "markdown: fenced code" {
    try expectHtml("```zig foo\nconst a = 1 < 2;\n\n```\n```math\nx\n```\n```nope\nif\n```",
        "<pre><code class=\"language-zig\"><span class=\"hl-kw\">const</span> a = <span class=\"hl-num\">1</span> &lt; <span class=\"hl-num\">2</span>;\n</code></pre>\n" ++
            "<div class=\"math\"><math display=\"block\"><mrow><mi>x</mi></mrow></math></div>\n" ++
            "<pre><code class=\"language-nope\">if</code></pre>\n");
}

test "markdown: unclosed fence runs to end" {
    try expectHtml("```\na", "<pre><code>a</code></pre>\n");
}

test "markdown: tight nested list" {
    try expectHtml("- a\n  - b\n- c",
        \\<ul>
        \\<li>a
        \\<ul>
        \\<li>b
        \\</li>
        \\</ul>
        \\</li>
        \\<li>c
        \\</li>
        \\</ul>
        \\
    );
}

test "markdown: loose ordered list" {
    try expectHtml("3. a\n\n4. b",
        \\<ol start="3">
        \\<li><p>a</p>
        \\</li>
        \\<li><p>b</p>
        \\</li>
        \\</ol>
        \\
    );
}

test "markdown: task list" {
    try expectHtml("- [ ] a\n- [x] b",
        \\<ul>
        \\<li class="task"><input type="checkbox" disabled> a
        \\</li>
        \\<li class="task"><input type="checkbox" checked disabled> b
        \\</li>
        \\</ul>
        \\
    );
}

test "markdown: rule is not a list" {
    try expectHtml("- - -\n***", "<hr>\n<hr>\n");
}

test "markdown: blockquote nests blocks" {
    try expectHtml("> # t\n> - a", "<blockquote>\n<h1 id=\"t\">t</h1>\n<ul>\n<li>a\n</li>\n</ul>\n</blockquote>\n");
}

test "markdown: table with alignment" {
    try expectHtml("| a | b |\n|:--|--:|\n| `x` | y |\n",
        "<div class=\"table\"><table>\n<thead>\n" ++
            "<tr><th style=\"text-align:left\">a</th><th style=\"text-align:right\">b</th></tr>\n" ++
            "</thead>\n<tbody>\n" ++
            "<tr><td style=\"text-align:left\"><code>x</code></td><td style=\"text-align:right\">y</td></tr>\n" ++
            "</tbody>\n</table></div>\n");
}

test "markdown: ordered marker at end of line" {
    // Regression: content offset pointed past the end of "1.".
    try expectHtml("1.\nfoo", "<ol>\n<li>foo\n</li>\n</ol>\n");
}

test "markdown: suffixed slugs stay unique" {
    try expectHtml("# a-1\n# a\n# a",
        "<h1 id=\"a-1\">a-1</h1>\n<h1 id=\"a\">a</h1>\n<h1 id=\"a-2\">a</h1>\n");
}

test "markdown: indented fence content is de-indented" {
    try expectHtml("  ```\n  x\n    y\n  ```", "<pre><code>x\n  y</code></pre>\n");
}

test "markdown: hard breaks" {
    try expectHtml("a  \nb\\\nc", "<p>a<br>\nb<br>\nc</p>\n");
}

test "markdown: collects headings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var r: Renderer = .init(arena.allocator());
    try r.render(&out.writer, "# A *b*\ntext\n## C");
    try std.testing.expectEqual(2, r.headings.items.len);
    try std.testing.expectEqualStrings("A b", r.headings.items[0].text);
    try std.testing.expectEqualStrings("c", r.headings.items[1].id);
}

test "markdown: unbalanced input does not crash" {
    // Every prefix of a document full of half-open constructs.
    const src = "# *a [b](c `d $e ~~f\n> - [ ] | x |\n|-|\n```\n$$\n1. ";
    for (0..src.len) |n| try expectHtml(src[0..n], expectAny);
}

/// Sentinel for tests that only care that rendering succeeds.
const expectAny = "\x00any";

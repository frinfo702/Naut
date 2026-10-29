//! Syntax highlighting for code blocks.
//!
//! A single lexer driven by per-language tables (keywords, comment and
//! string syntax). That is far less precise than a real grammar, and
//! precise enough for reading code in notes: the goal is to colour
//! keywords, strings, numbers, comments and calls the way an editor
//! would at a glance, without shipping highlight.js to every page.
//!
//! Output is the escaped source with `<span class="hl-...">` around
//! tokens. Classes: hl-kw (keyword, or the command word in shell),
//! hl-str, hl-num, hl-com, hl-fn (called function, or object key),
//! hl-var (shell variable).
//!
//! This module has no dependencies on the rest of naut and is exported as
//! its own Zig module, `highlight`.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Language = struct {
    keywords: []const []const u8,
    /// Each starts a comment that runs to end of line.
    line_comments: []const []const u8 = &.{},
    block_comment: ?[2][]const u8 = null,
    /// Characters that open a string closed by the same character.
    quotes: []const u8 = "\"'",
    /// Shell rules: the first word of each command is the "keyword" and
    /// `$name` is a variable.
    shell: bool = false,
};

/// Look up a language by the name in a code fence. Case-insensitive.
pub fn find(name: []const u8) ?*const Language {
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return null;
    return languages.get(std.ascii.lowerString(&buf, name));
}

/// Write `code` as escaped HTML with highlight spans.
pub fn render(w: *Writer, lang: *const Language, code: []const u8) Writer.Error!void {
    var lx: Lexer = .{ .lang = lang, .src = code };
    while (lx.next()) |tok| {
        const text = code[tok.start..tok.end];
        if (tok.class) |class| {
            try w.print("<span class=\"hl-{s}\">", .{@tagName(class)});
            try escape(w, text);
            try w.writeAll("</span>");
        } else {
            try escape(w, text);
        }
    }
}

const Class = enum { kw, str, num, com, @"fn", @"var" };

const Token = struct {
    start: usize,
    end: usize,
    class: ?Class,
};

const Lexer = struct {
    lang: *const Language,
    src: []const u8,
    pos: usize = 0,
    /// Shell: true until the first word of the current command is seen.
    command_start: bool = true,

    fn next(lx: *Lexer) ?Token {
        if (lx.pos >= lx.src.len) return null;
        const start = lx.pos;
        const rest = lx.src[start..];
        const c = rest[0];

        for (lx.lang.line_comments) |marker| {
            if (!std.mem.startsWith(u8, rest, marker)) continue;
            // "#" in shell is only a comment at a word boundary, so
            // "a#b" and "${#x}" stay intact.
            if (lx.lang.shell and start > 0 and !std.ascii.isWhitespace(lx.src[start - 1])) break;
            lx.pos = std.mem.indexOfScalarPos(u8, lx.src, start, '\n') orelse lx.src.len;
            return lx.tok(start, .com);
        }

        if (lx.lang.block_comment) |bc| if (std.mem.startsWith(u8, rest, bc[0])) {
            const close = std.mem.indexOfPos(u8, lx.src, start + bc[0].len, bc[1]);
            lx.pos = if (close) |i| i + bc[1].len else lx.src.len;
            return lx.tok(start, .com);
        };

        if (std.mem.indexOfScalar(u8, lx.lang.quotes, c) != null) {
            lx.pos += 1;
            while (lx.pos < lx.src.len) : (lx.pos += 1) {
                const d = lx.src[lx.pos];
                if (d == '\\') {
                    lx.pos += 1;
                } else if (d == c) {
                    lx.pos += 1;
                    break;
                } else if (d == '\n' and c != '`' and !lx.lang.shell) {
                    // Unterminated: stop at the line end rather than
                    // colouring the rest of the block as a string.
                    break;
                }
            }
            // A trailing backslash can step past the end.
            lx.pos = @min(lx.pos, lx.src.len);
            // A string followed by ':' is an object key, as in JSON.
            const key = lx.peekNonSpace() == ':';
            return lx.tok(start, if (key) .@"fn" else .str);
        }

        if (std.ascii.isDigit(c)) {
            while (lx.pos < lx.src.len and (std.ascii.isAlphanumeric(lx.src[lx.pos]) or
                lx.src[lx.pos] == '_' or lx.src[lx.pos] == '.')) lx.pos += 1;
            return lx.tok(start, .num);
        }

        if (lx.lang.shell and c == '$') {
            lx.pos += 1;
            if (lx.pos < lx.src.len and lx.src[lx.pos] == '{') {
                lx.pos = if (std.mem.indexOfScalarPos(u8, lx.src, lx.pos, '}')) |i| i + 1 else lx.src.len;
            } else {
                while (lx.pos < lx.src.len and isIdent(lx.src[lx.pos])) lx.pos += 1;
            }
            return lx.tok(start, .@"var");
        }

        if (isIdentStart(c)) {
            // The start may be '@', which isIdent rejects, so step past it
            // first or the token would be empty.
            lx.pos += 1;
            while (lx.pos < lx.src.len and isIdent(lx.src[lx.pos])) lx.pos += 1;
            if (lx.lang.shell) {
                // Commands can contain - and . ("git-lfs", "./run.sh").
                while (lx.pos < lx.src.len and (isIdent(lx.src[lx.pos]) or lx.src[lx.pos] == '-' or
                    lx.src[lx.pos] == '.' or lx.src[lx.pos] == '/')) lx.pos += 1;
                if (lx.command_start) {
                    lx.command_start = false;
                    return lx.tok(start, .kw);
                }
                return lx.tok(start, null);
            }
            const word = lx.src[start..lx.pos];
            for (lx.lang.keywords) |kw| if (std.mem.eql(u8, kw, word)) return lx.tok(start, .kw);
            if (lx.peekNonSpace() == '(') return lx.tok(start, .@"fn");
            return lx.tok(start, null);
        }

        // Shell: a new command starts after a newline, pipe, ;, && or ||.
        if (lx.lang.shell) switch (c) {
            '\n', '|', ';', '&', '(' => lx.command_start = true,
            else => {},
        };

        // Plain text runs to the next byte that could start a token.
        lx.pos += 1;
        while (lx.pos < lx.src.len) : (lx.pos += 1) {
            const d = lx.src[lx.pos];
            if (isIdentStart(d) or std.ascii.isDigit(d) or d == '/' or d == '#' or d == '-' or
                d == '$' or d == '\n' or d == '|' or d == ';' or d == '&' or d == '(' or
                std.mem.indexOfScalar(u8, lx.lang.quotes, d) != null) break;
        }
        return lx.tok(start, null);
    }

    fn tok(lx: *const Lexer, start: usize, class: ?Class) Token {
        std.debug.assert(lx.pos > start);
        return .{ .start = start, .end = lx.pos, .class = class };
    }

    fn peekNonSpace(lx: *const Lexer) u8 {
        var i = lx.pos;
        while (i < lx.src.len and (lx.src[i] == ' ' or lx.src[i] == '\t')) i += 1;
        return if (i < lx.src.len) lx.src[i] else 0;
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '@';
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
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

// --- Languages --------------------------------------------------------------

const c_like_comments: []const []const u8 = &.{"//"};
const c_block: [2][]const u8 = .{ "/*", "*/" };

const zig: Language = .{
    .keywords = &.{
        "addrspace", "align",       "allowzero",      "and",     "anyframe", "anytype", "asm",         "break",
        "callconv",  "catch",       "comptime",       "const",   "continue", "defer",   "else",        "enum",
        "errdefer",  "error",       "export",         "extern",  "fn",       "for",     "if",          "inline",
        "noalias",   "noinline",    "nosuspend",      "opaque",  "or",       "orelse",  "packed",      "pub",
        "resume",    "return",      "struct",         "suspend", "switch",   "test",    "threadlocal", "try",
        "union",     "unreachable", "usingnamespace", "var",     "volatile", "while",   "true",        "false",
        "null",      "undefined",
    },
    .line_comments = c_like_comments,
};

const c_lang: Language = .{
    .keywords = &.{
        "auto",     "break",    "case",   "char",      "const",     "continue", "default",  "do",
        "double",   "else",     "enum",   "extern",    "float",     "for",      "goto",     "if",
        "inline",   "int",      "long",   "register",  "return",    "short",    "signed",   "sizeof",
        "static",   "struct",   "switch", "typedef",   "union",     "unsigned", "void",     "volatile",
        "while",    "bool",     "true",   "false",     "NULL",      "nullptr",  "class",    "namespace",
        "template", "typename", "public", "private",   "protected", "virtual",  "override", "new",
        "delete",   "this",     "using",  "constexpr", "noexcept",  "size_t",
    },
    .line_comments = c_like_comments,
    .block_comment = c_block,
};

const swift: Language = .{
    .keywords = &.{
        "actor",     "any",         "as",          "async",       "await",    "break",    "case",    "catch",
        "class",     "continue",    "default",     "defer",       "deinit",   "do",       "else",    "enum",
        "extension", "fallthrough", "false",       "fileprivate", "final",    "for",      "func",    "guard",
        "if",        "import",      "in",          "init",        "inout",    "internal", "is",      "let",
        "mutating",  "nil",         "nonisolated", "open",        "operator", "override", "private", "protocol",
        "public",    "repeat",      "rethrows",    "return",      "self",     "Self",     "some",    "static",
        "struct",    "subscript",   "super",       "switch",      "throw",    "throws",   "true",    "try",
        "typealias", "var",         "weak",        "where",       "while",
    },
    .line_comments = c_like_comments,
    .block_comment = c_block,
};

const rust: Language = .{
    .keywords = &.{
        "as",    "async",  "await",  "break", "const", "continue", "crate", "dyn",    "else",
        "enum",  "extern", "false",  "fn",    "for",   "if",       "impl",  "in",     "let",
        "loop",  "match",  "mod",    "move",  "mut",   "pub",      "ref",   "return", "self",
        "Self",  "static", "struct", "super", "trait", "true",     "type",  "unsafe", "use",
        "where", "while",
    },
    .line_comments = c_like_comments,
    .block_comment = c_block,
};

const go: Language = .{
    .keywords = &.{
        "break",       "case",    "chan",  "const",  "continue", "default", "defer",  "else",
        "fallthrough", "for",     "func",  "go",     "goto",     "if",      "import", "interface",
        "map",         "package", "range", "return", "select",   "struct",  "switch", "type",
        "var",         "nil",     "true",  "false",
    },
    .line_comments = c_like_comments,
    .block_comment = c_block,
    .quotes = "\"'`",
};

const js: Language = .{
    .keywords = &.{
        "async",    "await",   "break",     "case",     "catch",  "class",      "const",    "continue",
        "debugger", "default", "delete",    "do",       "else",   "export",     "extends",  "false",
        "finally",  "for",     "from",      "function", "if",     "import",     "in",       "instanceof",
        "let",      "new",     "null",      "of",       "return", "static",     "super",    "switch",
        "this",     "throw",   "true",      "try",      "typeof", "undefined",  "var",      "void",
        "while",    "yield",   "interface", "type",     "enum",   "implements", "readonly", "as",
    },
    .line_comments = c_like_comments,
    .block_comment = c_block,
    .quotes = "\"'`",
};

const python: Language = .{
    .keywords = &.{
        "and",      "as",     "assert", "async",  "await",  "break",  "class",   "continue",
        "def",      "del",    "elif",   "else",   "except", "False",  "finally", "for",
        "from",     "global", "if",     "import", "in",     "is",     "lambda",  "None",
        "nonlocal", "not",    "or",     "pass",   "raise",  "return", "True",    "try",
        "while",    "with",   "yield",  "match",  "case",   "self",
    },
    .line_comments = &.{"#"},
};

const ruby: Language = .{
    .keywords = &.{
        "begin",  "break",  "case",  "class",  "def",   "do",     "else",    "elsif", "end",
        "ensure", "false",  "for",   "if",     "in",    "module", "next",    "nil",   "not",
        "or",     "and",    "redo",  "rescue", "retry", "return", "self",    "super", "then",
        "true",   "unless", "until", "when",   "while", "yield",  "require",
    },
    .line_comments = &.{"#"},
};

const lua: Language = .{
    .keywords = &.{
        "and",  "break", "do",    "else",  "elseif", "end", "false", "for",    "function",
        "goto", "if",    "in",    "local", "nil",    "not", "or",    "repeat", "return",
        "then", "true",  "until", "while",
    },
    .line_comments = &.{"--"},
};

const sql: Language = .{
    .keywords = &.{
        "select",     "from",  "where", "insert",   "into",  "values", "update",  "set",   "delete",
        "create",     "table", "drop",  "alter",    "index", "join",   "left",    "right", "inner",
        "outer",      "on",    "as",    "and",      "or",    "not",    "null",    "is",    "in",
        "group",      "by",    "order", "having",   "limit", "offset", "primary", "key",   "foreign",
        "references", "union", "all",   "distinct", "case",  "when",   "then",    "else",  "end",
        "SELECT",     "FROM",  "WHERE", "INSERT",   "INTO",  "VALUES", "UPDATE",  "SET",   "DELETE",
        "CREATE",     "TABLE", "DROP",  "ALTER",    "INDEX", "JOIN",   "LEFT",    "RIGHT", "INNER",
        "OUTER",      "ON",    "AS",    "AND",      "OR",    "NOT",    "NULL",    "IS",    "IN",
        "GROUP",      "BY",    "ORDER", "HAVING",   "LIMIT", "OFFSET", "PRIMARY", "KEY",   "FOREIGN",
        "REFERENCES", "UNION", "ALL",   "DISTINCT", "CASE",  "WHEN",   "THEN",    "ELSE",  "END",
    },
    .line_comments = &.{"--"},
    .block_comment = c_block,
};

const nix: Language = .{
    .keywords = &.{ "let", "in", "with", "rec", "inherit", "import", "if", "then", "else", "assert", "true", "false", "null" },
    .line_comments = &.{"#"},
    .block_comment = c_block,
    .quotes = "\"",
};

const hcl: Language = .{
    .keywords = &.{ "resource", "data", "variable", "output", "provider", "module", "terraform", "locals", "true", "false", "null", "for", "in", "if" },
    .line_comments = &.{ "#", "//" },
    .block_comment = c_block,
    .quotes = "\"",
};

const json: Language = .{
    .keywords = &.{ "true", "false", "null" },
    .quotes = "\"",
};

const config: Language = .{
    .keywords = &.{ "true", "false", "null", "yes", "no", "on", "off" },
    .line_comments = &.{"#"},
};

const shell: Language = .{
    .keywords = &.{},
    .line_comments = &.{"#"},
    .shell = true,
};

const languages: std.StaticStringMap(*const Language) = .initComptime(.{
    .{ "zig", &zig },       .{ "c", &c_lang },    .{ "h", &c_lang },      .{ "cpp", &c_lang },
    .{ "c++", &c_lang },    .{ "cc", &c_lang },   .{ "objc", &c_lang },   .{ "swift", &swift },
    .{ "rust", &rust },     .{ "rs", &rust },     .{ "go", &go },         .{ "js", &js },
    .{ "javascript", &js }, .{ "jsx", &js },      .{ "ts", &js },         .{ "typescript", &js },
    .{ "tsx", &js },        .{ "java", &c_lang }, .{ "kotlin", &c_lang }, .{ "python", &python },
    .{ "py", &python },     .{ "ruby", &ruby },   .{ "rb", &ruby },       .{ "lua", &lua },
    .{ "sql", &sql },       .{ "nix", &nix },     .{ "hcl", &hcl },       .{ "terraform", &hcl },
    .{ "tf", &hcl },        .{ "json", &json },   .{ "jsonc", &json },    .{ "toml", &config },
    .{ "yaml", &config },   .{ "yml", &config },  .{ "ini", &config },    .{ "sh", &shell },
    .{ "bash", &shell },    .{ "zsh", &shell },   .{ "fish", &shell },    .{ "shell", &shell },
    .{ "console", &shell },
});

// --- Tests ------------------------------------------------------------------

fn expectHighlight(lang: []const u8, code: []const u8, expected: []const u8) !void {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, find(lang).?, code);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "highlight: zig keywords, calls, strings, comments" {
    try expectHighlight("zig", "const s = f(\"a<b\"); // hi", "<span class=\"hl-kw\">const</span> s = <span class=\"hl-fn\">f</span>(<span class=\"hl-str\">&quot;a&lt;b&quot;</span>); <span class=\"hl-com\">// hi</span>");
}

test "highlight: json keys differ from values" {
    try expectHighlight("json", "{\"a\": \"b\", \"n\": 1}", "{<span class=\"hl-fn\">&quot;a&quot;</span>: <span class=\"hl-str\">&quot;b&quot;</span>, <span class=\"hl-fn\">&quot;n&quot;</span>: <span class=\"hl-num\">1</span>}");
}

test "highlight: shell command words and variables" {
    try expectHighlight("sh", "rex ls -a $HOME # list\ngit log | head", "<span class=\"hl-kw\">rex</span> ls -a <span class=\"hl-var\">$HOME</span> <span class=\"hl-com\"># list</span>\n" ++
        "<span class=\"hl-kw\">git</span> log | <span class=\"hl-kw\">head</span>");
}

test "highlight: unterminated string stops at line end" {
    try expectHighlight("python", "x = 'a\ny = 1", "x = <span class=\"hl-str\">'a</span>\ny = <span class=\"hl-num\">1</span>");
}

test "highlight: block comment" {
    try expectHighlight("c", "/* a */ int", "<span class=\"hl-com\">/* a */</span> <span class=\"hl-kw\">int</span>");
}

test "highlight: find is case-insensitive and rejects unknown" {
    try std.testing.expect(find("Swift") != null);
    try std.testing.expect(find("brainfuck") == null);
    try std.testing.expect(find("a-name-much-longer-than-the-buffer") == null);
}

test "highlight: at-prefixed identifiers" {
    // Regression: '@' started an identifier but was never consumed,
    // producing an empty token (assert in debug, hang in release).
    try expectHighlight("zig", "@import(\"std\")", "<span class=\"hl-fn\">@import</span>(<span class=\"hl-str\">&quot;std&quot;</span>)");
    try expectHighlight("python", "@ x", "@ x");
    try expectHighlight("sh", "ssh user@host", "<span class=\"hl-kw\">ssh</span> user@host");
}

test "highlight: every prefix renders" {
    const src = "\"a\\\n/* x '`$ {1.2e3 // # @x @";
    for (std.meta.tags(enum { zig, sh, json, go, python })) |l| {
        for (0..src.len + 1) |n| {
            var out: Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            try render(&out.writer, find(@tagName(l)).?, src[0..n]);
        }
    }
}

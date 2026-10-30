import Foundation

/// Where the Markdown syntax is in a note, for an editor that styles the
/// source in place (Live Preview). It reads the same constructs libnaut
/// renders, but only locates them: the editor decides how each looks.
///
/// Ranges are UTF-16 (NSString), as AppKit's text system wants them.
public enum LiveMarkdown {
    public struct Element: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case heading(level: Int)
            case strong, emphasis, strikethrough
            /// An inline code span.
            case code
            /// `[label](target)`: `content` is the label.
            case link
            /// `$tex$`, rendered in place when not being edited.
            case math(tex: String)
            /// A `$$` block; `markers` are its two fence lines.
            case mathBlock(tex: String)
            /// A fenced code block; `markers` are its two fence lines.
            case codeBlock(language: String)
            /// A GFM table; `range` is all its rows.
            case table
            /// An image alone on its line: `![alt](url)`.
            case image(url: String)
            case quote
            /// `markers` is the bullet or number.
            case listItem
        }

        public var kind: Kind
        /// The whole construct, syntax included.
        public var range: NSRange
        /// Syntax characters: shown while editing, hidden otherwise.
        public var markers: [NSRange]
        /// The text the syntax wraps.
        public var content: NSRange
        /// The caret anywhere in here means the element is being edited:
        /// its lines, newlines included.
        public var scope: NSRange
    }

    public static func parse(_ source: String) -> [Element] {
        let text = source as NSString
        var out: [Element] = []
        var lines: [(line: NSRange, enclosing: NSRange)] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            lines.append((line, enclosing))
        }

        var i = 0
        while i < lines.count {
            let (line, enclosing) = lines[i]
            let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespaces)

            if let fence = fence(trimmed), let j = closing(fence, after: i, in: lines, text) {
                let scope = union(enclosing, lines[j].enclosing)
                let inner = i + 1 <= j - 1 ? union(lines[i + 1].line, lines[j - 1].line) : NSRange(location: NSMaxRange(enclosing), length: 0)
                let markers = [line, lines[j].line]
                // ```math is display math, as libnaut renders it.
                let language = trimmed.dropFirst(fence.count).split(separator: " ").first.map(String.init) ?? ""
                let kind: Element.Kind = language == "math" ? .mathBlock(tex: text.substring(with: inner)) : .codeBlock(language: language)
                out.append(Element(kind: kind, range: scope, markers: markers, content: inner, scope: scope))
                i = j + 1
                continue
            }

            if trimmed == "$$" {
                var j = i + 1
                while j < lines.count, text.substring(with: lines[j].line).trimmingCharacters(in: .whitespaces) != "$$" { j += 1 }
                if j < lines.count {
                    let scope = union(enclosing, lines[j].enclosing)
                    let inner = i + 1 <= j - 1 ? union(lines[i + 1].line, lines[j - 1].line) : NSRange(location: NSMaxRange(enclosing), length: 0)
                    out.append(Element(kind: .mathBlock(tex: text.substring(with: inner)), range: scope, markers: [line, lines[j].line], content: inner, scope: scope))
                    i = j + 1
                    continue
                }
            }

            // A header row, then a delimiter row, then rows until a blank.
            if trimmed.contains("|"), i + 1 < lines.count, text.substring(with: lines[i + 1].line).contains("|"),
               delimiter.firstMatch(in: source, range: lines[i + 1].line) != nil {
                var j = i + 2
                while j < lines.count, text.substring(with: lines[j].line).contains("|") { j += 1 }
                let scope = union(enclosing, lines[j - 1].enclosing)
                let rows = union(line, lines[j - 1].line)
                out.append(Element(kind: .table, range: rows, markers: [], content: rows, scope: scope))
                i = j
                continue
            }

            if let m = image.firstMatch(in: source, range: line) {
                let url = text.substring(with: m.range(at: 1))
                out.append(Element(kind: .image(url: url), range: line, markers: [line], content: m.range(at: 1), scope: enclosing))
                i += 1
                continue
            }

            var inline = line
            if let m = heading.firstMatch(in: source, range: line) {
                let marker = m.range
                let content = NSRange(location: NSMaxRange(marker), length: NSMaxRange(line) - NSMaxRange(marker))
                out.append(Element(kind: .heading(level: m.range(at: 1).length), range: line, markers: [marker], content: content, scope: enclosing))
                inline = content
            } else if let m = quote.firstMatch(in: source, range: line) {
                let content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
                out.append(Element(kind: .quote, range: line, markers: [m.range], content: content, scope: enclosing))
                inline = content
            } else if let m = list.firstMatch(in: source, range: line) {
                let content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
                out.append(Element(kind: .listItem, range: line, markers: [m.range(at: 1)], content: content, scope: enclosing))
                inline = content
            }
            out += spans(in: inline, of: source, scope: enclosing)
            i += 1
        }
        return out
    }

    // MARK: - Inline

    private static func spans(in range: NSRange, of source: String, scope: NSRange) -> [Element] {
        var out: [Element] = []
        // Code and math take their contents literally; nothing inside them
        // is emphasis or a link.
        var literal: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !literal.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in code.matches(in: source, range: range) {
            let tick = m.range(at: 1).length
            let markers = [NSRange(location: m.range.location, length: tick), NSRange(location: NSMaxRange(m.range) - tick, length: tick)]
            out.append(Element(kind: .code, range: m.range, markers: markers, content: m.range(at: 2), scope: scope))
            literal.append(m.range)
        }
        for m in math.matches(in: source, range: range) where free(m.range) {
            let tex = (source as NSString).substring(with: m.range(at: 1))
            out.append(Element(kind: .math(tex: tex), range: m.range, markers: [m.range], content: m.range(at: 1), scope: scope))
            literal.append(m.range)
        }
        for m in link.matches(in: source, range: range) where free(m.range) {
            let label = m.range(at: 1)
            let markers = [
                NSRange(location: m.range.location, length: 1),
                NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)),
            ]
            out.append(Element(kind: .link, range: m.range, markers: markers, content: label, scope: scope))
        }
        for (re, kind) in [(strong, Element.Kind.strong), (strike, .strikethrough), (emphasis, .emphasis)] {
            for m in re.matches(in: source, range: range) where free(m.range) {
                let n = m.range(at: 1).length
                // `***x***` is strong and emphasis; emphasis then sees the
                // inner `*x*`, so skip any match inside a strong one's markers.
                if kind == .emphasis, out.contains(where: { $0.kind == .strong && $0.markers.contains { NSIntersectionRange($0, m.range(at: 1)).length > 0 } }) { continue }
                let markers = [NSRange(location: m.range.location, length: n), NSRange(location: NSMaxRange(m.range) - n, length: n)]
                let content = NSRange(location: m.range.location + n, length: m.range.length - 2 * n)
                out.append(Element(kind: kind, range: m.range, markers: markers, content: content, scope: scope))
            }
        }
        return out
    }

    /// The line closing a fence opened on line `i`. Without one the fence
    /// is text: libnaut would run it to the end of the note, but in an
    /// editor that means everything below turns to code while ``` is
    /// being typed.
    private static func closing(_ fence: String, after i: Int, in lines: [(line: NSRange, enclosing: NSRange)], _ text: NSString) -> Int? {
        (i + 1..<lines.count).first { text.substring(with: lines[$0].line).trimmingCharacters(in: .whitespaces).hasPrefix(fence) }
    }

    private static func fence(_ trimmed: String) -> String? {
        ["```", "~~~"].first { trimmed.hasPrefix($0) }
    }

    private static func union(_ a: NSRange, _ b: NSRange) -> NSRange { NSUnionRange(a, b) }

    // Block prefixes, each matched at the start of a line.
    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+")
    private static let quote = try! NSRegularExpression(pattern: "^[ \\t]*>[ \\t]?")
    private static let list = try! NSRegularExpression(pattern: "^[ \\t]*([-*+]|\\d+[.)])[ \\t]+")

    /// `| :-- | --: |`: only dashes and colons between pipes.
    private static let delimiter = try! NSRegularExpression(pattern: "^[ \\t]*\\|?[ \\t]*:?-+:?[ \\t]*(\\|[ \\t]*:?-+:?[ \\t]*)*\\|?[ \\t]*$")
    /// The whole line, an optional title after the URL.
    private static let image = try! NSRegularExpression(pattern: "^[ \\t]*!\\[[^\\]\\n]*\\]\\(([^)\\s]+)(?:[ \\t]+\"[^\"\\n]*\")?\\)[ \\t]*$")

    /// The content can't start or end with a backtick, so ``` alone (a
    /// fence being typed) isn't a span around one backtick.
    private static let code = try! NSRegularExpression(pattern: "(`+)(?!`)(.+?)(?<!`)\\1")
    /// libnaut's rule, after Pandoc: no space inside either `$`, and no
    /// digit right after the closing one, so "$5 and $10" stays text.
    private static let math = try! NSRegularExpression(pattern: "\\$(?![ $])((?:\\\\.|[^$\\\\\\n])+?)(?<! )\\$(?!\\d)")
    private static let link = try! NSRegularExpression(pattern: "(?<!!)\\[([^\\]\\n]+)\\]\\([^)\\n]*\\)")
    private static let strong = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let strike = try! NSRegularExpression(pattern: "(~~)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let emphasis = try! NSRegularExpression(pattern: "(?<![*\\w])([*_])(?![\\s*_])(.+?)(?<![\\s*_])\\1(?![*\\w])")
}

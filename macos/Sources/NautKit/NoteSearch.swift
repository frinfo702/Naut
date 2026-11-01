import Foundation

/// Finding a query in a note, for the command palette's search.
public enum NoteSearch {
    public struct Match: Equatable, Sendable {
        /// Occurrences in the title and the text.
        public var count: Int
        /// The heading above the first match in the text, if any.
        public var section: String?
        /// The line holding the first match in the text, cut to a window
        /// around it; empty when only the title matched.
        public var snippet: String
    }

    /// Case- and width-insensitive, so "camera" finds "Camera" and
    /// half-width kana find full-width ones.
    private static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]

    public static func match(_ query: String, title: String, text: String, width: Int = 80) -> Match? {
        guard !query.isEmpty else { return nil }
        let inTitle = occurrences(of: query, in: title)
        let inText = occurrences(of: query, in: text)
        guard inTitle + inText > 0 else { return nil }
        guard let first = text.range(of: query, options: options) else {
            return Match(count: inTitle, section: nil, snippet: "")
        }

        let line = text.lineRange(for: first)
        var section: String?
        // A "#" line inside a fenced code block is a comment, not a heading.
        var fence: Substring?
        text[..<line.lowerBound].enumerateLines { line, _ in
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix { $0 == trimmed.first }
            } else if line.hasPrefix("#") {
                section = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            }
        }

        // A window starting a little before the match, so the match shows
        // even where the snippet is cut to one line.
        let lead = min(12, width / 3)
        let start = text.index(first.lowerBound, offsetBy: -lead, limitedBy: line.lowerBound) ?? line.lowerBound
        let end = text.index(start, offsetBy: width, limitedBy: line.upperBound) ?? line.upperBound
        var snippet = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        if start == line.lowerBound {
            // Drop Markdown's line markers: "## ", "- ", "> ".
            snippet = String(snippet.drop { "#->* ".contains($0) })
        } else {
            snippet = "…" + snippet
        }
        if end < line.upperBound, text[end...].first?.isNewline == false { snippet += "…" }
        return Match(count: inTitle + inText, section: section, snippet: snippet)
    }

    static func occurrences(of query: String, in text: String) -> Int {
        var count = 0
        var rest = text.startIndex..<text.endIndex
        while let found = text.range(of: query, options: options, range: rest) {
            count += 1
            rest = found.upperBound..<text.endIndex
        }
        return count
    }
}

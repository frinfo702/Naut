import Foundation

extension LiveProjection {
    /// The Markdown a display selection stands for, for ⌘C and Vim yanks.
    ///
    /// Live Preview hides the syntax, so the display range alone gives the
    /// text without the `## `, `**` or fence that was selected along with
    /// it. A selection that covers a line's text gets its prefix back; one
    /// that covers an inline span's text gets its markers; touching a
    /// drawn block or a code block copies the whole block, because half a
    /// fence is not Markdown.
    ///
    /// Trailing spaces and tabs on each line are dropped. The selection
    /// background paints them for the newline it contains, but they are
    /// not text the reader meant to copy.
    public func copiedMarkdown(for display: NSRange) -> String {
        guard display.length > 0, display.location >= 0, NSMaxRange(display) <= self.display.length else { return "" }
        var range = sourceRange(display)

        for (i, e) in elements.enumerated() {
            switch e.kind {
            case .heading, .quote, .listItem, .table:
                guard let visible = visibleRange(of: i), contains(display, visible) else { continue }
                range = NSUnionRange(range, e.range)
            case .codeBlock:
                guard let visible = visibleRange(of: i), NSIntersectionRange(display, visible).length > 0 else { continue }
                range = NSUnionRange(range, e.range)
            case .mathBlock, .image, .rule:
                guard let at = attachment(of: i), NSIntersectionRange(display, NSRange(location: at, length: 1)).length > 0 else { continue }
                range = NSUnionRange(range, e.range)
            case .strong, .emphasis, .strikethrough, .code, .link, .math:
                guard let visible = visibleRange(of: i), contains(display, visible) else { continue }
                range = NSUnionRange(range, e.range)
            }
        }

        let start = min(range.location, source.length)
        let end = min(NSMaxRange(range), source.length)
        let text = source.substring(with: NSRange(location: start, length: max(0, end - start)))
        return text.trimmingTrailingSpacesPerLine()
    }

    /// What an element shows, or nil for one drawn without a display
    /// range (an empty code block, or a block whose image hasn't arrived).
    private func visibleRange(of element: Int) -> NSRange? {
        if let at = attachment(of: element) { return NSRange(location: at, length: 1) }
        let e = elements[element]
        switch e.kind {
        case .heading, .quote, .listItem, .strong, .emphasis, .strikethrough, .code, .link, .codeBlock:
            let r = displayRange(e.content)
            return r.length > 0 ? r : nil
        case .table:
            let r = displayRange(e.range)
            return r.length > 0 ? r : nil
        case .math, .mathBlock, .image, .rule:
            return nil
        }
    }

    private func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.length > 0 && outer.location <= inner.location && NSMaxRange(outer) >= NSMaxRange(inner)
    }

}

public extension String {
    /// Drop spaces and tabs at the end of every line. A line selection
    /// paints the newline it contains to the end of the column; those
    /// pixels are not text, and neither are the spaces a note happens to
    /// carry at the end of a line.
    func trimmingTrailingSpacesPerLine() -> String {
        components(separatedBy: "\n").map { line in
            var line = line
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }
}

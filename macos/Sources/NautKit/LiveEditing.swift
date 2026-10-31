import Foundation

/// What an edit in Live Preview does to the note. The editor holds the
/// projection (`LiveProjection`), so every edit arrives in display
/// coordinates; this turns it into an edit of the Markdown and says where
/// the selection goes. Pure, so the rules are tested here and the editor
/// only applies the answers.
///
/// Most edits are the obvious mapping. The rules are for where the
/// obvious mapping would break syntax the user can't see, as Notion
/// behaves: deleting into a heading makes a paragraph, deleting a span's
/// last letter takes its markers, deleting toward a block selects it
/// first, Return continues a list, ``` or $$ then Return makes a block.
public struct LiveEditing {
    public let projection: LiveProjection
    private var source: NSString { projection.source }
    private var elements: [LiveMarkdown.Element] { projection.elements }

    public enum Edit: Equatable, Sendable {
        /// Nothing happens.
        case none
        /// Select this display range, without changing the text.
        case select(NSRange)
        /// Replace this source range; then select `selection`, in source
        /// positions of the new text.
        case replace(NSRange, with: String, selection: NSRange)
    }

    public init(_ projection: LiveProjection) {
        self.projection = projection
    }

    public init(text: String) {
        self.init(LiveProjection(text))
    }

    // MARK: - Typing

    /// Typing `s` over display range `r` (empty for a caret). `preferring`
    /// is the source position the caret is known to be at, if any: see
    /// `LiveProjection.insertion`.
    public func type(_ s: String, over r: NSRange, preferring: Int? = nil) -> Edit {
        guard r.length == 0 else {
            let range = projection.sourceRange(r)
            return .replace(range, with: s, selection: caret(range.location + length(s)))
        }
        let at = projection.insertion(at: r.location, preferring: preferring, newline: s.contains("\n"))
        return .replace(caret(at.position), with: at.before + s + at.after,
                        selection: caret(at.position + length(at.before + s)))
    }

    // MARK: - Deleting

    /// Deleting display range `r`, the selection being `selection`.
    public func delete(_ r: NSRange, selection: NSRange) -> Edit {
        guard r.length > 0 else { return .none }
        let range = projection.sourceRange(r)

        // Deleting all of a span's text takes its markers too, so `****`
        // isn't left behind.
        if let e = elements.first(where: { $0.kind.isSpan && $0.content == range }) {
            return .replace(e.range, with: "", selection: caret(e.range.location))
        }

        // An attachment is selected first, then deleted, as in Notion. A
        // block goes with its line.
        if r.length == 1, let i = projection.attachments[r.location], let atom = projection.atoms.first(where: { $0.element == i }) {
            guard selection == r else { return .select(r) }
            var gone = atom.range
            if atom.isBlock {
                if NSMaxRange(gone) < source.length {
                    gone.length += 1
                } else if gone.location > 0 {
                    gone = NSRange(location: gone.location - 1, length: gone.length + 1)
                }
            }
            return .replace(gone, with: "", selection: caret(gone.location))
        }

        // A newline: joining two lines where block syntax may be hidden.
        if range.length == 1, source.character(at: range.location) == 0x0A {
            return deleteNewline(at: range.location, display: r, backward: r.location < selection.location)
        }
        return .replace(range, with: "", selection: caret(range.location))
    }

    /// Deleting the newline at source `n`. Hidden block syntax may start
    /// right after it, or a block may end right before it.
    private func deleteNewline(at n: Int, display r: NSRange, backward: Bool) -> Edit {
        let plain = Edit.replace(NSRange(location: n, length: 1), with: "", selection: caret(n))
        let next = n + 1

        // Into a heading, list item or quote from the line above: it
        // becomes a paragraph, as in Notion, rather than its `## ` showing.
        if let e = elements.first(where: { isLine($0.kind) && $0.range.location == next }) {
            let prefix = linePrefix(e)
            return .replace(prefix, with: "", selection: caret(prefix.location))
        }

        // Into a code block's opening fence from the line above: joining a
        // blank line is harmless and an empty block goes; otherwise nothing,
        // as the fence can't share its line.
        if let e = elements.first(where: { isCode($0.kind) && $0.markers[0].location == next }) {
            if isBlank(line(containing: n)) { return plain }
            if isBlank(e.content) {
                let block = LiveProjection.trimmed(e.scope, in: source)
                return .replace(block, with: "", selection: caret(block.location))
            }
            return .none
        }

        // The newline ending a code block's last line, its closing fence
        // next: backspace from the line below the block, or forward delete
        // at the end of the code. A blank line below goes instead; otherwise
        // the caret moves to the end of the code.
        if let e = elements.first(where: { isCode($0.kind) && $0.markers.count == 2 && $0.markers[1].location == next }) {
            let fence = e.markers[1]
            if NSMaxRange(fence) < source.length {
                let below = line(containing: NSMaxRange(fence) + 1)
                // Backspace at the start of the line below meets that
                // line's hidden prefix first: the fence hides the newline
                // before it, so the displayed newline is the code's last.
                if backward, let item = elements.first(where: { isLine($0.kind) && $0.range.location == below.location }) {
                    let prefix = linePrefix(item)
                    return .replace(prefix, with: "", selection: caret(prefix.location))
                }
                if isBlank(below) {
                    // The blank line's own newline, or, if it ends the note,
                    // the fence's.
                    let gone = NSMaxRange(below) < source.length ? NSMaxRange(below) : NSMaxRange(fence)
                    return .replace(NSRange(location: gone, length: 1), with: "", selection: caret(min(below.location, gone)))
                }
            }
            return backward ? .select(NSRange(location: r.location, length: 0)) : .none
        }

        // Next to a block: joining a blank line is harmless; otherwise the
        // block is selected.
        if let atom = projection.atoms.first(where: { $0.isBlock && ($0.range.location == next || NSMaxRange($0.range) == n) }) {
            let other = atom.range.location == next ? line(containing: n) : line(containing: next)
            if isBlank(other) { return plain }
            return .select(NSRange(location: projection.display(at: atom.range.location), length: 1))
        }
        return plain
    }

    // MARK: - Return

    /// What Return does at display `selection`; `preferring` as for `type`.
    public func newline(_ selection: NSRange, preferring: Int? = nil) -> Edit {
        guard selection.length == 0 else { return type("\n", over: selection) }
        let p = projection.insertion(at: selection.location, preferring: preferring, newline: true)
        guard p.before.isEmpty, p.after.isEmpty else { return type("\n", over: selection, preferring: preferring) }
        let at = p.position
        let l = line(containing: at)
        let t = source.substring(with: l).trimmingCharacters(in: .whitespaces)
        let element = elements.first {
            (isLine($0.kind) || isCode($0.kind)) && (NSLocationInRange(at, $0.scope) || at == NSMaxRange($0.scope) && $0.scope.length > 0)
        }

        if let e = element, isCode(e.kind), at >= e.content.location, at <= NSMaxRange(e.content) {
            // Return on an empty last line leaves the block, below its fence.
            if l.length == 0, NSMaxRange(l) == NSMaxRange(e.content), l.location > e.content.location {
                let fence = e.markers[1]
                let tail = NSMaxRange(fence) == source.length ? "\n" : ""
                let replaced = NSRange(location: l.location, length: NSMaxRange(fence) - l.location)
                return .replace(replaced, with: source.substring(with: fence) + tail, selection: caret(l.location + fence.length + 1))
            }
            // Otherwise a new line of code, keeping the indent.
            let indent = String(source.substring(with: l).prefix { $0 == " " || $0 == "\t" })
            return .replace(caret(at), with: "\n" + indent, selection: caret(at + 1 + length(indent)))
        }

        // ``` or $$ then Return makes the block, the caret inside. (Until
        // its fence is closed, ``` is text, so it isn't a code block yet.)
        if at == NSMaxRange(l) {
            if let fence = ["```", "~~~"].first(where: { t.hasPrefix($0) }), !t.dropFirst(3).contains(where: { $0 == "`" || $0 == " " }) {
                return .replace(caret(at), with: "\n\n" + fence, selection: caret(at + 1))
            }
            if t == "$$" {
                return .replace(caret(at), with: "\n\n$$", selection: caret(at + 1))
            }
        }

        if let e = element, isLine(e.kind) {
            let prefix = linePrefix(e)
            let text = NSRange(location: NSMaxRange(prefix), length: NSMaxRange(e.range) - NSMaxRange(prefix))
            // Return on an empty item ends the list (or heading, or quote).
            if isBlank(text) { return .replace(prefix, with: "", selection: caret(prefix.location)) }
            // At the start of the text, a new line above.
            if at <= text.location {
                let above = isHeading(e.kind) ? "\n" : (continuation(e) ?? "") + "\n"
                return .replace(caret(l.location), with: above, selection: caret(at + length(above)))
            }
            if let next = continuation(e) {
                return .replace(caret(at), with: "\n" + next, selection: caret(at + 1 + length(next)))
            }
        }
        return .replace(caret(at), with: "\n", selection: caret(at + 1))
    }

    /// The prefix for the line after `e`: the same bullet, the next number,
    /// an unchecked box if `e` has one; a quote's `> `.
    private func continuation(_ e: LiveMarkdown.Element) -> String? {
        switch e.kind {
        case .quote:
            return source.substring(with: e.markers[0])
        case .listItem:
            let marker = source.substring(with: e.markers[0])
            let indent = source.substring(with: NSRange(location: e.range.location, length: e.markers[0].location - e.range.location))
            var next = marker
            if let n = Int(marker.dropLast()) { next = "\(n + 1)\(marker.last!)" }
            return indent + next + " " + (LiveProjection.isTask(source, e.content) ? "[ ] " : "")
        default:
            return nil
        }
    }

    // MARK: - Formatting

    /// Wrap display `selection` in `marker`, or unwrap the span of `kind`
    /// it is in.
    public func toggle(_ kind: LiveMarkdown.Element.Kind, marker: String, selection: NSRange) -> Edit {
        let s = projection.sourceRange(selection)
        if let e = elements.first(where: { $0.kind == kind && $0.content.location <= s.location && NSMaxRange(s) <= NSMaxRange($0.content) }) {
            let m = e.content.location - e.range.location
            return .replace(e.range, with: source.substring(with: e.content), selection: NSRange(location: s.location - m, length: s.length))
        }
        // Markdown can't open emphasis before a space, so whitespace at the
        // ends stays outside the markers.
        var r = s
        while r.length > 0, isSpace(r.location) { r = NSRange(location: r.location + 1, length: r.length - 1) }
        while r.length > 0, isSpace(NSMaxRange(r) - 1) { r.length -= 1 }
        let text = source.substring(with: r)
        guard r.length > 0, !text.contains("\n"), !projection.atoms.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) else { return .none }
        let m = length(marker)
        return .replace(r, with: marker + text + marker, selection: NSRange(location: r.location + m, length: r.length))
    }

    // MARK: -

    /// The hidden prefix of a heading, list item or quote line.
    private func linePrefix(_ e: LiveMarkdown.Element) -> NSRange {
        if case .listItem = e.kind { return LiveProjection.prefix(of: e, in: source) }
        return e.markers[0]
    }

    /// The line holding `p`, without its newline.
    private func line(containing p: Int) -> NSRange {
        var start = 0, end = 0
        source.getLineStart(&start, end: nil, contentsEnd: &end, for: NSRange(location: min(p, source.length), length: 0))
        return NSRange(location: start, length: end - start)
    }

    private func isLine(_ k: LiveMarkdown.Element.Kind) -> Bool {
        switch k {
        case .heading, .listItem, .quote: true
        default: false
        }
    }

    private func isHeading(_ k: LiveMarkdown.Element.Kind) -> Bool {
        if case .heading = k { true } else { false }
    }

    private func isCode(_ k: LiveMarkdown.Element.Kind) -> Bool {
        if case .codeBlock = k { true } else { false }
    }

    private func isBlank(_ r: NSRange) -> Bool {
        source.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isSpace(_ i: Int) -> Bool {
        let c = source.character(at: i)
        return c == 0x20 || c == 0x09
    }

    private func caret(_ p: Int) -> NSRange { NSRange(location: p, length: 0) }

    private func length(_ s: String) -> Int { (s as NSString).length }
}

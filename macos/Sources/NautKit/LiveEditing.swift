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
/// first, Return continues a list, ``` or $$ then Return makes a block,
/// and `$$` alone on a line makes a closed equation as it is typed.
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
        // `$$` on a line of its own makes the equation at once, closed: an
        // open `$$` would take everything down to the next one into it.
        if s == "$", at.before.isEmpty, at.after.isEmpty, opensEquation(at.position) {
            return .replace(caret(at.position), with: "$\n\n$$", selection: caret(at.position + 2))
        }
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
            let gone = atom.isBlock ? withLine(atom.range) : atom.range
            return .replace(gone, with: "", selection: caret(gone.location))
        }

        // A newline: joining two lines where block syntax may be hidden.
        if range.length == 1, source.character(at: range.location) == 0x0A {
            return deleteNewline(at: range.location, display: r, backward: r.location < selection.location)
        }
        return remove(range)
    }

    /// Backspace with the caret at display `p`, where it does something
    /// other than delete the character before: at the start of a heading's,
    /// quote's or list item's text it takes the line's syntax, a nested
    /// item one level out first; at the start of an empty code block it
    /// takes the block. Nil where backspace just deletes.
    ///
    /// Asked before the text view picks what to delete, because at the
    /// start of the note there is nothing to delete and it would not ask.
    public func backspace(at p: Int, preferring: Int? = nil) -> Edit? {
        let i = projection.insertion(at: p, preferring: preferring)
        guard i.before.isEmpty, i.after.isEmpty else { return nil }
        let at = i.position
        if let e = elements.first(where: { isLine($0.kind) && NSMaxRange(linePrefix($0)) == at }) {
            let prefix = linePrefix(e)
            if case .listItem = e.kind, let step = indentStep(at: prefix.location) {
                return .replace(step, with: "", selection: caret(at - step.length))
            }
            return .replace(prefix, with: "", selection: caret(prefix.location))
        }
        if let e = elements.first(where: { isCode($0.kind) && $0.content.location == at }), isBlank(e.content) {
            let block = LiveProjection.trimmed(e.scope, in: source)
            return .replace(block, with: "", selection: caret(block.location))
        }
        return nil
    }

    /// Remove source `range`, which a display selection stands for. Hidden
    /// syntax strictly inside goes with it; a code block that loses one
    /// fence that way loses the other too, so what is left of its code
    /// joins the text instead of an unpaired ``` showing. A selection of
    /// all of a block's lines takes the block.
    private func remove(_ range: NSRange) -> Edit {
        var cuts = [range]
        for e in elements where isCode(e.kind) {
            let open = NSRange(location: e.markers[0].location, length: e.content.location - e.markers[0].location)
            let close = e.markers[1]
            let hasOpen = NSIntersectionRange(range, open).length > 0
            let hasClose = NSIntersectionRange(range, close).length > 0
            if hasOpen, !hasClose {
                cuts.append(withLine(close))
            } else if hasClose, !hasOpen {
                cuts.append(open)
            } else if !hasOpen, range.location == e.content.location, NSMaxRange(range) == close.location, e.content.length > 0 {
                cuts = [withLine(LiveProjection.trimmed(e.scope, in: source))]
            }
        }
        cuts.sort { $0.location < $1.location }
        let all = cuts.dropFirst().reduce(cuts[0]) { NSUnionRange($0, $1) }
        var kept = "", before = 0, at = all.location
        for cut in cuts {
            if cut.location > at {
                kept += source.substring(with: NSRange(location: at, length: cut.location - at))
                if cut.location <= range.location { before = length(kept) }
            }
            at = max(at, NSMaxRange(cut))
        }
        return .replace(all, with: kept, selection: caret(all.location + before))
    }

    /// `r`, whole lines, with one of the newlines around it: the one
    /// after, or at the end of the note the one before.
    private func withLine(_ r: NSRange) -> NSRange {
        if NSMaxRange(r) < source.length { return NSRange(location: r.location, length: r.length + 1) }
        if r.location > 0 { return NSRange(location: r.location - 1, length: r.length + 1) }
        return r
    }

    /// Deleting the newline at source `n`. Hidden block syntax may start
    /// right after it, or a block may end right before it.
    private func deleteNewline(at n: Int, display r: NSRange, backward: Bool) -> Edit {
        let plain = Edit.replace(NSRange(location: n, length: 1), with: "", selection: caret(n))
        let next = n + 1

        // A heading, list item or quote below joins the line above as
        // text: its syntax goes with the newline.
        if let e = elements.first(where: { isLine($0.kind) && $0.range.location == next }) {
            return .replace(NSRange(location: n, length: NSMaxRange(linePrefix(e)) - n), with: "", selection: caret(n))
        }

        // Into a code block's opening fence from the line above: a blank
        // line above goes; otherwise nothing, as the fence can't share its
        // line.
        if elements.contains(where: { isCode($0.kind) && $0.markers[0].location == next }) {
            return isBlank(line(containing: n)) ? plain : .none
        }

        // The newline ending a code block's last line, its closing fence
        // next: backspace from the line below the block, or forward delete
        // at the end of the code. A blank line below goes instead; otherwise
        // the caret moves to the end of the code.
        if let e = elements.first(where: { isCode($0.kind) && $0.markers.count == 2 && $0.markers[1].location == next }) {
            let fence = e.markers[1]
            if NSMaxRange(fence) < source.length {
                let below = line(containing: NSMaxRange(fence) + 1)
                if isBlank(below) {
                    // The blank line's own newline, or, if it ends the note,
                    // the fence's.
                    let gone = NSMaxRange(below) < source.length ? NSMaxRange(below) : NSMaxRange(fence)
                    return .replace(NSRange(location: gone, length: 1), with: "", selection: caret(min(below.location, gone)))
                }
            }
            return backward ? .select(NSRange(location: r.location, length: 0)) : .none
        }

        // Next to a block: a blank line beside it goes, and the block is
        // selected; so it is when the line has text, which can't join it.
        if let atom = projection.atoms.first(where: { $0.isBlock && ($0.range.location == next || NSMaxRange($0.range) == n) }) {
            let above = atom.range.location == next
            let other = above ? line(containing: n) : line(containing: next)
            guard isBlank(other) else {
                return .select(NSRange(location: projection.display(at: atom.range.location), length: 1))
            }
            let gone = above ? NSRange(location: other.location, length: other.length + 1) : NSRange(location: n, length: other.length + 1)
            return .replace(gone, with: "", selection: NSRange(location: above ? other.location : atom.range.location, length: atom.range.length))
        }
        return plain
    }

    // MARK: - Tab

    /// Tab and Shift-Tab at display `selection`: nest the list items it
    /// touches one level in or out; in a code block, indent the line.
    /// Nil where Tab has nothing to do, as in a paragraph: a tab there
    /// would be an indented code block to Markdown.
    public func indent(_ selection: NSRange, outdent: Bool) -> Edit? {
        let s = selection.length == 0
            ? caret(projection.insertion(at: selection.location).position)
            : projection.sourceRange(selection)
        if selection.length == 0, elements.contains(where: { isCode($0.kind) && s.location >= $0.content.location && s.location <= NSMaxRange($0.content) }) {
            if !outdent { return .replace(s, with: "    ", selection: caret(s.location + 4)) }
            let l = line(containing: s.location)
            var n = 0
            while n < 4, n < l.length, source.character(at: l.location + n) == 0x20 { n += 1 }
            guard n > 0 else { return Edit.none }
            return .replace(NSRange(location: l.location, length: n), with: "", selection: caret(max(l.location, s.location - n)))
        }

        var lines: [NSRange] = []
        var at = line(containing: s.location)
        while true {
            lines.append(at)
            guard NSMaxRange(at) < NSMaxRange(s), NSMaxRange(at) < source.length else { break }
            at = line(containing: NSMaxRange(at) + 1)
        }
        let items = lines.filter { l in elements.contains { if case .listItem = $0.kind { $0.range.location == l.location } else { false } } }
        guard !items.isEmpty else { return nil }
        if !outdent {
            // An item nests under the one above it, one level at most.
            let first = items[0]
            guard first.location > 0 else { return Edit.none }
            let above = line(containing: first.location - 1)
            guard elements.contains(where: { if case .listItem = $0.kind { $0.range.location == above.location } else { false } }),
                  indentWidth(first) <= indentWidth(above) else { return Edit.none }
        }

        let all = NSUnionRange(items[0], items[items.count - 1])
        var out = "", cursor = all.location
        var start = s.location, end = NSMaxRange(s)
        for l in items {
            out += source.substring(with: NSRange(location: cursor, length: l.location - cursor))
            cursor = l.location
            var delta = 0
            if outdent, let step = indentStep(at: l.location) {
                cursor += step.length
                delta = -step.length
            } else if !outdent {
                out += "  "
                delta = 2
            }
            if s.location >= l.location { start = max(l.location, start + delta) }
            if NSMaxRange(s) >= l.location { end = max(l.location, end + delta) }
        }
        out += source.substring(with: NSRange(location: cursor, length: NSMaxRange(all) - cursor))
        guard out != source.substring(with: all) else { return Edit.none }
        return .replace(all, with: out, selection: NSRange(location: start, length: max(0, end - start)))
    }

    /// One level of indent at the start of the line at `l`: two spaces
    /// (or the one there is), or a tab.
    private func indentStep(at l: Int) -> NSRange? {
        guard l < source.length else { return nil }
        if source.character(at: l) == 0x09 { return NSRange(location: l, length: 1) }
        guard source.character(at: l) == 0x20 else { return nil }
        let two = l + 1 < source.length && source.character(at: l + 1) == 0x20
        return NSRange(location: l, length: two ? 2 : 1)
    }

    /// A line's indent, a tab counting as two spaces.
    private func indentWidth(_ l: NSRange) -> Int {
        var n = 0, i = l.location
        while i < NSMaxRange(l) {
            let c = source.character(at: i)
            if c == 0x20 { n += 1 } else if c == 0x09 { n += 2 } else { break }
            i += 1
        }
        return n
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

    /// Whether a `$` typed at source `p` makes its line `$$` and that opens
    /// an equation, rather than closing one left open above, as when its
    /// closing `$$` is typed by hand.
    private func opensEquation(_ p: Int) -> Bool {
        let l = line(containing: p)
        guard p == NSMaxRange(l), (source.substring(with: l) + "$").trimmingCharacters(in: .whitespaces) == "$$" else { return false }
        var open = false
        source.substring(to: l.location).enumerateLines { line, _ in
            if line.trimmingCharacters(in: .whitespaces) == "$$" { open.toggle() }
        }
        return !open
    }

    private func length(_ s: String) -> Int { (s as NSString).length }

    // MARK: - Blocks

    /// Put `markdown`, a block such as a pasted picture, on a line of its
    /// own in place of display range `r`. The caret goes to the line after
    /// it, made if the block ends the note.
    public func insertBlock(_ markdown: String, over r: NSRange) -> Edit {
        let range = r.length > 0 ? projection.sourceRange(r) : caret(projection.insertion(at: r.location).position)
        let end = NSMaxRange(range)
        let before = range.location > 0 && source.character(at: range.location - 1) != 0x0A ? "\n" : ""
        let after = end < source.length && source.character(at: end) == 0x0A ? "" : "\n"
        return .replace(range, with: before + markdown + after, selection: caret(range.location + length(before + markdown) + 1))
    }

    /// Move the block whose source lines are `r` (whole lines, as an
    /// element's `scope`) to just before the line starting at source `to`,
    /// or to the end of the note. A drop inside another block lands
    /// above it. The moved block ends up selected.
    public func moveBlock(_ r: NSRange, to target: Int) -> Edit {
        let to = blockBoundary(target)
        guard to < r.location || to > NSMaxRange(r) else { return .none }
        var block = source.substring(with: r)
        if !block.hasSuffix("\n") { block += "\n" }
        var rest = source.replacingCharacters(in: r, with: "")
        // The block was the last line: the newline that led to it goes too.
        if NSMaxRange(r) == source.length, rest.hasSuffix("\n") { rest.removeLast() }
        var at = to > r.location ? to - r.length : to
        at = min(at, length(rest))
        if at == length(rest), !rest.isEmpty, !rest.hasSuffix("\n") {
            block = "\n" + block.dropLast()
        }
        let moved = (rest as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: block)
        let lead = block.hasPrefix("\n") ? 1 : 0
        let shown = LiveProjection.trimmed(NSRange(location: at + lead, length: length(block) - lead), in: moved as NSString)
        return .replace(NSRange(location: 0, length: source.length), with: moved, selection: shown)
    }

    /// Where a block dropped at the start of source line `p` lands: there,
    /// or above the block (code, equation, table) whose lines `p` is
    /// inside, since a block can't be split.
    public func blockBoundary(_ p: Int) -> Int {
        elements.first { ($0.kind.isBlockAtom || isCode($0.kind)) && $0.scope.location < p && p < NSMaxRange($0.scope) }?.scope.location ?? p
    }

    /// Show the picture at element `i` `width` points wide: `|width` at
    /// the end of its alt text, as libnaut reads it. Nil takes it off.
    public func resizeImage(_ i: Int, width: Int?) -> Edit {
        let e = elements[i]
        guard case .image = e.kind,
              let m = LiveMarkdown.image.firstMatch(in: source as String, range: e.range)
        else { return .none }
        let label = m.range(at: 1)
        let alt = LiveMarkdown.imageWidth(source.substring(with: label)).alt
        let new = width.map { "\(alt)|\($0)" } ?? alt
        return .replace(label, with: new, selection: NSRange(location: e.range.location, length: e.range.length - label.length + length(new)))
    }
}

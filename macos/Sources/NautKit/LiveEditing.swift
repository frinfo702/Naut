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
            let s = cell(at: range.location) == nil ? s : cellText(s)
            if let kept = keepingTables(range) {
                guard case let .replace(cut, rest, after) = kept else { return .none }
                let at = after.location - cut.location
                let text = (rest as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: s)
                return .replace(cut, with: text, selection: caret(after.location + length(s)))
            }
            return .replace(range, with: s, selection: caret(range.location + length(s)))
        }
        let at = projection.insertion(at: r.location, preferring: preferring, newline: s.contains("\n"))
        if cell(at: at.position) != nil, at.before.isEmpty, at.after.isEmpty {
            let s = cellText(s)
            return .replace(caret(at.position), with: s, selection: caret(at.position + length(s)))
        }
        // `$$` on a line of its own makes the equation at once, closed: an
        // open `$$` would take everything down to the next one into it.
        if s == "$", at.before.isEmpty, at.after.isEmpty, opensEquation(at.position) {
            return .replace(caret(at.position), with: "$\n\n$$", selection: caret(at.position + 2))
        }
        if at.before.isEmpty, at.after.isEmpty, let shortcut = shortcut(s, at: at.position) { return shortcut }
        // Text on an empty quote line, `>` alone: the space it needs to
        // stay a quote line once it has text.
        if at.before.isEmpty, let q = elements.first(where: { $0.kind == .quote && NSMaxRange($0.markers[0]) == at.position && $0.content.length == 0 }),
           !source.substring(with: q.markers[0]).hasSuffix(" "), !source.substring(with: q.markers[0]).hasSuffix("\t") {
            let space = s.hasPrefix(" ") || s.hasPrefix("\t") ? "" : " "
            return .replace(caret(at.position), with: space + s + at.after, selection: caret(at.position + length(space + s)))
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

        if let kept = keepingTables(range) { return kept }

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
        // In a table, Tab goes to the next cell, Shift-Tab the one before.
        if let c = cell(at: projection.sourceRange(NSRange(location: selection.location, length: 0)).location) {
            return move(from: c, by: outdent ? -1 : 1)
        }
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
        // In a table, Return goes to the cell below, as in Linear.
        if let c = cell(at: at) { return move(from: c, by: c.table.cells[c.row].count) }
        let l = line(containing: at)
        let t = source.substring(with: l).trimmingCharacters(in: .whitespaces)
        // At an element's end only if that end is on this line: the empty
        // line after a list is past the last item, not in it.
        let element = elements.first {
            (isLine($0.kind) || isCode($0.kind))
                && (NSLocationInRange(at, $0.scope) || at == NSMaxRange($0.scope) && $0.scope.length > 0 && NSMaxRange($0.scope) > l.location)
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

    // MARK: - Shortcuts

    /// Linear's typed shortcuts that Markdown itself doesn't have, for `s`
    /// typed at the end of its line at source `p`:
    ///
    /// - `[]` then Space makes a checklist item, `- [ ] `.
    /// - `---` or `___` is a divider at once, so the caret goes below it:
    ///   it is drawn as a block, with no text to be in.
    /// - `|--` makes a table of two columns.
    private func shortcut(_ s: String, at p: Int) -> Edit? {
        let l = line(containing: p)
        guard p == NSMaxRange(l) else { return nil }
        let typed = source.substring(with: l) + s
        let lead = String(typed.prefix { $0 == " " || $0 == "\t" })
        let rest = typed.dropFirst(lead.count)
        if s == " ", let bullet = rest.firstMatch(of: #/^(?:([-*+]|\d+[.)]) )?\[\] $/#) {
            let item = lead + (bullet.1.map { "\($0) " } ?? "- ") + "[ ] "
            return .replace(l, with: item, selection: caret(l.location + length(item)))
        }
        if s == " ", typed == "___ " || typed == "*** " {
            let below = NSMaxRange(l) < source.length
            return .replace(l, with: below ? "---" : "---\n", selection: caret(l.location + 4))
        }
        if typed == "---" {
            let below = NSMaxRange(l) < source.length && isBlank(line(containing: NSMaxRange(l) + 1))
            if below { return .replace(caret(p), with: s, selection: caret(p + 2)) }
            return .replace(caret(p), with: s + "\n", selection: caret(p + 2))
        }
        if typed == "|--" {
            // The caret in its first cell, to type the header.
            return .replace(l, with: Self.newTable + (NSMaxRange(l) == source.length ? "\n" : ""), selection: caret(l.location + 2))
        }
        return nil
    }

    // MARK: - Blocks by line

    /// What a line can be made into: by ⌘⇧7/8/9, or the `/` menu.
    public enum LineStyle: Equatable, Sendable {
        case paragraph
        case heading(Int)
        case bullet, numbered, task, quote
    }

    /// Make every line of display `selection` `style`. With `toggle`, lines
    /// that all are already go back to paragraphs, as ⌘⇧8 on a list ends
    /// it. A list keeps a line's indent; numbers count on from an item of
    /// the same list just above.
    public func make(_ style: LineStyle, selection: NSRange, toggle: Bool = false) -> Edit {
        make(style, source: projection.sourceRange(selection), toggle: toggle)
    }

    /// `make` over source range `s`.
    public func make(_ style: LineStyle, source s: NSRange, toggle: Bool = false) -> Edit {
        guard !inBlock(s) else { return .none }
        var lines = lines(s)
        if lines.count > 1 { lines = lines.filter { !isBlank($0) } }
        guard let first = lines.first, let last = lines.last else { return .none }
        let all = lines.allSatisfy { lineStyle($0) == style }
        let target: LineStyle = toggle && all ? .paragraph : style

        var number = 1
        if target == .numbered, first.location > 0, let n = numberedItem(line(containing: first.location - 1)) { number = n + 1 }
        let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var out = source.substring(with: whole) as NSString
        // From the last line up, so earlier ranges stay put.
        var selection = s
        for l in lines.reversed() {
            let old = prefix(of: l)
            let indent = source.substring(with: NSRange(location: l.location, length: old.indent))
            let n = number + lines.firstIndex(of: l)!
            let new = (isList(target) ? indent : "") + marker(target, number: n)
            out = out.replacingCharacters(in: NSRange(location: l.location - whole.location, length: old.length), with: new) as NSString
            selection = shift(selection, at: l.location, removed: old.length, inserted: length(new))
        }
        return .replace(whole, with: out as String, selection: selection)
    }

    /// ⌘Return: check the checklist items in display `selection`, or
    /// uncheck them if all are checked.
    public func check(_ selection: NSRange) -> Edit {
        let s = projection.sourceRange(selection)
        let tasks = lines(s).compactMap { l -> NSRange? in
            let t = source.substring(with: l)
            guard let m = t.firstMatch(of: #/^[ \t]*(?:[-*+]|\d+[.)])[ \t]+\[([ xX])\] /#) else { return nil }
            return NSRange(location: l.location + t.utf16.distance(from: t.startIndex, to: m.1.startIndex), length: 1)
        }
        guard !tasks.isEmpty else { return .none }
        let done = tasks.allSatisfy { source.substring(with: $0) != " " }
        let whole = NSRange(location: tasks[0].location, length: NSMaxRange(tasks[tasks.count - 1]) - tasks[0].location)
        let out = NSMutableString(string: source.substring(with: whole))
        for t in tasks { out.replaceCharacters(in: NSRange(location: t.location - whole.location, length: 1), with: done ? " " : "x") }
        return .replace(whole, with: out as String, selection: s)
    }

    /// ⌘⇧\\: put the lines of display `selection` in a code block, or an
    /// empty one on an empty line; in a code block, take its fences off.
    public func codeBlock(_ selection: NSRange) -> Edit {
        codeBlock(source: projection.sourceRange(selection))
    }

    public func codeBlock(source s: NSRange) -> Edit {
        if let e = elements.first(where: { isCode($0.kind) && NSLocationInRange(s.location, $0.scope) }) {
            let open = e.markers[0], close = e.markers[1]
            let whole = NSRange(location: open.location, length: NSMaxRange(close) - open.location)
            let cut = e.content.location - open.location
            let start = max(s.location - cut, open.location)
            return .replace(whole, with: source.substring(with: e.content),
                            selection: NSRange(location: start, length: min(s.length, e.content.length)))
        }
        guard !inBlock(s) else { return .none }
        let lines = lines(s)
        let whole = NSRange(location: lines[0].location, length: NSMaxRange(lines[lines.count - 1]) - lines[0].location)
        let text = source.substring(with: whole)
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return .replace(whole, with: "```\n\n```", selection: caret(whole.location + 4))
        }
        return .replace(whole, with: "```\n" + text + "\n```", selection: NSRange(location: s.location + 4, length: s.length))
    }

    /// Put a divider, table or equation at source `p`'s line: in place of
    /// it if empty, else below it. The caret goes below a divider, inside
    /// a table or equation, which the editor then opens.
    public enum Insert: Sendable { case divider, table, equation }

    public func insert(_ block: Insert, source p: Int) -> Edit {
        guard !inBlock(caret(p)) else { return .none }
        let l = line(containing: p)
        let empty = isBlank(l)
        let at = empty ? l : caret(NSMaxRange(l))
        let lead = empty ? "" : "\n"
        let body: String, inside: Int
        switch block {
        case .divider: (body, inside) = ("---\n", 4)
        case .table: (body, inside) = (Self.newTable + "\n", 2)
        case .equation: (body, inside) = ("$$\n\n$$", 3)
        }
        let start = at.location + length(lead)
        // A divider that ends the note still has a line below it for the caret.
        let tail = (block == .divider || block == .table) && NSMaxRange(at) < source.length && source.character(at: NSMaxRange(at)) == 0x0A ? String(body.dropLast()) : body
        return .replace(at, with: lead + tail, selection: caret(start + inside))
    }

    /// Three columns, a header and two rows, all empty. A table is always
    /// given a newline after it: an empty last cell ending the note would
    /// have no character to be laid out in, and its row came out short.
    static let newTable = "|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |"

    // MARK: - Tables

    /// A table cell: its table, row (0 the header) and column.
    struct Cell {
        var table: LiveMarkdown.Element
        var row: Int
        var col: Int
        var range: NSRange { table.cells[row][col] }
    }

    private var tables: [LiveMarkdown.Element] {
        elements.filter { if case .table = $0.kind { true } else { false } }
    }

    /// The cell whose text holds source position `p`, at either end too.
    private func cell(at p: Int) -> Cell? {
        for t in tables where t.range.location <= p && p <= NSMaxRange(t.range) {
            for (r, row) in t.cells.enumerated() {
                if let c = row.firstIndex(where: { $0.location <= p && p <= NSMaxRange($0) }) { return Cell(table: t, row: r, col: c) }
            }
        }
        return nil
    }

    /// Text typed into a cell: a pipe would end it, and it has one line.
    private func cellText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\|", with: "|").replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// Deleting source `range` where it reaches a table's pipes and
    /// delimiter row, or the newlines holding it apart from the text
    /// around it: only the cells' text goes, so the table stays a table.
    /// All of a table selected goes whole. Nil if no table is touched.
    private func keepingTables(_ asked: NSRange) -> Edit? {
        // A selection of every cell's text is all of the table, its hidden
        // pipes at either end too.
        var range = asked
        var whole: [NSRange] = []
        for t in tables {
            guard let first = t.cells.first?.first, let last = t.cells.last?.last,
                  range.location <= shownStart(first), NSMaxRange(range) >= shownEnd(last) else { continue }
            whole.append(t.range)
            range = NSUnionRange(range, t.range)
        }
        var kept = IndexSet()
        for t in tables {
            let whole = t.range
            if range.location <= whole.location, NSMaxRange(range) >= NSMaxRange(whole) { continue }
            var s = IndexSet(integersIn: Range(whole)!)
            for c in t.cells.joined() { s.remove(integersIn: Range(c)!) }
            if whole.location > 0, !isBlank(line(containing: whole.location - 1)) { s.insert(whole.location - 1) }
            if NSMaxRange(whole) < source.length, NSMaxRange(whole) + 1 <= source.length, !isBlank(line(containing: NSMaxRange(whole) + 1)) {
                s.insert(NSMaxRange(whole))
            }
            kept.formUnion(s)
        }
        guard kept.intersects(integersIn: Range(range)!) else {
            return whole.isEmpty ? nil : .replace(range, with: "", selection: caret(range.location))
        }
        var rest: [unichar] = []
        var first: Int?
        for i in range.location ..< NSMaxRange(range) {
            if kept.contains(i) { rest.append(source.character(at: i)) } else if first == nil { first = i }
        }
        guard let first else { return Edit.none }
        return .replace(range, with: String(utf16CodeUnits: rest, count: rest.count), selection: caret(first))
    }

    /// Where the shown text of source range `r` starts and ends: inside
    /// any markers hidden at its edges.
    private func shownStart(_ r: NSRange) -> Int {
        let d = projection.display(at: r.location)
        return d < projection.units.count && projection.units[d].location < NSMaxRange(r) ? projection.units[d].location : r.location
    }

    private func shownEnd(_ r: NSRange) -> Int {
        let d = projection.display(at: NSMaxRange(r))
        return d > 0 && projection.units[d - 1].location >= r.location ? NSMaxRange(projection.units[d - 1]) : r.location
    }

    /// The cell `step` cells on from `c`, in reading order; past the last,
    /// a new row is added. Its text is selected, as Tab does in Linear.
    private func move(from c: Cell, by step: Int) -> Edit {
        let flat = Array(c.table.cells.joined())
        let at = c.table.cells[..<c.row].reduce(0) { $0 + $1.count } + c.col + step
        if at < 0 { return .select(projection.displayRange(c.range)) }
        if at < flat.count { return .select(projection.displayRange(flat[at])) }
        let columns = c.table.cells[0].count
        let row = "|" + String(repeating: "  |", count: columns)
        let end = NSMaxRange(c.table.range)
        let col = step == 1 ? 0 : c.col
        return .replace(caret(end), with: "\n" + row + (end == source.length ? "\n" : ""), selection: caret(end + 3 + 3 * col))
    }

    /// Where the caret at display `p` in a table cell goes with the Down
    /// arrow (`down`) or Up: as far into the cell below or above, the
    /// same column; from its last or first row, to the line below or above
    /// the table. Nil outside a table, and where the note has no such line.
    ///
    /// The cells of a row are paragraphs side by side, which the text view
    /// steps through as lines: Down went to the row's last cell.
    public func vertical(from p: Int, preferring: Int? = nil, down: Bool) -> Int? {
        guard let c = cell(at: projection.insertion(at: p, preferring: preferring).position) else { return nil }
        let row = c.row + (down ? 1 : -1)
        guard c.table.cells.indices.contains(row) else {
            let all = projection.displayRange(c.table.range)
            if down { return NSMaxRange(all) < projection.display.length ? NSMaxRange(all) + 1 : nil }
            return all.location > 0 ? all.location - 1 : nil
        }
        guard c.col < c.table.cells[row].count else { return nil }
        let from = projection.displayRange(c.range)
        let to = projection.displayRange(c.table.cells[row][c.col])
        return to.location + min(max(0, p - from.location), to.length)
    }

    /// What the table menu does to a table.
    public enum TableChange: Sendable { case addRow, addColumn, deleteRow, deleteColumn, deleteTable }

    /// `change` table element `i`, at the cell holding display `selection`
    /// if it is in that table, else its last cell. The caret goes to the
    /// cell the change made, or the one nearest.
    public func change(_ change: TableChange, table i: Int, selection: NSRange) -> Edit {
        let t = elements[i]
        guard case .table = t.kind, !t.cells.isEmpty else { return .none }
        let p = projection.sourceRange(NSRange(location: min(selection.location, projection.display.length), length: 0)).location
        let here = cell(at: p).flatMap { $0.table.range == t.range ? $0 : nil }
        var r = here?.row ?? t.cells.count - 1
        var c = here?.col ?? t.cells[r].count - 1
        let columns = t.cells.map(\.count).max() ?? 1
        var rows = t.cells.map { row in (0 ..< columns).map { $0 < row.count ? source.substring(with: row[$0]) : "" } }
        var aligns = source.substring(with: t.markers[0]).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        aligns += Array(repeating: "---", count: max(0, columns - aligns.count))
        aligns = Array(aligns.prefix(columns))

        switch change {
        case .deleteTable:
            return .replace(t.scope, with: "", selection: caret(t.scope.location))
        case .addRow:
            rows.insert(Array(repeating: "", count: columns), at: r + 1)
            r += 1
        case .addColumn:
            for k in rows.indices { rows[k].insert("", at: c + 1) }
            aligns.insert("---", at: c + 1)
            c += 1
        case .deleteRow:
            guard rows.count > 1 else { return self.change(.deleteTable, table: i, selection: selection) }
            rows.remove(at: r)
            r = min(r, rows.count - 1)
        case .deleteColumn:
            guard columns > 1 else { return self.change(.deleteTable, table: i, selection: selection) }
            for k in rows.indices { rows[k].remove(at: c) }
            aligns.remove(at: c)
            c = min(c, columns - 2)
        }

        var text = "", target = 0
        func line(_ cells: [String], row: Int?) {
            text += "|"
            for (k, cell) in cells.enumerated() {
                text += " "
                if row == r, k == c { target = length(text) + length(cell) }
                text += cell + " |"
            }
        }
        for (k, row) in rows.enumerated() {
            if k > 0 { text += "\n" }
            line(row, row: k)
            if k == 0 { text += "\n"; line(aligns, row: nil) }
        }
        if NSMaxRange(t.range) == source.length { text += "\n" }
        return .replace(t.range, with: text, selection: caret(t.range.location + target))
    }

    /// The style of source line `l`.
    private func lineStyle(_ l: NSRange) -> LineStyle {
        let t = source.substring(with: l)
        if let m = t.firstMatch(of: #/^(#{1,6})[ \t]+/#) { return .heading(m.1.count) }
        if t.firstMatch(of: #/^[ \t]*>/#) != nil { return .quote }
        if t.firstMatch(of: #/^[ \t]*(?:[-*+]|\d+[.)])[ \t]+\[[ xX]\] /#) != nil { return .task }
        if t.firstMatch(of: #/^[ \t]*\d+[.)][ \t]+/#) != nil { return .numbered }
        if t.firstMatch(of: #/^[ \t]*[-*+][ \t]+/#) != nil { return .bullet }
        return .paragraph
    }

    /// The line prefix of source line `l`, a box included, and the indent
    /// it starts with.
    private func prefix(of l: NSRange) -> (indent: Int, length: Int) {
        let t = source.substring(with: l)
        let m = t.firstMatch(of: #/^([ \t]*)(?:#{1,6}[ \t]+|>[ \t]?|(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\] )?)?/#)!
        return (length(String(m.1)), length(String(m.0)))
    }

    private func marker(_ style: LineStyle, number: Int) -> String {
        switch style {
        case .paragraph: ""
        case let .heading(n): String(repeating: "#", count: n) + " "
        case .bullet: "- "
        case .numbered: "\(number). "
        case .task: "- [ ] "
        case .quote: "> "
        }
    }

    private func isList(_ style: LineStyle) -> Bool {
        [.bullet, .numbered, .task].contains(style)
    }

    private func numberedItem(_ l: NSRange) -> Int? {
        (source.substring(with: l)).firstMatch(of: #/^[ \t]*(\d+)[.)][ \t]+/#).flatMap { Int($0.1) }
    }

    /// The source lines, without newlines, that `s` touches.
    private func lines(_ s: NSRange) -> [NSRange] {
        var out = [line(containing: s.location)]
        while NSMaxRange(out[out.count - 1]) < NSMaxRange(s) {
            out.append(line(containing: NSMaxRange(out[out.count - 1]) + 1))
        }
        return out
    }

    /// Whether `s` is in a code block, or touches a drawn block.
    private func inBlock(_ s: NSRange) -> Bool {
        elements.contains { e in
            (isCode(e.kind) || isTable(e.kind) || e.kind.isBlockAtom) && e.scope.location <= s.location && s.location < NSMaxRange(e.scope)
                && (isCode(e.kind) || isTable(e.kind) ? true : NSIntersectionRange(LiveProjection.trimmed(e.scope, in: source), NSRange(location: s.location, length: max(s.length, 1))).length > 0)
        }
    }

    /// `r` after `removed` characters at `at` became `inserted`: a position
    /// in the removed stretch goes to its new end.
    private func shift(_ r: NSRange, at: Int, removed: Int, inserted: Int) -> NSRange {
        func move(_ p: Int) -> Int {
            if p >= at + removed { return p - removed + inserted }
            if p >= at { return at + inserted }
            return p
        }
        let start = move(r.location)
        return NSRange(location: start, length: max(0, move(NSMaxRange(r)) - start))
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

    private func isTable(_ k: LiveMarkdown.Element.Kind) -> Bool {
        if case .table = k { true } else { false }
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
        elements.first { ($0.kind.isBlockAtom || isCode($0.kind) || isTable($0.kind)) && $0.scope.location < p && p < NSMaxRange($0.scope) }?.scope.location ?? p
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

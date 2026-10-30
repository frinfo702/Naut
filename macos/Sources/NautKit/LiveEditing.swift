import Foundation

/// How a WYSIWYG editor over Markdown moves and edits around syntax it
/// never shows, as Notion does: the caret steps over hidden markers,
/// deleting next to them does what deleting the visible thing would, and
/// typing Markdown shortcuts makes blocks. Pure range arithmetic over
/// `LiveMarkdown.parse`; the editor only applies the answers.
///
/// Ranges are UTF-16, positions are caret positions (between characters).
public struct LiveEditing {
    public let text: NSString
    public let elements: [LiveMarkdown.Element]

    /// Hidden or drawn line prefixes (`## `, `> `, `- `): the caret only
    /// goes after them.
    public private(set) var prefixes: [NSRange] = []
    /// Inline syntax (`**`, `` ` ``, `](url)`) and inline math: the caret
    /// can sit at either edge, never inside.
    public private(set) var inline: [NSRange] = []
    /// Lines the caret never enters: code fences, and blocks edited
    /// elsewhere (math, tables, images).
    public private(set) var zones: [Zone] = []
    /// Elements edited in a popover rather than in the text.
    public private(set) var atoms: [Int] = []

    public struct Zone: Equatable, Sendable {
        /// The lines, without the newline after the last.
        public var range: NSRange
        public var element: Int
        public var isFence: Bool
    }

    public enum Edit: Equatable, Sendable {
        /// Let the text view do what it was going to.
        case allow
        /// Do nothing.
        case ignore
        case replace(NSRange, with: String, select: NSRange)
        case select(NSRange)
    }

    public enum Motion: Sendable { case forward, backward, nearest }

    public init(text: String, elements: [LiveMarkdown.Element]) {
        self.text = text as NSString
        self.elements = elements
        for (i, e) in elements.enumerated() {
            switch e.kind {
            case .heading, .quote:
                prefixes.append(e.markers[0])
            case .listItem:
                // A task's box is part of its prefix.
                let task = Self.isTask(self.text, e.content) ? 4 : 0
                prefixes.append(NSRange(location: e.range.location, length: e.content.location - e.range.location + task))
            case .strong, .emphasis, .strikethrough, .code, .link:
                inline += e.markers
            case .math:
                inline.append(e.range)
                atoms.append(i)
            case .codeBlock:
                zones += e.markers.map { Zone(range: $0, element: i, isFence: true) }
            case .mathBlock, .table, .image:
                zones.append(Zone(range: trimmed(e.scope), element: i, isFence: false))
                atoms.append(i)
            }
        }
    }

    /// The block atom whose lines hold `position`, start and end included.
    public func zone(at position: Int) -> Zone? {
        zones.first { !$0.isFence && $0.range.location <= position && position <= NSMaxRange($0.range) }
    }

    // MARK: - Caret

    /// Where a caret that moved from `old` to `p` should land instead.
    /// Stepping onto hidden syntax steps over it; a click lands on the
    /// nearer side.
    public func snap(_ p: Int, from old: Int, _ motion: Motion) -> Int {
        var p = p
        // Hidden things can sit next to each other (a fence after a
        // block); a few rounds settle any of them.
        for _ in 0..<8 {
            let q = step(p, from: old, motion)
            if q == p { break }
            p = q
        }
        return p
    }

    private func step(_ p: Int, from old: Int, _ motion: Motion) -> Int {
        for z in zones where z.range.location <= p && p <= NSMaxRange(z.range) {
            // The end of the line above, or the start of the line below.
            let above = z.range.location > 0 ? z.range.location - 1 : nil
            let below = NSMaxRange(z.range) < text.length ? NSMaxRange(z.range) + 1 : nil
            let down = motion == .forward || (motion == .nearest && p - z.range.location > NSMaxRange(z.range) - p)
            return (down ? below ?? above : above ?? below) ?? p
        }
        for r in prefixes where r.location <= p && p < NSMaxRange(r) {
            // Left from the start of the text goes up a line; anything else
            // (a click, up or down) lands after the prefix.
            if motion == .backward, old == NSMaxRange(r), r.location > 0 { return r.location - 1 }
            return NSMaxRange(r)
        }
        for r in inline {
            let s = r.location, e = NSMaxRange(r)
            if s < p && p < e {
                switch motion {
                case .forward: return e
                case .backward: return s
                case .nearest: return p - s <= e - p ? s : e
                }
            }
            // Both edges of a hidden run look the same; arriving at one
            // steps to the other so no keypress seems to do nothing.
            if motion == .forward, p == s, old < p, s < e { return e }
            if motion == .backward, p == e, old > p, s < e { return s }
        }
        return p
    }

    /// A selection grown to whole syntax at either end, so cutting or
    /// deleting it never leaves half a marker.
    public func expand(_ r: NSRange) -> NSRange {
        var s = r.location, e = NSMaxRange(r)
        for z in zones.map(\.range) + prefixes + inline {
            if z.location < s && s < NSMaxRange(z) { s = z.location }
            if z.location < e && e < NSMaxRange(z) { e = NSMaxRange(z) }
        }
        return NSRange(location: s, length: e - s)
    }

    // MARK: - Deleting

    /// What deleting `r` should do, the caret or selection being
    /// `selection`.
    public func delete(_ r: NSRange, selection: NSRange) -> Edit {
        guard r.length > 0 else { return .allow }
        // Deleting all of a span's text deletes its markers too, so `****`
        // isn't left behind.
        if let e = elements.first(where: { isSpan($0.kind) && $0.content == r }) {
            return .replace(e.range, with: "", select: NSRange(location: e.range.location, length: 0))
        }
        if selection.length > 0 { return .allow }
        let backward = r.location < selection.location

        // An inline atom is selected first, then deleted.
        if let i = atoms.first(where: { NSIntersectionRange(elements[$0].range, r).length > 0 && !isBlock(elements[$0].kind) }) {
            return .select(elements[i].range)
        }

        // A newline joining a line to a zone.
        if r.length == 1, text.character(at: r.location) == 0x0A {
            let above = line(at: r.location)
            let below = line(at: r.location + 1)
            let za = zones.first { touches($0.range, above) }
            let zb = zones.first { touches($0.range, below) }
            if za != nil || zb != nil {
                // Joining an empty line to a zone leaves the zone as it was.
                if (za != nil && isBlank(below)) || (zb != nil && isBlank(above)) { return .allow }
                return into(backward ? (za ?? zb)! : (zb ?? za)!, backward: backward, selection: selection)
            }
        }
        if let z = zones.first(where: { NSIntersectionRange($0.range, r).length > 0 }) {
            return into(z, backward: backward, selection: selection)
        }

        // Deleting into a line's prefix turns it into a plain paragraph.
        if let p = prefixes.first(where: { NSIntersectionRange($0, r).length > 0 }) {
            return .replace(p, with: "", select: NSRange(location: p.location, length: 0))
        }

        // Deleting a hidden marker deletes the visible character past it.
        if let run = inline.first(where: { NSIntersectionRange($0, r).length == r.length }) {
            let i = backward ? run.location - 1 : NSMaxRange(run)
            guard i >= 0, i < text.length else { return .ignore }
            let c = text.rangeOfComposedCharacterSequence(at: i)
            // The last character of a span takes the span with it.
            if let e = elements.first(where: { isSpan($0.kind) && $0.content == c }) {
                return .replace(e.range, with: "", select: NSRange(location: e.range.location, length: 0))
            }
            return .replace(c, with: "", select: NSRange(location: backward ? c.location : selection.location, length: 0))
        }
        return .allow
    }

    /// Deleting toward zone `z` from outside it.
    private func into(_ z: Zone, backward: Bool, selection: NSRange) -> Edit {
        let e = elements[z.element]
        guard z.isFence else {
            // An atom is selected first, then deleted, as in Notion.
            return .select(z.range)
        }
        // An empty code block goes as a whole.
        if isBlank(e.content) {
            let block = trimmed(e.scope)
            return .replace(block, with: "", select: NSRange(location: block.location, length: 0))
        }
        // From inside, its own fence stops the caret; from outside, the
        // caret moves into the code.
        if e.content.location <= selection.location, selection.location <= NSMaxRange(e.content) { return .ignore }
        let to = backward ? NSMaxRange(e.content) : e.content.location
        return .select(NSRange(location: to, length: 0))
    }

    // MARK: - Typing

    /// Typing `s` over `r`: text typed where a block starts goes on a new
    /// line above it, so the block's syntax stays whole.
    public func insert(_ r: NSRange, _ s: String) -> Edit {
        guard r.length == 0, zones.contains(where: { $0.range.location == r.location && r.location < NSMaxRange($0.range) }) else { return .allow }
        return .replace(r, with: s + "\n", select: NSRange(location: r.location + (s as NSString).length, length: 0))
    }

    /// What Return does at `selection`.
    public func newline(_ selection: NSRange) -> Edit {
        guard selection.length == 0 else { return .allow }
        let p = selection.location
        let l = line(at: p)
        let t = text.substring(with: l).trimmingCharacters(in: .whitespaces)
        let containing = elements.firstIndex { NSLocationInRange(p, $0.scope) || p == NSMaxRange($0.scope) && p == text.length && $0.scope.length > 0 }

        // ``` or $$ then Return makes the block and puts the caret in it.
        if p == NSMaxRange(l), containing.map({ !isBlock(elements[$0].kind) && !isCode(elements[$0].kind) }) ?? true {
            if let fence = ["```", "~~~"].first(where: { t.hasPrefix($0) }), !t.dropFirst(3).contains(where: { $0 == "`" || $0 == " " }) {
                return .replace(NSRange(location: p, length: 0), with: "\n\n" + fence, select: NSRange(location: p + 1, length: 0))
            }
            if t == "$$" {
                return .replace(NSRange(location: p, length: 0), with: "\n\n$$", select: NSRange(location: p + 1, length: 0))
            }
        }

        guard let i = containing else { return .allow }
        let e = elements[i]
        switch e.kind {
        case .codeBlock:
            guard NSLocationInRange(p, e.content) || p == NSMaxRange(e.content), e.markers.count == 2 else { return .allow }
            // Return on an empty last line leaves the block.
            if l.length == 0, NSMaxRange(l) == NSMaxRange(e.content), l.location > e.content.location {
                let fence = e.markers[1]
                let tail = NSMaxRange(fence) == text.length ? "\n" : ""
                let replaced = NSRange(location: l.location, length: NSMaxRange(fence) - l.location)
                let with = text.substring(with: fence) + tail
                return .replace(replaced, with: with, select: NSRange(location: l.location + fence.length + 1, length: 0))
            }
            // Keep the indent.
            let indent = String(text.substring(with: l).prefix { $0 == " " || $0 == "\t" })
            return .replace(NSRange(location: p, length: 0), with: "\n" + indent, select: NSRange(location: p + 1 + (indent as NSString).length, length: 0))
        case .heading, .listItem, .quote:
            let prefix = NSRange(location: e.range.location, length: e.content.location - e.range.location)
            // Return on an empty item ends the list (or heading, or quote).
            if isBlank(e.content) {
                return .replace(prefix, with: "", select: NSRange(location: prefix.location, length: 0))
            }
            // At the start of the text, a new line above.
            if p <= e.content.location {
                if case .heading = e.kind {
                    return .replace(NSRange(location: l.location, length: 0), with: "\n", select: NSRange(location: e.content.location + 1, length: 0))
                }
                let next = continuation(e) ?? ""
                return .replace(NSRange(location: l.location, length: 0), with: next + "\n", select: NSRange(location: e.content.location + (next as NSString).length + 1, length: 0))
            }
            guard let next = continuation(e) else { return .allow }
            return .replace(NSRange(location: p, length: 0), with: "\n" + next, select: NSRange(location: p + 1 + (next as NSString).length, length: 0))
        default:
            return .allow
        }
    }

    /// The prefix for the item after `e`: the same bullet, the next
    /// number, an unchecked box if `e` has one.
    private func continuation(_ e: LiveMarkdown.Element) -> String? {
        let prefix = text.substring(with: NSRange(location: e.range.location, length: e.content.location - e.range.location))
        switch e.kind {
        case .quote:
            return prefix
        case .listItem:
            let marker = text.substring(with: e.markers[0])
            let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
            var next = marker
            if let n = Int(marker.dropLast()) { next = "\(n + 1)\(marker.last!)" }
            let task = ["[ ] ", "[x] ", "[X] "].contains { text.substring(with: e.content).hasPrefix($0) }
            return indent + next + " " + (task ? "[ ] " : "")
        default:
            return nil
        }
    }

    /// Wrap the selection in `marker` (bold, italic…), or unwrap the span
    /// of `kind` it's in.
    public func toggle(_ kind: LiveMarkdown.Element.Kind, marker: String, selection: NSRange) -> Edit {
        if let e = elements.first(where: { $0.kind == kind && $0.content.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.content) }) {
            let m = e.content.location - e.range.location
            return .replace(e.range, with: text.substring(with: e.content), select: NSRange(location: selection.location - m, length: selection.length))
        }
        // Markdown can't open emphasis before a space, so whitespace at
        // the ends stays outside the markers.
        var r = selection
        while r.length > 0, isSpace(r.location) { r = NSRange(location: r.location + 1, length: r.length - 1) }
        while r.length > 0, isSpace(NSMaxRange(r) - 1) { r.length -= 1 }
        let s = text.substring(with: r)
        guard r.length > 0, !s.contains("\n") else { return .ignore }
        let m = (marker as NSString).length
        return .replace(r, with: marker + s + marker, select: NSRange(location: r.location + m, length: r.length))
    }

    // MARK: -

    /// Whether a list item's text starts with a task box, `[ ] ` or `[x] `.
    public static func isTask(_ text: NSString, _ content: NSRange) -> Bool {
        content.length >= 4 && ["[ ] ", "[x] ", "[X] "].contains(text.substring(with: NSRange(location: content.location, length: 4)))
    }

    private func isSpan(_ k: LiveMarkdown.Element.Kind) -> Bool {
        switch k {
        case .strong, .emphasis, .strikethrough, .code, .link: true
        default: false
        }
    }

    private func isCode(_ k: LiveMarkdown.Element.Kind) -> Bool {
        if case .codeBlock = k { true } else { false }
    }

    private func isBlock(_ k: LiveMarkdown.Element.Kind) -> Bool {
        switch k {
        case .mathBlock, .table, .image: true
        default: false
        }
    }

    /// The line holding `p`, without its newline.
    private func line(at p: Int) -> NSRange {
        var start = 0, end = 0
        text.getLineStart(&start, end: nil, contentsEnd: &end, for: NSRange(location: min(p, text.length), length: 0))
        return NSRange(location: start, length: end - start)
    }

    private func touches(_ zone: NSRange, _ line: NSRange) -> Bool {
        NSIntersectionRange(zone, line).length > 0 || zone.location == line.location
    }

    private func isBlank(_ r: NSRange) -> Bool {
        text.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isSpace(_ i: Int) -> Bool {
        let c = text.character(at: i)
        return c == 0x20 || c == 0x09
    }

    private func trimmed(_ r: NSRange) -> NSRange {
        var r = r
        while r.length > 0, [0x0A, 0x0D].contains(text.character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
        return r
    }
}

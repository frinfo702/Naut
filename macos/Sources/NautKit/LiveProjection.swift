import Foundation

/// What Live Preview shows of a note, and how each shown character maps
/// back to the Markdown.
///
/// Live Preview first held the whole source in the text view and hid the
/// syntax by drawing it with no width. Caret positions were then source
/// positions: the text view could put the caret inside hidden syntax (a
/// fence line, an equation's `$$`, between `**`), and two positions could
/// look the same. Snapping the caret after the fact had to catch every
/// path the text view moves it by (arrows, line and word moves, clicks,
/// drags, undo, typing), and each one missed put the caret somewhere it
/// can't be, such as the hidden fence of a code block ending the note.
///
/// So the text view holds only this: the note with its syntax left out.
/// Every caret position it can make is a real one, by construction.
///
/// - Line prefixes (`## `, `> `, `- `, `1. `, `- [ ] `) are left out;
///   the editor draws bullets, numbers, boxes and quote bars itself.
/// - Code fences are left out, each with its newline.
/// - Inline markers (`**`, `*`, `~~`, `` ` ``, `[`, `](url)`) are left out.
/// - Math blocks, tables, pictures and inline math are one U+FFFC each,
///   which the editor draws as an attachment: atomic, by construction.
///
/// Positions and ranges are UTF-16 (NSString), as AppKit's are.
public struct LiveProjection {
    public let source: NSString
    public let elements: [LiveMarkdown.Element]
    /// The text the editor holds.
    public let display: NSString
    /// For each display unit, the source range it stands for: one unit
    /// for text, the whole construct for an attachment. In source order,
    /// never overlapping.
    public let units: [NSRange]
    /// Display index of each attachment → index into `elements`.
    public let attachments: [Int: Int]
    /// Hidden source units that are block syntax: line prefixes and code
    /// fences. They own whole lines (a fence) or start them (a prefix).
    public let blockSyntax: IndexSet
    /// The code fence lines among them, each with its newline.
    public let fences: IndexSet
    /// Constructs drawn as one attachment: their source range (for a
    /// block, its lines without the newline after the last) and element.
    public let atoms: [(range: NSRange, element: Int, isBlock: Bool)]

    public static let attachmentCharacter: unichar = 0xFFFC

    public init(_ text: String) {
        self.init(text, elements: LiveMarkdown.parse(text))
    }

    public init(_ text: String, elements: [LiveMarkdown.Element]) {
        let source = text as NSString
        self.source = source
        self.elements = elements

        var inline = IndexSet()
        var block = IndexSet()
        var fences = IndexSet()
        var atoms: [(range: NSRange, element: Int, isBlock: Bool)] = []
        for (i, e) in elements.enumerated() {
            switch e.kind {
            case .heading, .quote:
                block.insert(integersIn: Range(e.markers[0])!)
            case .listItem:
                block.insert(integersIn: Range(Self.prefix(of: e, in: source))!)
            case .strong, .emphasis, .strikethrough, .code, .link:
                for m in e.markers { inline.insert(integersIn: Range(m)!) }
            case .codeBlock:
                // A fence goes with its newline: the code's lines are the
                // block's lines in the display, nothing above or below.
                for m in e.markers {
                    let end = NSMaxRange(m) < source.length && source.character(at: NSMaxRange(m)) == 0x0A ? NSMaxRange(m) + 1 : NSMaxRange(m)
                    block.insert(integersIn: m.location..<end)
                    fences.insert(integersIn: m.location..<end)
                }
            case .mathBlock, .table, .image:
                atoms.append((Self.trimmed(e.scope, in: source), i, true))
            case .math:
                atoms.append((e.range, i, false))
            }
        }
        atoms.sort { $0.range.location < $1.range.location }

        var display: [unichar] = []
        var units: [NSRange] = []
        var attachments: [Int: Int] = [:]
        display.reserveCapacity(source.length)
        units.reserveCapacity(source.length)
        var next = 0
        var i = 0
        while i < source.length {
            if next < atoms.count, atoms[next].range.location == i {
                attachments[display.count] = atoms[next].element
                display.append(Self.attachmentCharacter)
                units.append(atoms[next].range)
                i = NSMaxRange(atoms[next].range)
                next += 1
                continue
            }
            if !inline.contains(i), !block.contains(i) {
                display.append(source.character(at: i))
                units.append(NSRange(location: i, length: 1))
            }
            i += 1
        }

        self.display = NSString(characters: display, length: display.count)
        self.units = units
        self.attachments = attachments
        self.blockSyntax = block
        self.fences = fences
        self.atoms = atoms
    }

    // MARK: - Mapping

    /// The source range a display range stands for: from its first unit's
    /// start to its last unit's end. Hidden syntax strictly inside is
    /// included; at either edge it is not, so deleting shown text never
    /// takes a marker it doesn't enclose.
    public func sourceRange(_ r: NSRange) -> NSRange {
        precondition(NSMaxRange(r) <= units.count, "display range out of bounds")
        guard r.length > 0 else { return NSRange(location: insertion(at: r.location).position, length: 0) }
        let start = units[r.location].location
        return NSRange(location: start, length: NSMaxRange(units[NSMaxRange(r) - 1]) - start)
    }

    /// Where text typed at display position `p` goes in the source, and
    /// what must go around it so block syntax keeps whole lines.
    ///
    /// Several source positions show as `p` when hidden syntax sits there:
    /// after bold text and after its closing `**` look the same. If the
    /// editor knows which one the caret is at (`preferring`, say just after
    /// the `**` that was typed), that one. Otherwise just after the unit
    /// before `p` (left affinity, as the text view's typing attributes come
    /// from the character before): typing at the end of bold text continues
    /// it. Then past hidden block syntax: typing at a heading's start goes
    /// after `## `, below a code block after its closing fence.
    ///
    /// A `newline` never goes inside an inline span, which can't cross
    /// lines: it goes after the span's closing marker.
    public func insertion(at p: Int, preferring: Int? = nil, newline: Bool = false) -> (position: Int, before: String, after: String) {
        precondition(p >= 0 && p <= units.count, "display position out of bounds")
        var position = p == 0 ? 0 : NSMaxRange(units[p - 1])
        // The gap of hidden syntax `p` stands for runs to the next unit.
        let gapEnd = p < units.count ? units[p].location : source.length
        if let preferring, preferring >= position, preferring <= gapEnd { position = preferring }
        let start = position
        while position < source.length, blockSyntax.contains(position) { position += 1 }
        if newline {
            while let span = elements.first(where: { $0.kind.isSpan && NSMaxRange($0.content) <= position && position < NSMaxRange($0.range) }) {
                position = NSMaxRange(span.range)
            }
        }

        // A block (an attachment) owns its line: text beside it goes on a
        // line of its own, below it or above it.
        if atoms.contains(where: { $0.isBlock && NSMaxRange($0.range) == position }) {
            return (position, "\n", "")
        }
        if atoms.contains(where: { $0.isBlock && $0.range.location == position }) {
            return (position, "", "\n")
        }
        // Skipping a fence that ends the note leaves us at the end of its
        // line, not the start of the next. (A prefix is meant to be
        // followed on its line: after `- ` is where an item's text goes.)
        if position > start, fences.contains(position - 1), source.character(at: position - 1) != 0x0A {
            return (position, "\n", "")
        }
        return (position, "", "")
    }

    /// The display position for source position `p`: the number of display
    /// units that start before it.
    public func display(at p: Int) -> Int {
        var lo = 0, hi = units.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if units[mid].location < p { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The display range covering source range `r`.
    public func displayRange(_ r: NSRange) -> NSRange {
        let start = display(at: r.location)
        return NSRange(location: start, length: display(at: NSMaxRange(r)) - start)
    }

    /// The display paragraphs that the source lines `r` spans became: from
    /// the paragraph of its first line to the paragraph of its last line,
    /// empty or not.
    ///
    /// Not `display.paragraphRange(for: displayRange(r))`: a range ending
    /// where an empty last line starts reaches no character of that line,
    /// so its paragraph was left out. After Return at the end of a code
    /// block the new empty line was styled and drawn as outside the block
    /// until a letter was typed into it.
    public func displayLines(_ r: NSRange) -> NSRange {
        var lastLine = 0
        source.getLineStart(&lastLine, end: nil, contentsEnd: nil, for: NSRange(location: NSMaxRange(r), length: 0))
        let first = display.paragraphRange(for: NSRange(location: display(at: r.location), length: 0))
        let last = display.paragraphRange(for: NSRange(location: display(at: max(r.location, lastLine)), length: 0))
        return NSUnionRange(first, last)
    }

    /// The display index of element `i`'s attachment, if it is drawn as one.
    public func attachment(of element: Int) -> Int? {
        attachments.first { $0.value == element }?.key
    }

    // MARK: -

    /// A list item's prefix: indent, marker, space, and a task's box.
    public static func prefix(of e: LiveMarkdown.Element, in source: NSString) -> NSRange {
        let task = isTask(source, e.content) ? 4 : 0
        return NSRange(location: e.range.location, length: e.content.location - e.range.location + task)
    }

    /// Whether a list item's text starts with a task box, `[ ] ` or `[x] `.
    public static func isTask(_ text: NSString, _ content: NSRange) -> Bool {
        content.length >= 4 && ["[ ] ", "[x] ", "[X] "].contains(text.substring(with: NSRange(location: content.location, length: 4)))
    }

    /// `r` without newlines at its end.
    static func trimmed(_ r: NSRange, in text: NSString) -> NSRange {
        var r = r
        while r.length > 0, [0x0A, 0x0D].contains(text.character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
        return r
    }
}

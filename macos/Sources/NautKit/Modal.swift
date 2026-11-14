import Foundation

/// How the note's keys behave, set in Settings.
public enum EditorKeymap: String, CaseIterable, Identifiable, Sendable {
    /// The standard macOS editing keys.
    case normal
    case vim
    case helix

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .vim: "Vim"
        case .helix: "Helix"
        }
    }

    public var isModal: Bool { self != .normal }
}

/// The mode a modal keymap is in. Normal and Helix both use `normal`;
/// `visual` and `visualLine` are Vim's, `select` and `selectLine` Helix's.
public enum ModalMode: String, Equatable, Sendable {
    case normal
    case insert
    case visual
    case visualLine
    case select
    case selectLine

    /// The mode shown in the corner of the editor.
    public var title: String {
        switch self {
        case .normal: "NORMAL"
        case .insert: "INSERT"
        case .visual: "VISUAL"
        case .visualLine: "VISUAL LINE"
        case .select: "SELECT"
        case .selectLine: "SELECT LINE"
        }
    }

    public var isVisual: Bool {
        switch self {
        case .visual, .visualLine, .select, .selectLine: true
        default: false
        }
    }

    public var isLinewise: Bool {
        self == .visualLine || self == .selectLine
    }
}

/// Text motions shared by Vim and Helix. Ranges are UTF-16 (NSString),
/// as AppKit's are. Word rules:
///
/// - spaces, tabs and newlines separate words;
/// - ASCII letters, digits and `_` are one word;
/// - other ASCII punctuation is a word of its own, so `foo.bar` walks
///   through `foo`, `.` and `bar`;
/// - everything non-ASCII is a word, so Japanese notes move by run, not
///   by UTF-16 unit.
public enum ModalText {
    public enum Word {
        /// Letters, digits, `_`, and anything non-ASCII.
        case small
        /// Any run of non-space, as Vim's `W`, `B` and `E`.
        case big
    }

    /// The line holding `p`, its newline included when it has one.
    public static func lineRange(_ text: NSString, at p: Int) -> NSRange {
        let length = text.length
        if p >= length, length > 0, text.character(at: length - 1) == 0x0A {
            // The empty line after a final newline.
            return NSRange(location: length, length: 0)
        }
        var start = 0, end = 0
        text.getLineStart(&start, end: nil, contentsEnd: &end, for: NSRange(location: min(max(0, p), length), length: 0))
        var range = NSRange(location: start, length: end - start)
        if end < length, text.character(at: end) == 0x0A { range.length += 1 }
        return range
    }

    /// The line's text, without its newline.
    public static func lineContentRange(_ text: NSString, at p: Int) -> NSRange {
        let line = lineRange(text, at: p)
        guard line.length > 0 else { return line }
        var range = line
        while range.length > 0, [0x0A, 0x0D].contains(text.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        return range
    }

    /// Where the line's first non-space character is, or its start.
    public static func firstNonBlank(_ text: NSString, at p: Int) -> Int {
        let content = lineContentRange(text, at: p)
        var i = content.location
        while i < NSMaxRange(content), text.character(at: i) == 0x20 || text.character(at: i) == 0x09 { i += 1 }
        return i
    }

    /// The last character of the line, as a caret may sit on it. Empty
    /// lines answer their start.
    public static func lastCharacter(_ text: NSString, at p: Int) -> Int {
        let content = lineContentRange(text, at: p)
        guard content.length > 0 else { return content.location }
        let r = text.rangeOfComposedCharacterSequence(at: NSMaxRange(content) - 1)
        return r.location
    }

    /// The start of the next word, from any position in the current one.
    public static func nextWordStart(_ text: NSString, from p: Int, word: Word = .small) -> Int {
        let n = text.length
        var i = min(max(0, p), n)
        guard i < n else { return n }
        if !isBlank(text, i, word: word) {
            let current = kind(text, i, word: word)
            while i < n, kind(text, i, word: word) == current { i += 1 }
        }
        while i < n, isBlank(text, i, word: word) { i += 1 }
        return i
    }

    /// The start of the previous word.
    public static func previousWordStart(_ text: NSString, from p: Int, word: Word = .small) -> Int {
        let n = text.length
        var i = min(max(0, p), n)
        guard i > 0 else { return 0 }
        i -= 1
        while i > 0, isBlank(text, i, word: word) { i -= 1 }
        let current = kind(text, i, word: word)
        while i > 0, kind(text, i - 1, word: word) == current { i -= 1 }
        return i
    }

    /// The last character of the word at or after `p`.
    public static func wordEnd(_ text: NSString, from p: Int, word: Word = .small) -> Int {
        let n = text.length
        var i = min(max(0, p), n - 1)
        guard n > 0 else { return 0 }
        if isBlank(text, i, word: word) {
            while i < n, isBlank(text, i, word: word) { i += 1 }
            guard i < n else { return lastCharacter(text, at: n - 1) }
        } else if i + 1 < n, kind(text, i + 1, word: word) == kind(text, i, word: word) {
            i += 1
        } else if i + 1 < n {
            // At the end of a run: the next word's end.
            i += 1
            while i < n, isBlank(text, i, word: word) { i += 1 }
            guard i < n else { return lastCharacter(text, at: n - 1) }
        }
        let k = kind(text, i, word: word)
        while i + 1 < n, kind(text, i + 1, word: word) == k { i += 1 }
        return text.rangeOfComposedCharacterSequence(at: i).location
    }

    /// The first character of the word at or after `p`, skipping blanks.
    public static func wordRunStart(_ text: NSString, from p: Int, word: Word = .small) -> Int {
        let n = text.length
        var i = min(max(0, p), n)
        while i < n, isBlank(text, i, word: word) { i += 1 }
        return i
    }

    /// The end (exclusive) of the word at or after `p`, skipping blanks
    /// first. `w` in Helix selects this run.
    public static func wordRunEnd(_ text: NSString, from p: Int, word: Word = .small) -> Int {
        let n = text.length
        var i = min(max(0, p), n)
        while i < n, isBlank(text, i, word: word) { i += 1 }
        guard i < n else { return n }
        let k = kind(text, i, word: word)
        while i < n, kind(text, i, word: word) == k { i += 1 }
        return i
    }

    /// `p` moved to the start of the next line's content, when there is
    /// one; otherwise the end of the text.
    public static func nextLineStart(_ text: NSString, from p: Int) -> Int {
        let line = lineRange(text, at: p)
        let next = NSMaxRange(line)
        return min(next, text.length)
    }

    /// The start of the previous line, or the start of the text.
    public static func previousLineStart(_ text: NSString, from p: Int) -> Int {
        guard p > 0 else { return 0 }
        return lineRange(text, at: p - 1).location
    }

    /// The line whose start is `lineStart` to the end of the last line in
    /// `lines`, newline included.
    public static func linewiseRange(_ text: NSString, from start: Int, lines: Int) -> NSRange {
        let first = lineRange(text, at: start)
        var end = first
        for _ in 1 ..< max(1, lines) {
            let next = NSMaxRange(end)
            guard next < text.length else { break }
            end = lineRange(text, at: next)
        }
        return NSRange(location: first.location, length: NSMaxRange(end) - first.location)
    }

    /// The first line's start to the end of the last line: `gg` to `G`.
    public static func wholeLines(_ text: NSString) -> NSRange {
        NSRange(location: 0, length: text.length)
    }

    /// The range of the character at `p`, a whole composed sequence.
    public static func characterRange(_ text: NSString, at p: Int) -> NSRange? {
        guard p >= 0, p < text.length else { return nil }
        return text.rangeOfComposedCharacterSequence(at: p)
    }

    // MARK: - Character classes

    private enum Kind { case blank, word, punctuation }

    private static func kind(_ text: NSString, _ i: Int, word: Word) -> Kind {
        let c = text.character(at: i)
        if word == .big {
            return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D ? .blank : .word
        }
        if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { return .blank }
        if c >= 0x80 { return .word }
        if c >= 0x30, c <= 0x39 { return .word }
        if c >= 0x41, c <= 0x5A { return .word }
        if c >= 0x61, c <= 0x7A { return .word }
        if c == 0x5F { return .word }
        return .punctuation
    }

    private static func isBlank(_ text: NSString, _ i: Int, word: Word) -> Bool {
        kind(text, i, word: word) == .blank
    }
}

import AppKit
import NautKit

/// What a modal keymap edits. Live Preview answers in display positions
/// and turns them into source edits.
@MainActor
protocol ModalTarget: AnyObject {
    var modalText: NSString { get }
    var modalSelection: NSRange { get set }
    var modalIsComposing: Bool { get }

    func modalDelete(_ range: NSRange, linewise: Bool)
    func modalInsert(_ text: String, at position: Int)
    func modalInsertLine(_ text: String, after: Bool)
    func modalReplace(_ range: NSRange, with text: String)
    func modalOpenLine(below: Bool)
    func modalYank(_ range: NSRange, linewise: Bool) -> String
    func modalSource(_ range: NSRange, linewise: Bool) -> String
    func modalUndo()
    func modalRedo()
    func modalScrollToVisible()
    /// Where moving `delta` wrapped lines from `position` lands, at x
    /// `goal`, or the caret's own x when nil, which it then sets; nil when
    /// the layout can't say.
    /// The characters of the wrapped row at `position`, without its
    /// newline; nil past the end.
    func modalDisplayRow(at position: Int) -> NSRange?
    func modalDisplayLineTarget(from position: Int, delta: Int, allowLineEnd: Bool, goal: inout CGFloat?) -> Int?
    func modalModeChanged(_ mode: ModalMode)
    /// Down (or up) off a block onto another that touches it: make an
    /// empty line between them for the cursor. False if there is none.
    func modalOpenGap(below: Bool) -> Bool
}

/// Vim and Helix keys, turned into motions and edits of `ModalTarget`.
///
/// There is no command line: a note saves itself and has no process to
/// quit, so `:w` and `:q` have nothing to do. Everything else is the
/// everyday vocabulary of the two editors: motions, counts, operators,
/// Helix's selection-first editing, and insert mode.
@MainActor
final class ModalEngine {
    private weak var target: ModalTarget?

    var keymap: EditorKeymap {
        didSet {
            guard keymap != oldValue else { return }
            reset()
        }
    }

    /// j and k step through wrapped lines, as Vim's gj and gk do.
    var displayLines = false
    /// The x that j and k keep to across short rows, and the caret they
    /// left: any other motion moves the caret, which drops it.
    private var goalX: CGFloat?
    private var goalCaret = -1

    private(set) var mode: ModalMode = .normal
    /// The last yank or linewise delete, for p and P.
    private var register = ""
    private var registerIsLinewise = false

    private var countString = ""
    private var pendingOperator: String?
    private var pendingOperatorCount = 1
    private var pendingPrefix = ""
    private var pendingReplace = false
    private var pendingReplaceCount = 1

    private var vimAnchor = 0
    private var vimHead = 0
    private var helixAnchor = 0
    private var helixHead = 0
    /// Helix's normal mode can hold a line selection, as after `x`, while
    /// still saying NORMAL. `d` and `y` must treat that range as whole
    /// lines.
    private var linewiseSelection = false

    init(keymap: EditorKeymap) {
        self.keymap = keymap
    }

    func attach(_ target: ModalTarget) {
        self.target = target
    }

    func reset() {
        clearPending()
        setMode(.normal)
    }

    // MARK: - Keys

    /// Handle `event`; false lets the text view do its usual thing, which
    /// is what every key except Esc does in insert mode.
    func handle(_ event: NSEvent) -> Bool {
        guard keymap.isModal, let target, !target.modalIsComposing,
              let key = keyName(event)
        else { return false }

        if mode == .insert {
            guard key == "esc" || key == "ctrl-[" || key == "ctrl-c" else { return false }
            leaveInsert()
            return true
        }

        switch keymap {
        case .vim: return vimKey(key)
        case .helix: return helixKey(key)
        case .normal: return false
        }
    }

    private func keyName(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Menu shortcuts and input methods keep their usual meaning.
        if flags.contains(.command) || flags.contains(.option) { return nil }
        switch event.keyCode {
        case 53: return "esc"
        case 36, 76: return "return"
        case 48: return "tab"
        case 51: return "backspace"
        case 117: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: break
        }
        let chars = event.charactersIgnoringModifiers ?? ""
        if flags.contains(.control) {
            guard chars.count == 1 else { return nil }
            return "ctrl-" + chars.lowercased()
        }
        guard chars.count == 1, let scalar = chars.unicodeScalars.first, scalar.value >= 0x20 else { return nil }
        return chars
    }

    private func setMode(_ mode: ModalMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        target?.modalModeChanged(mode)
    }

    private func clearPending() {
        countString = ""
        pendingOperator = nil
        pendingOperatorCount = 1
        pendingPrefix = ""
        pendingReplace = false
        pendingReplaceCount = 1
    }

    // MARK: - Buffer

    private var text: NSString { target?.modalText ?? ("" as NSString) }
    private var selection: NSRange { target?.modalSelection ?? NSRange(location: 0, length: 0) }
    private var caret: Int {
        switch mode {
        case .visual, .visualLine: vimHead
        case .select, .selectLine: helixHead
        default: selection.location
        }
    }

    private func clamp(_ p: Int) -> Int { min(max(0, p), text.length) }

    private func setCaret(_ p: Int, scroll: Bool = true) {
        let q = clamp(p)
        target?.modalSelection = NSRange(location: q, length: 0)
        if scroll { target?.modalScrollToVisible() }
    }

    private func setSelection(_ r: NSRange, scroll: Bool = true) {
        let q = clamp(r.location)
        let end = clamp(NSMaxRange(r))
        target?.modalSelection = NSRange(location: q, length: max(0, end - q))
        if scroll { target?.modalScrollToVisible() }
    }

    private var count: Int {
        max(1, Int(countString) ?? 1)
    }

    private func takeCount() -> Int {
        let n = count
        countString = ""
        return n
    }

    private func accumulateCount(_ key: String) -> Bool {
        guard key.count == 1, let c = key.first, c.isNumber else { return false }
        if key == "0", countString.isEmpty { return false }
        countString.append(key)
        return true
    }

    // MARK: - Vim

    private func vimKey(_ key: String) -> Bool {
        if mode == .visual || mode == .visualLine { return vimVisualKey(key) }
        if pendingReplace { replace(with: key); return true }
        if pendingOperator != nil { handleVimOperator(key); return true }
        if pendingPrefix == "g" { handleVimPrefix(key); return true }
        if accumulateCount(key) { return true }

        switch key {
        case "esc":
            clearPending()
        case "h", "left", "backspace":
            if let p = motionTarget("h", count: takeCount()) { setCaret(p) }
        case "l", "right", " ":
            if let p = motionTarget("l", count: takeCount()) { setCaret(p) }
        case "j", "down":
            if let p = motionTarget("j", count: takeCount()) { setCaret(p) }
        case "k", "up":
            if let p = motionTarget("k", count: takeCount()) { setCaret(p) }
        case "return":
            let line = ModalText.lineRange(text, at: caret)
            setCaret(ModalText.firstNonBlank(text, at: NSMaxRange(line)))
        case "0", "^", "$", "w", "b", "e", "W", "B", "E":
            if let p = motionTarget(key, count: takeCount()) { setCaret(p) }
        case "g":
            pendingPrefix = "g"
        case "G":
            let n = countString.isEmpty ? 0 : takeCount()
            setCaret(n == 0 ? lastLineStart() : lineStart(number: n))
        case "i":
            clearPending()
            enterInsert(at: caret)
        case "a":
            clearPending()
            enterInsert(at: afterCaret(caret))
        case "I":
            clearPending()
            enterInsert(at: ModalText.firstNonBlank(text, at: caret))
        case "A":
            clearPending()
            enterInsert(at: NSMaxRange(ModalText.lineContentRange(text, at: caret)))
        case "o":
            clearPending()
            target?.modalOpenLine(below: true)
            setMode(.insert)
            target?.modalScrollToVisible()
        case "O":
            clearPending()
            target?.modalOpenLine(below: false)
            setMode(.insert)
            target?.modalScrollToVisible()
        case "x", "delete":
            deleteCharacters(count: takeCount())
        case "X":
            deleteCharacters(before: takeCount())
        case "d", "c", "y":
            pendingOperator = key
            pendingOperatorCount = takeCount()
        case "D":
            applyOperator("d", range: NSRange(location: caret, length: max(0, NSMaxRange(ModalText.lineContentRange(text, at: caret)) - caret)), linewise: false)
        case "C":
            applyOperator("c", range: NSRange(location: caret, length: max(0, NSMaxRange(ModalText.lineContentRange(text, at: caret)) - caret)), linewise: false)
        case "S":
            let line = ModalText.lineContentRange(text, at: caret)
            applyOperator("c", range: line, linewise: false)
        case "Y":
            let line = ModalText.lineRange(text, at: caret)
            applyOperator("y", range: line, linewise: true)
        case "p":
            clearPending()
            paste(before: false)
            target?.modalScrollToVisible()
        case "P":
            clearPending()
            paste(before: true)
            target?.modalScrollToVisible()
        case "u":
            clearPending()
            target?.modalUndo()
        case "ctrl-r":
            clearPending()
            target?.modalRedo()
        case "r":
            pendingReplace = true
            pendingReplaceCount = takeCount()
        case "v":
            clearPending()
            enterVimVisual(linewise: false)
        case "V":
            clearPending()
            enterVimVisual(linewise: true)
        default:
            clearPending()
        }
        return true
    }

    private func handleVimPrefix(_ key: String) {
        pendingPrefix = ""
        switch key {
        case "g":
            let n = countString.isEmpty ? 0 : takeCount()
            if n == 0 {
                setCaret(ModalText.firstNonBlank(text, at: 0))
            } else {
                setCaret(lineStart(number: n))
            }
        case "e":
            // End of the previous word.
            let start = ModalText.previousWordStart(text, from: caret)
            setCaret(ModalText.wordEnd(text, from: start))
        default:
            clearPending()
        }
    }

    private func handleVimVisualPrefix(_ key: String) {
        pendingPrefix = ""
        switch key {
        case "g":
            let n = countString.isEmpty ? 0 : takeCount()
            vimHead = n == 0 ? 0 : lineStart(number: n)
            updateVimSelection()
        default:
            clearPending()
        }
    }

    private func handleVimOperator(_ key: String) {
        if pendingPrefix == "g" {
            pendingPrefix = ""
            guard key == "g" else {
                clearPending()
                return
            }
            let line = ModalText.lineRange(text, at: caret)
            let start = countString.isEmpty ? 0 : lineStart(number: takeCount())
            let range = NSRange(location: start, length: max(0, NSMaxRange(line) - start))
            applyOperator(pendingOperator ?? "", range: range, linewise: true)
            return
        }
        if key == "g" {
            pendingPrefix = "g"
            return
        }
        if accumulateCount(key) { return }

        let n = pendingOperatorCount * count
        let op = pendingOperator ?? ""

        if key == op {
            var range = ModalText.linewiseRange(text, from: caret, lines: n)
            // c changes the line's text, not the line break: `cc` leaves
            // an empty line to type in, as in Vim.
            if op == "c" {
                while range.length > 0, text.character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
            }
            applyOperator(op, range: range, linewise: true)
            return
        }

        guard let (range, linewise) = operatorRange(for: key, count: n, operator: op) else {
            clearPending()
            return
        }
        applyOperator(op, range: range, linewise: linewise)
    }

    private func operatorRange(for key: String, count n: Int, operator op: String) -> (NSRange, Bool)? {
        switch key {
        case "h", "left", "backspace":
            guard let p = motionTarget("h", count: n) else { return nil }
            return (NSRange(location: p, length: max(0, caret - p)), false)
        case "l", "right", " ":
            // dl is x, not "delete to where l would stop": the character
            // under the caret is included, even at the end of a line.
            var end = caret
            for _ in 0..<n {
                guard let c = ModalText.characterRange(text, at: end) else { break }
                end = NSMaxRange(c)
            }
            return (NSRange(location: caret, length: max(0, end - caret)), false)
        case "j", "down":
            let current = ModalText.lineRange(text, at: caret)
            return (ModalText.linewiseRange(text, from: current.location, lines: n + 1), true)
        case "k", "up":
            var start = ModalText.lineRange(text, at: caret).location
            for _ in 0..<n { start = ModalText.previousLineStart(text, from: start) }
            let end = NSMaxRange(ModalText.lineRange(text, at: caret))
            return (NSRange(location: start, length: max(0, end - start)), true)
        case "w", "W":
            let word: ModalText.Word = key == "W" ? .big : .small
            if op == "c" {
                let end = wordRunEnd(from: caret, count: n, word: word)
                return (NSRange(location: caret, length: max(0, end - caret)), false)
            }
            var p = caret
            for _ in 0..<n { p = ModalText.nextWordStart(text, from: p, word: word) }
            return (NSRange(location: caret, length: max(0, p - caret)), false)
        case "b", "B":
            let word: ModalText.Word = key == "B" ? .big : .small
            var p = caret
            for _ in 0..<n { p = ModalText.previousWordStart(text, from: p, word: word) }
            return (NSRange(location: p, length: max(0, caret - p)), false)
        case "e", "E":
            let word: ModalText.Word = key == "E" ? .big : .small
            let end = wordEndExclusive(from: caret, count: n, word: word)
            return (NSRange(location: caret, length: max(0, end - caret)), false)
        case "0":
            let start = ModalText.lineRange(text, at: caret).location
            return (NSRange(location: start, length: max(0, caret - start)), false)
        case "^":
            let start = ModalText.firstNonBlank(text, at: caret)
            return (NSRange(location: start, length: max(0, caret - start)), false)
        case "$":
            let end = NSMaxRange(ModalText.lineContentRange(text, at: caret))
            return (NSRange(location: caret, length: max(0, end - caret)), false)
        case "G":
            let start = ModalText.lineRange(text, at: caret).location
            return (NSRange(location: start, length: max(0, text.length - start)), true)
        default:
            return nil
        }
    }

    private func applyOperator(_ op: String, range: NSRange, linewise: Bool) {
        let range = NSRange(location: clamp(range.location), length: max(0, min(NSMaxRange(range), text.length) - clamp(range.location)))
        switch op {
        case "y":
            yank(range, linewise: linewise)
            setMode(.normal)
        case "c":
            remember(range, linewise: linewise)
            target?.modalDelete(range, linewise: linewise)
            setMode(.insert)
        case "d":
            remember(range, linewise: linewise)
            target?.modalDelete(range, linewise: linewise)
            setMode(.normal)
        default:
            break
        }
        clearPending()
        target?.modalScrollToVisible()
    }

    // MARK: - Vim visual

    private func enterVimVisual(linewise: Bool) {
        if mode.isVisual {
            if linewise == mode.isLinewise {
                setMode(.normal)
                setCaret(vimHead)
            } else {
                setMode(linewise ? .visualLine : .visual)
                updateVimSelection()
            }
            return
        }
        vimAnchor = caret
        vimHead = caret
        setMode(linewise ? .visualLine : .visual)
        updateVimSelection()
    }

    private func updateVimSelection() {
        let anchorLine = ModalText.lineRange(text, at: vimAnchor)
        let headLine = ModalText.lineRange(text, at: vimHead)
        if mode == .visualLine {
            let start = min(anchorLine.location, headLine.location)
            let end = max(NSMaxRange(anchorLine), NSMaxRange(headLine))
            setSelection(NSRange(location: start, length: end - start))
        } else {
            let lo = min(vimAnchor, vimHead)
            let hi = max(vimAnchor, vimHead)
            let width = ModalText.characterRange(text, at: hi)?.length ?? 1
            let end = max(lo, min(hi + width, text.length))
            setSelection(NSRange(location: lo, length: end - lo))
        }
    }

    private func vimVisualKey(_ key: String) -> Bool {
        if pendingReplace { replace(with: key); return true }
        if pendingPrefix == "g" { handleVimVisualPrefix(key); return true }
        if accumulateCount(key) { return true }

        switch key {
        case "esc":
            let head = vimHead
            setMode(.normal)
            setCaret(head)
        case "h", "left", "backspace":
            if let p = motionTarget("h", count: takeCount()) { vimHead = clamp(p); updateVimSelection() }
        case "l", "right", " ":
            if let p = motionTarget("l", count: takeCount()) { vimHead = clamp(p); updateVimSelection() }
        case "j", "down":
            if let p = motionTarget("j", count: takeCount()) { vimHead = clamp(p); updateVimSelection() }
        case "k", "up":
            if let p = motionTarget("k", count: takeCount()) { vimHead = clamp(p); updateVimSelection() }
        case "return":
            let line = ModalText.lineRange(text, at: vimHead)
            vimHead = ModalText.firstNonBlank(text, at: NSMaxRange(line))
            updateVimSelection()
        case "0", "^", "$", "w", "b", "e", "W", "B", "E":
            if let p = motionTarget(key, count: takeCount()) {
                vimHead = clamp(p)
                updateVimSelection()
            }
        case "g":
            pendingPrefix = "g"
        case "G":
            vimHead = lastLineStart()
            updateVimSelection()
        case "o":
            swap(&vimAnchor, &vimHead)
            updateVimSelection()
        case "v":
            setMode(mode == .visual ? .normal : .visual)
            if mode == .normal { setCaret(vimHead) } else { updateVimSelection() }
        case "V":
            setMode(mode == .visualLine ? .normal : .visualLine)
            if mode == .normal { setCaret(vimHead) } else { updateVimSelection() }
        case "d", "x", "delete":
            applyOperator("d", range: selection, linewise: mode == .visualLine)
        case "c":
            applyOperator("c", range: selection, linewise: mode == .visualLine)
        case "y":
            applyOperator("y", range: selection, linewise: mode == .visualLine)
        case "p", "P":
            clearPending()
            paste(before: key == "P")
            setMode(.normal)
        case "r":
            pendingReplace = true
            pendingReplaceCount = 1
        default:
            clearPending()
        }
        return true
    }

    // MARK: - Helix

    private func helixKey(_ key: String) -> Bool {
        if mode == .select || mode == .selectLine { return helixSelectKey(key) }
        if pendingReplace { replace(with: key); return true }
        if pendingPrefix == "g" { handleHelixPrefix(key); return true }
        if accumulateCount(key) { return true }

        switch key {
        case "esc":
            clearPending()
            linewiseSelection = false
            collapseHelixSelection()
        case "h", "left", "backspace":
            linewiseSelection = false
            collapseHelix(toEnd: false)
            setCaret(caret - takeCount())
        case "l", "right", " ":
            linewiseSelection = false
            collapseHelix(toEnd: true)
            setCaret(min(caret + takeCount(), NSMaxRange(ModalText.lineContentRange(text, at: caret))))
        case "j", "down":
            linewiseSelection = false
            collapseHelix(toEnd: false)
            let n = takeCount()
            if n == 1, target?.modalOpenGap(below: true) == true { break }
            if let p = helixVerticalTarget(delta: n) { setCaret(p) }
        case "k", "up":
            linewiseSelection = false
            collapseHelix(toEnd: false)
            let n = takeCount()
            if n == 1, target?.modalOpenGap(below: false) == true { break }
            if let p = helixVerticalTarget(delta: -n) { setCaret(p) }
        case "return":
            linewiseSelection = false
            collapseHelix(toEnd: false)
            let line = ModalText.lineRange(text, at: caret)
            setCaret(ModalText.firstNonBlank(text, at: NSMaxRange(line)))
        case "w", "W":
            selectWord(forward: true, word: key == "W" ? .big : .small, count: takeCount())
        case "b", "B":
            selectWord(forward: false, word: key == "B" ? .big : .small, count: takeCount())
        case "e", "E":
            extendToWordEnd(word: key == "E" ? .big : .small, count: takeCount())
        case "0":
            linewiseSelection = false
            if let p = motionTarget("0", count: 1) { setCaret(p) }
        case "$":
            linewiseSelection = false
            setCaret(NSMaxRange(ModalText.lineContentRange(text, at: caret)))
        case "g":
            pendingPrefix = "g"
        case "G":
            linewiseSelection = false
            setCaret(lastLineStart())
        case "x":
            selectLines(extend: false, count: takeCount())
        case "X":
            selectLines(extend: true, count: takeCount())
        case "%":
            linewiseSelection = false
            setSelection(NSRange(location: 0, length: text.length))
        case ";":
            linewiseSelection = false
            collapseHelixSelection()
        case "d", "delete":
            deleteHelixSelection(insert: false)
        case "c":
            deleteHelixSelection(insert: true)
        case "y":
            yankHelixSelection()
        case "p":
            clearPending()
            paste(before: false)
            target?.modalScrollToVisible()
        case "P":
            clearPending()
            paste(before: true)
            target?.modalScrollToVisible()
        case "r":
            pendingReplace = true
            pendingReplaceCount = takeCount()
        case "i":
            clearPending()
            enterInsert(at: selection.location)
        case "a":
            clearPending()
            enterInsert(at: selection.length > 0 ? NSMaxRange(selection) : afterCaret(caret))
        case "I":
            clearPending()
            enterInsert(at: ModalText.firstNonBlank(text, at: caret))
        case "A":
            clearPending()
            enterInsert(at: NSMaxRange(ModalText.lineContentRange(text, at: caret)))
        case "o":
            clearPending()
            target?.modalOpenLine(below: true)
            setMode(.insert)
            target?.modalScrollToVisible()
        case "O":
            clearPending()
            target?.modalOpenLine(below: false)
            setMode(.insert)
            target?.modalScrollToVisible()
        case "u":
            clearPending()
            target?.modalUndo()
        case "U":
            clearPending()
            target?.modalRedo()
        case "v":
            clearPending()
            enterHelixSelect(linewise: false)
        case "V":
            clearPending()
            enterHelixSelect(linewise: true)
        default:
            clearPending()
        }
        return true
    }

    private func handleHelixPrefix(_ key: String) {
        pendingPrefix = ""
        linewiseSelection = false
        switch key {
        case "g":
            let n = countString.isEmpty ? 0 : takeCount()
            setCaret(n == 0 ? ModalText.firstNonBlank(text, at: 0) : lineStart(number: n))
        case "e":
            setCaret(lastLineStart())
        case "h":
            setCaret(rowStart(caret))
        case "l":
            setCaret(rowEnd(caret))
        case "s":
            setCaret(rowFirstNonBlank(caret))
        default:
            clearPending()
        }
    }

    private func collapseHelix(toEnd: Bool) {
        guard selection.length > 0 else { return }
        let p = toEnd ? NSMaxRange(selection) : selection.location
        target?.modalSelection = NSRange(location: clamp(p), length: 0)
    }

    private func collapseHelixSelection() {
        if selection.length > 0 {
            target?.modalSelection = NSRange(location: selection.location, length: 0)
        }
        clearPending()
    }

    private func selectWord(forward: Bool, word: ModalText.Word, count: Int) {
        linewiseSelection = false
        let current = selection
        if forward {
            let start = current.length > 0 ? NSMaxRange(current) : current.location
            var end = start
            for _ in 0..<count { end = ModalText.wordRunEnd(text, from: end, word: word) }
            let anchor = current.length > 0
                ? current.location
                : ModalText.wordRunStart(text, from: start, word: word)
            setSelection(NSRange(location: anchor, length: max(0, end - anchor)))
        } else {
            let end = current.length > 0 ? current.location : current.location
            var start = end
            for _ in 0..<count { start = ModalText.previousWordStart(text, from: start, word: word) }
            setSelection(NSRange(location: start, length: max(0, end - start)))
        }
    }

    private func extendToWordEnd(word: ModalText.Word, count: Int) {
        linewiseSelection = false
        let current = selection
        let start = current.length > 0 ? NSMaxRange(current) : current.location
        var end = start
        for _ in 0..<count { end = ModalText.wordRunEnd(text, from: end == start ? start : end, word: word) }
        let anchor = current.length > 0
            ? current.location
            : ModalText.wordRunStart(text, from: start, word: word)
        setSelection(NSRange(location: anchor, length: max(0, end - anchor)))
    }

    private func selectLines(extend: Bool, count: Int) {
        let current = selection
        let start = ModalText.lineRange(text, at: current.length > 0 ? current.location : caret).location
        if extend, current.length > 0 {
            let lines = lineCount(in: NSRange(location: start, length: max(0, NSMaxRange(current) - start))) + count
            let range = ModalText.linewiseRange(text, from: start, lines: lines)
            setSelection(range)
        } else {
            let range = ModalText.linewiseRange(text, from: start, lines: count)
            setSelection(range)
        }
        linewiseSelection = true
    }

    private func enterHelixSelect(linewise: Bool) {
        if mode.isVisual {
            if linewise == mode.isLinewise {
                linewiseSelection = linewise
                setMode(.normal)
                return
            }
            setMode(linewise ? .selectLine : .select)
            linewiseSelection = linewise
            helixAnchor = selection.length > 0 ? selection.location : caret
            helixHead = selection.length > 0 ? NSMaxRange(selection) : caret
            updateHelixSelection()
            return
        }
        helixAnchor = selection.length > 0 ? selection.location : caret
        helixHead = selection.length > 0 ? NSMaxRange(selection) : caret
        linewiseSelection = linewise
        setMode(linewise ? .selectLine : .select)
        updateHelixSelection()
    }

    private func updateHelixSelection() {
        if mode == .selectLine {
            let anchorLine = ModalText.lineRange(text, at: helixAnchor)
            let headAt = helixHead == helixAnchor ? helixHead : max(0, helixHead - 1)
            let headLine = ModalText.lineRange(text, at: headAt)
            let start = min(anchorLine.location, headLine.location)
            let end = max(NSMaxRange(anchorLine), NSMaxRange(headLine))
            setSelection(NSRange(location: start, length: end - start))
        } else {
            let lo = min(helixAnchor, helixHead)
            let hi = max(helixAnchor, helixHead)
            setSelection(NSRange(location: lo, length: hi - lo))
        }
    }

    private func helixSelectKey(_ key: String) -> Bool {
        if pendingReplace { replace(with: key); return true }
        if pendingPrefix == "g" { handleHelixSelectPrefix(key); return true }
        if accumulateCount(key) { return true }

        switch key {
        case "esc":
            clearPending()
            linewiseSelection = mode.isLinewise
            setMode(.normal)
        case "v":
            linewiseSelection = false
            setMode(.normal)
        case "V":
            if mode == .selectLine {
                linewiseSelection = true
                setMode(.normal)
            } else {
                linewiseSelection = true
                setMode(.selectLine)
                updateHelixSelection()
            }
        case "h", "left", "backspace":
            helixHead -= takeCount()
            updateHelixSelection()
        case "l", "right", " ":
            helixHead += takeCount()
            updateHelixSelection()
        case "j", "down":
            if let p = helixVerticalTarget(delta: takeCount()) { helixHead = p; updateHelixSelection() }
        case "k", "up":
            if let p = helixVerticalTarget(delta: -takeCount()) { helixHead = p; updateHelixSelection() }
        case "w", "W":
            let word: ModalText.Word = key == "W" ? .big : .small
            for _ in 0..<takeCount() { helixHead = ModalText.wordRunEnd(text, from: helixHead, word: word) }
            updateHelixSelection()
        case "b", "B":
            let word: ModalText.Word = key == "B" ? .big : .small
            for _ in 0..<takeCount() { helixHead = ModalText.previousWordStart(text, from: helixHead, word: word) }
            updateHelixSelection()
        case "e", "E":
            let word: ModalText.Word = key == "E" ? .big : .small
            for _ in 0..<takeCount() { helixHead = ModalText.wordRunEnd(text, from: helixHead, word: word) }
            updateHelixSelection()
        case "0":
            helixHead = ModalText.lineRange(text, at: helixHead).location
            updateHelixSelection()
        case "$":
            helixHead = NSMaxRange(ModalText.lineContentRange(text, at: helixHead))
            updateHelixSelection()
        case "G":
            helixHead = lastLineStart()
            updateHelixSelection()
        case "d", "delete", "x":
            applyHelixOperator("d")
        case "c":
            applyHelixOperator("c")
        case "y":
            applyHelixOperator("y")
        case "p", "P":
            clearPending()
            paste(before: key == "P")
            setMode(.normal)
        case "r":
            pendingReplace = true
            pendingReplaceCount = 1
        case "i":
            clearPending()
            enterInsert(at: selection.location)
        case "a":
            clearPending()
            enterInsert(at: NSMaxRange(selection))
        default:
            clearPending()
        }
        return true
    }

    private func handleHelixSelectPrefix(_ key: String) {
        pendingPrefix = ""
        switch key {
        case "g":
            let n = countString.isEmpty ? 0 : takeCount()
            helixHead = n == 0 ? 0 : lineStart(number: n)
            updateHelixSelection()
        case "e":
            helixHead = lastLineStart()
            updateHelixSelection()
        case "h":
            helixHead = rowStart(helixHead)
            updateHelixSelection()
        case "l":
            helixHead = rowEnd(helixHead)
            updateHelixSelection()
        case "s":
            helixHead = rowFirstNonBlank(helixHead)
            updateHelixSelection()
        default:
            clearPending()
        }
    }

    private func applyHelixOperator(_ op: String) {
        let range = selection
        let linewise = linewiseSelection || mode.isLinewise
        switch op {
        case "d":
            remember(range, linewise: linewise)
            target?.modalDelete(range, linewise: linewise)
            setMode(.normal)
        case "c":
            remember(range, linewise: linewise)
            target?.modalDelete(range, linewise: linewise)
            setMode(.insert)
        case "y":
            yank(range, linewise: linewise)
            setMode(.normal)
        default:
            break
        }
        clearPending()
        target?.modalScrollToVisible()
    }

    private func deleteHelixSelection(insert: Bool) {
        let range = selection.length > 0
            ? selection
            : (ModalText.characterRange(text, at: caret) ?? NSRange(location: caret, length: 0))
        let linewise = linewiseSelection || mode.isLinewise
        remember(range, linewise: linewise)
        target?.modalDelete(range, linewise: linewise)
        setMode(insert ? .insert : .normal)
        clearPending()
        target?.modalScrollToVisible()
    }

    private func yankHelixSelection() {
        let range = selection.length > 0
            ? selection
            : (ModalText.characterRange(text, at: caret) ?? NSRange(location: caret, length: 0))
        yank(range, linewise: linewiseSelection || mode.isLinewise)
        setMode(.normal)
        clearPending()
    }

    // MARK: - Insert

    private func enterInsert(at p: Int) {
        setCaret(p)
        setMode(.insert)
        target?.modalScrollToVisible()
    }

    private func leaveInsert() {
        let p = clamp(selection.location)
        // A block selected while inserting: the cursor goes on it.
        let onBlock = selection.length > 0
        setMode(.normal)
        // As in Vim, Esc leaves the caret on the character just typed.
        if onBlock {
            setCaret(p)
        } else if p > 0, text.length > 0, text.character(at: p - 1) != 0x0A {
            let previous = text.rangeOfComposedCharacterSequence(at: p - 1).location
            setCaret(previous)
        }
        clearPending()
    }

    // MARK: - Replace

    private func replace(with key: String) {
        pendingReplace = false
        guard key != "esc", key != "return", key != "tab", key.count == 1 else {
            clearPending()
            return
        }
        let n = max(1, pendingReplaceCount)
        let range: NSRange
        if selection.length > 0 {
            range = selection
        } else {
            var end = caret
            for _ in 0..<n {
                guard let c = ModalText.characterRange(text, at: end) else { break }
                end = max(end + 1, NSMaxRange(c))
                if text.character(at: c.location) == 0x0A { break }
            }
            range = NSRange(location: caret, length: max(0, end - caret))
        }
        guard range.length > 0 else {
            clearPending()
            return
        }
        let replacement = String(repeating: key, count: max(1, range.length))
        target?.modalReplace(range, with: replacement)
        let wasVisual = mode.isVisual
        setMode(.normal)
        clearPending()
        if wasVisual { target?.modalScrollToVisible() }
    }

    // MARK: - Delete and yank

    private func deleteCharacters(count n: Int) {
        var end = caret
        for _ in 0..<n {
            guard let c = ModalText.characterRange(text, at: end) else { break }
            end = NSMaxRange(c)
        }
        guard end > caret else { return }
        let range = NSRange(location: caret, length: end - caret)
        remember(range, linewise: false)
        target?.modalDelete(range, linewise: false)
        clearPending()
        target?.modalScrollToVisible()
    }

    private func deleteCharacters(before n: Int) {
        var start = caret
        for _ in 0..<n {
            guard start > 0 else { break }
            start = text.rangeOfComposedCharacterSequence(at: start - 1).location
        }
        guard start < caret else { return }
        let range = NSRange(location: start, length: caret - start)
        remember(range, linewise: false)
        target?.modalDelete(range, linewise: false)
        clearPending()
        target?.modalScrollToVisible()
    }

    /// Deleted text goes to the register, as in Vim, but not to the system
    /// clipboard: deleting a sentence should not replace what was copied
    /// elsewhere.
    private func remember(_ range: NSRange, linewise: Bool) {
        guard range.length > 0 else { return }
        register = target?.modalSource(range, linewise: linewise) ?? ""
        registerIsLinewise = linewise
    }

    private func yank(_ range: NSRange, linewise: Bool) {
        guard range.length > 0 else { return }
        register = target?.modalYank(range, linewise: linewise) ?? ""
        registerIsLinewise = linewise
        guard !register.isEmpty else { return }
        // Yanks go to the system clipboard too, so a note can be pasted
        // into another app.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(register, forType: .string)
    }

    private func paste(before: Bool) {
        var string = register
        if string.isEmpty {
            string = NSPasteboard.general.string(forType: .string) ?? ""
            registerIsLinewise = false
        }
        guard !string.isEmpty else { return }

        if selection.length > 0 {
            target?.modalReplace(selection, with: string)
            setMode(.normal)
            clearPending()
            target?.modalScrollToVisible()
            return
        }

        if registerIsLinewise {
            let pasted = string.hasSuffix("\n") ? string : string + "\n"
            target?.modalInsertLine(pasted, after: !before)
        } else {
            let position = before ? caret : min(caret + 1, text.length)
            target?.modalInsert(string, at: position)
            let end = position + (string as NSString).length
            if end > position {
                setCaret(text.rangeOfComposedCharacterSequence(at: min(end, text.length) - 1).location)
            }
        }
        setMode(.normal)
        clearPending()
    }

    // MARK: - Motions

    /// The caret a Vim motion asks for, in display/source positions.
    private func motionTarget(_ key: String, count n: Int) -> Int? {
        switch key {
        case "h", "left":
            let start = ModalText.lineRange(text, at: caret).location
            return max(start, caret - n)
        case "l", "right", " ":
            let content = ModalText.lineContentRange(text, at: caret)
            let end = max(content.location, ModalText.lastCharacter(text, at: caret))
            return max(caret, min(end, caret + n))
        case "j", "down":
            return verticalTarget(delta: n, allowLineEnd: false)
        case "k", "up":
            return verticalTarget(delta: -n, allowLineEnd: false)
        case "0":
            return ModalText.lineRange(text, at: caret).location
        case "^":
            return ModalText.firstNonBlank(text, at: caret)
        case "$":
            return ModalText.lastCharacter(text, at: caret)
        case "w", "W":
            let word: ModalText.Word = key == "W" ? .big : .small
            var p = caret
            for _ in 0..<n { p = ModalText.nextWordStart(text, from: p, word: word) }
            return p
        case "b", "B":
            let word: ModalText.Word = key == "B" ? .big : .small
            var p = caret
            for _ in 0..<n { p = ModalText.previousWordStart(text, from: p, word: word) }
            return p
        case "e", "E":
            let word: ModalText.Word = key == "E" ? .big : .small
            var p = caret
            for i in 0..<n {
                p = ModalText.wordEnd(text, from: p, word: word)
                if i < n - 1, p + 1 < text.length { p += 1 }
            }
            return p
        default:
            return nil
        }
    }

    private func verticalTarget(delta: Int, allowLineEnd: Bool) -> Int {
        if displayLines {
            if caret != goalCaret { goalX = nil }
            if let p = target?.modalDisplayLineTarget(from: caret, delta: delta, allowLineEnd: allowLineEnd, goal: &goalX) {
                goalCaret = composedStart(p)
                return goalCaret
            }
        }
        let current = ModalText.lineRange(text, at: caret)
        let column = max(0, caret - current.location)
        var start = current.location
        var steps = abs(delta)
        while steps > 0 {
            if delta > 0 {
                let next = NSMaxRange(ModalText.lineRange(text, at: start))
                guard next < text.length else { break }
                start = next
            } else {
                guard start > 0 else { break }
                start = ModalText.previousLineStart(text, from: start)
            }
            steps -= 1
        }
        let content = ModalText.lineContentRange(text, at: start)
        let maximum = allowLineEnd ? content.length : max(0, content.length - 1)
        let p = content.location + min(column, maximum)
        return composedStart(p)
    }

    private func helixVerticalTarget(delta: Int) -> Int? {
        verticalTarget(delta: delta, allowLineEnd: true)
    }

    private func wordRunEnd(from p: Int, count n: Int, word: ModalText.Word) -> Int {
        var q = p
        for _ in 0..<n { q = ModalText.wordRunEnd(text, from: q, word: word) }
        return q
    }

    private func wordEndExclusive(from p: Int, count n: Int, word: ModalText.Word) -> Int {
        var q = p
        for i in 0..<n {
            q = ModalText.wordEnd(text, from: q, word: word)
            if i < n - 1, q + 1 < text.length { q += 1 }
        }
        return min(text.length, q + 1)
    }

    /// The wrapped row at `p`, when j and k move by them.
    private func displayRow(at p: Int) -> NSRange? {
        displayLines ? target?.modalDisplayRow(at: p) : nil
    }

    /// Helix's gh, gl and gs: of the row on screen when moving by
    /// display line, else of the source line.
    private func rowStart(_ p: Int) -> Int {
        displayRow(at: p)?.location ?? ModalText.lineRange(text, at: p).location
    }

    private func rowEnd(_ p: Int) -> Int {
        let end = NSMaxRange(ModalText.lineContentRange(text, at: p))
        // A wrapped row's end is the start of the next row: stop on its
        // last character instead.
        guard let row = displayRow(at: p), row.length > 0, NSMaxRange(row) < end else { return end }
        return composedStart(NSMaxRange(row) - 1)
    }

    private func rowFirstNonBlank(_ p: Int) -> Int {
        guard let row = displayRow(at: p), row.location > ModalText.lineRange(text, at: p).location else {
            return ModalText.firstNonBlank(text, at: p)
        }
        return row.location
    }

    private func composedStart(_ p: Int) -> Int {
        guard p > 0, p < text.length else { return clamp(p) }
        return text.rangeOfComposedCharacterSequence(at: p).location
    }

    private func afterCaret(_ p: Int) -> Int {
        let content = ModalText.lineContentRange(text, at: p)
        guard p < NSMaxRange(content), let c = ModalText.characterRange(text, at: p) else { return p }
        return min(NSMaxRange(c), NSMaxRange(content))
    }

    private func lastLineStart() -> Int {
        ModalText.lineRange(text, at: text.length).location
    }

    private func lineStart(number: Int) -> Int {
        var start = 0
        var n = max(1, number)
        while n > 1 {
            let next = NSMaxRange(ModalText.lineRange(text, at: start))
            guard next < text.length else { break }
            start = next
            n -= 1
        }
        return ModalText.firstNonBlank(text, at: start)
    }

    private func lineCount(in range: NSRange) -> Int {
        var n = 1
        var start = ModalText.lineRange(text, at: range.location).location
        while start < NSMaxRange(range) {
            let next = NSMaxRange(ModalText.lineRange(text, at: start))
            guard next < text.length, next < NSMaxRange(range) else { break }
            start = next
            n += 1
        }
        return n
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(range.lowerBound, self), range.upperBound)
    }
}

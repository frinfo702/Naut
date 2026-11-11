import AppKit
import NautKit
import SwiftUI

/// The shape of the insertion point. `match` follows the keymap: a bar
/// when typing normally, a block in Vim's and Helix's normal modes.
enum CursorShape: String, CaseIterable, Identifiable {
    case match
    case bar
    case block
    case underline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .match: "Match Keymap"
        case .bar: "Bar"
        case .block: "Block"
        case .underline: "Underline"
        }
    }
}

/// How often the insertion point blinks. The values are the time it is
/// on, so "Normal" is the familiar half-second caret.
enum CursorBlink: String, CaseIterable, Identifiable {
    case off
    case slow
    case normal
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }

    /// Seconds on, then seconds off. No blink when off.
    var period: TimeInterval? {
        switch self {
        case .off: nil
        case .slow: 0.9
        case .normal: 0.53
        case .fast: 0.3
        }
    }
}

/// Draws the insertion point as a bar, block or underline, blinking on its
/// own schedule. A view rather than a drawing in the text view so the
/// blink is an animation on a layer and doesn't redraw the note.
@MainActor
final class EditorCursorView: NSView {
    var shape: CursorShape = .bar
    var blink: CursorBlink = .normal
    var color: NSColor = .themeCursor
    /// The character under a block, drawn in the background colour so it
    /// stays legible on the fill.
    var content: NSAttributedString?

    private var animation: CAAnimation?
    /// True while typing: the cursor stays solid and its blink resumes a
    /// moment after the last keystroke, as the system indicator does.
    private var paused = false

    var isPaused: Bool { paused }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = 1
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Show `shape` at `rect`, or hide the cursor when `visible` is false.
    func update(shape: CursorShape, blink: CursorBlink, rect: NSRect, content: NSAttributedString?, visible: Bool) {
        var rect = rect
        switch shape {
        case .bar, .match:
            rect.size.width = 2
        case .underline:
            rect.size.height = 2
            rect.origin.y = rect.maxY - 2
        case .block:
            break
        }

        let wasHidden = isHidden
        let restyle = self.shape != shape || self.blink != blink
        self.shape = shape
        self.blink = blink
        self.content = content
        if frame != rect { frame = rect }

        isHidden = !visible
        if !visible {
            stopBlinking()
        } else if restyle, !paused {
            stopBlinking()
            startBlinking()
        } else if !paused, wasHidden || animation == nil {
            startBlinking()
        }
        needsDisplay = true
    }

    func refreshColor() {
        color = .themeCursor
        needsDisplay = true
    }

    func restartBlinking() {
        paused = false
        guard !isHidden else { return }
        stopBlinking()
        startBlinking()
    }

    /// Solid while a key is being typed; `restartBlinking` brings the
    /// blink back after the typist pauses.
    func pauseBlinking() {
        paused = true
        stopBlinking()
    }

    private func startBlinking() {
        guard let period = blink.period,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            layer?.removeAnimation(forKey: "blink")
            layer?.opacity = 1
            animation = nil
            return
        }
        // Every shape blinks on and off, as a terminal's cursor does: no
        // fade in between.
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 0]
        a.keyTimes = [0, 0.5, 1]
        a.duration = period * 2
        a.repeatCount = .infinity
        a.calculationMode = .discrete
        animation = a
        layer?.removeAnimation(forKey: "blink")
        layer?.add(a, forKey: "blink")
    }

    private func stopBlinking() {
        layer?.removeAnimation(forKey: "blink")
        layer?.opacity = 1
        animation = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        switch shape {
        case .bar:
            color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
        case .underline:
            color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
        case .block, .match:
            color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
            guard let content, content.length > 0, content.size().width <= bounds.width + 0.5 else { return }
            let size = content.size()
            content.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
    }
}

/// A text view whose insertion point is drawn by `EditorCursorView`: a
/// bar, a square block or an underline, on its own blink, so Vim and Helix
/// get their block.
class CursorTextView: NSTextView {
    /// The user's choice; `match` resolves against the keymap and mode.
    var cursorShape: CursorShape = .match {
        didSet { updateCursor() }
    }
    var cursorBlink: CursorBlink = .normal {
        didSet { updateCursor() }
    }
    var keymap: EditorKeymap = .normal {
        didSet { updateCursor() }
    }
    var modalMode: ModalMode = .normal {
        didSet { updateCursor() }
    }
    /// Modal keys; true if handled. Esc in insert mode and every normal
    /// mode key come through here before the text view sees them.
    var modalKey: ((NSEvent) -> Bool)?

    private let cursor = EditorCursorView()
    private var insertionRect = NSRect.zero
    private var blinkResume: Timer?
    /// True between resigning and taking focus again. The window's first
    /// responder is still this view for a moment during a hand-off (and
    /// AppKit may ask for the insertion point again), so the flag is the
    /// source of truth: no caret while we are not editing.
    private var resigned = false

    /// For subclasses that show where the cursor is some other way.
    var hidesCursor: Bool { false }

    /// The shape `cursorShape` resolves to now.
    var resolvedCursorShape: CursorShape {
        guard cursorShape == .match else { return cursorShape }
        return keymap.isModal && modalMode != .insert ? .block : .bar
    }

    /// Whether the cursor should be showing. AppKit still asks for the
    /// insertion point when the view is not focused or has a selection;
    /// the cursor follows those questions rather than the native caret.
    var insertionVisible: Bool {
        guard !resigned, let window, window.isKeyWindow, window.firstResponder === self else { return false }
        return shouldDrawInsertionPoint && selectedRange().length == 0 && !hasMarkedText()
    }

    override func keyDown(with event: NSEvent) {
        TypingSound.shared.keyDown(event)
        if window?.firstResponder === self, modalKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        TypingSound.shared.keyUp(event)
        super.keyUp(with: event)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Our cursor owns the look and the blink.
        insertionRect = rect
        updateCursor()
    }

    override func setSelectedRange(_ range: NSRange) {
        let old = selectedRange()
        super.setSelectedRange(range)
        updateCursor()
        // A caret move during typing does not need a full redraw; a new or
        // lost selection does, because the custom selection background is
        // ours to paint.
        if range.length > 0 || old.length > 0 { needsDisplay = true }
        if !cursor.isPaused { cursor.restartBlinking() }
    }

    /// During a drag TextKit updates the selection here with
    /// `stillSelecting: true` and defers `textViewDidChangeSelection` until
    /// the mouse comes up. Redraw now, or the selection appears a beat late.
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        let old = selectedRange()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateCursor()
        if stillSelecting || old.length > 0 || ranges.contains(where: { $0.rangeValue.length > 0 }) {
            needsDisplay = true
        }
    }

    /// Called when this takes the keyboard: its pane is the focused one.
    var focused: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            resigned = false
            focused?()
        }
        updateCursor()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            // The window installs the next first responder after this
            // returns, so insertionVisible still sees this view and would
            // keep the caret. Resigning is definitive: the caret is no
            // longer ours, so hide it and stay hidden until we are first
            // responder again.
            resigned = true
            cursor.isHidden = true
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(cursorWindowChanged), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(cursorWindowChanged), name: NSWindow.didResignKeyNotification, object: window)
        }
        updateCursor()
    }

    override func didChangeText() {
        super.didChangeText()
        updateCursor()
        // Solid while typing, blinking again after a short pause. The old
        // system indicator did the same; a caret that blinks mid-word
        // reads as a flicker.
        cursor.pauseBlinking()
        blinkResume?.invalidate()
        blinkResume = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cursor.restartBlinking() }
        }
    }

    override func layout() {
        super.layout()
        updateCursor()
    }

    @objc private func cursorWindowChanged() {
        updateCursor()
        needsDisplay = true
        windowStateDidChange()
    }

    /// For subclasses whose drawing also follows the window's focus.
    func windowStateDidChange() {}

    /// The caret follows the theme card's cursor bar. A new theme is
    /// another dynamic colour; the next draw resolves it.
    func updateCursorColor() {
        cursor.refreshColor()
    }

    /// Refresh the frame and shape of the cursor after a selection, layout
    /// or settings change.
    func updateCursor() {
        if cursor.superview == nil {
            addSubview(cursor, positioned: .above, relativeTo: nil)
        }
        let visible = insertionVisible && insertionRect.width > 0 && insertionRect.height > 0 && !hidesCursor
        let shape = resolvedCursorShape
        var rect = insertionRect
        if shape == .block || shape == .underline {
            rect.size.width = blockWidth(at: selectedRange().location)
        }
        cursor.update(
            shape: shape,
            blink: cursorBlink,
            rect: rect,
            content: shape == .block ? blockContent(at: selectedRange().location) : nil,
            visible: visible
        )
    }

    /// A block is a character cell wide. A tab or a drawn block would be
    /// enormous, so those become one square.
    private func blockWidth(at p: Int) -> CGFloat {
        let font = font(at: p)
        let fallback = max(2, (" " as NSString).size(withAttributes: [.font: font]).width)
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              p >= 0, p < storage.length
        else { return fallback }
        let string = storage.string as NSString
        let c = string.character(at: p)
        if c == 0x0A { return fallback }
        if c == LiveProjection.attachmentCharacter { return max(2, insertionRect.height) }
        let range = string.rangeOfComposedCharacterSequence(at: p)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let r = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return max(2, min(r.width, font.pointSize * 2))
    }

    /// The character a block sits on, in the page background colour. A
    /// newline or an attachment has nothing to invert.
    private func blockContent(at p: Int) -> NSAttributedString? {
        guard let storage = textStorage, p >= 0, p < storage.length else { return nil }
        let text = storage.string as NSString
        if text.character(at: p) == 0x0A || text.character(at: p) == LiveProjection.attachmentCharacter { return nil }
        let range = text.rangeOfComposedCharacterSequence(at: p)
        let s = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        s.addAttribute(.foregroundColor, value: NSColor(token: .bg), range: NSRange(location: 0, length: s.length))
        s.removeAttribute(.attachment, range: NSRange(location: 0, length: s.length))
        return s
    }

    private func font(at p: Int) -> NSFont {
        guard let storage = textStorage, storage.length > 0 else { return font ?? .systemFont(ofSize: 13) }
        return storage.attribute(.font, at: min(max(0, p), storage.length - 1), effectiveRange: nil) as? NSFont
            ?? font
            ?? .systemFont(ofSize: 13)
    }

#if DEBUG
    /// Test hook: show the caret without waiting for a blink. Used by
    /// `Snapshot.runCaretTest` to reproduce the title hand-off and by
    /// `--focus-editor` snapshots to put the cursor in the picture.
    func testShowInsertionIndicator() {
        insertionRect = testCaretRect() ?? NSRect(x: 0, y: 0, width: 1, height: 20)
        updateCursor()
    }

    /// The caret's rect, computed rather than waited for from AppKit.
    private func testCaretRect() -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return nil }
        let origin = textContainerOrigin
        if storage.length == 0 {
            let height = (font ?? .systemFont(ofSize: 13)).ascender - (font ?? .systemFont(ofSize: 13)).descender
            return NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y, width: 1, height: height)
        }
        let p = selectedRange().location
        if p >= storage.length {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { return extra.offsetBy(dx: origin.x, dy: origin.y) }
        }
        let q = min(p, storage.length - 1)
        let glyph = layout.glyphIndexForCharacter(at: q)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSRect(x: origin.x + glyphRect.minX, y: origin.y + line.minY, width: 1, height: line.height)
    }

    var testInsertionHidden: Bool { cursor.isHidden }
#endif
}

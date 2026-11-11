import AppKit
import NautKit

// The chrome a block shows under the pointer, as Notion's do: a handle in
// the margin to drag it elsewhere in the note, a floating bar of buttons
// at its top right, and for a picture, handles on its sides to resize it.
// Drawn by the layout over the block, like the rest of Live Preview's
// decoration; the editor tracks the pointer and acts on clicks.

extension LiveLayout {
    enum Chrome {
        enum Kind { case code, math, table, image }

        enum Action: Equatable {
            case copy, edit, language, fullScreen, open, delete

            var symbol: String {
                switch self {
                case .copy: "square.on.square"
                case .edit: "pencil"
                case .language: "chevron.down"
                case .fullScreen: "arrow.up.left.and.arrow.down.right"
                case .open: "arrow.up.right.square"
                case .delete: "trash"
                }
            }
        }

        enum Edge { case left, right }

        enum Control: Equatable {
            case handle
            case button(Action)
            case resize(Edge)
        }

        static let side: CGFloat = 28
        static let inset: CGFloat = 8
        /// The handle: this wide, this far left of the text column.
        static let handleWidth: CGFloat = 18
        static let handleGap: CGFloat = 6
    }

    // MARK: Geometry

    func kind(of element: Int) -> Chrome.Kind? {
        if state.code.contains(where: { $0.element == element }) { return .code }
        return atoms.first { $0.element == element }?.kind
    }

    /// Every block, by element, in note order.
    var blockElements: [Int] {
        (state.code.map(\.element) + atoms.map(\.element)).sorted()
    }

    /// A block's box, in container coordinates.
    func blockRect(_ element: Int) -> NSRect? {
        if let code = state.code.first(where: { $0.element == element }) { return codeBlockRect(code.lines) }
        guard let atom = atoms.first(where: { $0.element == element }) else { return nil }
        return mathRect(at: atom.at)
    }

    /// Where the pointer counts as over a block: its box, widened to the
    /// margin so the handle can be reached.
    func hoverRect(_ element: Int) -> NSRect? {
        guard let r = blockRect(element), let handle = handleRect(element) else { return nil }
        return NSRect(x: handle.minX, y: r.minY, width: r.maxX - handle.minX, height: r.height)
    }

    /// The drag handle: in the margin left of the text column, level with
    /// the block's top.
    func handleRect(_ element: Int) -> NSRect? {
        guard let r = blockRect(element), let container = textContainers.first else { return nil }
        let x = container.lineFragmentPadding - Chrome.handleWidth - Chrome.handleGap
        let y = kind(of: element) == .code ? r.minY + 10 : r.minY + 4
        return NSRect(x: x, y: y, width: Chrome.handleWidth, height: 24)
    }

    func actions(_ kind: Chrome.Kind) -> [Chrome.Action] {
        switch kind {
        case .code: [.language, .copy]
        case .math, .table: [.copy, .edit]
        case .image: [.copy, .fullScreen, .open, .delete]
        }
    }

    /// The bar's buttons, right to left from the block's top right.
    func buttons(_ element: Int) -> [(Chrome.Action, NSRect)] {
        guard let kind = kind(of: element), let r = blockRect(element) else { return [] }
        var x = r.maxX - Chrome.inset - 2
        let y = r.minY + Chrome.inset + 2
        var out: [(Chrome.Action, NSRect)] = []
        for action in actions(kind).reversed() {
            let width = action == .language ? languageWidth(element) : Chrome.side
            x -= width
            out.insert((action, NSRect(x: x, y: y, width: width, height: Chrome.side)), at: 0)
        }
        return out
    }

    /// The language button of code block `element`: its label and a
    /// chevron. Clicking it edits the fence's language.
    func languageRect(_ element: Int) -> NSRect? {
        buttons(element).first { $0.0 == .language }?.1
    }

    private func languageWidth(_ element: Int) -> CGFloat {
        let label = state.code.first { $0.element == element }?.label ?? ""
        return ceil(Self.text(label, .fgDim).size().width) + 30
    }

    func resizeRect(_ element: Int, _ edge: Chrome.Edge) -> NSRect? {
        guard let r = blockRect(element) else { return nil }
        let h = min(48, r.height * 0.4)
        return NSRect(x: edge == .left ? r.minX + 8 : r.maxX - 14, y: r.midY - h / 2, width: 6, height: h)
    }

    /// The block under `p` (container coordinates), and the control of its
    /// chrome there, if any.
    func chromeHit(at p: NSPoint) -> (element: Int, control: Chrome.Control?)? {
        guard let element = blockElements.first(where: { hoverRect($0)?.contains(p) ?? false }) else { return nil }
        return (element, control(of: element, at: p))
    }

    func control(of element: Int, at p: NSPoint) -> Chrome.Control? {
        if handleRect(element)?.insetBy(dx: -4, dy: -4).contains(p) == true { return .handle }
        if let (action, _) = buttons(element).first(where: { $0.1.contains(p) }) { return .button(action) }
        if kind(of: element) == .image {
            for edge in [Chrome.Edge.left, .right] where resizeRect(element, edge)?.insetBy(dx: -8, dy: -8).contains(p) == true {
                return .resize(edge)
            }
        }
        return nil
    }

    // MARK: Drawing

    func drawChrome(at origin: NSPoint) {
        guard let container = textContainers.first else { return }
        if let y = dropLine {
            let pad = container.lineFragmentPadding
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: origin.x + pad, y: origin.y + y - 1.5, width: container.size.width - 2 * pad, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if let element = dragging, let r = blockRect(element) {
            // The block being moved fades where it was.
            NSColor(token: .bg).withAlphaComponent(0.55).setFill()
            r.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
        }
        guard dragging == nil else { return }

        // A code block's bar also shows while its code is edited, with the
        // language the fence would otherwise keep.
        var shown = Set<Int>()
        if let element = hovered { shown.insert(element) }
        if let code = editingCode { shown.insert(code.element) }
        if let element = copiedCode { shown.insert(element) }
        for element in shown.sorted() {
            guard let kind = kind(of: element) else { continue }
            let over = element == hovered ? hoveredControl : nil
            if element == hovered, let handle = handleRect(element) {
                drawHandle(handle.offsetBy(dx: origin.x, dy: origin.y), over: over == .handle)
            }
            if kind == .image, element == hovered {
                for edge in [Chrome.Edge.left, .right] {
                    guard let r = resizeRect(element, edge) else { continue }
                    drawResizeHandle(r.offsetBy(dx: origin.x, dy: origin.y), over: over == .resize(edge))
                }
            }
            drawBar(element, kind: kind, over: over, at: origin)
        }
    }

    private func drawHandle(_ r: NSRect, over: Bool) {
        if over {
            NSColor(token: .line).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
        // Six dots, two by three, as Notion's handle.
        NSColor(token: over ? .fg : .fgDim).setFill()
        for col in 0..<2 {
            for row in 0..<3 {
                let c = NSPoint(x: r.midX + (CGFloat(col) - 0.5) * 6, y: r.midY + CGFloat(row - 1) * 5.5)
                NSBezierPath(ovalIn: NSRect(x: c.x - 1.4, y: c.y - 1.4, width: 2.8, height: 2.8)).fill()
            }
        }
    }

    private func drawResizeHandle(_ r: NSRect, over: Bool) {
        let r = over ? r.insetBy(dx: -1, dy: -4) : r
        let path = NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor.white.withAlphaComponent(0.95).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    /// The floating bar: a capsule of buttons, and the hovered button's
    /// name under it at once, without a tooltip's delay.
    private func drawBar(_ element: Int, kind: Chrome.Kind, over: Chrome.Control?, at origin: NSPoint) {
        let buttons = buttons(element)
        guard let first = buttons.first?.1, let last = buttons.last?.1 else { return }
        let bar = NSUnionRect(first, last).insetBy(dx: -2, dy: -2).offsetBy(dx: origin.x, dy: origin.y)
        let path = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor(token: .surfaceRaised).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(token: .edgeTop).setStroke()
        path.lineWidth = 1
        path.stroke()

        for (action, rect) in buttons {
            let r = rect.offsetBy(dx: origin.x, dy: origin.y)
            let hot = over == .button(action)
            if hot {
                NSColor(token: .line).setFill()
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            }
            let color = NSColor(token: hot ? .fg : .fgDim)
            if action == .language {
                let label = Self.text(state.code.first { $0.element == element }?.label ?? "", hot ? .fg : .fgDim)
                let size = label.size()
                label.draw(at: NSPoint(x: r.minX + 10, y: r.midY - size.height / 2))
                Self.icon("chevron.down", color: color, in: NSRect(x: r.maxX - 18, y: r.minY, width: 10, height: r.height), size: 8)
            } else {
                let copied = action == .copy && copiedCode == element
                Self.icon(copied ? "checkmark" : action.symbol, color: copied ? NSColor(token: .fg) : color, in: r, size: 12)
            }
            if hot { drawTip(Self.title(action, kind), key: action == .fullScreen ? "Space" : nil, under: r) }
        }
    }

    private func drawTip(_ title: String, key: String?, under button: NSRect) {
        let text = Self.text(title, .fg, size: 12)
        let keyText = key.map { Self.text($0, .fgDim, size: 11) }
        let keyWidth = keyText.map { $0.size().width + 12 + 6 } ?? 0
        let size = NSSize(width: ceil(text.size().width + keyWidth) + 20, height: 26)
        var x = button.midX - size.width / 2
        if let view = firstTextView { x = min(x, view.bounds.maxX - size.width - 8) }
        let box = NSRect(x: x, y: button.maxY + 8, width: size.width, height: size.height)
        let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowBlurRadius = 8
        shadow.set()
        NSColor(token: .surfaceRaised).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(token: .edgeTop).setStroke()
        path.stroke()
        text.draw(at: NSPoint(x: box.minX + 10, y: box.midY - text.size().height / 2))
        if let keyText {
            let k = keyText.size()
            let cap = NSRect(x: box.maxX - 10 - k.width - 12, y: box.midY - 9, width: k.width + 12, height: 18)
            NSColor(token: .line).setStroke()
            NSBezierPath(roundedRect: cap, xRadius: 4, yRadius: 4).stroke()
            keyText.draw(at: NSPoint(x: cap.minX + 6, y: cap.midY - k.height / 2))
        }
    }

    static func title(_ action: Chrome.Action, _ kind: Chrome.Kind) -> String {
        switch (action, kind) {
        case (.copy, .code): "Copy code"
        case (.copy, .math): "Copy TeX"
        case (.copy, .table): "Copy Markdown"
        case (.copy, .image): "Copy image"
        case (.edit, .table): "Edit table"
        case (.edit, _): "Edit equation"
        case (.language, _): "Language"
        case (.fullScreen, _): "Full screen"
        case (.open, _): "Open original"
        case (.delete, _): "Delete"
        }
    }

    /// A symbol tinted with `color`, centred in `rect`. Drawn rather than
    /// put in a button: the page's button is drawn by the layout too.
    static func icon(_ name: String, color: NSColor, in rect: NSRect, size: CGFloat = 13) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let configuration = NSImage.SymbolConfiguration(paletteColors: [resolved])
            .applying(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let s = image.size
        image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }

    static func text(_ s: String, _ token: ThemeToken, size: CGFloat = 11) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor(token: token),
        ])
    }
}

/// A picture full screen over the window: dimmed page, the picture as
/// large as fits. A click, Esc or Space puts it away.
final class ImageViewer: NSView {
    private let image: NSImage
    private var onClose: () -> Void = {}

    static func show(_ image: NSImage, in window: NSWindow, onClose: @escaping () -> Void) {
        guard let content = window.contentView else { return }
        let viewer = ImageViewer(image: image)
        viewer.onClose = onClose
        viewer.frame = content.bounds
        viewer.autoresizingMask = [.width, .height]
        viewer.alphaValue = 0
        content.addSubview(viewer)
        window.makeFirstResponder(viewer)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            viewer.animator().alphaValue = 1
        }
    }

    private init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.85).setFill()
        bounds.fill()
        let room = bounds.insetBy(dx: 48, dy: 48)
        let scale = min(1, room.width / max(image.size.width, 1), room.height / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) { close() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == " " { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func close() {
        let onClose = onClose
        self.onClose = {}
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: {
            self.removeFromSuperview()
            onClose()
        }
    }
}

import AppKit
import NautKit
import SwiftUI

/// A picture in a window of its own, over the note's: zoomed with the
/// scroll wheel or a pinch, about the pointer, and ⌘0 fits it again; dragged
/// to pan once it outgrows the window. Its scale at the top left, buttons to
/// save, copy and copy its link at the top right, on the traffic lights'
/// line. Esc, ⌘W, the close button or
/// the red light puts it away and the note gets the keyboard back.
@MainActor
final class ImageViewer: NSWindow, NSWindowDelegate {
    static let id = NSUserInterfaceItemIdentifier("naut.image")
    /// The one open; a new one replaces it.
    private static var current: ImageViewer?

    private let image: NSImage
    private let url: URL
    private let scroll = ZoomScrollView()
    private let model = ViewerModel()
    private var onClose: () -> Void = {}
    /// The strip the traffic lights sit in, as tall as the note window's.
    private static let bar: CGFloat = Metrics.titleBarHeight

    static func show(_ image: NSImage, url: URL, over parent: NSWindow, onClose: @escaping () -> Void) {
        current?.close()
        let viewer = ImageViewer(image: image, url: url, frame: parent.frame)
        viewer.onClose = onClose
        current = viewer
        viewer.makeKeyAndOrderFront(nil)
        viewer.fit()
    }

    private init(image: NSImage, url: URL, frame: NSRect) {
        self.image = image
        self.url = url
        super.init(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        identifier = Self.id
        title = url.lastPathComponent
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        delegate = self
        setFrame(frame, display: false)
        backgroundColor = NSColor(token: .bg)
        // The note window's unified toolbar puts its traffic lights lower
        // than a bare title bar's; an empty one puts these in the same place.
        toolbar = NSToolbar()
        toolbarStyle = .unified

        let content = NSView()
        contentView = content
        // Everything in the bar is centred on the traffic lights.
        let lights: CGFloat = standardWindowButton(.closeButton).flatMap { button in
            button.superview.map { content.bounds.height - content.convert(NSPoint(x: 0, y: button.frame.midY), from: $0).y }
        } ?? Self.bar / 2

        let picture = NSImageView(image: image)
        picture.imageScaling = .scaleAxesIndependently
        picture.frame = NSRect(origin: .zero, size: image.size)
        scroll.contentView = CenteringClipView()
        scroll.documentView = picture
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        scroll.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - Self.bar)
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        scroll.zoomedByHand = { [weak self] in self?.fitted = false }

        // The bar, as the note window's pane controls are made: a fill
        // under the pointer, a give under the press, a name on hover, and a
        // check once a copy is done.
        let bar = NSHostingView(rootView: ViewerBar(model: model))
        bar.frame = NSRect(x: 0, y: content.bounds.height - lights - Self.bar / 2, width: content.bounds.width, height: Self.bar)
        bar.autoresizingMask = [.width, .minYMargin]
        // It sits in the title bar on purpose; not pushed out of it.
        bar.safeAreaRegions = []
        content.addSubview(bar)
        model.save = { [weak self] in self?.save() }
        model.copyImage = { [weak self] in self?.copyImage() }
        model.copyLink = { [weak self] in self?.copyLink() }
        model.close = { [weak self] in self?.close() }

        NotificationCenter.default.addObserver(self, selector: #selector(zoomed), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
    }

    /// Whether it is at the size that fits, rather than zoomed by hand.
    /// Fitted, it fits again whenever the window changes size: maximized,
    /// it grows with the window instead of staying small in a corner.
    private var fitted = true

    /// As large as fits, never past its own size.
    func fit() {
        fitted = true
        let room = scroll.bounds.insetBy(dx: 40, dy: 40).size
        let scale = min(1, room.width / max(image.size.width, 1), room.height / max(image.size.height, 1))
        scroll.magnification = scale
        // In the middle of the window, wherever the old size left it.
        let clip = scroll.contentView
        clip.setBoundsOrigin(clip.constrainBoundsRect(clip.bounds).origin)
        scroll.reflectScrolledClipView(clip)
        zoomed()
    }

    func windowDidResize(_ notification: Notification) {
        if fitted { fit() }
    }

    @objc private func zoomed() {
        model.zoom = "\(Int((scroll.magnification * 100).rounded()))%"
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (command, event.charactersIgnoringModifiers) {
        case (false, _) where event.keyCode == 53, (false, " "): close()
        case (true, "0"): fit()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "0": fit()
        case "w": close()
        case "c": copyImage()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) { close() }

    // MARK: Buttons

    private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        model.flash(.copyImage)
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.isFileURL ? url.path : url.absoluteString, forType: .string)
        model.flash(.copyLink)
    }

    /// The file as it is when it is one; otherwise the picture as PNG.
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent.isEmpty ? "image.png" : url.lastPathComponent
        panel.beginSheetModal(for: self) { [image, url] response in
            guard response == .OK, let target = panel.url else { return }
            let data = url.isFileURL ? try? Data(contentsOf: url)
                : image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            guard let data, (try? data.write(to: target, options: .atomic)) != nil else { return NSSound.beep() }
            MainActor.assumeIsolated { self.model.flash(.save) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if Self.current === self { Self.current = nil }
        let onClose = onClose
        self.onClose = {}
        DispatchQueue.main.async { onClose() }
    }
}

/// The scroll wheel zooms, about the pointer, instead of scrolling; a drag
/// pans.
private final class ZoomScrollView: NSScrollView {
    /// Called when the wheel or a pinch zooms.
    var zoomedByHand: (() -> Void)?

    override func magnify(with event: NSEvent) {
        zoomedByHand?()
        super.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let doc = documentView else { return super.scrollWheel(with: event) }
        // A trackpad's deltas are points, many per gesture; a wheel's are
        // lines, a few per notch.
        let step = event.hasPreciseScrollingDeltas ? 0.005 : 0.08
        let factor = exp(event.scrollingDeltaY * step)
        zoomedByHand?()
        let at = doc.convert(event.locationInWindow, from: nil)
        setMagnification(min(maxMagnification, max(minMagnification, magnification * factor)), centeredAt: at)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        var last = event.locationInWindow
        NSCursor.closedHand.push()
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type == .leftMouseDragged {
            let p = e.locationInWindow
            var origin = contentView.bounds.origin
            origin.x -= (p.x - last.x) / magnification
            origin.y += (p.y - last.y) / magnification * (contentView.isFlipped ? 1 : -1)
            contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
            reflectScrolledClipView(contentView)
            last = p
        }
        NSCursor.pop()
    }
}

/// Keeps a picture smaller than the window in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView?.frame else { return r }
        if doc.width < r.width { r.origin.x = (doc.width - r.width) / 2 }
        if doc.height < r.height { r.origin.y = (doc.height - r.height) / 2 }
        return r
    }
}

/// What the viewer's bar shows, and what its buttons do.
@MainActor
private final class ViewerModel: ObservableObject {
    enum Done { case save, copyImage, copyLink }

    @Published var zoom = ""
    /// The button whose action just finished, showing a check.
    @Published var done: Done?
    var save: () -> Void = {}
    var copyImage: () -> Void = {}
    var copyLink: () -> Void = {}
    var close: () -> Void = {}
    private var reset: Task<Void, Never>?

    func flash(_ action: Done) {
        done = action
        reset?.cancel()
        reset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.done = nil
        }
    }
}

/// The scale after the traffic lights; save, copy, copy link and close at
/// the right, each a pane control as in the note window.
private struct ViewerBar: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        HStack(spacing: 2) {
            Text(model.zoom)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.fg)
                // Where the note window starts its own controls.
                .padding(.leading, Metrics.trafficLightsWidth + 14)
            Spacer()
            button(.save, "square.and.arrow.down", "Save image…", done: "Saved", action: model.save)
            button(.copyImage, "square.on.square", "Copy image", done: "Copied", action: model.copyImage)
            button(.copyLink, "link", "Copy link", done: "Link copied", action: model.copyLink)
            Rectangle().fill(Theme.line).frame(width: 1, height: 18).padding(.horizontal, 6)
            button(nil, "xmark", "Close (Esc)", done: "", action: model.close)
        }
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity)
    }

    private func button(_ kind: ViewerModel.Done?, _ symbol: String, _ help: String, done: String, action: @escaping () -> Void) -> some View {
        let finished = kind != nil && model.done == kind
        return Button(action: action) {
            PaneIcon(symbol: finished ? "checkmark" : symbol, tint: finished ? Theme.fg : Theme.fgDim)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressStyle())
        .help(finished ? done : help)
        .accessibilityLabel(help)
    }
}

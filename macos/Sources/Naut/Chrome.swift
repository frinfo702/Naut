import AppKit
import NautKit
import SwiftUI

// The window's frame, after Rex: the theme's background with rounded
// panels floating on it, a gap between them.

/// The theme's background, or in Glass the desktop behind the window
/// seen through it.
struct WindowBackdrop: View {
    let background: Store.WindowBackground
    /// In zen there are no panels to raise: the window is one page.
    var zen = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch background {
        case .solid:
            // The panels hold the theme's background, as the page does; the
            // frame around them sits a step deeper so they read as raised.
            ZStack {
                Theme.bg
                Color.black.opacity(zen ? 0 : colorScheme == .dark ? 0.3 : 0.05)
            }
        case .glass:
            ZStack {
                BehindWindowBlur()
                Theme.bg.opacity(Metrics.glassOpacity)
            }
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// A floating panel: the theme's background, a hairline edge, round
    /// corners. In Glass it lets some of the desktop through too.
    /// `bare` keeps only the clip: the page lies on the window itself, as
    /// in zen, and the edge and its shadow fade out.
    func panel(_ background: Store.WindowBackground, bare: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        return self
            .background(bare ? .clear : Theme.bg.opacity(background == .glass ? 0.8 : 1), in: shape)
            .clipShape(shape)
            // Lit from above, like the Settings groups: the edge carries the
            // depth in dark themes, where a shadow can't be seen.
            .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1).opacity(bare ? 0 : 1))
            // A translucent panel would show its own shadow through itself.
            .shadow(color: .black.opacity(bare || background == .glass ? 0 : 0.05), radius: 5, y: 2)
    }

    /// A fill under the pointer. It appears at once: hovering happens too
    /// often for a fade to be anything but lag.
    func hoverFill(_ color: Color, radius: CGFloat) -> some View {
        modifier(HoverFill(color: color, radius: radius))
    }
}

private struct HoverFill: ViewModifier {
    let color: Color
    let radius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                if hovering { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color) }
            }
            .onHover { hovering = $0 }
    }
}

/// A plain button that gives a little under the press, so a click is felt
/// before its result is seen.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: Metrics.pressDuration), value: configuration.isPressed)
    }
}

extension Store {
    /// Fold the sidebar away or bring it back, sliding from its edge.
    func toggleSidebar() {
        withAnimation(.snappy(duration: Metrics.toggleDuration)) { showSidebar.toggle() }
    }

    /// Into zen or out of it, at once. It is a key press: motion would only
    /// make the page wait, and animating the layout would rewrap the text
    /// on every frame.
    func toggleZen() {
        // The lights back first: the title bar lays the returning toolbar
        // out around them only if they are there to be seen.
        if zen { ZenTrackingView.restoreLights() }
        zen.toggle()
    }

    private static var watchingSwipe = false

    /// A two-finger swipe anywhere in the window pulls the sidebar out
    /// from its edge or pushes it back. The scroll still reaches the view
    /// under the pointer; only a gesture that is mostly sideways and long
    /// enough counts, once, and its momentum is ignored.
    func watchSidebarSwipe() {
        // Once for the app: every window shares this store.
        guard !Self.watchingSwipe else { return }
        Self.watchingSwipe = true
        var travel = CGSize.zero
        var fired = false
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard self.swipeSidebar, !self.zen, event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return event }
            if event.phase.contains(.began) { travel = .zero; fired = false }
            guard event.phase.contains(.changed), !fired else { return event }
            // Where the fingers went, whatever the natural-scrolling setting.
            let flip: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            travel.width += event.scrollingDeltaX * flip
            travel.height += event.scrollingDeltaY
            guard abs(travel.width) > 60, abs(travel.width) > abs(travel.height) * 2 else { return event }
            fired = true
            // Away from the sidebar's edge opens it; toward it closes.
            let away = self.sidebarSide == .left ? travel.width > 0 : travel.width < 0
            if away != self.showSidebar { self.toggleSidebar() }
            return event
        }
    }
}

/// The window's own controls, which SwiftUI doesn't reach: in zen the
/// traffic lights fade away, and come back only while the pointer is
/// near their corner.
struct ZenWindow: NSViewRepresentable {
    let zen: Bool

    func makeNSView(context: Context) -> ZenTrackingView { ZenTrackingView() }

    func updateNSView(_ view: ZenTrackingView, context: Context) {
        view.zen = zen
    }
}

/// Spread over the whole window, title bar included, to follow the
/// pointer. A tracking area reports to its owner whatever is drawn over
/// it, so the notes above take every click as before.
final class ZenTrackingView: NSView {
    var zen = false {
        didSet {
            guard zen != oldValue else { return }
            near = false
            // Later: a new view is not in its window yet.
            DispatchQueue.main.async { self.showLights(!self.zen, animated: false) }
        }
    }

    /// The pointer is around the lights.
    private var near = false

    /// How far around the lights the pointer brings them back.
    private static let reach: CGFloat = 28

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { setNear(false) }

    private func follow(_ event: NSEvent) {
        guard zen, let corner = lightsFrame else { return }
        setNear(corner.insetBy(dx: -Self.reach, dy: -Self.reach).contains(event.locationInWindow))
    }

    /// Snapshot harness: as if the pointer had come to the lights.
    func pointAtLights() {
        guard lightsFrame != nil else { return }
        setNear(true)
    }

    private func setNear(_ value: Bool) {
        guard zen, value != near else { return }
        near = value
        showLights(value)
    }

    /// The three lights, in the window's space.
    private var lightsFrame: NSRect? {
        guard let window else { return nil }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { kind in
                window.standardWindowButton(kind).flatMap { $0.superview?.convert($0.frame, to: nil) }
            }
            .reduce(nil) { union, frame in union?.union(frame) ?? frame }
    }

    /// Every window's lights at full strength, at once.
    static func restoreLights() {
        for window in NSApp.windows {
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.alphaValue = 1
            }
        }
    }

    /// Faded, not disabled: the toolbar lays its items out as if disabled
    /// lights weren't there, over them once back. Hidden, they can't be
    /// clicked by accident: the pointer near them shows them first.
    /// Animated only for the pointer; going into zen is instant like the
    /// rest of the window.
    private func showLights(_ show: Bool, animated: Bool = true) {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            // Quick to come when looked for, a little slower to go.
            context.duration = animated ? show ? 0.12 : 0.2 : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.animator().alphaValue = show ? 1 : 0
            }
        }
    }
}

// MARK: - Panel header

/// The publish control's face among the pane controls: a globe, in the
/// cursor colour once the note is on the web.
struct PublishIcon: View {
    let published: Bool
    let busy: Bool

    var body: some View {
        if busy {
            ProgressView().controlSize(.mini).frame(width: Metrics.paneControl, height: Metrics.paneControl)
        } else {
            PaneIcon(symbol: "globe", tint: published ? Theme.cursor : Theme.fgDim)
        }
    }
}

// MARK: - Status bar

/// The focused pane's state, once for the window, in the title bar: the
/// keymap and its mode while a modal keymap is in use, and the note's
/// length if asked for in Settings.
/// Static: it changes on a key press, and motion on keyboard input is
/// noise, not feedback.
struct StatusBar: View {
    let keymap: EditorKeymap
    let mode: ModalMode
    /// nil hides the count.
    let characters: Int?

    var body: some View {
        HStack(spacing: 10) {
            if let characters {
                Text("\(characters.formatted()) characters").foregroundStyle(Theme.fgDim)
            }
            if keymap.isModal {
                KeymapMark(keymap: keymap)
                ModePill(mode: mode)
            }
        }
        .font(.system(size: 12))
        .padding(.trailing, 6)
    }
}

struct KeymapMark: View {
    let keymap: EditorKeymap

    var body: some View {
        HStack(spacing: 6) {
            if let logo = Logos.keymap(keymap) {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
            }
            Text(keymap.title)
        }
        .foregroundStyle(Theme.fgBody)
        .accessibilityElement(children: .combine)
    }
}

/// NORMAL is neutral; INSERT takes the theme's green and the selecting
/// modes its blue, so the mode reads at a glance in any theme.
struct ModePill: View {
    let mode: ModalMode

    var body: some View {
        let tint: Color? = switch mode {
        case .normal: nil
        case .insert: Theme.swatch(2)
        case .visual, .visualLine, .select, .selectLine: Theme.swatch(4)
        }
        Text(mode.title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(tint ?? Theme.fg)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Capsule().fill(tint?.opacity(0.12) ?? Theme.surfaceRaised))
            .overlay(Capsule().strokeBorder(tint?.opacity(0.35) ?? Theme.guide, lineWidth: 1))
            .accessibilityLabel("\(mode.title) mode")
    }
}

// MARK: - Tabs

/// The open notes, as pills in the title bar like Rex's tabs. The
/// selected one is raised and bright; the rest are dim.
struct TabStrip: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.tabs, id: \.self) { id in
                if let note = store.notes.first(where: { $0.id == id }) {
                    NoteTab(note: note, selected: id == store.selection)
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
    }
}

private struct NoteTab: View {
    @Environment(Store.self) private var store
    let note: Note
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        // Cut by characters rather than by a frame, so a short name's tab
        // hugs it instead of growing to the frame's limit.
        Text(note.displayName.count > Metrics.tabMaxCharacters
            ? note.displayName.prefix(Metrics.tabMaxCharacters - 1) + "…"
            : note.displayName)
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Theme.fg : Theme.fgDim)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background {
                if selected {
                    Capsule().fill(Theme.surfaceRaised)
                        .overlay(Capsule().strokeBorder(Theme.guide, lineWidth: 1))
                } else if hovering {
                    Capsule().fill(Theme.surfaceRaised.opacity(0.6))
                }
            }
            // The close button covers the end of the name under the pointer,
            // so a tab keeps its width and has no room set aside for it.
            .overlay(alignment: .trailing) {
                if hovering, store.tabs.count > 1 {
                    Button { store.closeTab(note.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.fgBody)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(selected ? Theme.surfaceRaised : Theme.surface))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .help("Close Tab (⌘W)")
                }
            }
            .contentShape(Capsule())
            .onTapGesture { store.selection = note.id }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Close Tab") { store.closeTab(note.id) }
                    .disabled(store.tabs.count < 2)
                Button("Close Other Tabs") { store.closeOtherTabs(than: note.id) }
                    .disabled(store.tabs.count < 2)
            }
    }
}

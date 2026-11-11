import AppKit
import NautKit
import SwiftUI

/// The window's panes, each a floating panel, with the gaps between them
/// dragging to resize. They are laid out flat from the tree's frames, so a
/// pane is the same view wherever it is: in the layout, maximized over it
/// or floating in front. It keeps its editor, and moving between those is
/// one change of frame.
/// A new pane slides in from the edge it was split towards while the pane
/// it came from gives way on the same spring: the split reads as one push.
struct Panes: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set by the sidebar outline; the focused pane scrolls there.
    @Binding var scrollTarget: String?
    /// Each pane's Vim or Helix mode, shown once for the focused pane.
    @Binding var modes: [Pane.ID: ModalMode]
    let openSettings: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let area = CGRect(origin: .zero, size: geometry.size)
            let placed = store.place(store.layout, in: area.size)
            ZStack(alignment: .topLeading) {
                ForEach(items(placed.panes, in: area)) { item in
                    NotePane(
                        pane: item.pane, floating: item.floating, area: area.size,
                        scrollTarget: $scrollTarget, mode: Binding(get: { modes[item.pane.id] ?? .normal }, set: { modes[item.pane.id] = $0 }),
                        openSettings: openSettings
                    )
                    .frame(width: item.frame.width, height: item.frame.height)
                    // Under a maximized pane the layout is out of sight
                    // and out of reach, also where the panel is translucent.
                    .opacity(item.covered ? 0 : 1)
                    .allowsHitTesting(!item.covered)
                    .zIndex(item.floating ? 3 : item.pane.id == store.maximized ? 1 : 0)
                    .transition(PaneSlide(item))
                }
                if store.maximized == nil {
                    ForEach(placed.dividers) { divider in
                        // A little wider than the gap, to be easy to catch.
                        let frame = divider.frame.insetBy(dx: divider.vertical ? 0 : -2, dy: divider.vertical ? -2 : 0)
                        DividerHandle(divider: divider)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .zIndex(2)
                    }
                }
            }
            // Floating and maximizing are a pane changing its frame, on the
            // spring a new pane arrives on. Not the drag of a floating one.
            .animation(reduceMotion ? nil : Metrics.paneSplit, value: store.maximized)
            .animation(reduceMotion ? nil : Metrics.paneSplit, value: Set(store.floating.keys))
            .onChange(of: geometry.size, initial: true) { _, size in store.paneArea = size }
        }
    }

    /// Every pane in the tree's order, with the frame it has now.
    private func items(_ placed: [PaneNode.Placed], in area: CGRect) -> [PaneItem] {
        store.layout.panes.compactMap { pane in
            if let unit = store.floating[pane.id] {
                let frame = CGRect(
                    x: unit.minX * area.width, y: unit.minY * area.height,
                    width: unit.width * area.width, height: unit.height * area.height
                )
                return PaneItem(pane: pane, frame: frame, floating: true)
            }
            guard let home = placed.first(where: { $0.pane.id == pane.id }) else { return nil }
            return PaneItem(
                pane: pane, frame: pane.id == store.maximized ? area : home.frame,
                vertical: home.vertical, first: home.first,
                covered: store.maximized != nil && store.maximized != pane.id
            )
        }
    }
}

/// A pane as drawn.
private struct PaneItem: Identifiable {
    let pane: Pane
    let frame: CGRect
    var floating = false
    /// The split it is in is stacked, and it is the first there.
    var vertical = false
    var first = false
    /// Behind a maximized pane.
    var covered = false
    var id: Pane.ID { pane.id }
}

/// A pane arriving or leaving: it slides its own length, away from the
/// pane that makes room for it or takes its place, inside its own frame.
/// A floating one has no such neighbour, and only fades.
private struct PaneSlide: Transition {
    let travel: CGSize
    /// Where the pane is. Placed here, outside the clip, which has to be
    /// around the pane before it is moved to its place.
    let origin: CGPoint
    /// How far outside the pane the clip is: room for its shadow.
    let margin: CGFloat

    init(_ item: PaneItem) {
        origin = item.frame.origin
        margin = item.floating ? Metrics.floatShadow * 3 : Metrics.panelGap
        // The first of a split leaves backwards, the rest go back the way
        // they came.
        let sign: CGFloat = item.first ? -1 : 1
        travel = item.floating ? .zero : item.vertical
            ? CGSize(width: 0, height: sign * (item.frame.height + Metrics.panelGap))
            : CGSize(width: sign * (item.frame.width + Metrics.panelGap), height: 0)
    }

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(phase.isIdentity ? .zero : travel)
            .opacity(phase.isIdentity ? 1 : 0)
            .padding(margin)
            .clipped()
            .padding(-margin)
            .offset(x: origin.x, y: origin.y)
    }
}

/// The gap between two panes. Dragging it moves space from one to the
/// other; a grip shows under the pointer.
private struct DividerHandle: View {
    @Environment(Store.self) private var store
    let divider: PaneNode.Divider
    /// The share the pane before had when the drag began.
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(Theme.fgDim.opacity(hovering || start != nil ? 0.7 : 0))
            .frame(width: divider.vertical ? Metrics.gripLength : 2, height: divider.vertical ? 2 : Metrics.gripLength)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .modifier(ResizeCursor(vertical: divider.vertical))
            .gesture(
                // In the window's space: the handle moves as it is dragged.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? divider.weight
                        start = from
                        let moved = divider.vertical ? drag.translation.height : drag.translation.width
                        store.resizePanes(divider, to: from + moved / divider.perWeight)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

/// The pointer over a divider: ↔ between panes side by side, ↕ between
/// stacked ones, to say it drags.
private struct ResizeCursor: ViewModifier {
    let vertical: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            // The system's own, which the text views on either side can't
            // take back while the pointer is here.
            content.pointerStyle(vertical ? .rowResize : .columnResize)
        } else {
            content.onHover { inside in
                if inside { (vertical ? NSCursor.resizeUpDown : .resizeLeftRight).push() } else { NSCursor.pop() }
            }
        }
    }
}

extension Store {
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func splitAnimated(_ direction: SplitDirection) {
        withAnimation(reduceMotion ? nil : Metrics.paneSplit) { split(direction) }
    }

    /// Leaving is quicker than arriving and doesn't bounce.
    func closePaneAnimated() {
        withAnimation(reduceMotion ? nil : .snappy(duration: Metrics.paneCloseDuration)) { closePane() }
    }
}

/// One note: its header and its text.
struct NotePane: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pane: Pane
    /// In front of the layout, where its header drags it about.
    let floating: Bool
    /// The size of the panes' area, which a floating pane's place is in
    /// fractions of.
    let area: CGSize
    @Binding var scrollTarget: String?
    /// The mode this pane's Vim or Helix editor is in.
    @Binding var modalMode: ModalMode
    let openSettings: () -> Void
    /// Where a floating pane was when its drag began.
    @State private var dragStart: CGPoint?

    init(
        pane: Pane, floating: Bool, area: CGSize,
        scrollTarget: Binding<String?>, mode: Binding<ModalMode>, openSettings: @escaping () -> Void
    ) {
        self.pane = pane
        self.floating = floating
        self.area = area
        _scrollTarget = scrollTarget
        _modalMode = mode
        self.openSettings = openSettings
    }

    var body: some View {
        let focused = pane.id == store.focus
        let note = store.notes.first { $0.id == pane.note }
        VStack(spacing: 0) {
            header(note, focused: focused)
            if let note {
                editor(note, focused: focused)
                    .onChange(of: note.id) { _, _ in modalMode = .normal }
                    .onChange(of: store.keymap) { _, _ in modalMode = .normal }
            } else {
                NotePicker { id in
                    store.focus(pane.id)
                    store.selection = id
                }
            }
        }
        // The pane is its frame, whatever its content would like to be.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // Among several, the pane the keyboard and the sidebar act on is
        // the one at full strength.
        .opacity(focused ? 1 : Metrics.unfocusedPaneOpacity)
        .animation(.easeOut(duration: Metrics.pressDuration), value: focused)
        // A floating pane is over other text, which mustn't show through.
        .panel(floating ? .solid : store.windowBackground)
        .shadow(color: .black.opacity(floating ? 0.35 : 0), radius: Metrics.floatShadow, y: Metrics.floatShadow / 2)
        // A click on the header or an empty pane; a click in the text
        // focuses through the editor taking the keyboard.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { store.focus(pane.id) })
    }

    /// The note's name and its star, and on the focused pane what can be
    /// done with it. A floating pane moves by its header.
    private func header(_ note: Note?, focused: Bool) -> some View {
        HStack(spacing: 10) {
            if let note {
                // Quiet: the page's own title is right below, and this only
                // has to say where you are once that has scrolled away.
                Text(note.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(note.isUntitled ? Theme.fgDim : Theme.fgBody)
                    .lineLimit(1)
                // Like the controls, the star is the focused pane's.
                if focused {
                    let favorite = store.isFavorite(note.id)
                    Button { store.toggleFavorite(note.id) } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .foregroundStyle(favorite ? Theme.cursor : Theme.fgDim)
                    }
                    .buttonStyle(PressStyle())
                    .help(favorite ? "Remove from Favorites" : "Add to Favorites")
                }
            }
            Spacer(minLength: 0)
            if focused {
                // In a pane too narrow for the row, the controls fold into
                // a menu.
                ViewThatFits(in: .horizontal) {
                    PaneControls(pane: pane, note: note, floating: floating, compact: false, openSettings: openSettings)
                    PaneControls(pane: pane, note: note, floating: floating, compact: true, openSettings: openSettings)
                }
                // The title is cut short before the controls are.
                .layoutPriority(1)
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 18)
        .padding(.trailing, 10)
        // The header takes the pane's width, however narrow: what doesn't
        // fit is cut, not left to push the pane wider than its frame.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.panelHeaderHeight)
        .clipped()
        .contentShape(Rectangle())
        .gesture(floating ? drag : nil)
    }

    /// In the window's space: the header moves as it is dragged.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard let rect = store.floating[pane.id], area.width > 0, area.height > 0 else { return }
                let from = dragStart ?? rect.origin
                dragStart = from
                store.focus(pane.id)
                store.moveFloat(pane.id, to: CGPoint(
                    x: from.x + value.translation.width / area.width,
                    y: from.y + value.translation.height / area.height
                ))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func editor(_ note: Note, focused: Bool) -> some View {
        LiveEditor(
            // Through the store by pane, not a binding to its text: the
            // editor keeps the binding it was made with, and which note is
            // the selected one changes under it.
            text: Binding(get: { store.text(in: pane) }, set: { store.setText($0, in: pane) }),
            font: store.textNSFont,
            mono: store.sourceNSFont,
            lineHeight: store.density.lineHeight,
            outline: store.outline(in: pane),
            baseURL: store.folder,
            title: note.title,
            themeRevision: store.themeRevision,
            keymap: store.keymap,
            displayLineMotion: store.displayLineMotion,
            cursorShape: store.cursorShape,
            cursorBlink: store.cursorBlink,
            mode: $modalMode,
            note: note.id,
            rename: { store.rename(note, to: $0) },
            focusRequest: focused ? store.focusRequest : nil,
            focus: { store.focus(pane.id) },
            scrollTarget: focused ? $scrollTarget : .constant(nil),
            saveImage: { try await store.saveImage($0, ext: $1) }
        )
        // Text scrolling up fades into the header instead of being cut by
        // an edge that isn't drawn. Not in Glass: the panel is translucent
        // there, and a band of solid background would show as a stripe.
        .overlay(alignment: .top) {
            if store.windowBackground == .solid {
                LinearGradient(colors: [Theme.bg, Theme.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Metrics.scrollFade)
                    .allowsHitTesting(false)
            }
        }
        // A new note's page rises into place on the same spring as its row
        // in the sidebar, fading in faster than it settles.
        .keyframeAnimator(
            initialValue: PageArrival(),
            trigger: reduceMotion || !focused ? 0 : store.created
        ) { page, value in
            page.opacity(value.opacity).offset(y: value.rise)
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.2)
            }
            KeyframeTrack(\.rise) {
                MoveKeyframe(Metrics.arriveRise)
                SpringKeyframe(0, duration: 0.6, spring: Metrics.arriveSpring)
            }
        }
    }
}

/// What can be done with the focused pane, in its header: publish its
/// note, split it, float it, maximize it, close it.
private struct PaneControls: View {
    @Environment(Store.self) private var store
    let pane: Pane
    let note: Note?
    let floating: Bool
    /// One menu instead of the row, for a narrow pane.
    let compact: Bool
    let openSettings: () -> Void

    var body: some View {
        let maximized = store.maximized == pane.id
        if compact {
            Menu {
                Button("Split Right") { store.splitAnimated(.right) }.disabled(!store.canSplit(.right))
                Button("Split Down") { store.splitAnimated(.down) }.disabled(!store.canSplit(.down))
                Button(floating ? "Back to the Layout" : "Float") { store.toggleFloat(pane.id) }
                Button(maximized ? "Back to the Layout" : "Maximize") { store.toggleMaximize(pane.id) }
                Button("Close Pane") { store.closePaneAnimated() }.disabled(store.paneCount < 2)
            } label: {
                PaneIcon(symbol: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pane")
        } else {
            row(maximized: maximized)
        }
    }

    private func row(maximized: Bool) -> some View {
        HStack(spacing: 2) {
            if let note { PublishButton(note: note, openSettings: openSettings) }
            split(.right, "rectangle.split.2x1", "Split Right (⌘D)")
            split(.down, "rectangle.split.1x2", "Split Down (⇧⌘D)")
            button("rectangle.on.rectangle", floating ? "Back to the Layout" : "Float", on: floating) {
                store.toggleFloat(pane.id)
            }
            button(
                maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                maximized ? "Back to the Layout (⇧⌘↩)" : "Maximize (⇧⌘↩)", on: maximized
            ) { store.toggleMaximize(pane.id) }
            button("xmark", "Close Pane (⌘W)") { store.closePaneAnimated() }
                .disabled(store.paneCount < 2)
                .opacity(store.paneCount < 2 ? 0.4 : 1)
        }
    }

    /// Dim and dead where a half would be smaller than a pane can be.
    private func split(_ direction: Store.SplitDirection, _ symbol: String, _ help: String) -> some View {
        let room = store.canSplit(direction)
        return button(symbol, room ? help : "No room to split") { store.splitAnimated(direction) }
            .disabled(!room)
            .opacity(room ? 1 : 0.4)
    }

    private func button(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { PaneIcon(symbol: symbol, tint: on ? Theme.fg : Theme.fgDim) }
            .buttonStyle(PressStyle())
            .help(help)
    }
}

/// One of the pane controls' faces.
struct PaneIcon: View {
    let symbol: String
    var tint = Theme.fgDim

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .frame(width: Metrics.paneControl, height: Metrics.paneControl)
            .contentShape(Rectangle())
            .hoverFill(Theme.surface, radius: 6)
    }
}

/// Where a new note's page is on its way in.
private struct PageArrival {
    var opacity = 1.0
    var rise: CGFloat = 0
}

/// An empty pane's way to a note: a search field that is a button until
/// pressed, over the notes opened last, or once searching the notes that
/// match by title or text.
private struct NotePicker: View {
    @Environment(Store.self) private var store
    let open: (Note.ID) -> Void
    @State private var searching = false
    @State private var query = ""
    @State private var index = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let notes = notes()
        VStack(alignment: .leading, spacing: 6) {
            field
            ForEach(Array(notes.enumerated()), id: \.element.id) { offset, note in
                Button { open(note.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundStyle(Theme.fgDim).frame(width: 16)
                        Text(note.displayName).foregroundStyle(Theme.fgBody).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background {
                        if searching, offset == index {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface)
                        }
                    }
                    .contentShape(Rectangle())
                    .hoverFill(Theme.surface, radius: 6)
                }
                .buttonStyle(PressStyle())
            }
            if searching, notes.isEmpty, !query.isEmpty {
                Text("No matching notes").foregroundStyle(Theme.fgDim).padding(.horizontal, 10).frame(height: 30)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: query) { _, _ in index = 0 }
    }

    @ViewBuilder private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.fgDim)
            if searching {
                TextField("Search notes", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.fg)
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.escape) {
                        searching = false
                        query = ""
                        return .handled
                    }
                    .onSubmit {
                        let notes = notes()
                        if notes.indices.contains(index) { open(notes[index].id) }
                    }
            } else {
                Text("Search notes").foregroundStyle(Theme.fgDim)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.guide, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            searching = true
            fieldFocused = true
        }
        .padding(.bottom, 6)
    }

    /// Recent notes until something is typed, then what matches it.
    private func notes() -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if searching, !q.isEmpty { return store.search(q).prefix(8).map(\.note) }
        let recent = store.recent.compactMap { id in store.notes.first { $0.id == id } }
        return Array((recent.isEmpty ? store.notes : recent).prefix(5))
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let count = notes().count
        guard count > 0 else { return .ignored }
        index = (index + delta + count) % count
        return .handled
    }
}

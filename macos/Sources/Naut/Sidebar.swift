import NautKit
import SwiftUI

/// Notes, with the selected note's sections nested under it as a tree,
/// like a docs site navigation.
struct Sidebar: View {
    @Environment(Store.self) private var store
    @Binding var scrollTarget: String?
    /// Changes with the theme, so the body repaints the chrome.
    let themeRevision: Int
    /// Opens the command palette; the search pill opens it on search.
    let openPalette: (CommandPalette.Scope) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchPill { openPalette(.search) }

            ScrollView {
                // Not lazy: the outline unfolding pushes every row below it,
                // and a lazy stack doesn't animate rows it hasn't laid out.
                // ponytail: builds every row each update. Fine for hundreds
                // of notes; go back to LazyVStack and animate only the
                // visible range if thousands ever feel slow.
                VStack(alignment: .leading, spacing: 18) {
                    section("Favorites", notes(store.favorites), outline: false)
                    section("Recent", Array(notes(store.recent).prefix(Metrics.recentShown)), outline: false)
                    section("Library", store.notes, outline: true)
                }
                .padding(.bottom, Metrics.sidebarPadding)
            }
            .scrollIndicators(.never)

            Button { store.newNote() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New note")
                    Spacer()
                    Text("⌘N").foregroundStyle(Theme.fgDim)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.fgDim)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Note (⌘N)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
    }

    /// Notes for ids, skipping any that are gone.
    private func notes(_ ids: [Note.ID]) -> [Note] {
        ids.compactMap { id in store.notes.first { $0.id == id } }
    }

    /// A titled group of rows, as in Rex's docs navigation. Empty groups
    /// don't show; only the Library unfolds a note's outline, so it
    /// appears once.
    @ViewBuilder private func section(_ title: String, _ notes: [Note], outline: Bool) -> some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                ForEach(notes) { note in
                    row(note, outline: outline)
                }
            }
        }
    }

    @ViewBuilder private func row(_ note: Note, outline: Bool) -> some View {
        let selected = note.id == store.selection
        Button {
            select(note)
        } label: {
            HStack(spacing: 8) {
                Text(note.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if store.published.contains(note.name) {
                    Circle()
                        .fill(Theme.cursor)
                        .frame(width: 6, height: 6)
                        .help("Published")
                }
            }
            .font(.system(size: 14, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Theme.fg : Theme.fgBody)
            .padding(.horizontal, 10)
            .frame(height: Metrics.rowHeight)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Theme.surfaceRaised)
                        .strokeBorder(Theme.line, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(store.isFavorite(note.id) ? "Remove from Favorites" : "Add to Favorites") {
                store.toggleFavorite(note.id)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { store.trash(note) }
        }

        if selected, outline {
            let sections = store.outline.filter { $0.level == 2 }
            // One view per note, so switching notes folds the old tree away
            // and unfolds the new one as two units.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(sections.enumerated()), id: \.element) { index, heading in
                    Button {
                        scrollTarget = heading.id
                    } label: {
                        HStack(spacing: 0) {
                            TreeGuide(isLast: index == sections.count - 1)
                                .stroke(Theme.guide, lineWidth: 1)
                                .frame(width: Metrics.guideWidth)
                            Text(heading.text)
                                .lineLimit(1)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.fgDim)
                        .frame(height: Metrics.outlineRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 14)
                }
            }
            .id(note.id)
            .transition(Unfold())
        }
    }

    /// Select with the unfold animation. Only selection changes animate;
    /// headings appearing while typing should just appear.
    private func select(_ note: Note) {
        guard note.id != store.selection else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: Metrics.unfoldDuration)) {
            store.selection = note.id
        }
    }

    /// ↑↓ walk the Library, where every note is.
    private func move(_ delta: Int) -> KeyPress.Result {
        let notes = store.notes
        guard !notes.isEmpty else { return .ignored }
        let current = notes.firstIndex { $0.id == store.selection } ?? -delta
        select(notes[max(0, min(notes.count - 1, current + delta))])
        return .handled
    }
}

/// The outline arriving under its note: it fades in while settling down a
/// few points, and the rows below slide to make room. Leaving is the
/// reverse. Matches the navigation on Rex's docs site.
struct Unfold: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(y: phase.isIdentity ? 0 : -Metrics.unfoldOffset)
    }
}

/// "├─" or "└─", drawn so stacked rows join into one continuous line.
struct TreeGuide: Shape {
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let x = rect.minX + 0.5
        p.move(to: CGPoint(x: x, y: rect.minY))
        p.addLine(to: CGPoint(x: x, y: isLast ? rect.midY : rect.maxY))
        p.move(to: CGPoint(x: x, y: rect.midY))
        p.addLine(to: CGPoint(x: x + Metrics.guideTick, y: rect.midY))
        return p
    }
}

/// The capsule that opens the command palette on search, with its ⌘K hint.
struct SearchPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Search")
                Spacer()
                Text("⌘K").font(.system(size: 12))
            }
            .font(.system(size: 14))
            .foregroundStyle(Theme.fgDim)
            .padding(.horizontal, 12)
            .frame(height: Metrics.searchHeight)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

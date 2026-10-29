import NautKit
import SwiftUI

/// Notes, with the selected note's sections nested under it as a tree,
/// like a docs site navigation.
struct Sidebar: View {
    @Environment(Store.self) private var store
    @Binding var scrollTarget: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            SearchField(text: $store.query, focused: $searchFocused)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.filteredNotes) { note in
                        row(note)
                    }
                }
                .padding(.bottom, Metrics.sidebarPadding)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, Metrics.sidebarPadding)
        .padding(.top, 4)
        .background(Theme.bg)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .background {
            // ⌘K focuses search, like a docs site.
            Button("") { searchFocused = true }
                .keyboardShortcut("k")
                .hidden()
        }
        .toolbar {
            ToolbarItem {
                Button { store.newNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .help("New Note (⌘N)")
            }
        }
    }

    @ViewBuilder private func row(_ note: Note) -> some View {
        let selected = note.id == store.selection
        Button {
            store.selection = note.id
        } label: {
            HStack(spacing: 6) {
                Text(note.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if store.published.contains(note.name) {
                    Image(systemName: "globe.americas.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.fgDim)
                        .help("Published")
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(selected ? Theme.fg : Theme.fgDim)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { store.trash(note) }
        }

        if selected {
            let sections = store.outline.filter { $0.level == 2 }
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
                .padding(.leading, 6)
            }
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let notes = store.filteredNotes
        guard !notes.isEmpty else { return .ignored }
        let current = notes.firstIndex { $0.id == store.selection } ?? -delta
        store.selection = notes[max(0, min(notes.count - 1, current + delta))].id
        return .handled
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

/// The capsule search field with a ⌘K hint.
struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.fgDim)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onExitCommand { text = ""; focused.wrappedValue = false }
            if text.isEmpty {
                Text("⌘K")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fgDim)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: Metrics.searchHeight)
        .background(Capsule().strokeBorder(Theme.line, lineWidth: 1))
    }
}

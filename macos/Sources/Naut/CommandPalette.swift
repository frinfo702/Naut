import AppKit
import NautKit
import SwiftUI

/// ⌘K. One field that does everything: type to filter commands and notes,
/// or type a scope's word ("theme", "search") and Tab into it. A scope
/// replaces the list: themes preview live as you move through them, and
/// search shows each match in context.
struct CommandPalette: View {
    enum Scope: Equatable {
        case root, theme, search, sound
    }

    @Environment(Store.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    /// nil when closed.
    @Binding var scope: Scope?
    @Binding var scrollTarget: String?
    let openSettings: () -> Void

    @State private var query = ""
    @State private var index = 0
    /// The themes in effect when the theme scope opened, for esc.
    @State private var savedThemes: (light: String, dark: String)?
    /// Which list the theme scope shows.
    @State private var darkList = true

    var body: some View {
        let current = scope ?? .root
        let rows = rows(for: current)
        ZStack(alignment: .top) {
            // Clicking outside closes, like a menu.
            Color.black.opacity(Metrics.scrimOpacity)
                .ignoresSafeArea()
                .onTapGesture { close(revert: true) }

            VStack(spacing: 0) {
                field(current, rows: rows)
                Theme.line.frame(height: 1)
                switch current {
                case .root, .theme, .sound: list(rows, scope: current)
                case .search: searchBody(rows)
                }
                if current == .theme { backgroundRow }
                footer(current)
            }
            .frame(width: current == .search ? 860 : 640)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.guide, lineWidth: 1))
            .compositingGroup()
            .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
            .padding(.top, 96)
        }
        .onAppear {
            enter(current)
            if let q = Snapshot.paletteQuery { query = q }
        }
    }

    // MARK: - Rows

    private struct Row: Identifiable {
        enum Kind {
            case command(Command)
            case note(Note)
            case theme(ThemePalette)
            case sound(KeySound)
            case hit(Note, NoteSearch.Match)
        }

        let id: String
        let section: String
        let kind: Kind
    }

    private struct Command {
        let title: String
        /// What to type to find it.
        let keyword: String
        let symbol: String
        var shortcut: String?
        let action: Action

        enum Action {
            case scope(Scope)
            case run(() -> Void)
        }

        var opensScope: Bool {
            if case .scope = action { true } else { false }
        }
    }

    private var commands: [Command] {
        var list: [Command] = [
            Command(title: "Search notes", keyword: "search", symbol: "magnifyingglass", shortcut: "⇧⌘F", action: .scope(.search)),
            Command(title: "Change theme…", keyword: "theme", symbol: "paintpalette", action: .scope(.theme)),
            Command(
                title: "Window background: \(store.windowBackground == .glass ? "Solid" : "Glass")",
                keyword: "glass", symbol: "macwindow",
                action: .run { store.windowBackground = store.windowBackground == .glass ? .solid : .glass }
            ),
        ]
        for keymap in EditorKeymap.allCases where keymap != store.keymap {
            list.append(Command(
                title: "Keymap: \(keymap == .normal ? "Mac" : keymap.title)",
                keyword: "keymap", symbol: "keyboard",
                action: .run { store.keymap = keymap }
            ))
        }
        let soundOn = store.typingSound != .off
        list.append(Command(
            title: soundOn ? "Turn off typing sound" : "Turn on typing sound",
            keyword: "sound", symbol: soundOn ? "speaker.slash" : "speaker.wave.2",
            action: .run {
                store.toggleTypingSound()
                TypingSound.shared.preview()
            }
        ))
        list.append(Command(title: "Change typing sound…", keyword: "sound", symbol: "keyboard", action: .scope(.sound)))
        if let note = store.selectedNote {
            let favorite = store.isFavorite(note.id)
            list.append(Command(
                title: favorite ? "Remove from favorites" : "Add to favorites",
                keyword: "favorite", symbol: favorite ? "star.slash" : "star",
                action: .run { store.toggleFavorite(note.id) }
            ))
        }
        // Zen has no sidebar to show or hide.
        if !store.zen {
            list.append(Command(
                title: store.showSidebar ? "Hide sidebar" : "Show sidebar",
                keyword: "sidebar", symbol: store.sidebarSide == .left ? "sidebar.left" : "sidebar.right",
                shortcut: "⌃⌘S",
                action: .run { store.toggleSidebar() }
            ))
        }
        list.append(Command(
            title: store.zen ? "Leave zen mode" : "Enter zen mode",
            keyword: "zen focus distraction free", symbol: "leaf",
            shortcut: "⌃⌘Z",
            action: .run { store.toggleZen() }
        ))
        list.append(Command(
            title: "Move sidebar to the \(store.sidebarSide == .left ? "right" : "left")",
            keyword: "sidebar", symbol: store.sidebarSide == .left ? "sidebar.right" : "sidebar.left",
            action: .run { store.sidebarSide = store.sidebarSide == .left ? .right : .left }
        ))
        if let note = store.selectedNote, store.site != nil {
            let published = store.published.contains(note.name)
            list.append(Command(
                title: published ? "Unpublish this note" : "Publish this note",
                keyword: "publish", symbol: "globe",
                action: .run { store.setPublished(note, !published) }
            ))
        }
        list.append(Command(title: "New note", keyword: "new", symbol: "square.and.pencil", shortcut: "⌘N", action: .run { store.newNote() }))
        list.append(Command(title: "Split right", keyword: "split pane", symbol: "rectangle.split.2x1", shortcut: "⌘D", action: .run { store.splitAnimated(.right) }))
        list.append(Command(title: "Split down", keyword: "split pane", symbol: "rectangle.split.1x2", shortcut: "⇧⌘D", action: .run { store.splitAnimated(.down) }))
        list.append(Command(title: "Float pane", keyword: "float window", symbol: "rectangle.on.rectangle", action: .run { store.toggleFloat() }))
        list.append(Command(title: "Maximize pane", keyword: "maximize zoom", symbol: "arrow.up.left.and.arrow.down.right", shortcut: "⇧⌘↩", action: .run { store.toggleMaximize() }))
        list.append(Command(title: "Settings…", keyword: "settings", symbol: "gearshape", shortcut: "⌘,", action: .run { openSettings() }))
        return list
    }

    private func rows(for scope: Scope) -> [Row] {
        switch scope {
        case .root:
            let q = query.trimmingCharacters(in: .whitespaces)
            let matching = commands.filter {
                q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.keyword.hasPrefix(q.lowercased())
            }
            var rows = matching.map { Row(id: "c:\($0.title)", section: "Commands", kind: .command($0)) }
            let notes = q.isEmpty
                ? Array(store.notes.filter { $0.id != store.selection }.prefix(3))
                : store.notes.filter { $0.name.localizedCaseInsensitiveContains(q) }
            rows += notes.map { Row(id: "n:\($0.id)", section: q.isEmpty ? "Recent notes" : "Notes", kind: .note($0)) }
            return rows
        case .theme:
            let themes = darkList ? ThemePalette.darkThemes : ThemePalette.lightThemes
            return themes
                .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                .map { Row(id: "t:\($0.id)", section: "", kind: .theme($0)) }
        case .sound:
            return KeySound.allCases
                .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                .map { Row(id: "k:\($0.rawValue)", section: "", kind: .sound($0)) }
        case .search:
            return store.search(query).map { Row(id: "s:\($0.note.id)", section: "", kind: .hit($0.note, $0.match)) }
        }
    }

    // MARK: - Field

    private func field(_ scope: Scope, rows: [Row]) -> some View {
        HStack(spacing: 10) {
            switch scope {
            case .root:
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.cursor)
                    .frame(width: 16)
            case .theme:
                ScopeChip(title: "Theme", symbol: "paintpalette")
            case .search:
                ScopeChip(title: "Search", symbol: "magnifyingglass")
            case .sound:
                ScopeChip(title: "Typing Sound", symbol: "keyboard")
            }
            PaletteField(
                text: $query,
                placeholder: placeholder(scope),
                onMove: { move($0, count: rows.count) },
                onTab: { tab(rows) },
                onSubmit: { submit(rows) },
                onCancel: { close(revert: true) },
                onDeleteEmpty: { if scope != .root { back() } }
            )
            .onChange(of: query) { index = 0; autoEnter() }
            if scope == .theme {
                LightDarkSwitch(dark: $darkList)
                    .onChange(of: darkList) { index = 0; preview(rows: self.rows(for: .theme)) }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private func placeholder(_ scope: Scope) -> String {
        switch scope {
        case .root: "Type a command, a note, or a theme…"
        case .theme: "Filter themes"
        case .search: "Search every note"
        case .sound: "Filter switches"
        }
    }

    // MARK: - Lists

    private func list(_ rows: [Row], scope: Scope) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        if scope == .root, offset == 0 || rows[offset - 1].section != row.section {
                            Text(row.section)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.fgDim)
                                .padding(.horizontal, 10)
                                .padding(.top, offset == 0 ? 6 : 14)
                                .padding(.bottom, 6)
                        }
                        rowView(row, selected: offset == index)
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture { index = offset; submit(rows) }
                    }
                    if rows.isEmpty {
                        Text("Nothing matches “\(query)”")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.fgDim)
                            .padding(14)
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: index) { if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) } }
        }
    }

    private func rowView(_ row: Row, selected: Bool) -> some View {
        Group {
            switch row.kind {
            case let .command(command):
                HStack(spacing: 12) {
                    Image(systemName: command.symbol)
                        .foregroundStyle(selected ? Theme.cursor : Theme.fgDim)
                        .frame(width: 18)
                    Text(command.title).foregroundStyle(selected ? Theme.fg : Theme.fgBody)
                    Spacer()
                    // A chevron marks a command that opens a list of its own;
                    // otherwise its shortcut, if it has one.
                    if command.opensScope {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? Theme.fg : Theme.fgDim)
                    } else if let shortcut = command.shortcut {
                        Text(shortcut)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.fgDim)
                    }
                }
                .frame(height: 40)
            case let .note(note):
                HStack(spacing: 12) {
                    Image(systemName: "doc.text").foregroundStyle(Theme.fgDim).frame(width: 18)
                    Text(note.displayName).foregroundStyle(selected ? Theme.fg : Theme.fgBody).lineLimit(1)
                    Spacer()
                }
                .frame(height: 40)
            case let .theme(theme):
                ThemeRow(theme: theme, current: theme.id == currentThemeID, selected: selected)
            case let .sound(sound):
                HStack(spacing: 12) {
                    Image(systemName: sound == .off ? "speaker.slash" : "speaker.wave.2")
                        .foregroundStyle(selected ? Theme.cursor : Theme.fgDim)
                        .frame(width: 18)
                    Text(sound.title).foregroundStyle(selected ? Theme.fg : Theme.fgBody)
                    Spacer()
                    if sound == store.typingSound {
                        Image(systemName: "checkmark").foregroundStyle(Theme.cursor)
                    }
                }
                .frame(height: 40)
            case .hit:
                EmptyView()
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.line)
            }
        }
    }

    private var currentThemeID: String? {
        guard let saved = savedThemes else { return nil }
        return darkList ? saved.dark : saved.light
    }

    /// Glass or Solid, under the theme list: it is part of how a theme
    /// looks, so it is chosen here too.
    private var backgroundRow: some View {
        @Bindable var store = store
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Window background").font(.system(size: 14)).foregroundStyle(Theme.fg)
                Text("Glass lets the desktop show through the theme’s background.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fgDim)
            }
            Spacer()
            Picker("", selection: $store.windowBackground) {
                ForEach(Store.WindowBackground.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button("") { store.windowBackground = store.windowBackground == .glass ? .solid : .glass }
                .keyboardShortcut("g")
                .hidden()
                .frame(width: 0)
            Text("⌘G").font(.system(size: 12)).foregroundStyle(Theme.fgDim)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func searchBody(_ rows: [Row]) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !query.isEmpty {
                        let total = rows.reduce(0) { sum, row in
                            if case let .hit(_, match) = row.kind { sum + match.count } else { sum }
                        }
                        Text("\(rows.count) \(rows.count == 1 ? "note" : "notes") · \(total) matches")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.fgDim)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        if case let .hit(note, match) = row.kind {
                            HitRow(note: note, match: match, query: query, selected: offset == index)
                                .contentShape(Rectangle())
                                .onTapGesture { index = offset; submit(rows) }
                        }
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.never)
            .frame(width: 380)
            Theme.line.frame(width: 1)
            Group {
                if rows.indices.contains(index), case let .hit(note, match) = rows[index].kind {
                    Peek(note: note, match: match, query: query)
                } else {
                    Text(query.isEmpty ? "Type to search every note." : "No notes contain “\(query)”.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.fgDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding([.trailing, .bottom], 12)
        }
        .frame(height: query.isEmpty ? 180 : 400)
    }

    private func footer(_ scope: Scope) -> some View {
        HStack(spacing: 18) {
            hint("↑↓", scope == .theme || scope == .sound ? "preview" : "move")
            hint("↵", scope == .root ? "run" : scope == .search ? "open" : "apply")
            if scope == .root { hint("tab", "enter scope") }
            if scope == .theme { hint("⌘L", "light / dark") }
            Spacer()
            if scope == .root {
                Text(store.palette(for: colorScheme == .dark).name)
            } else {
                hint("⌫", "back to commands")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.fgDim)
        .padding(.horizontal, 20)
        .frame(height: 38)
        .background(Theme.surface)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(Theme.fg)
            Text(label)
        }
    }

    // MARK: - Keys

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        index = (index + delta + count) % count
        if scope == .theme { preview(rows: rows(for: .theme)) }
        if scope == .sound {
            let rows = rows(for: .sound)
            if rows.indices.contains(index), case let .sound(sound) = rows[index].kind {
                TypingSound.shared.preview(sound)
            }
        }
    }

    /// Tab enters the highlighted command's scope.
    private func tab(_ rows: [Row]) {
        guard scope == .root, rows.indices.contains(index),
              case let .command(command) = rows[index].kind,
              case let .scope(target) = command.action else { return }
        enter(target)
    }

    /// Typing a scope's word and a space enters it, as Tab would.
    private func autoEnter() {
        guard scope == .root, query.hasSuffix(" ") else { return }
        let word = query.trimmingCharacters(in: .whitespaces).lowercased()
        for command in commands where command.keyword == word {
            if case let .scope(target) = command.action { enter(target) }
        }
    }

    private func submit(_ rows: [Row]) {
        guard rows.indices.contains(index) else { return }
        switch rows[index].kind {
        case let .command(command):
            switch command.action {
            case let .scope(target): enter(target)
            case let .run(action):
                close(revert: false)
                action()
            }
        case let .note(note):
            store.selection = note.id
            close(revert: false)
        case .theme:
            close(revert: false)
        case let .sound(sound):
            store.typingSound = sound
            close(revert: false)
        case let .hit(note, match):
            store.selection = note.id
            // The note has loaded, so its outline is the one to look in.
            if let section = match.section {
                scrollTarget = store.outline.first { $0.text == section }?.id
            }
            close(revert: false)
        }
    }

    private func enter(_ target: Scope) {
        scope = target
        query = ""
        index = 0
        if target == .theme {
            savedThemes = (store.lightTheme, store.darkTheme)
            darkList = colorScheme == .dark
            let themes = darkList ? ThemePalette.darkThemes : ThemePalette.lightThemes
            index = themes.firstIndex { $0.id == (darkList ? store.darkTheme : store.lightTheme) } ?? 0
        }
        if target == .sound {
            index = KeySound.allCases.firstIndex(of: store.typingSound) ?? 0
        }
    }

    /// The theme scope applies the highlighted theme as you move, so the
    /// whole window, this palette included, shows what you'd get.
    private func preview(rows: [Row]) {
        guard rows.indices.contains(index), case let .theme(theme) = rows[index].kind else { return }
        if theme.dark { store.darkTheme = theme.id } else { store.lightTheme = theme.id }
    }

    private func back() {
        revertThemes()
        enter(.root)
    }

    private func revertThemes() {
        guard let saved = savedThemes else { return }
        store.lightTheme = saved.light
        store.darkTheme = saved.dark
        savedThemes = nil
    }

    private func close(revert: Bool) {
        if revert { revertThemes() }
        savedThemes = nil
        scope = nil
    }
}

// MARK: - Pieces

private struct ScopeChip: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Theme.cursor)
            Text(title).foregroundStyle(Theme.fg)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Theme.line))
        .overlay(Capsule().strokeBorder(Theme.guide, lineWidth: 1))
    }
}

private struct LightDarkSwitch: View {
    @Binding var dark: Bool

    var body: some View {
        HStack(spacing: 2) {
            segment("Light", false)
            segment("Dark", true)
        }
        .padding(2)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .background {
            Button("") { dark.toggle() }.keyboardShortcut("l").hidden()
        }
    }

    private func segment(_ title: String, _ value: Bool) -> some View {
        Button { dark = value } label: {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(dark == value ? Theme.fg : Theme.fgDim)
                .padding(.horizontal, 11)
                .frame(height: 22)
                .background { if dark == value { Capsule().fill(Theme.line) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A theme as the palette lists it: a sample of its page, its name, and
/// its eight swatches.
private struct ThemeRow: View {
    let theme: ThemePalette
    let current: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 1) {
                Text("Aa").foregroundStyle(color(.fg))
                RoundedRectangle(cornerRadius: 1).fill(Color(theme: theme.cursor)).frame(width: 2, height: 11)
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 40, height: 28)
            .background(color(.bg), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.guide, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name).font(.system(size: 14, weight: selected ? .medium : .regular)).foregroundStyle(Theme.fg)
                if selected || current {
                    Text(selected && !current ? "Previewing" : "Current")
                        .font(.system(size: 12))
                        .foregroundStyle(selected && !current ? Theme.cursor : Theme.fgDim)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(Array(theme.swatches.enumerated()), id: \.offset) { _, swatch in
                    Circle().fill(Color(theme: swatch)).frame(width: 10, height: 10)
                }
            }
            Image(systemName: selected ? "return" : "checkmark")
                .font(.system(size: 12))
                .foregroundStyle(Theme.fgDim)
                .opacity(selected || current ? 1 : 0)
                .frame(width: 24, alignment: .trailing)
        }
        .frame(height: 52)
    }

    private func color(_ token: ThemeToken) -> Color {
        theme.color(token).map { Color(theme: $0) } ?? .clear
    }
}

private struct HitRow: View {
    let note: Note
    let match: NoteSearch.Match
    let query: String
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.displayName)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.fg : Theme.fgBody)
                    .lineLimit(1)
                Spacer()
                Text("\(match.count)").font(.system(size: 12)).foregroundStyle(Theme.fgDim)
            }
            if !match.snippet.isEmpty {
                Text(highlighted(match.snippet, query))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Theme.fgBody : Theme.fgDim)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if selected { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.line) }
        }
    }
}

/// The first match in context: where it is, and its line.
private struct Peek: View {
    let note: Note
    let match: NoteSearch.Match
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text([note.displayName, match.section].compactMap(\.self).joined(separator: "  ›  "))
                .font(.system(size: 12))
                .foregroundStyle(Theme.fgDim)
            Text(match.section ?? note.displayName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.fg)
            if !match.snippet.isEmpty {
                Text(highlighted(match.snippet, query))
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.fgBody)
            }
            Spacer()
            HStack(spacing: 16) {
                Text("↵ open at match")
                Text("\(match.count) in this note")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.fgDim)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
    }
}

/// `text` with every occurrence of `query` in the cursor colour.
private func highlighted(_ text: String, _ query: String) -> AttributedString {
    var out = AttributedString(text)
    guard !query.isEmpty else { return out }
    var rest = out.startIndex ..< out.endIndex
    while let found = out[rest].range(of: query, options: [.caseInsensitive, .widthInsensitive]) {
        out[found].foregroundColor = Theme.cursor
        out[found].inlinePresentationIntent = .stronglyEmphasized
        rest = found.upperBound ..< out.endIndex
    }
    return out
}

/// The palette's text field. AppKit's, because the palette has to see
/// the arrow keys, Tab, Return and Escape before the field does.
private struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onTab: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onDeleteEmpty: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor(token: .fgDim), .font: NSFont.systemFont(ofSize: 17)]
        )
        field.textColor = NSColor(token: .fg)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField

        init(parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertTab(_:)): parent.onTab()
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty: parent.onDeleteEmpty()
            default: return false
            }
            return true
        }
    }
}

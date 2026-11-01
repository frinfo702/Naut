import AppKit
import NautKit
import SwiftUI

// The window's frame, after Rex: the theme's background with rounded
// panels floating on it, a gap between them.

/// The theme's background, or in Glass the desktop behind the window
/// seen through it.
struct WindowBackdrop: View {
    let background: Store.WindowBackground
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch background {
        case .solid:
            // The panels hold the theme's background, as the page does; the
            // frame around them sits a step deeper so they read as raised.
            ZStack {
                Theme.bg
                Color.black.opacity(colorScheme == .dark ? 0.3 : 0.05)
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
    func panel(_ background: Store.WindowBackground) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        return self
            .background(Theme.bg.opacity(background == .glass ? 0.8 : 1), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension Store {
    /// Fold the sidebar away or bring it back, sliding from its edge.
    func toggleSidebar() {
        withAnimation(.snappy(duration: Metrics.toggleDuration)) { showSidebar.toggle() }
    }
}

// MARK: - Panel header

/// The publish control's face: a dot and a word, tinted with the cursor
/// colour once the note is on the web.
struct PublishPill: View {
    let published: Bool
    let busy: Bool

    var body: some View {
        HStack(spacing: 7) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(published ? Theme.cursor : Theme.fgDim)
                    .frame(width: 6, height: 6)
            }
            Text(published ? "Published" : "Publish")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(published ? Theme.cursor : Theme.fgBody)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 26)
        .background(Capsule().fill(published ? Theme.cursor.opacity(0.12) : Theme.surface))
        .overlay(Capsule().strokeBorder(published ? Theme.cursor.opacity(0.35) : Theme.line, lineWidth: 1))
        .contentShape(Capsule())
    }
}

// MARK: - Status bar

/// The editor panel's bottom edge: the keymap and its mode while a modal
/// keymap is in use, and the note's length if asked for in Settings.
/// Static: it changes on a key press, and motion on keyboard input is
/// noise, not feedback.
struct StatusBar: View {
    let keymap: EditorKeymap
    let mode: ModalMode
    /// nil hides the count.
    let characters: Int?

    var body: some View {
        HStack(spacing: 10) {
            if keymap.isModal {
                KeymapMark(keymap: keymap)
                ModePill(mode: mode)
            }
            Spacer()
            if let characters {
                Text("\(characters.formatted()) characters").foregroundStyle(Theme.fgDim)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: Metrics.statusBarHeight)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
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
                }
            }
            // The close button covers the end of the name under the pointer,
            // so a tab keeps its width and has no room set aside for it.
            .overlay(alignment: .trailing) {
                if hovering {
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
                Button("Close Other Tabs") { store.closeOtherTabs(than: note.id) }
                    .disabled(store.tabs.count < 2)
            }
    }
}

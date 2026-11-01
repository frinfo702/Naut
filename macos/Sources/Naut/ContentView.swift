import AppKit
import NautKit
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(\.openSettings) private var openSettings
    /// The effective scheme, which decides which of the two themes to
    /// show in the preview when the app follows macOS.
    @Environment(\.colorScheme) private var colorScheme
    /// Set by the sidebar outline; the preview scrolls there and clears it.
    @State private var scrollTarget: String?
    /// The mode the focused Vim or Helix editor is in, shown in its corner.
    @State private var modalMode: ModalMode = .normal

    /// The command palette's scope while it is open.
    @State private var palette: CommandPalette.Scope?

    var body: some View {
        // Reading the theme keeps the window in step with a pick in Settings,
        // including in Live Preview, where no preview style is built.
        let _ = store.palette(for: colorScheme == .dark)

        ZStack {
            HStack(spacing: Metrics.panelGap) {
                if store.showSidebar, store.sidebarSide == .left { sidebar }
                detail
                    .panel(store.windowBackground)
                if store.showSidebar, store.sidebarSide == .right { sidebar }
            }
            .padding([.horizontal, .bottom], Metrics.panelGap)

            if palette != nil {
                CommandPalette(scope: $palette, scrollTarget: $scrollTarget) { openSettings() }
                    .transition(.opacity)
            }
        }
        .background { WindowBackdrop(background: store.windowBackground).ignoresSafeArea() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 16) {
                    Button { store.toggleSidebar() } label: {
                        Image(systemName: store.sidebarSide == .left ? "sidebar.left" : "sidebar.right")
                            .foregroundStyle(store.showSidebar ? Theme.fgBody : Theme.fgDim)
                    }
                    .buttonStyle(.plain)
                    .help(store.showSidebar ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
                    titleBar
                    if !store.tabs.isEmpty { TabStrip() }
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle("")
        .background {
            // ⌘K opens the palette, ⇧⌘F opens it on search.
            Group {
                Button("") { palette = palette == nil ? .root : nil }.keyboardShortcut("k")
                Button("") { palette = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
                // ⌘W closes the tab; with one left it closes the window, as
                // the menu's Close does when this button isn't here.
                if store.tabs.count > 1, let selection = store.selection {
                    Button("") { store.closeTab(selection) }.keyboardShortcut("w")
                }
                Button("") { store.selectTab(offset: 1) }.keyboardShortcut(.tab, modifiers: .control)
                Button("") { store.selectTab(offset: -1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("") { store.selectTab(offset: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("") { store.selectTab(offset: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                ForEach(Array(store.tabs.prefix(9).enumerated()), id: \.offset) { index, id in
                    Button("") { store.selection = id }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .hidden()
        }
        .task {
            if let name = Snapshot.note { store.selection = store.notes.first { $0.name == name }?.id }
            if let scope = Snapshot.palette { palette = scope }
            #if DEBUG
            if Snapshot.isCaretTest { await Snapshot.runCaretTest() }
            if Snapshot.isModalTest { await Snapshot.runModalTest() }
            if Snapshot.isTitleSwitchTest { await Snapshot.runTitleSwitchTest(store: store) }
            if Snapshot.isMathEditTest { await Snapshot.runMathEditTest(store: store) }
            if Snapshot.isMathScrollTest { await Snapshot.runMathScrollTest(store: store) }
            if Snapshot.isDollarTest { await Snapshot.runDollarTest(store: store) }
            #endif
            if let path = Snapshot.path {
                if Snapshot.settingsPane != nil { openSettings() }
                await Snapshot.capture(to: path)
            }
        }
        .alert("Publishing failed", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(store.error ?? "")
        }
    }

    private var sidebar: some View {
        Sidebar(scrollTarget: $scrollTarget, themeRevision: store.themeRevision) { palette = $0 }
            .frame(width: Metrics.sidebarWidth)
            .panel(store.windowBackground)
            .transition(.move(edge: store.sidebarSide == .left ? .leading : .trailing).combined(with: .opacity))
    }

    /// The folder and its size, beside the traffic lights.
    private var titleBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.folder.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.fg)
            Text("\(store.notes.count) notes")
                .font(.system(size: 11))
                .foregroundStyle(Theme.fgDim)
        }
        .padding(.leading, 4)
    }

    @ViewBuilder private var detail: some View {
        @Bindable var store = store
        if let note = store.selectedNote {
            VStack(spacing: 0) {
                header(note)
                editor(note)
                if store.keymap.isModal || store.showCharacterCount {
                    StatusBar(
                        keymap: store.keymap,
                        mode: modalMode,
                        characters: store.showCharacterCount ? store.text.count : nil
                    )
                }
            }
            .onChange(of: note.id) { _, _ in modalMode = .normal }
            .onChange(of: store.keymap) { _, _ in modalMode = .normal }
        } else {
            Text("No note selected")
                .foregroundStyle(Theme.fgDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The note's name, its star, and the publish control.
    private func header(_ note: Note) -> some View {
        @Bindable var store = store
        return HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(Theme.fgBody)
            Text(note.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(note.isUntitled ? Theme.fgDim : Theme.fg)
                .lineLimit(1)
            let favorite = store.isFavorite(note.id)
            Button { store.toggleFavorite(note.id) } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? Theme.cursor : Theme.fgDim)
            }
            .buttonStyle(.plain)
            .help(favorite ? "Remove from Favorites" : "Add to Favorites")
            Spacer()
            PublishButton(note: note, openSettings: { openSettings() })
        }
        .font(.system(size: 13))
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: Metrics.panelHeaderHeight)
    }

    private func editor(_ note: Note) -> some View {
        @Bindable var store = store
        return LiveEditor(
            text: $store.text,
            font: store.textNSFont,
            mono: store.sourceNSFont,
            lineHeight: store.density.lineHeight,
            outline: store.outline,
            baseURL: store.folder,
            title: note.title,
            themeRevision: store.themeRevision,
            keymap: store.keymap,
            cursorShape: store.cursorShape,
            cursorBlink: store.cursorBlink,
            mode: $modalMode,
            note: note.id,
            rename: { store.rename(note, to: $0) },
            scrollTarget: $scrollTarget
        )
    }
}

/// The one control for the web: a pill that takes the cursor colour when
/// the note is public. Clicking it when publishing isn't set up opens Settings instead
/// of showing a disabled button with no explanation.
struct PublishButton: View {
    @Environment(Store.self) private var store
    let note: Note
    let openSettings: () -> Void
    @State private var showPopover = false

    var body: some View {
        let isPublished = store.published.contains(note.name)
        Button {
            if store.site == nil { openSettings() } else { showPopover.toggle() }
        } label: {
            PublishPill(published: isPublished, busy: store.isBusy(note))
        }
        .buttonStyle(.plain)
        .help(store.site == nil ? "Set up publishing in Settings" : "Publish to the web")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            PublishPopover(note: note)
                .modifier(FittedPopover())
        }
        .task {
            // Snapshot harness: open the popover so its layout can be
            // measured without a person clicking the toolbar.
            if Snapshot.publishPopover {
                try? await Task.sleep(for: .milliseconds(300))
                showPopover = true
            }
        }
    }
}

struct PublishPopover: View {
    @Environment(Store.self) private var store
    let note: Note
    @State private var copied = false

    var body: some View {
        let isPublished = store.published.contains(note.name)
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { isPublished },
                set: { store.setPublished(note, $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Publish to web").font(.headline)
                    Text(isPublished ? "Anyone with the link can read this note." : "Only you can see this note.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(store.isBusy(note))

            if isPublished, let url = store.url(for: note) {
                HStack {
                    Text(url.absoluteString)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied link" : "Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copied = true
                    }
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        // Fit the popover to its content: a narrow row when the note is
        // private, wider once the address and its buttons are there.
        .frame(minWidth: 280, maxWidth: 360, alignment: .leading)
    }
}

/// SwiftUI 6 can size a presentation to its content; on macOS 14 the
/// popover uses the content's ideal size, which the frame above bounds.
private struct FittedPopover: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.presentationSizing(.fitted)
        } else {
            content
        }
    }
}

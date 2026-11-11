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
    /// Each pane's Vim or Helix mode. The focused one's shows in the title bar.
    @State private var modes: [Pane.ID: ModalMode] = [:]

    /// The command palette's scope while it is open.
    @State private var palette: CommandPalette.Scope?

    var body: some View {
        // Reading the theme keeps the window in step with a pick in Settings,
        // including in Live Preview, where no preview style is built.
        let _ = store.palette(for: colorScheme == .dark)

        ZStack {
            HStack(spacing: Metrics.panelGap) {
                if store.showSidebar, store.sidebarSide == .left { sidebar }
                Panes(scrollTarget: $scrollTarget, modes: $modes) { openSettings() }
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
                    .buttonStyle(PressStyle())
                    .help(store.showSidebar ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
                    titleBar
                    if !store.tabs.isEmpty {
                        // The toolbar draws above the palette's scrim, so
                        // the strip takes the same dimming itself.
                        TabStrip().overlay {
                            if palette != nil {
                                Capsule().fill(.black.opacity(Metrics.scrimOpacity)).allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            if store.keymap.isModal || store.showCharacterCount {
                // Pushes the status to the window's far edge.
                ToolbarItem { Spacer() }
                ToolbarItem(placement: .primaryAction) {
                    StatusBar(
                        keymap: store.keymap,
                        mode: modes[store.focus] ?? .normal,
                        characters: store.showCharacterCount ? store.text.count : nil
                    )
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
                // ⌘W closes the pane, or with one pane the tab; with one tab
                // left it closes the window, as the menu's Close does when
                // this button isn't here.
                if store.paneCount > 1 {
                    Button("") { store.closePaneAnimated() }.keyboardShortcut("w")
                } else if store.tabs.count > 1, let selection = store.selection {
                    Button("") { store.closeTab(selection) }.keyboardShortcut("w")
                }
            }
            .hidden()
        }
        .background {
            // ⌘] and ⌘[ walk the panes.
            Group {
                Button("") { store.focusPane(offset: 1) }.keyboardShortcut("]")
                Button("") { store.focusPane(offset: -1) }.keyboardShortcut("[")
                Button("") { store.toggleMaximize() }.keyboardShortcut(.return, modifiers: [.command, .shift])
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
            if let content = Snapshot.split {
                store.splitContent = content
                store.split(.right)
            }
            #if DEBUG
            if EditorTest.isEnabled { await EditorTest.run() }
            if Snapshot.isCaretTest { await Snapshot.runCaretTest() }
            if Snapshot.isModalTest { await Snapshot.runModalTest() }
            if Snapshot.isTitleSwitchTest { await Snapshot.runTitleSwitchTest(store: store) }
            if Snapshot.isTabEditTest { await Snapshot.runTabEditTest(store: store) }
            if Snapshot.isMathEditTest { await Snapshot.runMathEditTest(store: store) }
            if Snapshot.isMathScrollTest { await Snapshot.runMathScrollTest(store: store) }
            if Snapshot.isDollarTest { await Snapshot.runDollarTest(store: store) }
            if Snapshot.isSplitTest { await Snapshot.runSplitTest(store: store) }
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
            PublishIcon(published: isPublished, busy: store.isBusy(note))
        }
        .buttonStyle(PressStyle())
        .help(store.site == nil ? "Set up publishing in Settings" : isPublished ? "Published to the web" : "Publish to the web")
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

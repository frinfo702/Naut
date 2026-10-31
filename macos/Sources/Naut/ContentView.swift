import AppKit
import NautKit
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(\.openSettings) private var openSettings
    /// Set by the sidebar outline; the preview scrolls there and clears it.
    @State private var scrollTarget: String?

    var body: some View {
        NavigationSplitView {
            Sidebar(scrollTarget: $scrollTarget)
                .navigationSplitViewColumnWidth(Metrics.sidebarWidth)
        } detail: {
            detail
                // The title bar takes the note's background, so the window
                // reads as one surface instead of a grey band on top.
                .toolbarBackground(Theme.bg, for: .windowToolbar)
        }
        .background(Theme.bg)
        .task {
            if let path = Snapshot.path {
                if let name = Snapshot.note { store.selection = store.notes.first { $0.name == name }?.id }
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

    @ViewBuilder private var detail: some View {
        @Bindable var store = store
        if let note = store.selectedNote {
            Group {
                switch store.editorMode {
                case .split:
                    HSplitView {
                        if store.showEditor {
                            Editor(text: $store.text, font: store.sourceNSFont, title: note.name) { store.rename(note, to: $0) }
                                // A new note starts without the old note's undo history.
                                .id(note.id)
                                .frame(minWidth: 280)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                                // The identity change is a fresh editor for the same
                                // pane, not the pane itself arriving.
                                .animation(nil, value: note.id)
                        }
                        Preview(html: store.html, title: note.name, baseURL: store.folder, style: previewStyle, scrollTarget: $scrollTarget)
                            .frame(minWidth: 320)
                    }
                case .live:
                    LiveEditor(
                        text: $store.text,
                        font: store.textNSFont,
                        mono: store.sourceNSFont,
                        lineHeight: store.density.lineHeight,
                        outline: store.outline,
                        baseURL: store.folder,
                        title: note.name,
                        rename: { store.rename(note, to: $0) },
                        scrollTarget: $scrollTarget
                    )
                }
            }
            .background(Theme.bg)
            .navigationTitle(note.name)
            .toolbar { toolbar(note) }
        } else {
            Text("No note selected")
                .foregroundStyle(Theme.fgDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
        }
    }

    private var previewStyle: Preview.Style {
        Preview.Style(textFont: store.textFont, textSize: store.textSize, sourceFont: store.sourceFont, lineHeight: store.density.lineHeight)
    }

    @ToolbarContentBuilder
    private func toolbar(_ note: Note) -> some ToolbarContent {
        ToolbarItemGroup {
            PublishButton(note: note, openSettings: { openSettings() })

            // Last, so it sits at the trailing edge like other panel toggles.
            if store.editorMode == .split {
                Button {
                    withAnimation(.snappy(duration: Metrics.toggleDuration)) { store.showEditor.toggle() }
                } label: {
                    Label("Editor", systemImage: "sidebar.squares.left")
                }
                .help(store.showEditor ? "Hide Editor (⌘E)" : "Show Editor (⌘E)")
            }
        }
    }
}

/// The one control for the web: a globe that is filled when the note is
/// public. Clicking it when publishing isn't set up opens Settings instead
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
            if store.isBusy(note) {
                ProgressView().controlSize(.small)
            } else {
                Label(isPublished ? "Published" : "Publish", systemImage: isPublished ? "globe.americas.fill" : "globe.americas")
                    .labelStyle(.titleAndIcon)
            }
        }
        .help(store.site == nil ? "Set up publishing in Settings" : "Publish to the web")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            PublishPopover(note: note)
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
        .frame(width: 380)
    }
}

struct Editor: View {
    @Binding var text: String
    let font: NSFont
    /// The note's name; editing it renames the note.
    let title: String
    let rename: (String) -> Void
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Untitled", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: Metrics.editorTitleSize, weight: .semibold))
                .foregroundStyle(Theme.fg)
                .focused($titleFocused)
                .onSubmit { rename(draft) }
                // Leaving the field renames too; a note switch resets it.
                .onChange(of: titleFocused) { if !titleFocused, draft != title { rename(draft) } }
                .onChange(of: title, initial: true) { draft = title }
                .padding(.horizontal, Metrics.editorInset)
                .padding(.top, Metrics.editorInset)
            source
        }
        .background(Theme.surface)
    }

    private var source: some View {
        TextEditor(text: $text)
            .font(Font(font as CTFont))
            .foregroundStyle(Theme.fg)
            .scrollContentBackground(.hidden)
            // contentMargins has no effect on TextEditor (it was set here
            // and the text sat on the edge), so inset the whole view.
            .padding(.horizontal, Metrics.editorInset - 5) // NSTextView adds 5pt line padding
            .padding(.vertical, Metrics.editorInset)
            .background(Theme.surface)
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in sync() }
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in sync() }
    }

    /// Undo and redo change the text view behind SwiftUI's back; write the
    /// result back through the binding, or the preview and the file keep
    /// the text that was undone. Field editors (title, search, settings)
    /// are not this editor, and Live Preview keeps its own source history.
    private func sync() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        guard let view = window?.firstResponder as? NSTextView, !view.isFieldEditor else { return }
        text = view.string
    }
}

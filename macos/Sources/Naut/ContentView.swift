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
        }
        .background(Theme.bg)
        .task {
            if let path = Snapshot.path {
                if let name = Snapshot.note { store.selection = store.notes.first { $0.name == name }?.id }
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
            HSplitView {
                if store.showEditor {
                    Editor(text: $store.text)
                        .frame(minWidth: 280)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Preview(html: store.html, baseURL: store.folder, scrollTarget: $scrollTarget)
                    .frame(minWidth: 320)
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

    @ToolbarContentBuilder
    private func toolbar(_ note: Note) -> some ToolbarContent {
        ToolbarItemGroup {
            PublishButton(note: note, openSettings: { openSettings() })

            // Last, so it sits at the trailing edge like other panel toggles.
            Button {
                withAnimation(.snappy(duration: Metrics.toggleDuration)) { store.showEditor.toggle() }
            } label: {
                Label("Editor", systemImage: "sidebar.squares.left")
            }
            .help(store.showEditor ? "Hide Editor (⌘E)" : "Show Editor (⌘E)")
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

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: Metrics.editorFontSize, design: .monospaced))
            .foregroundStyle(Theme.fg)
            .scrollContentBackground(.hidden)
            // contentMargins has no effect on TextEditor (it was set here
            // and the text sat on the edge), so inset the whole view.
            .padding(.horizontal, Metrics.editorInset - 5) // NSTextView adds 5pt line padding
            .padding(.vertical, Metrics.editorInset)
            .background(Theme.surface)
    }
}

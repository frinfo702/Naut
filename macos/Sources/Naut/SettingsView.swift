import AppKit
import NautKit
import SwiftUI

/// Settings, laid out like Rex's: a sidebar of panes with coloured icon
/// tiles under a status card, and grouped rows on the right. Only panes
/// with something real in them exist.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var pane: SettingsPane = Snapshot.settingsPane ?? .appearance
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(SettingsMetrics.sidebarWidth)
                // A fixed list of four panes never needs hiding.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                    switch pane {
                    case .appearance: AppearancePane()
                    case .editor: EditorPane()
                    case .trackpad: TrackpadPane()
                    case .notes: NotesPane()
                    case .publishing: PublishingPane()
                    case .shortcuts: ShortcutsPane()
                    }
                }
                .padding(SettingsMetrics.detailPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.bg)
            .navigationTitle(pane.title)
            .toolbarBackground(Theme.bg, for: .windowToolbar)
        }
        .environment(\.themeRevision, store.themeRevision)
        .frame(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSearchField(text: $query)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.allCases.filter { $0.matches(query) }) { p in
                    SidebarItem(pane: p, selected: p == pane) { pane = p }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .background(Theme.bg)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, editor, trackpad, notes, publishing, shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .editor: "Editor"
        case .trackpad: "Trackpad"
        case .notes: "Notes"
        case .publishing: "Publishing"
        case .shortcuts: "Shortcuts"
        }
    }

    var icon: SettingsIcon.Kind {
        switch self {
        case .appearance: .palette
        case .editor: .symbol("textformat", top: 0x64D2FF, bottom: 0x0A84FF)
        case .trackpad: .symbol("hand.draw.fill", top: 0x30D158, bottom: 0x248A3D)
        case .notes: .symbol("folder.fill", top: 0xFFD60A, bottom: 0xFF9F0A)
        // Purple globe, like Rex's Remote Hosts. The Cloudflare mark stays
        // on the status card so the two don't repeat each other.
        case .publishing: .symbol("globe", top: 0xC86BFA, bottom: 0x7B3FE4)
        case .shortcuts: .symbol("command", top: 0x9A9AA0, bottom: 0x5E5E64)
        }
    }

    /// Extra words that find this pane from the search field.
    private var keywords: [String] {
        switch self {
        case .appearance: ["theme", "dark", "light", "color", "colour", "scheme", "sidebar", "left", "right", "glass", "solid", "pane", "split", "resize", "adaptive", "even"]
        case .editor: ["font", "size", "typography", "character", "count", "status", "live", "preview", "markdown", "source", "line", "spacing", "density", "compact", "comfortable", "keymap", "vim", "helix", "modal", "wrap", "display", "gj", "gk", "normal", "cursor", "caret", "block", "bar", "blink", "sound", "typing", "click", "volume", "mechanical", "switch", "cherry", "topre"]
        case .trackpad: ["gesture", "gestures", "swipe", "two-finger", "sidebar"]
        case .notes: ["folder", "files", "markdown", "finder", "location"]
        case .publishing: ["cloudflare", "web", "publish", "token", "account", "workers", "terraform"]
        case .shortcuts: ["keyboard", "keys", "bindings", "hotkeys"]
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return ([title] + keywords).contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

enum SettingsMetrics {
    // MARK: - Window

    static let windowWidth: CGFloat = 760
    static let windowHeight: CGFloat = 620
    static let sidebarWidth: CGFloat = 220
    static let detailPadding: CGFloat = 24

    // MARK: - Sidebar

    static let iconSize: CGFloat = 24
    static let statusIconSize: CGFloat = 32
    static let itemHeight: CGFloat = 32
    static let itemRadius: CGFloat = 8

    // MARK: - Groups

    static let groupSpacing: CGFloat = 28
    static let groupRadius: CGFloat = 12
    static let rowHeight: CGFloat = 44
    static let rowPadding: CGFloat = 14
}

// MARK: - Sidebar pieces

private struct SettingsSearchField: View {
    @Binding var text: String
    @Environment(\.themeRevision) private var themeRevision

    var body: some View {
        let _ = themeRevision
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.fgDim)
            TextField("Search Settings", text: $text)
                .textFieldStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.edge, lineWidth: 1))
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @Environment(\.themeRevision) private var themeRevision

    var body: some View {
        let _ = themeRevision
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIcon(kind: pane.icon)
                Text(pane.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.fg)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: SettingsMetrics.itemHeight)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.itemRadius, style: .continuous)
                    .fill(selected ? Theme.fg.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Icons

/// A rounded tile with a white glyph, lit from above like the rest of the
/// app. Drawn rather than shipped as images so they stay sharp and can't
/// drift from the palette.
struct SettingsIcon: View {
    enum Kind {
        case symbol(String, top: UInt32, bottom: UInt32)
        case palette
        case cloudflare
    }

    let kind: Kind
    var size: CGFloat = SettingsMetrics.iconSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            switch kind {
            case let .symbol(name, top, bottom):
                shape.fill(LinearGradient(colors: [Color(hex: top), Color(hex: bottom)], startPoint: .top, endPoint: .bottom))
                Image(systemName: name)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            case .palette:
                // Rex's Themes tile: a full hue wheel, softened with white
                // toward the centre.
                shape.fill(AngularGradient(
                    colors: [0xFF453A, 0xFF9F0A, 0xFFD60A, 0x30D158, 0x64D2FF, 0x5E5CE6, 0xBF5AF2, 0xFF453A].map(Color.init(hex:)),
                    center: .center
                ))
                shape.fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: size * 0.5))
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
            case .cloudflare:
                // The logo on a dark tile, like Rex's Terminal icon: the
                // brand colour carries it, the tile stays quiet.
                shape.fill(LinearGradient(colors: [Color(hex: 0x2E2F2D), Color(hex: 0x161715)], startPoint: .top, endPoint: .bottom))
                Image(nsImage: Logos.cloudflare)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.14)
            }
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75
            )
        }
        .frame(width: size, height: size)
    }
}

enum Logos {
    /// Cloudflare's cloud mark, from the official brand assets via Simple
    /// Icons. NSImage renders SVG natively, so it ships as source. NSImage
    /// is main-actor state, even when it is never mutated.
    @MainActor
    static let cloudflare: NSImage = .init(data: Data("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#F38020" d="M16.5088 16.8447c.1475-.5068.0908-.9707-.1553-1.3154-.2246-.3164-.6045-.5-1.0615-.5205l-8.6592-.1123a.1559.1559 0 0 1-.1333-.0713c-.0283-.042-.0351-.0986-.021-.1553.0278-.084.1123-.1484.2036-.1562l8.7359-.1123c1.0351-.0489 2.1601-.8868 2.5537-1.9136l.499-1.3013c.0215-.0561.0293-.1128.0147-.168-.5625-2.5463-2.835-4.4453-5.5499-4.4453-2.5039 0-4.6284 1.6177-5.3876 3.8614-.4927-.3658-1.1187-.5625-1.794-.499-1.2026.119-2.1665 1.083-2.2861 2.2856-.0283.31-.0069.6128.0635.894C1.5683 13.171 0 14.7754 0 16.752c0 .1748.0142.3515.0352.5273.0141.083.0844.1475.1689.1475h15.9814c.0909 0 .1758-.0645.2032-.1553l.12-.4268zm2.7568-5.5634c-.0771 0-.1611 0-.2383.0112-.0566 0-.1054.0415-.127.0976l-.3378 1.1744c-.1475.5068-.0918.9707.1543 1.3164.2256.3164.6055.498 1.0625.5195l1.8437.1133c.0557 0 .1055.0263.1329.0703.0283.043.0351.1074.0214.1562-.0283.084-.1132.1485-.204.1553l-1.921.1123c-1.041.0488-2.1582.8867-2.5527 1.914l-.1406.3585c-.0283.0713.0215.1416.0986.1416h6.5977c.0771 0 .1474-.0489.169-.126.1122-.4082.1757-.837.1757-1.2803 0-2.6025-2.125-4.727-4.7344-4.727"/></svg>
    """.utf8))!

    /// The Helix and Vim marks, monochrome, from Simple Icons. Template
    /// images, so they take the theme's ink.
    @MainActor static let helix = template("M12.968 4.97 4.364 0v3.55c0 .449.239.863.627 1.087l4.276 2.47zm5.339 3.083-3.7 2.138 4.86 2.807c.11-.19.17-.407.17-.633V9.552c0-.452-.241-.87-.633-1.096zm1.33 12.397c0-.449-.24-.863-.627-1.087l-4.253-2.456-3.7 2.137L19.637 24zm-13.92-4.49 3.7-2.137c-2.703-1.562-4.884-2.82-4.884-2.82a1.26 1.26 0 0 0-.17.632v2.813c0 .452.242.87.634 1.096zm-.287-1.252a.93.93 0 0 1 .343-.342l12.455-7.194-.01.007.786-.455c.392-.226.633-.643.633-1.096V2.815c0-.452-.241-.87-.633-1.096l-.765-.442a.944.944 0 0 1-.005 1.617l-.006.004-13.231 7.641a1.26 1.26 0 0 0-.633 1.096v2.813c0 .453.24.87.633 1.096l.72.416h.002a.944.944 0 0 1-.29-1.252m12.873-6.652a.945.945 0 0 1-.07 1.575l-.005.004-13.231 7.641a1.26 1.26 0 0 0-.633 1.096v2.813c0 .452.24.87.633 1.096l.765.442a.945.945 0 0 1 .01-1.62l12.456-7.194-.01.006.786-.454c.392-.226.633-.644.633-1.096V9.552c0-.453-.241-.87-.633-1.096l-.697-.403z")
    @MainActor static let vim = template("M24 11.986h-.027l-4.318-4.318 4.303-4.414V1.461l-.649-.648h-8.198l-.66.605v1.045L12.015.027V0L12 .014 11.986 0v.027l-1.29 1.291-.538-.539H2.035l-.638.692v1.885l.616.616h.72v5.31L.027 11.987H0L.014 12 0 12.014h.027l2.706 2.706v6.467l.907.523h2.322l1.857-1.904 4.166 4.166V24l.015-.014.014.014v-.028l2.51-2.509h.485c.111 0 .211-.07.25-.179l.146-.426c.028-.084.012-.172-.037-.239l1.462-1.462-.612 1.962c-.043.141.036.289.177.332.025.008.052.012.078.012h1.824c.106-.001.201-.064.243-.163l.165-.394c.025-.065.024-.138-.004-.203-.027-.065-.08-.116-.146-.142-.029-.012-.062-.019-.097-.02h-.075l.84-2.644h1.232l-1.016 3.221c-.043.141.036.289.176.332.025.008.052.012.079.012h2.002c.11 0 .207-.066.248-.17l.164-.428c.051-.138-.021-.29-.158-.341-.029-.011-.06-.017-.091-.017h-.145l1.131-3.673c.027-.082.012-.173-.039-.24l-.375-.504-.003-.005c-.051-.064-.127-.102-.209-.102h-1.436c-.071 0-.141.03-.19.081l-.4.439h-.624l-.042-.046 4.445-4.445H24L23.986 12l.014-.014zM9.838 21.139l1.579-4.509h-.501l.297-.304h1.659l-1.563 4.555h.623l-.079.258H9.838zm3.695-7.516l.15.151-.269.922-.225.226h-.969l-.181-.181.311-.871.288-.247h.895zM5.59 20.829H3.877l-.262-.15V3.091H2.379l-.1-.1V1.815l.143-.154h7.371l.213.214v1.108l-.142.173H8.785v8.688l8.807-8.688h-2.086l-.175-.188V1.805l.121-.111h7.49l.132.133v1.07L12.979 13.25h-.373c-.015-.001-.028 0-.042.001l-.02.003c-.045.01-.086.03-.119.06l-.343.295-.004.003c-.033.031-.059.069-.073.111l-.296.83-6.119 6.276zm14.768-3.952l.474-.519h1.334l.309.415-1.265 4.107h.493l-.08.209H19.84l1.124-3.564h-2.015l-1.077 3.391h.424l-.073.174h-1.605l1.107-3.548h-2.096l-1.062 3.339h.436l-.072.209H13.27l1.514-4.46H14.198l.091-.271h1.65l.519.537h.906l.491-.554h1.061l.489.535h.953z")

    @MainActor static func keymap(_ keymap: EditorKeymap) -> NSImage? {
        switch keymap {
        case .helix: helix
        case .vim: vim
        case .normal: nil
        }
    }

    private static func template(_ path: String) -> NSImage {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="\#(path)"/></svg>"#
        let image = NSImage(data: Data(svg.utf8))!
        image.isTemplate = true
        return image
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Groups

/// A titled box of rows on the surface colour with a lit edge, the same
/// treatment as code blocks in a note.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var badge: String?
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.themeRevision) private var themeRevision

    var body: some View {
        let _ = themeRevision
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.fgDim)
                    }
                }
            }
            VStack(spacing: 0) { content }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous)
                        .strokeBorder(Theme.edge, lineWidth: 1)
                )
            if let footer {
                Text(.init(footer))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var divider = true
    @ViewBuilder var accessory: Accessory
    @Environment(\.themeRevision) private var themeRevision

    var body: some View {
        let _ = themeRevision
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.fg)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.fgDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, SettingsMetrics.rowPadding)
            .frame(minHeight: SettingsMetrics.rowHeight)

            if divider {
                Rectangle()
                    .fill(Theme.fg.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, SettingsMetrics.rowPadding)
            }
        }
    }
}

// MARK: - Panes

private struct AppearancePane: View {
    @Environment(Store.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var store = store

        SettingsGroup(
            title: "Appearance",
            footer: "Auto follows macOS and uses the matching theme. Glass lets the desktop show through the theme's background. Published pages always follow the reader's system."
        ) {
            SettingsRow(title: "Scheme") {
                Picker("", selection: $store.appearance) {
                    ForEach(Store.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Sidebar") {
                Picker("", selection: $store.sidebarSide) {
                    ForEach(Store.SidebarSide.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Window background", divider: false) {
                Picker("", selection: $store.windowBackground) {
                    ForEach(Store.WindowBackground.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsGroup(
            title: "Panes",
            footer: "Adaptive keeps the panes of a split at even sizes until you drag a divider there, then leaves your sizes alone. Always even goes back to even sizes on every split. Keep sizes halves the pane you split and touches nothing else. A new pane shows the same note, a new empty one, or a picker to search for one."
        ) {
            SettingsRow(title: "When splitting") {
                Picker("", selection: $store.paneScaling) {
                    ForEach(PaneScaling.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "New pane shows", divider: false) {
                Picker("", selection: $store.splitContent) {
                    ForEach(Store.SplitContent.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }

        ThemeSection(
            title: "Light Mode",
            themes: ThemePalette.lightThemes,
            selection: $store.lightTheme,
            active: colorScheme == .light
        )
        ThemeSection(
            title: "Dark Mode",
            themes: ThemePalette.darkThemes,
            selection: $store.darkTheme,
            active: colorScheme == .dark
        )
    }
}

private struct EditorPane: View {
    @Environment(Store.self) private var store
    private let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        @Bindable var store = store

        SettingsGroup(
            title: "Status bar",
            footer: "The keymap and its mode show there while Vim or Helix is in use."
        ) {
            SettingsRow(title: "Character count", subtitle: "In the title bar, for the focused pane", divider: false) {
                Toggle("", isOn: $store.showCharacterCount)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        SettingsGroup(
            title: "Keymap",
            footer: "Vim and Helix add modal editing to both editors. Esc returns to normal mode. A note saves itself and has no process to quit, so there is no command line: `:w` and `:q` have nothing to do."
        ) {
            SettingsRow(title: "Editing keys") {
                Picker("", selection: $store.keymap) {
                    ForEach(EditorKeymap.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Move by display line", subtitle: "j and k step through wrapped lines, like gj and gk", divider: false) {
                Toggle("", isOn: $store.displayLineMotion)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        SettingsGroup(
            title: "Cursor",
            footer: "Match Keymap shows a block in Vim and Helix normal mode, and a bar while typing. The block inverts the character under it."
        ) {
            VStack(spacing: 0) {
                CursorPreview(
                    shape: previewShape,
                    blink: store.cursorBlink
                )
                .padding(14)
                Rectangle()
                    .fill(Theme.fg.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, SettingsMetrics.rowPadding)
            }
            SettingsRow(title: "Shape") {
                Picker("", selection: $store.cursorShape) {
                    ForEach(CursorShape.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Blink speed", divider: false) {
                Picker("", selection: $store.cursorBlink) {
                    ForEach(CursorBlink.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsGroup(title: "Typing Sound", footer: "Recordings of real switches, from kbsim, as keys go down and up in the editors.") {
            SettingsRow(title: "Sound") {
                Picker("", selection: $store.typingSound) {
                    ForEach(KeySound.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: store.typingSound) { TypingSound.shared.preview() }
            }
            SettingsRow(title: "Volume", divider: false) {
                Slider(value: $store.typingVolume, in: 0 ... 1) { editing in
                    if !editing { TypingSound.shared.preview() }
                }
                .frame(width: 160)
                .disabled(store.typingSound == .off)
            }
        }

        SettingsGroup(title: "Text", footer: "The page and Live Preview. The default is Suisse Intl when it's installed, otherwise the system font.") {
            SettingsRow(title: "Font") { fontPicker($store.textFont, defaultName: Metrics.textFamily) }
            SettingsRow(title: "Size") { sizeStepper($store.textSize, range: 12 ... 28) }
            SettingsRow(title: "Line spacing", divider: false) {
                Picker("", selection: $store.density) {
                    ForEach(Store.Density.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsGroup(title: "Source", footer: "Code blocks and the TeX of equations.") {
            SettingsRow(title: "Font") { fontPicker($store.sourceFont, defaultName: "System Mono") }
            SettingsRow(title: "Size", divider: false) { sizeStepper($store.sourceSize, range: 9 ... 24) }
        }
    }

    /// What the keymap makes the cursor when Shape is Match Keymap.
    private var previewShape: CursorShape {
        guard store.cursorShape == .match else { return store.cursorShape }
        return store.keymap.isModal ? .block : .bar
    }

    private func fontPicker(_ selection: Binding<String>, defaultName: String) -> some View {
        Picker("", selection: selection) {
            Text("Default (\(defaultName))").tag("")
            Divider()
            ForEach(families, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }

    private func sizeStepper(_ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range) {
            Text("\(Int(value.wrappedValue)) pt")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.fgDim)
        }
    }
}

private struct TrackpadPane: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store

        SettingsGroup(title: "Trackpad Gestures") {
            SettingsRow(
                title: "Swipe to toggle sidebar",
                subtitle: "Two fingers sideways, anywhere in the window",
                divider: false
            ) {
                Toggle("", isOn: $store.swipeSidebar)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}

private struct NotesPane: View {
    @Environment(Store.self) private var store

    var body: some View {
        SettingsGroup(title: "Folder", footer: "Notes are plain Markdown files. Edit them with any app.") {
            SettingsRow(title: "Location", subtitle: store.folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Button("Show in Finder") { NSWorkspace.shared.open(store.folder) }
            }
            SettingsRow(title: "Notes", divider: false) {
                Text("\(store.notes.count)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.fgDim)
            }
        }
    }
}

private struct PublishingPane: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store

        CloudflareCard()

        SettingsGroup(
            title: "Cloudflare account",
            footer: "Create an API token with **Workers Scripts: Edit**, **Workers KV Storage: Edit** and **Account Settings: Read**. The token stays on this Mac in a file only you can read."
        ) {
            SettingsRow(title: "Account ID") {
                TextField("", text: $store.accountID, prompt: Text("32 hex characters"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 280)
            }
            SettingsRow(title: "API token", divider: false) {
                SecureField("", text: $store.apiToken, prompt: Text("Required"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 280)
            }
        }

        SettingsGroup(
            footer: "Runs Terraform to create a Worker and a KV namespace named “naut”. After that they are ordinary Cloudflare resources you can change in the dashboard."
        ) {
            SettingsRow(title: store.site == nil ? "Publishing is not set up" : "Publishing is set up",
                        subtitle: store.site?.url.absoluteString,
                        divider: store.error != nil) {
                if store.provisioning { ProgressView().controlSize(.small) }
                Button(store.site == nil ? "Set Up" : "Update") { store.provision() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.provisioning || store.accountID.isEmpty || store.apiToken.isEmpty)
            }
            if let error = store.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SettingsMetrics.rowPadding)
            }
        }

        SettingsGroup(
            title: "Pasted images",
            footer: "On Cloudflare, a pasted image is uploaded to the publishing Worker and the note links to its URL, so it shows wherever the note is read. Set up publishing first; until then images stay on this Mac, in **attachments** beside your notes."
        ) {
            SettingsRow(title: "Save to", divider: false) {
                Picker("", selection: $store.imageStorage) {
                    ForEach(Store.ImageStorage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(store.site == nil && store.imageStorage == .local)
            }
        }

        let published = store.notes.filter { store.published.contains($0.name) }
        SettingsGroup(title: "Published notes") {
            if published.isEmpty {
                SettingsRow(title: "Nothing published yet", subtitle: "Use the globe button on a note.", divider: false) { EmptyView() }
            }
            ForEach(Array(published.enumerated()), id: \.element.id) { i, note in
                Button {
                    if let url = store.url(for: note) { NSWorkspace.shared.open(url) }
                } label: {
                    SettingsRow(title: note.name, subtitle: store.url(for: note)?.absoluteString, divider: i < published.count - 1) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.fgDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Where notes get published, at a glance, and the way out to the
/// dashboard where the Worker and KV namespace can be changed. The same
/// idea as Rex's "Server — Running" card.
private struct CloudflareCard: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeRevision) private var themeRevision

    var body: some View {
        let _ = themeRevision
        HStack(spacing: 12) {
            SettingsIcon(kind: .cloudflare, size: SettingsMetrics.statusIconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloudflare")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                HStack(spacing: 5) {
                    StatusDot(
                        color: dot,
                        busy: store.provisioning,
                        connected: store.site?.url,
                        reduceMotion: reduceMotion
                    )
                    Text(status)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.fgDim)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.open(store.dashboardURL)
            } label: {
                Label("Dashboard", systemImage: "arrow.up.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .help(store.dashboardURL.absoluteString)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous)
                .strokeBorder(Theme.edge, lineWidth: 1)
        )
    }

    private var status: String {
        if store.provisioning { return "Setting up…" }
        guard let site = store.site else { return "Not set up" }
        return site.url.host() ?? "Connected"
    }

    private var dot: Color {
        if store.provisioning { return .orange }
        return store.site == nil ? Theme.fgDim : .green
    }
}

/// The connection dot: it breathes while Terraform runs, then lands with
/// one short pop when the Worker goes live. The pop is triggered by the
/// site appearing, so opening Settings after setup is still.
private struct StatusDot: View {
    let color: Color
    let busy: Bool
    let connected: URL?
    let reduceMotion: Bool

    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(color)
            .animation(.easeOut(duration: 0.2), value: color)
            .frame(width: 6, height: 6)
            .scaleEffect(breathing ? 1.45 : 1)
            .opacity(breathing ? 0.55 : 1)
            .phaseAnimator([1.0, 1.5, 1.0], trigger: connected) { dot, scale in
                dot.scaleEffect(reduceMotion ? 1 : scale)
            } animation: { scale in
                scale == 1.5
                    ? .easeOut(duration: 0.12)
                    : .spring(duration: 0.35, bounce: 0.3)
            }
            .onChange(of: busy, initial: true) { _, busy in
                let breathe = busy && !reduceMotion
                let animation: Animation = breathe
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2)
                withAnimation(animation) { breathing = breathe }
            }
            .accessibilityHidden(true)
    }
}

/// "Dashboard ↗": the arrow after the text, as links out usually read.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

private struct ShortcutsPane: View {
    private let shortcuts: [(String, [String])] = [
        ("New note", ["⌘", "N"]),
        ("Search notes", ["⌘", "K"]),
        ("Split right", ["⌘", "D"]),
        ("Split down", ["⇧", "⌘", "D"]),
        ("Next or previous pane", ["⌘", "]"]),
        ("Maximize the pane", ["⇧", "⌘", "↩"]),
        ("Close the pane", ["⌘", "W"]),
        ("Show or hide the editor", ["⌘", "E"]),
        ("Settings", ["⌘", ","]),
    ]

    var body: some View {
        SettingsGroup(title: "Keyboard", footer: "Shortcuts follow macOS conventions and can be changed in System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts.") {
            ForEach(Array(shortcuts.enumerated()), id: \.offset) { i, s in
                SettingsRow(title: s.0, divider: i < shortcuts.count - 1) {
                    HStack(spacing: 4) {
                        ForEach(s.1, id: \.self) { Keycap(label: $0) }
                    }
                }
            }
        }
    }
}

private struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.fg)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 4)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
    }
}

/// A live cursor in a field like a terminal's: the chosen shape, blinking
/// at the chosen speed, in the theme's cursor colour. It answers "what
/// will this feel like?" without making the user type in a note first.
private struct CursorPreview: View {
    let shape: CursorShape
    let blink: CursorBlink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeRevision) private var themeRevision

    var body: some View {
        let _ = themeRevision
        let period = blink.period ?? 0
        let paused = period == 0 || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            HStack(spacing: 1) {
                Text("Write something")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.fg)
                cursor
                    .opacity(opacity(at: context.date))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.edge, lineWidth: 1)
            )
        }
    }

    /// A bar fades like the editor's caret; a block blinks on and off like
    /// a terminal's.
    private func opacity(at date: Date) -> Double {
        guard let period = blink.period, !reduceMotion else { return 1 }
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period * 2) / (period * 2)
        if shape == .bar || shape == .match {
            return 0.5 + 0.5 * cos(2 * .pi * phase)
        }
        return phase < 0.5 ? 1 : 0
    }

    private var cursor: some View {
        let color = Color(nsColor: .themeCursor)
        return Group {
            switch shape {
            case .bar, .match:
                RoundedRectangle(cornerRadius: 1, style: .continuous).fill(color)
                    .frame(width: 2, height: 20)
            case .block:
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color)
                    .frame(width: 9, height: 20)
            case .underline:
                RoundedRectangle(cornerRadius: 1, style: .continuous).fill(color)
                    .frame(width: 9, height: 2)
                    .frame(height: 20, alignment: .bottom)
            }
        }
    }
}

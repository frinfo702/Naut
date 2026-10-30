import AppKit
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
        .frame(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSearchField(text: $query)

            StatusCard(selected: pane == .publishing) { pane = .publishing }

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
    case appearance, notes, publishing, shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .notes: "Notes"
        case .publishing: "Publishing"
        case .shortcuts: "Shortcuts"
        }
    }

    var icon: SettingsIcon.Kind {
        switch self {
        case .appearance: .palette
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
        case .appearance: ["theme", "dark", "light", "color", "colour", "scheme"]
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
    static let windowHeight: CGFloat = 540
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

    // MARK: - Appearance cards
    static let cardWidth: CGFloat = 112
    static let cardHeight: CGFloat = 76
    static let cardRadius: CGFloat = 12
}

// MARK: - Sidebar pieces

private struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
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

/// Where notes get published, at a glance. The same idea as Rex's
/// "Server — Running" card.
private struct StatusCard: View {
    @Environment(Store.self) private var store
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIcon(kind: .cloudflare, size: SettingsMetrics.statusIconSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cloudflare")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    HStack(spacing: 5) {
                        Circle().fill(dot).frame(width: 6, height: 6)
                        Text(status)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fgDim)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void

    var body: some View {
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
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
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
    /// Icons. NSImage renders SVG natively, so it ships as source.
    static let cloudflare: NSImage = NSImage(data: Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#F38020" d="M16.5088 16.8447c.1475-.5068.0908-.9707-.1553-1.3154-.2246-.3164-.6045-.5-1.0615-.5205l-8.6592-.1123a.1559.1559 0 0 1-.1333-.0713c-.0283-.042-.0351-.0986-.021-.1553.0278-.084.1123-.1484.2036-.1562l8.7359-.1123c1.0351-.0489 2.1601-.8868 2.5537-1.9136l.499-1.3013c.0215-.0561.0293-.1128.0147-.168-.5625-2.5463-2.835-4.4453-5.5499-4.4453-2.5039 0-4.6284 1.6177-5.3876 3.8614-.4927-.3658-1.1187-.5625-1.794-.499-1.2026.119-2.1665 1.083-2.2861 2.2856-.0283.31-.0069.6128.0635.894C1.5683 13.171 0 14.7754 0 16.752c0 .1748.0142.3515.0352.5273.0141.083.0844.1475.1689.1475h15.9814c.0909 0 .1758-.0645.2032-.1553l.12-.4268zm2.7568-5.5634c-.0771 0-.1611 0-.2383.0112-.0566 0-.1054.0415-.127.0976l-.3378 1.1744c-.1475.5068-.0918.9707.1543 1.3164.2256.3164.6055.498 1.0625.5195l1.8437.1133c.0557 0 .1055.0263.1329.0703.0283.043.0351.1074.0214.1562-.0283.084-.1132.1485-.204.1553l-1.921.1123c-1.041.0488-2.1582.8867-2.5527 1.914l-.1406.3585c-.0283.0713.0215.1416.0986.1416h6.5977c.0771 0 .1474-.0489.169-.126.1122-.4082.1757-.837.1757-1.2803 0-2.6025-2.125-4.727-4.7344-4.727"/></svg>
        """.utf8))!
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
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.fg)
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

    var body: some View {
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

    var body: some View {
        SettingsGroup(title: "Color scheme", footer: "Auto follows macOS. Published pages always follow the reader's system.") {
            HStack(spacing: 18) {
                ForEach(Store.Appearance.allCases, id: \.self) { a in
                    SchemeCard(appearance: a, selected: store.appearance == a) {
                        withAnimation(.snappy(duration: 0.15)) { store.appearance = a }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}

/// A miniature Naut window in the given scheme, on a tile, like the
/// Color scheme cards in Rex and System Settings.
private struct SchemeCard: View {
    let appearance: Store.Appearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    switch appearance {
                    case .auto:
                        MiniWindow(dark: false)
                        MiniWindow(dark: true)
                            .mask(DiagonalHalf())
                    case .light: MiniWindow(dark: false)
                    case .dark: MiniWindow(dark: true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                // Sat on a wallpaper, as in System Settings, so the dark
                // window has something to stand out from.
                .padding(.top, 12)
                .padding(.leading, 14)
                .frame(width: SettingsMetrics.cardWidth, height: SettingsMetrics.cardHeight, alignment: .topLeading)
                .background(LinearGradient(colors: [Color(hex: 0x2F6FD6), Color(hex: 0x0E2F73)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius + 3, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
                        .padding(-3)
                )

                Text(appearance.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.fg : Theme.fgDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Sidebar, a title line and a few lines of text, with the real palette
/// values of each scheme so the card is an honest preview.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let bg = Color(hex: dark ? 0x10120F : 0xFBFBF9)
        let side = Color(hex: dark ? 0x191C17 : 0xF0F0EC)
        let ink = Color(hex: dark ? 0xF1F1EE : 0x161715)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 5, height: 5) }
                }
                .padding(.bottom, 4)
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(ink.opacity(i == 1 ? 0.7 : 0.25)).frame(width: i == 1 ? 18 : 22, height: 3)
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 38)
            .frame(maxHeight: .infinity)
            .background(side)

            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink.opacity(0.85)).frame(width: 34, height: 5)
                ForEach([52, 46, 50, 30], id: \.self) { w in
                    Capsule().fill(ink.opacity(0.3)).frame(width: CGFloat(w), height: 3)
                }
                RoundedRectangle(cornerRadius: 3).fill(side).frame(width: 52, height: 12)
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(bg)
        }
    }
}

/// The bottom-right triangle, for the split Auto card.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
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

        SettingsGroup(
            title: "Cloudflare account",
            footer: "Create an API token with **Workers Scripts: Edit**, **Workers KV Storage: Edit** and **Account Settings: Read**. The token is kept in your keychain."
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

private struct ShortcutsPane: View {
    private let shortcuts: [(String, [String])] = [
        ("New note", ["⌘", "N"]),
        ("Search notes", ["⌘", "K"]),
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

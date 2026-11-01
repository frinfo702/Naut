import AppKit
import NautKit
import Observation
import Security

/// A note is a Markdown file in the notes folder. The file is the source
/// of truth; nothing about a note's content lives anywhere else.
struct Note: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// The page address when published: "My Note" → "my-note".
    var slug: String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }
}

@MainActor
@Observable
final class Store {
    // MARK: - Notes

    /// ponytail: a fixed folder. Make it a setting when someone wants
    /// their notes in iCloud Drive or a Git repo.
    let folder = URL.documentsDirectory.appending(path: "Naut", directoryHint: .isDirectory)

    private(set) var notes: [Note] = []

    var selection: Note.ID? {
        didSet {
            guard selection != oldValue else { return }
            saveNow(oldValue)
            load()
            guard let selection else { return }
            if !tabs.contains(selection) { tabs.append(selection) }
            recent.removeAll { $0 == selection }
            recent.insert(selection, at: 0)
            if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        }
    }

    // MARK: - Favorites and recent

    /// Starred notes, in the order they were starred.
    private(set) var favorites: [Note.ID] = [] {
        didSet { persist(favorites, as: "favorites") }
    }

    /// Notes by when they were last opened, newest first.
    private(set) var recent: [Note.ID] = [] {
        didSet { persist(recent, as: "recent") }
    }

    private static let recentLimit = 20

    func isFavorite(_ id: Note.ID) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: Note.ID) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
    }

    /// Lists of notes are kept by file name, so they survive a move of the
    /// notes folder's parent. The test harnesses open notes too; they must
    /// not change the user's lists.
    private func persist(_ ids: [Note.ID], as key: String) {
        guard !Snapshot.isHarness else { return }
        UserDefaults.standard.set(ids.map(\.lastPathComponent), forKey: key)
    }

    private func restore(_ key: String) -> [Note.ID] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { folder.appending(path: $0) }
    }

    // MARK: - Tabs

    /// Open notes, in tab order. Opening a note adds its tab; the selected
    /// note is always one of them. Kept by file name across launches.
    private(set) var tabs: [Note.ID] = [] {
        didSet { persist(tabs, as: "tabs") }
    }

    /// Close a tab. Closing the selected one moves to its neighbour, the
    /// one after it if there is one, as browsers do.
    func closeTab(_ id: Note.ID) {
        guard let index = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: index)
        guard selection == id else { return }
        selection = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
    }

    func closeOtherTabs(than id: Note.ID) {
        tabs = [id]
        selection = id
    }

    /// The tab `offset` places from the selected one, wrapping around.
    func selectTab(offset: Int) {
        guard let selection, let index = tabs.firstIndex(of: selection), !tabs.isEmpty else { return }
        self.selection = tabs[(index + offset + tabs.count) % tabs.count]
    }

    /// The selected note's text. Saved shortly after each edit.
    var text = "" {
        didSet {
            guard text != oldValue, !loading else { return }
            rerender()
            scheduleSave()
        }
    }

    /// `text`'s headings, for the sidebar and Live Preview, parsed once
    /// per edit.
    private(set) var outline: [Heading] = []

    // MARK: - Appearance

    enum Appearance: String, CaseIterable {
        case auto, light, dark

        var title: String { rawValue.capitalized }
    }

    /// Auto by default: follow macOS unless the user says otherwise.
    var appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .auto {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    private func applyAppearance() {
        // SwiftUI may build the App, and so a Store, more than once; a
        // snapshot's appearance has to win over every one of them.
        if let forced = Snapshot.forcedAppearance {
            NSApplication.shared.appearance = forced
            return
        }
        NSApplication.shared.appearance = switch appearance {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// One theme per mode: Auto then follows macOS into the right one.
    var lightTheme = UserDefaults.standard.string(forKey: "lightTheme") ?? ThemePalette.nautLight.id {
        didSet {
            guard lightTheme != oldValue else { return }
            UserDefaults.standard.set(lightTheme, forKey: "lightTheme")
            applyThemes()
        }
    }

    var darkTheme = UserDefaults.standard.string(forKey: "darkTheme") ?? ThemePalette.nautDark.id {
        didSet {
            guard darkTheme != oldValue else { return }
            UserDefaults.standard.set(darkTheme, forKey: "darkTheme")
            applyThemes()
        }
    }

    /// Solid paints the theme's background; Glass lets the desktop show
    /// through it, like Rex's translucent windows.
    enum WindowBackground: String, CaseIterable {
        case solid, glass

        var title: String { rawValue.capitalized }
    }

    var windowBackground = Snapshot.forcedBackground ?? WindowBackground(rawValue: UserDefaults.standard.string(forKey: "windowBackground") ?? "") ?? .solid {
        didSet {
            guard Snapshot.forcedBackground == nil else { return }
            UserDefaults.standard.set(windowBackground.rawValue, forKey: "windowBackground")
        }
    }

    enum SidebarSide: String, CaseIterable {
        case left, right

        var title: String { rawValue.capitalized }
    }

    var showSidebar = UserDefaults.standard.object(forKey: "showSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidebar, forKey: "showSidebar") }
    }

    var sidebarSide = SidebarSide(rawValue: UserDefaults.standard.string(forKey: "sidebarSide") ?? "") ?? .left {
        didSet { UserDefaults.standard.set(sidebarSide.rawValue, forKey: "sidebarSide") }
    }

    func palette(for dark: Bool) -> ThemePalette {
        ThemePalette.named(dark ? darkTheme : lightTheme, dark: dark)
    }

    /// Bumped on every theme change, for views that repaint the chrome.
    private(set) var themeRevision = 0

    private func applyThemes(redraw: Bool = true) {
        themeRevision += 1
        ThemeSelection.select(
            light: palette(for: false),
            dark: palette(for: true),
            redraw: redraw
        )
    }

    // MARK: - Editor

    /// Vim, Helix, or the standard editing keys. Applies to both editors.
    var keymap = Snapshot.forcedKeymap ?? EditorKeymap(rawValue: UserDefaults.standard.string(forKey: "keymap") ?? "") ?? .normal {
        didSet {
            guard ready, Snapshot.forcedKeymap == nil else { return }
            UserDefaults.standard.set(keymap.rawValue, forKey: "keymap")
        }
    }

    /// Bar, block or underline; `match` uses a block for Vim and Helix.
    var cursorShape = CursorShape(rawValue: UserDefaults.standard.string(forKey: "cursorShape") ?? "") ?? .match {
        didSet {
            guard ready else { return }
            UserDefaults.standard.set(cursorShape.rawValue, forKey: "cursorShape")
        }
    }

    /// How the insertion point blinks, in both editors.
    /// The note's length in the editor's status bar. Off by default.
    var showCharacterCount = UserDefaults.standard.bool(forKey: "showCharacterCount") {
        didSet { UserDefaults.standard.set(showCharacterCount, forKey: "showCharacterCount") }
    }

    var cursorBlink = CursorBlink(rawValue: UserDefaults.standard.string(forKey: "cursorBlink") ?? "") ?? .normal {
        didSet {
            guard ready else { return }
            UserDefaults.standard.set(cursorBlink.rawValue, forKey: "cursorBlink")
        }
    }

    /// Font families; empty means the default (Suisse Intl if installed,
    /// else the system font, for text; the system monospaced font for
    /// source and code).
    var textFont = UserDefaults.standard.string(forKey: "textFont") ?? "" {
        didSet { UserDefaults.standard.set(textFont, forKey: "textFont") }
    }

    var textSize = UserDefaults.standard.object(forKey: "textSize") as? Double ?? Double(Metrics.textFontSize) {
        didSet { UserDefaults.standard.set(textSize, forKey: "textSize") }
    }

    var sourceFont = UserDefaults.standard.string(forKey: "sourceFont") ?? "" {
        didSet { UserDefaults.standard.set(sourceFont, forKey: "sourceFont") }
    }

    var sourceSize = UserDefaults.standard.object(forKey: "sourceSize") as? Double ?? Double(Metrics.editorFontSize) {
        didSet { UserDefaults.standard.set(sourceSize, forKey: "sourceSize") }
    }

    var textNSFont: NSFont {
        Self.font(textFont.isEmpty ? Metrics.textFamily : textFont, size: textSize, fallback: .systemFont(ofSize: textSize))
    }

    /// How far apart lines of text are.
    enum Density: String, CaseIterable {
        /// Like Rex's docs: tighter lines, more on screen.
        case compact
        /// page.css's own spacing.
        case comfortable

        var title: String { rawValue.capitalized }
        /// CSS line-height.
        var lineHeight: Double { self == .compact ? 1.55 : 1.75 }
    }

    var density = Density(rawValue: UserDefaults.standard.string(forKey: "density") ?? "") ?? .compact {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "density") }
    }
    var sourceNSFont: NSFont {
        Self.font(sourceFont, size: sourceSize, fallback: .monospacedSystemFont(ofSize: sourceSize, weight: .regular))
    }

    private static func font(_ family: String, size: Double, fallback: NSFont) -> NSFont {
        guard !family.isEmpty else { return fallback }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? fallback
    }

    /// Set while `load` assigns `text`, so loading isn't mistaken for an edit.
    private var loading = false
    private var saveTask: Task<Void, Never>?

    var selectedNote: Note? { notes.first { $0.id == selection } }

    /// Notes whose title or text contain `query`, for the command palette.
    /// The open note is searched as typed, not as last saved.
    func search(_ query: String) -> [(note: Note, match: NoteSearch.Match)] {
        guard !query.isEmpty else { return [] }
        // ponytail: reads every file per keystroke. Fine for hundreds of
        // notes; index in libnaut if it ever isn't.
        return notes.compactMap { note in
            let body = note.id == selection ? text : (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
            guard let match = NoteSearch.match(query, title: note.name, text: body) else { return nil }
            return (note, match)
        }
        .sorted { $0.match.count > $1.match.count }
    }

    private func rerender() {
        outline = Markdown.render(text).outline
    }

    /// Set after the first load. Property observers run while SwiftUI's
    /// @Observable initializes, and a forced test keymap must not reach
    /// UserDefaults through them.
    private var ready = false

    init() {
        applyThemes(redraw: false)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        applyAppearance()
        tabs = restore("tabs")
        favorites = restore("favorites")
        recent = restore("recent")
        reload()
        if notes.isEmpty { newNote(named: "Welcome", text: Self.welcome) }
        selection = tabs.first ?? notes.first?.id
        ready = true
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        notes = urls
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Note.init)
        // A note deleted or renamed outside the app leaves every list.
        let gone = { (id: Note.ID) in !self.notes.contains { $0.id == id } }
        tabs.removeAll(where: gone)
        favorites.removeAll(where: gone)
        recent.removeAll(where: gone)
    }

    func newNote(named name: String = "Untitled", text: String = "") {
        var url = folder.appending(path: "\(name).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(name) \(n).md")
            n += 1
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        reload()
        selection = url
    }

    /// Rename a note: its title is its file name. A published note moves
    /// to the new address and the old one is taken down.
    func rename(_ note: Note, to title: String) {
        // A file name can't hold "/", and ":" shows as "/" in Finder.
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if name.isEmpty { name = "Untitled" }
        guard name != note.name, FileManager.default.fileExists(atPath: note.url.path) else { return }
        // The file has the latest text before it moves.
        if note.id == selection { saveNow(note.id) }

        var url = folder.appending(path: "\(name).md")
        var n = 2
        // The same name in another case is this file on a case-insensitive
        // disk, not a clash.
        while FileManager.default.fileExists(atPath: url.path), url.path.lowercased() != note.url.path.lowercased() {
            url = folder.appending(path: "\(name) \(n).md")
            n += 1
        }
        do {
            // Through a temporary name, so a change of case alone is a move.
            let temp = folder.appending(path: ".\(UUID().uuidString).md")
            try FileManager.default.moveItem(at: note.url, to: temp)
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            self.error = "Couldn't rename “\(note.name)”: \(error.localizedDescription)"
            return
        }

        let renamed = Note(url: url)
        let wasPublished = published.contains(note.name)
        reload()
        // The renamed note keeps its place in every list.
        if let i = tabs.firstIndex(of: note.id) { tabs[i] = renamed.id }
        if let i = favorites.firstIndex(of: note.id) { favorites[i] = renamed.id }
        if let i = recent.firstIndex(of: note.id) { recent[i] = renamed.id }
        if selection == note.id { selection = renamed.id }
        guard wasPublished else { return }
        // The page shows the title, so it is published again either way;
        // a new address also takes the old page down.
        published.remove(note.name)
        if renamed.slug != note.slug { unpublishSlug(of: note) }
        setPublished(renamed, true)
    }

    func trash(_ note: Note) {
        if published.contains(note.name) { unpublish(note) }
        try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        closeTab(note.id)
        reload()
        selection = selection ?? notes.first?.id
    }

    private func load() {
        loading = true
        defer { loading = false }
        text = selectedNote.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        rerender()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            saveNow(selection)
        }
    }

    private func saveNow(_ id: Note.ID?) {
        saveTask?.cancel()
        guard let note = notes.first(where: { $0.id == id }) else { return }
        // trash() moves the file before clearing the selection; writing
        // here would bring it back (and republish it).
        guard FileManager.default.fileExists(atPath: note.url.path) else { return }
        // On a selection change `text` still holds the old note's text.
        let current = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
        guard current != text else { return }
        try? text.write(to: note.url, atomically: true, encoding: .utf8)
        if published.contains(note.name) { publish(note, text: text) }
    }

    // MARK: - Publishing

    var accountID = UserDefaults.standard.string(forKey: "accountID") ?? "" {
        didSet { UserDefaults.standard.set(accountID, forKey: "accountID") }
    }

    var apiToken = TokenStore.read() ?? "" {
        didSet { TokenStore.write(apiToken) }
    }

    /// Set once provisioning succeeds.
    var site: Cloudflare.Site? = UserDefaults.standard.data(forKey: "site")
        .flatMap { try? JSONDecoder().decode(Cloudflare.Site.self, from: $0) }
    {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(site), forKey: "site") }
    }

    /// Names of published notes.
    private(set) var published = Set(UserDefaults.standard.stringArray(forKey: "published") ?? []) {
        didSet { UserDefaults.standard.set(Array(published), forKey: "published") }
    }

    /// The tail of each note's chain of Cloudflare requests, keyed by
    /// name. Requests for one note run in order, so an older autosave can't
    /// land after a newer one and a quick publish/unpublish can't finish
    /// backwards. `id` tells a finishing task whether it is still the tail.
    private var queues: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var nextQueueID = 0
    private(set) var provisioning = false
    var error: String?

    private var cloudflare: Cloudflare { Cloudflare(accountID: accountID, apiToken: apiToken) }

    /// The account's Workers & Pages overview, where the Worker and KV
    /// namespace live. Without a valid account ID, the dashboard home.
    var dashboardURL: URL {
        let id = accountID.trimmingCharacters(in: .whitespaces)
        let valid = id.count == 32 && id.allSatisfy(\.isHexDigit)
        return URL(string: valid ? "https://dash.cloudflare.com/\(id)/workers-and-pages" : "https://dash.cloudflare.com")!
    }

    func url(for note: Note) -> URL? {
        site?.url.appending(path: note.slug)
    }

    func provision() {
        let workdir = URL.applicationSupportDirectory.appending(path: "Naut/terraform", directoryHint: .isDirectory)
        provisioning = true
        error = nil
        Task {
            defer { provisioning = false }
            do {
                site = try await cloudflare.provision(workdir: workdir)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// A request for this note is queued or in flight.
    func isBusy(_ note: Note) -> Bool {
        queues[note.name] != nil
    }

    func setPublished(_ note: Note, _ on: Bool) {
        // A deliberate action replaces whatever error was showing.
        error = nil
        if on {
            // Names that differ only in case or whitespace share an
            // address; publishing one would overwrite the other's page.
            if let other = notes.first(where: {
                $0.id != note.id && $0.slug == note.slug && published.contains($0.name)
            }) {
                error = "“\(other.name)” is already published at /\(note.slug). Rename one of them to publish both."
                return
            }
            let text = note.id == selection ? text : (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
            publish(note, text: text)
        } else {
            unpublish(note)
        }
    }

    private func publish(_ note: Note, text: String) {
        guard let site else { return }
        let html = Markdown.page(text, title: note.name, toc: true)
        perform(note) { try await $0.put(site, key: note.slug, value: html) } done: {
            self.published.insert(note.name)
        }
    }

    /// Take down a renamed note's old page; its name is no longer listed.
    private func unpublishSlug(of note: Note) {
        guard let site else { return }
        perform(note) { try await $0.delete(site, key: note.slug) } done: {}
    }

    private func unpublish(_ note: Note) {
        guard let site else { return }
        perform(note) { try await $0.delete(site, key: note.slug) } done: {
            self.published.remove(note.name)
        }
    }

    /// Run `op` and only then record its effect with `done`, so the
    /// published state never claims something Cloudflare didn't confirm.
    private func perform(
        _ note: Note,
        _ op: @escaping @Sendable (Cloudflare) async throws -> Void,
        done: @escaping () -> Void
    ) {
        let cloudflare = cloudflare
        let previous = queues[note.name]?.task
        let id = nextQueueID
        nextQueueID += 1
        // Not clearing `error` here: autosave republishes come through this
        // path and would hide an error the user hasn't read yet.
        let task = Task {
            await previous?.value
            do {
                try await op(cloudflare)
                done()
            } catch {
                self.error = error.localizedDescription
            }
            if queues[note.name]?.id == id { queues[note.name] = nil }
        }
        queues[note.name] = (id, task)
    }

    // MARK: -

    static let welcome = """
        # Welcome to Naut

        Notes are Markdown files in `~/Documents/Naut`. Edit on the left, read on the right.

        ## Math

        Inline $e^{i\\pi} + 1 = 0$, or on its own line:

        $$
        \\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}
        $$

        ## Code

        ```zig
        const std = @import("std");
        pub fn main() void {
            std.debug.print("hello\\n", .{});
        }
        ```

        ## Publishing

        | Action | Shortcut |
        | --- | --- |
        | New note | `⌘N` |
        | Search | `⌘K` |
        | Toggle sidebar | `⌃⌘S` |

        - [x] Write a note
        - [ ] Publish it with the globe button
        """
}

/// The Cloudflare API token. Application Support rather than the login
/// keychain: ad-hoc signed development builds get a new code identity on
/// every rebuild, so macOS asked for keychain permission on every launch
/// and "Always Allow" never stuck. A 0600 file is readable only by this
/// user, the same protection UserDefaults has, without the prompts.
enum TokenStore {
    static var url: URL {
        URL.applicationSupportDirectory.appending(path: "Naut/api-token")
    }

    static func read() -> String? {
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        // Carry a token saved by an older build out of the keychain once.
        guard !UserDefaults.standard.bool(forKey: "tokenMigrated") else { return nil }
        var migrated: String?
        let status = legacyKeychain { migrated = $0 }
        if let migrated {
            UserDefaults.standard.set(true, forKey: "tokenMigrated")
            write(migrated)
            return migrated
        }
        // A snapshot or another headless run can't show the permission
        // prompt. Leave the migration pending for a real launch.
        if status != errSecInteractionNotAllowed {
            UserDefaults.standard.set(true, forKey: "tokenMigrated")
        }
        return nil
    }

    static func write(_ value: String) {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // The field still works for this session; publishing will say
            // why it failed.
        }
    }

    /// One-time migration from the keychain item older builds wrote.
    private static func legacyKeychain(imported: (String) -> Void) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.frinfo702.naut",
            kSecAttrAccount as String: "cloudflare-api-token",
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data {
            let token = String(decoding: data, as: UTF8.self)
            if !token.isEmpty { imported(token) }
        }
        return status
    }
}

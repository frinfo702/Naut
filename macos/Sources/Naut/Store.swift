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
        }
    }

    /// The selected note's text. Saved shortly after each edit.
    var text = "" {
        didSet {
            guard text != oldValue, !loading else { return }
            outline = Markdown.outline(text)
            scheduleSave()
        }
    }

    private(set) var outline: [Heading] = []
    var query = ""
    var showEditor = true

    /// Set while `load` assigns `text`, so loading isn't mistaken for an edit.
    private var loading = false
    private var saveTask: Task<Void, Never>?

    var selectedNote: Note? { notes.first { $0.id == selection } }

    var filteredNotes: [Note] {
        guard !query.isEmpty else { return notes }
        // ponytail: reads every file per keystroke. Fine for hundreds of
        // notes; index in libnaut if it ever isn't.
        return notes.filter { note in
            note.name.localizedCaseInsensitiveContains(query)
                || ((try? String(contentsOf: note.url, encoding: .utf8))?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
        if notes.isEmpty { newNote(named: "Welcome", text: Self.welcome) }
        selection = notes.first?.id
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        notes = urls
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Note.init)
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

    func trash(_ note: Note) {
        if published.contains(note.name) { unpublish(note) }
        try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        if selection == note.id { selection = nil }
        reload()
        selection = selection ?? notes.first?.id
    }

    private func load() {
        loading = true
        defer { loading = false }
        text = selectedNote.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        outline = Markdown.outline(text)
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

    var apiToken = Keychain.read() ?? "" {
        didSet { Keychain.write(apiToken) }
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

    /// Notes with a request in flight, for progress UI.
    private(set) var busy: Set<String> = []
    private(set) var provisioning = false
    var error: String?

    private var cloudflare: Cloudflare { Cloudflare(accountID: accountID, apiToken: apiToken) }

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

    func setPublished(_ note: Note, _ on: Bool) {
        if on {
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
        busy.insert(note.name)
        error = nil
        Task {
            defer { busy.remove(note.name) }
            do {
                try await op(cloudflare)
                done()
            } catch {
                self.error = error.localizedDescription
            }
        }
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
        | Toggle editor | `⌘E` |

        - [x] Write a note
        - [ ] Publish it with the globe button
        """
}

/// The API token lives in the login keychain, never in defaults.
enum Keychain {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.frinfo702.naut",
        kSecAttrAccount as String: "cloudflare-api-token",
    ] }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

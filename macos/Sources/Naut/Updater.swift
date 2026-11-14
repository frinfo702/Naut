import AppKit
import CryptoKit
import Security

/// Check for Updates…: asks GitHub for the newest release, and if it is
/// newer than this build, downloads its disk image, checks it, swaps it in
/// for this bundle and relaunches.
///
/// There is no helper app, as Sparkle has: the bundle can be renamed while
/// we run (the running binary stays mapped), so the new one is moved into
/// place first, and a shell that waits for us to quit opens it.
@MainActor
final class Updater {
    static let shared = Updater()

    /// Where .github/workflows/release.yml publishes.
    nonisolated static let repository = "frinfo702/Naut"

    private var busy = false
    private var panel: NSPanel?
    private var label: NSTextField?

    func checkForUpdates() {
        guard !busy else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        busy = true
        Task {
            await check()
            hideProgress()
            busy = false
        }
    }

    private func check() async {
        let current = Version(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? Version(0, 0, 0)
        let release: Release
        do {
            release = try await Self.latestRelease()
        } catch {
            fail("Naut couldn’t check for updates.", error, release: nil)
            return
        }
        guard let latest = Version(release.tagName), latest > current else {
            inform("You’re up to date.", "Naut \(current) is the newest version.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Naut \(latest) is available"
        alert.informativeText = "You have \(current). Naut will download the update, quit and open again."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.htmlUrl)
            return
        default: return
        }

        do {
            let app = try await install(release, version: latest)
            relaunch(app)
        } catch {
            hideProgress()
            fail("Naut couldn’t install \(latest).", error, release: release)
        }
    }

    // MARK: - Installing

    /// Puts the release's app where this one is, and returns its location.
    private func install(_ release: Release, version: Version) async throws -> URL {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { throw UpdateError.notABundle }
        // Opened from the disk image, or quarantined and run from a random
        // read-only copy: there is nowhere to put the new version.
        guard !app.path.hasPrefix("/Volumes/"), !app.path.contains("/AppTranslocation/") else {
            throw UpdateError.notInstalled
        }
        let folder = app.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else { throw UpdateError.readOnly(folder) }
        guard let image = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            throw UpdateError.noDiskImage
        }

        showProgress("Downloading Naut \(version)…")
        // Beside the app, so the swap below is a rename on one volume.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: work) }

        let dmg = work.appending(path: image.name)
        let (downloaded, response) = try await URLSession.shared.download(from: image.browserDownloadUrl)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
        try fm.moveItem(at: downloaded, to: dmg)
        if let sum = release.assets.first(where: { $0.name == image.name + ".sha256" }) {
            let (data, _) = try await URLSession.shared.data(from: sum.browserDownloadUrl)
            let expected = (String(bytes: data, encoding: .utf8) ?? "").split(separator: " ").first.map { $0.lowercased() }
            guard try await Self.sha256(of: dmg) == expected else { throw UpdateError.checksum }
        }

        showProgress("Installing Naut \(version)…")
        let mount = work.appending(path: "mount", directoryHint: .isDirectory)
        let staged = work.appending(path: "New.app", directoryHint: .isDirectory)
        try await Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        do {
            let found = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "app" }
            guard let found else { throw UpdateError.noApp }
            try await Self.run("/usr/bin/ditto", [found.path, staged.path])
        } catch {
            _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        try Self.verify(staged, replacing: app)

        // Swap, putting the old one back if the new one won't go in. The
        // old one is left in `work`, which goes when we return.
        let old = work.appending(path: "Old.app", directoryHint: .isDirectory)
        try fm.moveItem(at: app, to: old)
        do {
            try fm.moveItem(at: staged, to: app)
        } catch {
            try? fm.moveItem(at: old, to: app)
            throw error
        }
        return app
    }

    /// Quits, and opens `app` once we are gone.
    private func relaunch(_ app: URL) {
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = [
            "-c", #"while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$1""#,
            String(ProcessInfo.processInfo.processIdentifier), app.path,
        ]
        do {
            try shell.run()
        } catch {
            inform("Naut was updated.", "Open it again to use the new version.")
        }
        NSApp.terminate(nil)
    }

    /// The new bundle must be intact, be Naut, and, if this copy was
    /// signed by a developer, be signed by the same one.
    nonisolated static func verify(_ new: URL, replacing current: URL) throws {
        guard let id = Bundle(url: new)?.bundleIdentifier, id == Bundle(url: current)?.bundleIdentifier else {
            throw UpdateError.notNaut
        }
        let newTeam = try team(of: new, validate: true)
        if let currentTeam = try? team(of: current, validate: false), currentTeam != newTeam {
            throw UpdateError.signature
        }
    }

    /// The signing team, or nil for an ad-hoc signature.
    nonisolated static func team(of bundle: URL, validate: Bool) throws -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signature
        }
        if validate {
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw UpdateError.signature }
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else {
            throw UpdateError.signature
        }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - GitHub

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        let tagName: String
        let htmlUrl: URL
        let assets: [Asset]
    }

    @concurrent
    nonisolated static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        // 404: nothing released yet.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noRelease }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    @concurrent
    nonisolated static func sha256(of file: URL) async throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a tool to the end, throwing with its output if it fails.
    @concurrent
    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe would block the tool forever.
        let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.tool(URL(filePath: tool).lastPathComponent, output)
        }
        return output
    }

    // MARK: - Windows

    private func showProgress(_ text: String) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let label = NSTextField(labelWithString: text)
            let stack = NSStackView(views: [spinner, label])
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
            panel.contentView = stack
            panel.center()
            self.panel = panel
            self.label = label
        }
        label?.stringValue = text
        panel?.makeKeyAndOrderFront(nil)
    }

    private func hideProgress() {
        panel?.orderOut(nil)
    }

    private func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    private func fail(_ message: String, _ error: any Error, release: Release?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = (error as? UpdateError)?.description ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        if release != nil { alert.addButton(withTitle: "Download Manually") }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn, let release {
            NSWorkspace.shared.open(release.htmlUrl)
        }
    }
}

enum UpdateError: Error, CustomStringConvertible {
    case noRelease, notABundle, notInstalled, readOnly(URL), noDiskImage, download, checksum, noApp, notNaut, signature
    case tool(String, String)

    var description: String {
        switch self {
        case .noRelease: "No release has been published yet."
        case .notABundle: "This copy of Naut isn’t an app bundle, so it can’t replace itself."
        case .notInstalled: "Move Naut to your Applications folder first, then check again."
        case let .readOnly(folder): "Naut can’t write to \(folder.path)."
        case .noDiskImage: "The release has no disk image."
        case .download: "The download failed."
        case .checksum: "The download is damaged: its checksum doesn’t match."
        case .noApp: "The disk image has no app in it."
        case .notNaut: "The disk image doesn’t hold Naut."
        case .signature: "The new version’s signature isn’t valid, or isn’t from the same developer."
        case let .tool(name, output): "\(name) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// vX.Y.Z, as the release workflow tags it.
struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        parts = [major, minor, patch]
    }

    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? string.dropFirst() : Substring(string)
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap(\.self)
    }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0 ..< max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: Version, b: Version) -> Bool {
        !(a < b) && !(b < a)
    }

    var description: String {
        parts.map(String.init).joined(separator: ".")
    }
}

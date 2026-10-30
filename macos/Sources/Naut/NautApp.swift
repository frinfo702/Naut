import AppKit
import NautKit
import SwiftUI

@main
struct NautApp: App {
    @State private var store = Store()

    init() {
        // Launched as a bare SwiftPM binary (swift run) there is no bundle
        // to make us a regular app; do it by hand so we get a Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { store.newNote() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .sidebar) {
                Button(store.showEditor ? "Hide Editor" : "Show Editor") {
                    withAnimation(.snappy(duration: Metrics.toggleDuration)) { store.showEditor.toggle() }
                }
                .keyboardShortcut("e")
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// Colours are read from the tokens in src/page.css through libnaut, so the
/// native chrome and the rendered note are one palette by construction.
/// Each adapts to light and dark. The token list is checked by a test in
/// src/c.zig.
enum Theme {
    static let bg = Color(token: "--bg")
    static let surface = Color(token: "--surface")
    static let guide = Color(token: "--guide")
    static let fg = Color(token: "--fg")
    static let fgDim = Color(token: "--fg-dim")
    /// The lit edge: brightest on top, fading down the sides.
    static let edge = LinearGradient(
        colors: [Color(token: "--edge-top"), Color(token: "--edge-bottom")],
        startPoint: .top,
        endPoint: .bottom
    )
}

enum Metrics {
    // MARK: - Sidebar
    static let sidebarWidth: CGFloat = 260
    static let sidebarPadding: CGFloat = 14
    static let rowHeight: CGFloat = 30
    static let outlineRowHeight: CGFloat = 26
    /// Width of the tree guide drawn before outline entries.
    static let guideWidth: CGFloat = 22
    static let guideTick: CGFloat = 10
    /// How far the outline drops in from when a note is selected.
    static let unfoldOffset: CGFloat = 6

    // MARK: - Search
    static let searchHeight: CGFloat = 34

    // MARK: - Editor
    static let editorFontSize: CGFloat = 13
    static let editorInset: CGFloat = 24

    // MARK: - Animation
    static let toggleDuration = 0.2 // fast enough to feel instant, slow enough to track
    static let unfoldDuration = 0.22 // Rex's docs nav folds in about 0.2s
}

extension Color {
    /// A token from page.css. Both schemes are resolved once, up front;
    /// the dynamic provider runs on every redraw and must stay cheap.
    init(token: String) {
        func resolve(dark: Bool) -> NSColor {
            guard let c = Tokens.color(token, dark: dark) else {
                assertionFailure("missing colour token \(token)")
                return .magenta
            }
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
        let dark = resolve(dark: true)
        let light = resolve(dark: false)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

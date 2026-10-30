import AppKit
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

/// Colours mirror the tokens in src/page.css so the native chrome and the
/// rendered note read as one surface. Each adapts to light and dark.
enum Theme {
    static let bg = Color(dark: 0x111211, light: 0xFBFBF9)
    static let surface = Color(dark: 0x1A1B1A, light: 0xF3F3F0)
    static let line = Color(dark: 0x2C2D2B, light: 0xE0E0DB)
    static let guide = Color(dark: 0x3E3F3C, light: 0xCFCFCA)
    static let fg = Color(dark: 0xF1F1EE, light: 0x161715)
    static let fgDim = Color(dark: 0x8B8D87, light: 0x7A7C76)
    static let accent = Color(dark: 0xF2876A, light: 0xC8502D)
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
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

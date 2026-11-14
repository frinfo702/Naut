import AppKit
import NautKit
import SwiftUI

@main
struct NautApp: App {
    @State private var store = Store()

    init() {
        // Launched as a bare SwiftPM binary (swift run) there is no bundle
        // to make us a regular app; do it by hand so we get a Dock icon.
        // Test runs stay in the background instead: see Headless.
        if Snapshot.isHarness {
            Headless.install()
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { undoManager()?.undo() }
                    .keyboardShortcut("z")
                Button("Redo") { undoManager()?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Note") { store.newNote() }
                    .keyboardShortcut("n")
            }
            // ⌘W is the menu's, not a hidden button's: those came and went
            // with the panes, and the window's Close took ⌘W meanwhile.
            CommandGroup(replacing: .saveItem) {
                Button("Close") {
                    // Settings closes as a window; the image viewer takes
                    // its own ⌘W before the menu.
                    if let key = NSApp.keyWindow, key.identifier?.rawValue.contains("Settings") == true {
                        key.performClose(nil)
                    } else {
                        store.closePaneOrTab()
                    }
                }
                .keyboardShortcut("w")
            }
            CommandGroup(after: .sidebar) {
                Button("Split Right") { store.splitAnimated(.right) }
                    .keyboardShortcut("d")
                    .disabled(!store.canSplit(.right))
                Button("Split Down") { store.splitAnimated(.down) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!store.canSplit(.down))
                Button(store.floating[store.focus] == nil ? "Float Pane" : "Stop Floating") { store.toggleFloat() }
                Button(store.maximized == store.focus ? "Restore Pane" : "Maximize Pane") { store.toggleMaximize() }
                Divider()
                Button(store.showSidebar ? "Hide Sidebar" : "Show Sidebar") { store.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    .disabled(store.zen)
                Button(store.zen ? "Leave Zen Mode" : "Enter Zen Mode") { store.toggleZen() }
                    .keyboardShortcut("z", modifiers: [.control, .command])
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }

    /// The focused editor's undo manager. SwiftUI's TextEditor keeps one,
    /// but it doesn't answer the Edit menu's `undo:` action, so the menu
    /// items stay disabled unless we call the manager ourselves. Live
    /// Preview keeps the source's history apart from TextKit's.
    private func undoManager() -> UndoManager? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let live = window?.firstResponder as? LiveTextView { return live.history }
        return (window?.firstResponder as? NSTextView)?.undoManager
    }
}

/// Colours come from the light or dark theme the user picked in Settings.
/// The app's own Naut themes mirror the tokens in src/page.css, so the
/// native chrome and the rendered note stay one palette.
enum Theme {
    // Computed, not stored: a stored Color captures the theme it was made
    // in, so picking another one would repaint nothing.
    static var bg: Color { Color(token: .bg) }
    static var surface: Color { Color(token: .surface) }
    static var surfaceRaised: Color { Color(token: .surfaceRaised) }
    static var line: Color { Color(token: .line) }
    static var guide: Color { Color(token: .guide) }
    static var fg: Color { Color(token: .fg) }
    static var fgBody: Color { Color(token: .fgBody) }
    static var fgDim: Color { Color(token: .fgDim) }
    static var cursor: Color { Color(nsColor: .themeCursor) }
    /// One of the theme's eight ANSI-ordered swatches: 2 is green, 4 blue.
    static func swatch(_ index: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ThemeSelection.palette(dark: dark).swatches[index].nsColor
        })
    }

    /// The lit edge: brightest on top, fading down the sides.
    static var edge: LinearGradient {
        LinearGradient(
            colors: [Color(token: .edgeTop), Color(token: .edgeBottom)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

enum Metrics {
    // MARK: - Window

    /// Space between the floating panels and around them, as in Rex.
    static let panelGap: CGFloat = 8
    /// Concentric with the window: its corner radius less the gap. Windows
    /// are rounder from macOS 26 on.
    static let panelRadius: CGFloat = if #available(macOS 26.0, *) { 18 } else { 14 }
    /// Concentric again: the panel's radius less the sidebar's padding.
    static let rowRadius: CGFloat = panelRadius - 8
    /// How far the note's text fades out under the panel header.
    static let scrollFade: CGFloat = 18
    static let titleBarHeight: CGFloat = 44
    /// Room for the traffic lights before the title bar's own content.
    static let trafficLightsWidth: CGFloat = 78
    static let panelHeaderHeight: CGFloat = 44
    /// Long note names in a tab are cut after this many characters.
    static let tabMaxCharacters = 24
    /// How much of the theme's background Glass keeps over the desktop.
    static let glassOpacity: Double = 0.62
    /// How dark the window goes behind the command palette.
    static let scrimOpacity: Double = 0.35

    // MARK: - Sidebar

    static let sidebarWidth: CGFloat = 260
    static let sidebarPadding: CGFloat = 14
    static let rowHeight: CGFloat = 30
    static let outlineRowHeight: CGFloat = 26
    /// How many recently opened notes the sidebar lists.
    static let recentShown = 5
    /// Width of the tree guide drawn before outline entries.
    static let guideWidth: CGFloat = 22
    static let guideTick: CGFloat = 10
    /// How far the outline drops in from when a note is selected.
    static let unfoldOffset: CGFloat = 6
    /// A new note's row starts this far left of its place, and its page
    /// this far below.
    static let arriveSlide: CGFloat = 8
    static let arriveRise: CGFloat = 18

    // MARK: - Search

    static let searchHeight: CGFloat = 34

    // MARK: - Editor

    static let editorFontSize: CGFloat = 13
    static let editorInset: CGFloat = 24
    /// Body text in the preview and live editor, as in page.css.
    static let textFontSize: CGFloat = 17
    /// The default text font when installed, first in page.css's --font.
    /// It's commercial, so it isn't shipped; without it, the system font.
    static let textFamily = "Suisse Intl"
    /// Line length of the live editor, page.css's --measure.
    static let measure: CGFloat = 760

    // MARK: - Animation

    static let pressDuration = 0.16 // long enough to see, short enough not to wait for
    static let toggleDuration = 0.2 // fast enough to feel instant, slow enough to track
    static let unfoldDuration = 0.22 // Rex's docs nav folds in about 0.2s
    /// A new note arriving: slower than a toggle and with a little
    /// overshoot, since it happens rarely and is worth noticing.
    static let arriveSpring = Spring(duration: 0.45, bounce: 0.3)
    static let arrive = Animation.spring(arriveSpring)
    /// A pane splitting off, maximizing or floating: no overshoot, since
    /// panes that bounce past their edge read as jitter, not motion.
    static let paneSplit = Animation.smooth(duration: 0.3)
    static let paneCloseDuration = 0.25
    /// How much of itself a pane without the focus keeps.
    static let unfocusedPaneOpacity = 0.6
    /// The least a pane can be, by splitting or by a divider. As wide as
    /// its header needs to show every control beside a short title and
    /// the star; as tall as the header and a few lines of text.
    static let paneMinWidth: CGFloat = 264
    static let paneMinHeight: CGFloat = 140
    /// The grip that shows on a divider under the pointer.
    static let gripLength: CGFloat = 36
    /// A pane control's square in the header.
    static let paneControl: CGFloat = 26
    /// The blur of the shadow under a floating pane.
    static let floatShadow: CGFloat = 24
}

extension Color {
    /// A token from page.css. Both schemes are resolved once, up front;
    /// the dynamic provider runs on every redraw and must stay cheap.
    init(token: ThemeToken) {
        self.init(nsColor: NSColor(token: token))
    }
}

extension NSColor {
    /// A token from the current theme, resolved on each draw so picking a
    /// theme repaints existing views without rebuilding them. The provider
    /// can be called off the main thread; ThemeSelection locks.
    convenience init(token: ThemeToken) {
        self.init(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard let color = ThemeSelection.palette(dark: dark).color(token) else {
                assertionFailure("missing colour token \(token.rawValue)")
                return .magenta
            }
            return color.nsColor
        }
    }
}

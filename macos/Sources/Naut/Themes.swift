import AppKit
import NautKit
import SwiftUI

/// The user's light and dark theme choices, and where a dynamic colour
/// reads them from. A lock because NSColor may resolve a colour while
/// drawing; that is normally main-actor work, but not guaranteed.
enum ThemeSelection {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var light = ThemePalette.nautLight
    nonisolated(unsafe) private static var dark = ThemePalette.nautDark

    static func palette(dark: Bool) -> ThemePalette {
        lock.lock()
        defer { lock.unlock() }
        return dark ? self.dark : light
    }

    @MainActor
    static func select(light: ThemePalette, dark: ThemePalette, redraw: Bool = true) {
        lock.lock()
        self.light = light
        self.dark = dark
        lock.unlock()
        guard redraw else { return }
        // Dynamic NSColors resolve again on the next draw, and SwiftUI
        // resolves its colours lazily too, so marking the views dirty is
        // enough to repaint the chrome and the editor in place.
        for window in NSApp.windows {
            window.viewsNeedDisplay = true
            window.contentView?.needsDisplay = true
            window.contentView?.layer?.setNeedsDisplay()
        }
    }
}

extension ThemeColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Color {
    init(theme color: ThemeColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension NSColor {
    /// The caret colour from the current theme, resolved on each draw.
    static var themeCursor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ThemeSelection.palette(dark: dark).cursor.nsColor
        }
    }
}

private struct ThemeRevisionKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Bumped when the theme changes. Views that draw the chrome read it,
    /// so they repaint even when none of their own inputs changed.
    var themeRevision: Int {
        get { self[ThemeRevisionKey.self] }
        set { self[ThemeRevisionKey.self] = newValue }
    }
}

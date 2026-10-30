import AppKit
import WebKit

/// `Naut --snapshot out.png [--light] [--note Name] [--settings pane]`
/// renders the main window (or the settings window, opened on `pane`) to
/// a PNG and quits.
///
/// This exists so changes to the UI can be checked without a person
/// looking: screencapture needs Screen Recording permission, which agents
/// and CI don't have, but drawing our own view hierarchy needs nothing.
/// The window is sized to `size` so snapshots are comparable run to run.
enum Snapshot {
    static let size = NSSize(width: 1200, height: 760)

    /// How long to let SwiftUI settle and WebKit paint before capturing.
    /// WebKit gives no "painted" callback that covers our innerHTML swap.
    static let settle: Duration = .seconds(1.5)

    static var path: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// The note to select before capturing, by name.
    static var note: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--note"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var settingsPane: SettingsPane? {
        let args = CommandLine.arguments
        guard path != nil, let i = args.firstIndex(of: "--settings"), i + 1 < args.count else { return nil }
        return SettingsPane(rawValue: args[i + 1])
    }

    /// The appearance a snapshot is taken in, overriding the user's
    /// setting. Dark unless --light.
    static var forcedAppearance: NSAppearance? {
        guard path != nil else { return nil }
        return NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
    }

    @MainActor static func capture(to path: String) async {
        // The content view's superview is the window's frame view, which
        // includes the title bar and toolbar.
        try? await Task.sleep(for: settle)
        let settings = settingsPane != nil
        // SwiftUI names the Settings window's identifier after the scene.
        let isSettings = { (w: NSWindow) in w.identifier?.rawValue.contains("Settings") == true }
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView != nil && $0.identifier != MathImages.windowID && isSettings($0) == settings
        }),
              let view = window.contentView?.superview ?? window.contentView
        else { fail("no window to capture") }

        if !settings {
            window.setContentSize(size)
            try? await Task.sleep(for: settle)
        }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)

        // cacheDisplay doesn't capture WKWebView, which draws in its own
        // process. Ask WebKit for its pixels and draw them where the view is.
        for web in view.descendants(of: WKWebView.self) {
            guard let image = try? await web.takeSnapshot(configuration: nil) else { continue }
            let frame = web.convert(web.bounds, to: view)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // The bitmap is unflipped; view coordinates may be flipped.
            let rect = view.isFlipped
                ? NSRect(x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height)
                : frame
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let png = rep.representation(using: .png, properties: [:]) else { fail("png encoding") }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fail("could not write \(path): \(error.localizedDescription)")
        }
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("naut: snapshot failed: \(message)\n".utf8))
        exit(1)
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            if let match = view as? T { return [match] }
            return view.descendants(of: type)
        }
    }
}

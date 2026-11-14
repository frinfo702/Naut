import AppKit
import NautKit
import WebKit

/// Images for the live editor: math and tables drawn by the same libnaut
/// HTML and page.css as the preview, so they look the same in both, and
/// pictures a note embeds. One offscreen web view renders one snippet at
/// a time; results are cached for the life of the app.
@MainActor
final class LiveImages: NSObject, WKNavigationDelegate {
    static let shared = LiveImages()
    /// Posted when an image is ready; editors lay out again.
    static let didRender = Notification.Name("LiveImagesDidRender")
    /// Snapshot skips this window.
    static let windowID = NSUserInterfaceItemIdentifier("naut.render")

    /// A Markdown snippet rendered as the page would.
    struct Key: Hashable {
        let markdown: String
        /// The width to lay out in; nil shrinks to fit (math).
        let width: Double?
        let size: Double
        let dark: Bool
    }

    private var cache: [Key: NSImage] = [:]
    /// How far below its text's baseline each image reaches, in points.
    private var depths: [Key: CGFloat] = [:]
    /// Keys queued, rendering, or failed, so none is asked for twice.
    private var seen: Set<Key> = []
    private var queue: [Key] = []
    private var loaded = false
    private var running = false

    private lazy var web: WKWebView = {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        // WebKit only paints in a window; park one off screen.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1600, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.identifier = Self.windowID
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.contentView = web
        window.orderFrontRegardless()
        web.loadHTMLString(Markdown.page("", title: "", toc: false), baseURL: nil)
        return web
    }()

    /// The image if it's ready; otherwise starts rendering it and
    /// returns nil, and `didRender` follows.
    func image(_ key: Key) -> NSImage? {
        if let image = cache[key] { return image }
        if seen.insert(key).inserted {
            queue.append(key)
            pump()
        }
        return nil
    }

    /// How far the rendered image reaches below the baseline of the text
    /// in it: inline math sits on the line's baseline by this, as on the
    /// page. Nil until the image is ready.
    func depth(_ key: Key) -> CGFloat? { depths[key] }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        pump()
    }

    private func pump() {
        guard loaded else {
            _ = web
            return
        }
        guard !running, !queue.isEmpty else { return }
        running = true
        let key = queue.removeFirst()
        Task {
            // A failure stays in `seen`, so a broken formula isn't retried
            // per keystroke; the editor keeps showing its source.
            if let (image, depth) = await render(key) {
                cache[key] = image
                depths[key] = depth
            }
            running = false
            NotificationCenter.default.post(name: Self.didRender, object: nil)
            pump()
        }
    }

    private func render(_ key: Key) async -> (NSImage, CGFloat)? {
        let html = Markdown.render(key.markdown).html
        // prefers-color-scheme follows the view's appearance.
        web.appearance = NSAppearance(named: key.dark ? .darkAqua : .aqua)
        let script = """
            document.documentElement.style.background = "transparent";
            document.body.style.cssText = "margin:0;padding:0;background:transparent;font-size:" + size + "px";
            const main = document.querySelector("main");
            main.style.maxWidth = "none";
            main.innerHTML = '<div id="m" style="display:' + (width ? 'block;width:' + width + 'px;padding:2px 0' : 'inline-block;padding:2px 1px') + '">' + html + '</div>';
            main.querySelectorAll("p, div.math, math, div.table").forEach(e => e.style.margin = "0");
            const math = main.querySelector("math, .math, .katex, mjx-container");
            // Inline, the picture is the formula alone, a pixel around it
            // for what a glyph draws past its box: its paragraph's line
            // box has that line's leading above and below, and a line
            // with the picture in it stood taller, and lower, by as much.
            let r = document.getElementById("m").getBoundingClientRect();
            if (!width && math) {
                const f = math.getBoundingClientRect();
                const left = Math.floor(f.left) - 1, top = Math.floor(f.top) - 1;
                r = new DOMRect(left, top, Math.ceil(f.right) + 1 - left, Math.ceil(f.bottom) + 1 - top);
            }
            // The baseline: an empty inline-block's bottom sits on it. Put
            // after the formula only while measured, so the snapshot is
            // without it.
            const probe = document.createElement("span");
            probe.style.cssText = "display:inline-block;width:0;height:0;vertical-align:baseline";
            if (math) math.after(probe); else document.getElementById("m").append(probe);
            const baseline = probe.getBoundingClientRect().bottom;
            probe.remove();
            return [r.left, r.top, r.width, r.height, r.bottom - baseline];
            """
        guard let r = try? await web.callAsyncJavaScript(script, arguments: ["html": html, "size": key.size, "width": key.width ?? 0], contentWorld: .page) as? [Double],
              r.count == 5, r[2] > 0, r[3] > 0
        else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: r[0], y: r[1], width: ceil(r[2]), height: ceil(r[3]))
        config.afterScreenUpdates = true
        guard let image = try? await web.takeSnapshot(configuration: config) else { return nil }
        return (image, CGFloat(r[4]))
    }

    // MARK: - Pictures

    private var pictures: [URL: NSImage] = [:]
    private var fetching: Set<URL> = []

    /// A picture by URL: a file loads now, the web loads in the
    /// background and `didRender` follows. Nil while loading or if it
    /// can't be read; the editor shows the Markdown then.
    func picture(_ url: URL) -> NSImage? {
        if let image = pictures[url] { return image }
        if url.isFileURL {
            guard let image = NSImage(contentsOf: url) else { return nil }
            pictures[url] = image
            return image
        }
        guard fetching.insert(url).inserted else { return nil }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                pictures[url] = image
                NotificationCenter.default.post(name: Self.didRender, object: nil)
            }
        }
        return nil
    }
}

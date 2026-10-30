import NautKit
import SwiftUI
import WebKit

/// The rendered note. Loads libnaut's page template once, then on each
/// edit replaces only the contents of `<main>`. Reloading
/// the page per keystroke would flash white and lose the scroll position.
struct Preview: NSViewRepresentable {
    /// The rendered note body, from `Markdown.render`.
    let html: String
    let baseURL: URL
    let style: Style
    @Binding var scrollTarget: String?

    /// The user's font settings, applied over page.css's defaults. An
    /// empty family keeps the stylesheet's own stack.
    struct Style: Equatable {
        var textFont: String
        var textSize: Double
        var sourceFont: String
        var lineHeight: Double

        var script: String {
            func stack(_ family: String, _ fallback: String) -> String {
                family.isEmpty ? "" : "\"\(family)\", \(fallback)"
            }
            let json = (try? JSONEncoder().encode([
                stack(textFont, "-apple-system, sans-serif"),
                stack(sourceFont, "ui-monospace, monospace"),
                "\(textSize)px",
                "\(lineHeight)",
            ])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            return """
                (() => {
                  const [font, mono, size, lineHeight] = \(json);
                  const s = document.documentElement.style;
                  s.setProperty("--font", font);
                  s.setProperty("--mono", mono);
                  document.body.style.fontSize = size;
                  document.body.style.lineHeight = lineHeight;
                })()
                """
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        // Show the window background, not white, until the page paints.
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        // baseURL makes relative image paths resolve against the notes folder.
        view.loadHTMLString(Markdown.page("", title: "", toc: false), baseURL: baseURL)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.apply(style, in: view)
        context.coordinator.show(html, in: view)
        if let id = scrollTarget {
            context.coordinator.scroll(to: id, in: view)
            DispatchQueue.main.async { scrollTarget = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded = false
        private var pending: String?
        private var shown: String?
        private var style: Style?
        private var styled: Style?

        func apply(_ style: Style, in view: WKWebView) {
            self.style = style
            guard loaded, style != styled else { return }
            styled = style
            view.evaluateJavaScript(style.script)
        }

        func show(_ html: String, in view: WKWebView) {
            guard html != shown else { return }
            guard loaded else {
                pending = html
                return
            }
            shown = html
            let json = (try? String(data: JSONEncoder().encode(html), encoding: .utf8)) ?? "\"\""
            view.evaluateJavaScript("""
                (() => {
                  const main = document.querySelector("main");
                  main.innerHTML = \(json);
                  naut.enhance(main);
                })()
                """)
        }

        func scroll(to id: String, in view: WKWebView) {
            let json = (try? String(data: JSONEncoder().encode(id), encoding: .utf8)) ?? "\"\""
            view.evaluateJavaScript("document.getElementById(\(json))?.scrollIntoView({behavior: 'smooth'})")
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let style { apply(style, in: view) }
            if let html = pending {
                pending = nil
                show(html, in: view)
            }
        }

        /// Links open in the browser; in-page anchors scroll as usual.
        func webView(
            _ view: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                return decisionHandler(.allow)
            }
            if url.fragment != nil, url.absoluteString.hasPrefix(view.url?.absoluteString ?? "\u{0}") {
                return decisionHandler(.allow)
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

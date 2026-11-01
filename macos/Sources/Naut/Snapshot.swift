import AppKit
import NautKit
import WebKit

/// `Naut --snapshot out.png [--light] [--note Name] [--settings pane]
/// [--publish-popover] [--focus-editor [--caret N]]` renders the main
/// window (or the settings window, opened on `pane`, or the publish
/// popover) to a PNG and quits.
///
/// `Naut --caret-test` focuses the Live Preview body, then its title, and
/// fails if the body's caret survives the hand-off. It needs no person,
/// just a session where the app can be activated.
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

    /// `Naut --caret-test`: focus the note body, then its title, and fail
    /// if the body's caret survives the hand-off. The bug this covers:
    /// resignFirstResponder ran before the window installed the title's
    /// field editor, so the body caret stayed visible next to the title's.
    static var isCaretTest: Bool { CommandLine.arguments.contains("--caret-test") }
    static var isModalTest: Bool { CommandLine.arguments.contains("--modal-test") }

    /// `Naut --title-switch-test`: focus the Live Preview title, switch to
    /// another note, and fail if that note was renamed. The bug this
    /// covers: the title field outlived the switch and, when it lost
    /// focus, gave the new note the old note's title.
    static var isTitleSwitchTest: Bool { CommandLine.arguments.contains("--title-switch-test") }

    /// `Naut --math-edit-test --note Name`: type into the note's first
    /// display equation in place, and fail unless the note's source
    /// follows, the editor stays over its block, and Esc returns to the
    /// text. It edits the note: use a scratch one.
    static var isMathEditTest: Bool { CommandLine.arguments.contains("--math-edit-test") }

    /// `Naut --math-scroll-test --note Name`: with the note's last display
    /// equation open at the bottom of the window, type spaces and fail if
    /// the page moves. It edits the note: use a scratch one long enough
    /// to scroll, ending in a `$$` block.
    static var isMathScrollTest: Bool { CommandLine.arguments.contains("--math-scroll-test") }

    /// `Naut --dollar-test --note Name`: type a second `$` after a line's
    /// lone `$`, and fail unless that makes a closed equation, open for
    /// editing, without taking the text below into it. It edits the note:
    /// use a scratch one whose first `$` line is followed by more text.
    static var isDollarTest: Bool { CommandLine.arguments.contains("--dollar-test") }

    /// Any of the harnesses above. They open notes too, and must not change
    /// the user's tabs, favorites or recent notes.
    static var isHarness: Bool {
        path != nil || isCaretTest || isModalTest || isTitleSwitchTest || isMathEditTest || isMathScrollTest || isDollarTest
    }

    /// `Naut --snapshot out.png --publish-popover [--note Name]` captures
    /// the publish popover instead of the window.
    static var publishPopover: Bool { CommandLine.arguments.contains("--publish-popover") }

    /// Focus the Live Preview body before capturing, so its cursor is in
    /// the picture.
    static var focusEditor: Bool { CommandLine.arguments.contains("--focus-editor") }

    /// `--caret N` puts the focused editor's caret at display position N.
    static var caret: Int? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--caret"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    /// `--select A,B` selects the display range from A to B.
    static var selection: NSRange? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--select"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return NSRange(location: parts[0], length: max(0, parts[1] - parts[0]))
    }

    /// The caret test always runs the live editor; the modal test can run
    /// either editor, Live Preview by default.
    static var forcedEditorMode: Store.EditorMode? {
        if isCaretTest || isTitleSwitchTest || isMathEditTest || isMathScrollTest || isDollarTest { return .live }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--editor"), i + 1 < args.count,
           let mode = Store.EditorMode(rawValue: args[i + 1]) {
            return mode
        }
        return isModalTest ? .live : nil
    }

    /// The keymap the modal test runs with; Vim unless `--keymap` says
    /// otherwise.
    static var forcedKeymap: EditorKeymap? {
        guard isModalTest else { return nil }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--keymap"), i + 1 < args.count,
           let keymap = EditorKeymap(rawValue: args[i + 1]) {
            return keymap
        }
        return .vim
    }

    /// `--palette root|theme|search` opens the command palette on that
    /// scope before capturing.
    static var palette: CommandPalette.Scope? {
        let args = CommandLine.arguments
        guard path != nil, let i = args.firstIndex(of: "--palette"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "theme": return .theme
        case "search": return .search
        default: return .root
        }
    }

    /// `--query text` types into the palette before capturing.
    static var paletteQuery: String? {
        let args = CommandLine.arguments
        guard path != nil, let i = args.firstIndex(of: "--query"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `--glass` captures the window with the Glass background.
    static var forcedBackground: Store.WindowBackground? {
        guard path != nil else { return nil }
        return CommandLine.arguments.contains("--glass") ? .glass : .solid
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
            $0.isVisible && $0.contentView != nil && $0.identifier != LiveImages.windowID && isSettings($0) == settings
        }),
              let view = window.contentView?.superview ?? window.contentView
        else { fail("no window to capture") }

        if !settings {
            window.setContentSize(size)
            try? await Task.sleep(for: settle)
        }

        #if DEBUG
        if focusEditor { await focusEditorBody() }
        #endif

        // `--edit-math` opens the note's first display equation in place.
        if CommandLine.arguments.contains("--edit-math"),
           let body = window.contentView?.descendants(of: LiveTextView.self).first {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            body.editFirstMath?()
            try? await Task.sleep(for: settle)
        }

        if publishPopover {
            // The popover is its own window (a child of the main one).
            guard let popover = NSApp.windows.first(where: {
                $0.isVisible && $0.contentView != nil && $0 !== window
                    && $0.identifier?.rawValue.contains("Settings") != true
            }), let content = popover.contentView else {
                fail("no publish popover")
            }
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fail("no bitmap") }
            content.cacheDisplay(in: content.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { fail("png encoding") }
            do {
                try png.write(to: URL(fileURLWithPath: path))
            } catch {
                fail("could not write \(path): \(error.localizedDescription)")
            }
            exit(0)
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

#if DEBUG
    /// Show the live editor's cursor in a snapshot. A launched snapshot
    /// has no first responder, and the cursor is only drawn for the view
    /// being edited.
    @MainActor private static func focusEditorBody() async {
        guard let body = NSApp.windows.lazy.compactMap({
            $0.contentView?.descendants(of: CursorTextView.self).first
        }).first, let window = body.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where !window.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(50))
        }
        window.makeFirstResponder(body)
        let length = (body.string as NSString).length
        if let selection {
            let start = max(0, min(selection.location, length))
            let end = max(start, min(NSMaxRange(selection), length))
            // `stillSelecting` is the path a mouse drag takes. The
            // selection must be painted now, not when the button comes up.
            body.setSelectedRanges(
                [NSValue(range: NSRange(location: start, length: end - start))],
                affinity: .downstream,
                stillSelecting: true
            )
        } else {
            body.setSelectedRange(NSRange(location: max(0, min(caret ?? 0, length)), length: 0))
        }
        try? await Task.sleep(for: .milliseconds(100))
        body.testShowInsertionIndicator()
    }

    @MainActor static func runModalTest() async {
        try? await Task.sleep(for: settle)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(100))

        guard let body = NSApp.windows.lazy.compactMap({
            $0.contentView?.descendants(of: CursorTextView.self).first
        }).first,
            let window = body.window
        else { fail("modal test: no editor") }
        window.makeKeyAndOrderFront(nil)

        for _ in 0..<20 where !window.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard window.isKeyWindow else { fail("modal test: window did not become key") }
        guard window.makeFirstResponder(body) else { fail("modal test: body did not take focus") }

        let original = body.string
        guard !original.isEmpty else { fail("modal test: the note is empty") }

        func send(_ characters: String, keyCode: UInt16 = 0) -> Bool {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) else { fail("modal test: could not make a key event") }
            return body.modalKey?(event) ?? false
        }

        func undo() {
            if let live = body as? LiveTextView {
                live.history?.undo()
            } else {
                body.undoManager?.undo()
            }
        }

        let keymap = forcedKeymap ?? .vim
        let display = original as NSString
        // Start where l can move: two text characters beside each other,
        // not a drawn block or a line break.
        var start = 0
        while start + 1 < display.length {
            let a = display.character(at: start)
            let b = display.character(at: start + 1)
            if a != 0x0A, b != 0x0A, a != LiveProjection.attachmentCharacter, b != LiveProjection.attachmentCharacter {
                break
            }
            start += 1
        }
        guard start + 1 < display.length else { fail("modal test: the note has no two text characters") }
        body.setSelectedRange(NSRange(location: start, length: 0))

        switch keymap {
        case .vim:
            guard send("l") else { fail("modal test: l was not handled") }
            guard body.selectedRange().location == start + 1 else { fail("modal test: l did not move the caret") }

            guard send("v") else { fail("modal test: v was not handled") }
            guard body.selectedRange().length == 1 else { fail("modal test: v did not select a character") }
            guard send("\u{1b}", keyCode: 53), body.selectedRange().length == 0 else {
                fail("modal test: Esc did not leave visual mode")
            }

            guard send("x") else { fail("modal test: x was not handled") }
            guard body.string != original else { fail("modal test: x did not delete") }
            undo()
            guard body.string == original else { fail("modal test: undo did not restore the note") }

            guard send("i"), body.resolvedCursorShape == .bar else {
                fail("modal test: insert mode is not a bar")
            }
            guard send("\u{1b}", keyCode: 53), body.resolvedCursorShape == .block else {
                fail("modal test: normal mode is not a block")
            }

            body.setSelectedRange(NSRange(location: 0, length: 0))
            let firstLine = (original as NSString).lineRange(for: NSRange(location: 0, length: 0))
            let afterFirstLine = (original as NSString).replacingCharacters(in: firstLine, with: "")
            guard send("d"), send("d") else { fail("modal test: dd was not handled") }
            guard body.string == afterFirstLine else {
                fail("modal test: dd did not remove the whole line")
            }
            undo()
            guard body.string == original else { fail("modal test: undo did not restore dd") }

            // A linewise yank and paste: the Markdown line, hidden prefix
            // included, goes after the shown line and still reads the same.
            // A drawn block's lines merge when pasted next to themselves,
            // so this check wants a text line.
            if display.character(at: 0) != LiveProjection.attachmentCharacter {
                body.setSelectedRange(NSRange(location: 0, length: 0))
                let yankedLine = (original as NSString).lineRange(for: NSRange(location: 0, length: 0))
                let yankedDisplay = (original as NSString).substring(with: yankedLine)
                let pasted = (original as NSString).replacingCharacters(
                    in: NSRange(location: NSMaxRange(yankedLine), length: 0),
                    with: yankedDisplay.trimmingTrailingSpacesPerLine()
                )
                guard send("y"), send("y"), send("p") else { fail("modal test: yy p was not handled") }
                guard body.string == pasted else { fail("modal test: yy p did not paste a whole line") }
                undo()
                guard body.string == original else { fail("modal test: undo did not restore yy p") }
            }

        case .helix:
            guard send("w") else { fail("modal test: w was not handled") }
            guard body.selectedRange().length > 0 else { fail("modal test: w did not select a word") }
            guard send("d") else { fail("modal test: d was not handled") }
            guard body.string != original else { fail("modal test: d did not delete the selection") }
            undo()
            guard body.string == original else { fail("modal test: undo did not restore the note") }

            body.setSelectedRange(NSRange(location: 0, length: 0))
            let firstLine = (original as NSString).lineRange(for: NSRange(location: 0, length: 0))
            let afterFirstLine = (original as NSString).replacingCharacters(in: firstLine, with: "")
            guard send("x"), send("d") else { fail("modal test: x d was not handled") }
            guard body.string == afterFirstLine else {
                fail("modal test: x d did not remove the whole line")
            }
            undo()
            guard body.string == original else { fail("modal test: undo did not restore x d") }

        case .normal:
            fail("modal test: --keymap must be vim or helix")
        }

        body.setSelectedRange(NSRange(location: 0, length: 0))
        exit(0)
    }

    @MainActor static func runCaretTest() async {
        // Let SwiftUI build the live editor, then give the window focus.
        // The snapshot app was launched from a terminal, so it has to ask
        // for focus explicitly.
        try? await Task.sleep(for: settle)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(100))

        guard let body = NSApp.windows.lazy.compactMap({
            $0.contentView?.descendants(of: LiveTextView.self).first
        }).first,
            let window = body.window,
            let title = body.titleField
        else { fail("caret test: no live editor") }

        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where !window.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard window.isKeyWindow else { fail("caret test: window did not become key") }
        guard window.makeFirstResponder(body) else { fail("caret test: body did not take focus") }
        body.setSelectedRange(NSRange(location: 0, length: 0))

        body.testShowInsertionIndicator()
        guard !body.testInsertionHidden else { fail("caret test: body caret did not appear") }

        // The hand-off that used to leave two carets.
        title.selectText(nil)
        try? await Task.sleep(for: .milliseconds(50))
        guard title.currentEditor() != nil else { fail("caret test: title did not begin editing") }
        guard window.isKeyWindow else { fail("caret test: window lost key") }
        guard body.testInsertionHidden else { fail("caret test: body caret survived the title hand-off") }

        // And it must come back when focus returns to the note.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where !window.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard window.makeFirstResponder(body), window.firstResponder === body else {
            fail("caret test: body did not retake focus")
        }
        body.setSelectedRange(NSRange(location: 0, length: 0))
        try? await Task.sleep(for: .milliseconds(50))
        guard !body.testInsertionHidden else { fail("caret test: body caret did not return") }
        exit(0)
    }
#endif

    @MainActor static func runTitleSwitchTest(store: Store) async {
        try? await Task.sleep(for: settle)
        guard store.notes.count >= 2 else { fail("title switch test: needs two notes") }
        let first = store.notes[0], second = store.notes[1]
        store.selection = first.id
        try? await Task.sleep(for: .milliseconds(300))
        NSApp.activate(ignoringOtherApps: true)
        guard let body = NSApp.windows.lazy.compactMap({
            $0.contentView?.descendants(of: LiveTextView.self).first
        }).first, let window = body.window, let title = body.titleField
        else { fail("title switch test: no live editor") }
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where !window.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Editing the first note's title, unchanged, when the second opens.
        title.selectText(nil)
        try? await Task.sleep(for: .milliseconds(50))
        guard title.currentEditor() != nil else { fail("title switch test: title did not begin editing") }
        store.selection = second.id
        try? await Task.sleep(for: .milliseconds(300))
        window.makeFirstResponder(body)
        try? await Task.sleep(for: .milliseconds(300))

        let names = Set(store.notes.map(\.name))
        guard names.contains(first.name), names.contains(second.name) else {
            fail("title switch test: a note was renamed (\(first.name), \(second.name) → \(names.sorted()))")
        }
        exit(0)
    }

    @MainActor static func runMathEditTest(store: Store) async {
        try? await Task.sleep(for: settle)
        guard store.text.contains("$$") else { fail("math edit test: the note has no display equation") }
        NSApp.activate(ignoringOtherApps: true)
        guard let body = NSApp.windows.lazy.compactMap({ $0.contentView?.descendants(of: LiveTextView.self).first }).first,
              let window = body.window
        else { fail("math edit test: no live editor") }
        window.makeKeyAndOrderFront(nil)
        body.editFirstMath?()
        try? await Task.sleep(for: .milliseconds(300))
        guard let editor = body.descendants(of: MathBlockEditor.self).first else { fail("math edit test: the editor did not open") }
        guard window.firstResponder === editor.source else { fail("math edit test: the source did not take focus") }
        let before = editor.frame

        // Two lines, so the block has to grow.
        editor.source.insertText("\\\\ y = 1", replacementRange: editor.source.selectedRange())
        // The binding reaches the store on its own schedule; wait for it.
        for _ in 0..<40 where !store.text.contains("\\\\ y = 1") {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard store.text.contains("\\\\ y = 1") else { fail("math edit test: the note's source did not follow the edit") }
        guard editor.superview === body, editor.frame.minY == before.minY else {
            fail("math edit test: the editor left its block (\(before) → \(editor.frame))")
        }

        editor.source.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try? await Task.sleep(for: .milliseconds(300))
        guard body.descendants(of: MathBlockEditor.self).isEmpty else { fail("math edit test: Esc did not close the editor") }
        guard window.firstResponder === body else { fail("math edit test: Esc did not return to the text") }
        exit(0)
    }

    @MainActor static func runMathScrollTest(store: Store) async {
        try? await Task.sleep(for: settle)
        NSApp.activate(ignoringOtherApps: true)
        guard let body = NSApp.windows.lazy.compactMap({ $0.contentView?.descendants(of: LiveTextView.self).first }).first,
              let window = body.window, let scroll = body.enclosingScrollView
        else { fail("math scroll test: no live editor") }
        window.makeKeyAndOrderFront(nil)
        // To the bottom, where the equation is, then into it.
        if let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        body.editFirstMath?()
        try? await Task.sleep(for: .seconds(1))
        guard let editor = body.descendants(of: MathBlockEditor.self).first else { fail("math scroll test: the editor did not open") }
        let settled = scroll.contentView.bounds.origin.y
        let box = editor.convert(editor.bounds, to: scroll.documentView)
        guard box.maxY <= scroll.contentView.bounds.maxY + 1, box.minY >= settled - 1 else {
            fail("math scroll test: the editor opened out of view (\(box), visible \(scroll.contentView.bounds))")
        }
        // Every place the page is scrolled to while typing, not just where
        // it ends up: a moment somewhere else is the shake.
        final class Seen { var y: [CGFloat] = [] }
        let seen = Seen()
        scroll.contentView.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { n in
            seen.y.append((n.object as! NSView).bounds.origin.y)
        }
        for _ in 0..<6 {
            editor.source.insertText(" ", replacementRange: editor.source.selectedRange())
            try? await Task.sleep(for: .milliseconds(300))
        }
        NotificationCenter.default.removeObserver(observer)
        seen.y.append(scroll.contentView.bounds.origin.y)
        guard seen.y.allSatisfy({ abs($0 - settled) < 1 }) else {
            fail("math scroll test: the page moved while typing: \(settled) → \(seen.y)")
        }
        exit(0)
    }

    @MainActor static func runDollarTest(store: Store) async {
        try? await Task.sleep(for: settle)
        NSApp.activate(ignoringOtherApps: true)
        guard let body = NSApp.windows.lazy.compactMap({ $0.contentView?.descendants(of: LiveTextView.self).first }).first,
              let window = body.window
        else { fail("dollar test: no live editor") }
        window.makeKeyAndOrderFront(nil)
        let lines = store.text.components(separatedBy: "\n")
        guard let dollar = lines.firstIndex(of: "$"), dollar + 1 < lines.count else { fail("dollar test: the note has no line of a lone $") }
        let below = lines[(dollar + 1)...].joined(separator: "\n")
        // Plain lines before it: the display is the source up to there.
        let at = (lines[...dollar].joined(separator: "\n") as NSString).length
        guard window.makeFirstResponder(body) else { fail("dollar test: body did not take focus") }
        body.setSelectedRange(NSRange(location: at, length: 0))
        body.insertText("$", replacementRange: body.selectedRange())
        for _ in 0..<40 where body.descendants(of: MathBlockEditor.self).isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard store.text.contains("$$\n\n$$\n" + below) else {
            fail("dollar test: `$$` did not make a closed, empty equation above the text: \(store.text.debugDescription)")
        }
        guard !body.descendants(of: MathBlockEditor.self).isEmpty else { fail("dollar test: the equation did not open for editing") }
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

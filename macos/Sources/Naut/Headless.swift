import AppKit
import ObjectiveC

/// Test runs (`Snapshot.isHarness`) must not take the keyboard from
/// whoever is working at the Mac. They used to activate the app so their
/// window became key: the caret, the selection colour and some tests
/// depend on that. Instead, the app stays inactive (no Dock icon, never
/// activated) and AppKit is told the window is key without it really
/// being so.
///
/// - `NSApplication.activate` does nothing, whoever calls it.
/// - `NSWindow.makeKey()` / `makeKeyAndOrderFront(_:)` record the window
///   as key and post the key notifications, as AppKit does for an active
///   app.
/// - `NSWindow.isKeyWindow` and `NSApplication.keyWindow` answer from
///   that record.
///
/// The tests drive the views directly (`insertText`, `doCommand`,
/// `NSApp.sendEvent`), so none of them needs real keyboard focus; only
/// the "is this window key?" answers do. Pictures come from
/// `cacheDisplay`, which needs no screen either.
@MainActor
enum Headless {
    /// The window AppKit is told is key.
    private(set) nonisolated(unsafe) weak static var key: NSWindow?

    static func install() {
        NSApplication.shared.setActivationPolicy(.accessory)

        // NSApplication.activate(ignoringOtherApps:) and activate()
        let ignore: @convention(block) (NSApplication, Bool) -> Void = { _, _ in }
        replace(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)), imp_implementationWithBlock(ignore))
        if #available(macOS 14, *) {
            let ignoreNoArg: @convention(block) (NSApplication) -> Void = { _ in }
            replace(NSApplication.self, #selector(NSApplication.activate as (NSApplication) -> () -> Void), imp_implementationWithBlock(ignoreNoArg))
        }

        // NSApplication.keyWindow
        let appKey: @convention(block) (NSApplication) -> NSWindow? = { _ in key }
        replace(NSApplication.self, #selector(getter: NSApplication.keyWindow), imp_implementationWithBlock(appKey))

        // NSApplication.isActive: active once a window is key, as when
        // the app was really activated (the traffic lights draw in colour).
        let isActive: @convention(block) (NSApplication) -> Bool = { _ in key != nil }
        replace(NSApplication.self, #selector(getter: NSApplication.isActive), imp_implementationWithBlock(isActive))

        // NSWindow.isKeyWindow and isMainWindow
        let isKey: @convention(block) (NSWindow) -> Bool = { $0 === key }
        replace(NSWindow.self, #selector(getter: NSWindow.isKeyWindow), imp_implementationWithBlock(isKey))
        replace(NSWindow.self, #selector(getter: NSWindow.isMainWindow), imp_implementationWithBlock(isKey))
        // The title bar (traffic lights, selection colour) asks AppKit's
        // private "active appearance" instead. Best effort: if a later
        // macOS renames it, the lights just draw grey.
        for name in ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus", "hasKeyAppearance", "hasMainAppearance"] {
            let sel = NSSelectorFromString(name)
            guard class_getInstanceMethod(NSWindow.self, sel) != nil else { continue }
            replace(NSWindow.self, sel, imp_implementationWithBlock(isKey))
        }

        // NSWindow.makeKey() and makeKeyAndOrderFront(_:)
        typealias MakeKey = @convention(c) (NSWindow, Selector) -> Void
        let makeKeySel = #selector(NSWindow.makeKey)
        let originalMakeKey = unsafeBitCast(method(NSWindow.self, makeKeySel), to: MakeKey.self)
        let makeKey: @convention(block) (NSWindow) -> Void = { window in
            originalMakeKey(window, makeKeySel)
            MainActor.assumeIsolated { become(window) }
        }
        replace(NSWindow.self, makeKeySel, imp_implementationWithBlock(makeKey))

        typealias OrderFront = @convention(c) (NSWindow, Selector, Any?) -> Void
        let orderFrontSel = #selector(NSWindow.makeKeyAndOrderFront(_:))
        let originalOrderFront = unsafeBitCast(method(NSWindow.self, orderFrontSel), to: OrderFront.self)
        let orderFront: @convention(block) (NSWindow, Any?) -> Void = { window, sender in
            originalOrderFront(window, orderFrontSel, sender)
            MainActor.assumeIsolated { become(window) }
        }
        replace(NSWindow.self, orderFrontSel, imp_implementationWithBlock(orderFront))
    }

    /// Make `window` the key window, as far as anyone asking can tell.
    private static func become(_ window: NSWindow) {
        guard key !== window, window.canBecomeKey else { return }
        let old = key
        key = window
        if let old {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: old)
            old.contentView?.superview?.needsDisplay = true
        }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        window.contentView?.superview?.needsDisplay = true
    }

    private static func method(_ cls: AnyClass, _ sel: Selector) -> IMP {
        guard let m = class_getInstanceMethod(cls, sel) else { fatalError("headless: no \(sel) on \(cls)") }
        return method_getImplementation(m)
    }

    private static func replace(_ cls: AnyClass, _ sel: Selector, _ imp: IMP) {
        guard let m = class_getInstanceMethod(cls, sel) else { fatalError("headless: no \(sel) on \(cls)") }
        // Put the method on `cls` itself, so a superclass's copy is untouched.
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(m)) {
            method_setImplementation(m, imp)
        }
    }
}

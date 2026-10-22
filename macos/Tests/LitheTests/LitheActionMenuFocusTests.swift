import AppKit
import SwiftUI
import Testing
@testable import Lithe

@Suite("Action menu focus", .serialized)
@MainActor
struct LitheActionMenuFocusTests {
    @Test func actionKeysRemainScopedToTheOwnerAndEscapeRestoresItsResponder() throws {
        let window = makeWindow()
        let editor = NSTextView(frame: window.contentView!.bounds)
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss(); window.contentView = nil; window.close() }
        var calls = 0
        presenter.show(items: [.action("Copy") { calls += 1 }], at: window.frame.origin,
                       appearance: nil, locale: Locale(identifier: "en"), parentWindow: window)
        #expect(window.isKeyWindow)
        #expect(window.firstResponder === editor)
        try sendKey(125, to: window)
        try sendKey(53, to: window)
        #expect(calls == 0 && !hasPopup(window))
        #expect(window.firstResponder === editor)
    }

    @Test func childActionsReceiveKeysBeforeTheSearchableParentsHandler() throws {
        let window = makeWindow()
        window.makeKeyAndOrderFront(nil)
        let parent = LitheContextMenuPresenter(), child = LitheContextMenuPresenter()
        defer { child.dismiss(); parent.dismiss(); window.contentView = nil; window.close() }
        var parentKeys = 0, childCalls = 0
        let content = NSHostingController(rootView: Text("Parent")
            .frame(width: 200, height: 120)
            .litheDropdownKeyHandler { _ in parentKeys += 1; return true })
        parent.show(contentController: content, at: window.frame.origin, appearance: nil, parentWindow: window, onDismiss: {})
        let parentPanel = try #require(window.childWindows?.first(where: { $0.isVisible }))
        #expect(parentPanel.isKeyWindow)
        child.show(items: [.action("Copy") { childCalls += 1 }], at: parentPanel.frame.origin,
                   appearance: nil, locale: Locale(identifier: "en"), parentWindow: parentPanel)
        #expect(parentPanel.isKeyWindow)
        try sendKey(125, to: parentPanel)
        try sendKey(36, to: parentPanel)
        #expect(childCalls == 1 && parentKeys == 0)
        #expect(!hasPopup(parentPanel) && parentPanel.isVisible)
    }

    @Test func losingOwnerFocusAndApplicationActivationDismissesTheMenu() {
        let window = makeWindow()
        window.makeKeyAndOrderFront(nil)
        let presenter = LitheContextMenuPresenter()
        defer { presenter.dismiss(); window.contentView = nil; window.close() }
        func show() {
            presenter.show(items: [.action("Copy") {}], at: window.frame.origin,
                           appearance: nil, locale: Locale(identifier: "en"), parentWindow: window)
        }
        show()
        #expect(hasPopup(window))
        window.resignKey()
        #expect(!hasPopup(window))
        window.makeKey()
        show()
        #expect(hasPopup(window))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!hasPopup(window))
    }

    private func makeWindow() -> NSWindow {
        let window = ActionMenuFocusWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 240),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func hasPopup(_ window: NSWindow) -> Bool {
        window.childWindows?.contains(where: { $0.isVisible }) == true
    }
    private func sendKey(_ code: UInt16, to window: NSWindow) throws {
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code)))
    }
}

// A nonactivating native host can become key in the isolated test process;
// it exercises real AppKit focus without activating a desktop application.
@MainActor
private final class ActionMenuFocusWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

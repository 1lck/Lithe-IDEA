import AppKit
import SwiftUI
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Centered product popup", .serialized)
struct LitheCenteredPopupTests {
    @MainActor
    @Test
    func dragAreaHandsTheOriginalMouseEventToTheWindowServer() throws {
        let window = PopupDragRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 42),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let dragArea = LithePopupDragArea.DragView(frame: NSRect(x: 0, y: 0, width: 200, height: 42))
        window.contentView = dragArea
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 80, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(dragArea.hitTest(NSPoint(x: 80, y: 20)) === dragArea)
        window.sendEvent(event)
        #expect(window.dragEvent === event)
    }

    @MainActor
    @Test
    func draggedPopupKeepsItsTopLeftDuringLayoutAndResetsOnReopen() {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let presenter = LitheCenteredPopupPresenter()
        presenter.topInset = 84
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 84))
        // A deterministic native fitting size avoids waiting for SwiftUI's layout transaction.
        let fitting = PopupFittingView(frame: content.view.frame)
        content.view = fitting
        defer { presenter.close(); parent.close() }
        presenter.show(contentController: content, parent: parent, onDismiss: {})
        guard let popup = content.view.window else { Issue.record("Popup was not attached"); return }
        let initial = popup.frame
        presenter.preservePosition()
        // The Window Server owns the drag; emulate only its resulting native frame here.
        popup.setFrameOrigin(NSPoint(x: initial.minX + 80, y: initial.minY - 50))
        let topLeft = NSPoint(x: popup.frame.minX, y: popup.frame.maxY)
        fitting.size = NSSize(width: 450, height: 350)
        presenter.center()
        #expect(popup.frame.minX == topLeft.x)
        #expect(popup.frame.maxY == topLeft.y)
        #expect(popup.frame.size == fitting.size)
        parent.setContentSize(NSSize(width: 1100, height: 850))
        presenter.center()
        #expect(popup.frame.minX == topLeft.x)
        #expect(popup.frame.maxY == topLeft.y)
        presenter.close()
        presenter.show(contentController: content, parent: parent, onDismiss: {})
        #expect(content.view.window?.frame.midX == parent.frame.midX)
        #expect(content.view.window?.frame.maxY == parent.frame.maxY - 84)
    }

    @MainActor
    @Test(arguments: [ColorScheme.dark, .light], ["en", "zh-Hans"])
    func projectOpenDialogUsesSharedTitledPopup(scheme: ColorScheme, language: String) async throws {
        MacBundledFontRegistry.registerFonts()
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let presenter = LitheCenteredPopupPresenter()
        defer { presenter.close(); parent.close() }
        var dismissals = 0
        let locale = Locale(identifier: language)
        let title = String(localized: "Open Project", locale: locale)
        let request = PendingProjectOpen(
            url: URL(fileURLWithPath: "/workspace/Lithe-Git-Terminal-Stress-vxw526dr"), sourceSessionID: UUID()
        )
        let host = NSHostingController(rootView: OpenProjectLocationDialog(
            request: request, onResolve: { _, _ in }, onCancel: {}
        ).environment(\.colorScheme, scheme).environment(\.locale, locale))
        presenter.show(contentController: host, parent: parent, dialogTitle: title) { dismissals += 1 }
        let panel = try #require(host.view.window)
        // SwiftUI settles the hosting view after attachment; capture the laid-out window.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while host.view.bounds.width == 0, clock.now < deadline { await Task.yield() }
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.title == title)
        #expect(parent.sheets.isEmpty)
        #expect(host.view.bounds.width == 470)
        // Capture the real native titlebar and SwiftUI controls, including localized wrapping.
        if let directory = ProcessInfo.processInfo.environment["LITHE_POPUP_CAPTURE_DIR"] {
            let frame = try #require(panel.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("open-project-\(language)-\(scheme == .dark ? "dark" : "light").png"))
        }
        panel.performClose(nil)
        #expect(!panel.isVisible)
        #expect(dismissals == 1)
    }

    @MainActor
    @Test(arguments: [ColorScheme.dark, .light])
    func commitDialogUsesTitledWindowAndExplicitDismissal(scheme: ColorScheme) async throws {
        MacBundledFontRegistry.registerFonts()
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let presenter = LitheCenteredPopupPresenter()
        defer { presenter.close(); parent.close() }
        var dismissals = 0
        let host = NSHostingController(rootView: GitChangelistDialog(name: .constant("New changelist"),
            error: nil, isDisabled: false,
            save: {}, cancel: {}).environment(\.colorScheme, scheme))
        presenter.show(contentController: host, parent: parent, dialogTitle: "New Changelist") { dismissals += 1 }
        let panel = try #require(host.view.window)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(panel.firstResponder is NSTextView), clock.now < deadline { await Task.yield() }
        #expect(panel.firstResponder is NSTextView)
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.hasShadow)
        #expect(!panel.styleMask.contains(.miniaturizable))
        #expect(panel.title == "New Changelist")
        #expect(host.view.bounds.width == 340)
        presenter.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        #expect(panel.isVisible)
        #expect(dismissals == 0)
        if let directory = ProcessInfo.processInfo.environment["LITHE_POPUP_CAPTURE_DIR"] {
            let frame = try #require(panel.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("commit-dialog-\(scheme == .dark ? "dark" : "light").png"))
        }
        panel.performClose(nil)
        #expect(!panel.isVisible)
        #expect(dismissals == 1)
    }

    @MainActor
    @Test(arguments: [ColorScheme.dark, .light])
    func focusedNewItemFieldBlendsIntoPopup(scheme: ColorScheme) async throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let presenter = LitheCenteredPopupPresenter()
        defer { presenter.close(); parent.close() }
        let contents: [(String, AnyView)] = [
            ("file", AnyView(ProjectItemNameDialogContent(request: ProjectItemEditRequest(kind: .createFile, targetURL: URL(fileURLWithPath: "/")), onSubmit: { _ in }, onCancel: {}))),
            ("directory", AnyView(ProjectItemNameDialogContent(request: ProjectItemEditRequest(kind: .createDirectory, targetURL: URL(fileURLWithPath: "/")), onSubmit: { _ in }, onCancel: {}))),
            ("folder", AnyView(LitheNamePopup(title: "New Folder", onSubmit: { _ in }, onCancel: {})))
        ]
        for (kind, content) in contents {
            let host = NSHostingController(rootView: content.environment(\.colorScheme, scheme))
            presenter.show(contentController: host, parent: parent, onDismiss: {})
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while !(host.view.window?.firstResponder is NSTextView), clock.now < deadline {
                await Task.yield()
            }
            #expect(host.view.window?.firstResponder is NSTextView, "Capture the focused input")
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.view.bounds.width
            let background = try #require(bitmap.colorAt(x: Int(280 * scale), y: Int(10 * scale))?.usingColorSpace(.sRGB))
            for y in 34...69 {
                let color = try #require(bitmap.colorAt(x: Int(280 * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB))
                #expect(abs(color.redComponent - background.redComponent) < 0.02)
                #expect(abs(color.greenComponent - background.greenComponent) < 0.02)
                #expect(abs(color.blueComponent - background.blueComponent) < 0.02,
                        "Focused name input must not draw a separate fill or focus border")
            }
            if let directory = ProcessInfo.processInfo.environment["LITHE_POPUP_CAPTURE_DIR"] {
                let name = "new-\(kind)-\(scheme == .dark ? "dark" : "light").png"
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
            presenter.close()
        }
    }

    @MainActor
    @Test
    func stateChangesOpenCloseAndReopenWithoutAnotherInteraction() async throws {
        let controls = PopupControls()
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentViewController = NSHostingController(rootView: PopupHarness(controls: controls)
            .environment(\.locale, Locale(identifier: "zh-Hans")).environment(\.controlActiveState, .inactive))
        parent.orderFront(nil)
        defer {
            controls.close?()
            parent.contentViewController = nil
            parent.close()
        }
        func waitFor(_ predicate: @MainActor () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while !predicate(), clock.now < deadline { await Task.yield() }
            return predicate()
        }
        func panels() -> [NSWindow] { (parent.childWindows ?? []).filter(\.isVisible) }
        #expect(await waitFor { controls.open != nil })
        let open = try #require(controls.open)
        let close = try #require(controls.close)
        open()
        #expect(await waitFor { panels().count == 1 }, "Opening must react to @State alone")
        #expect(await waitFor { controls.renderedLocale == "zh-Hans" }, "Detached forms must inherit the app locale")
        let first = try #require(panels().first)
        let presenter = try #require(first.delegate as? LitheCenteredPopupPresenter)
        // Isolated tests do not activate the desktop app; deliver the native key-window callback directly.
        presenter.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: first))
        #expect(await waitFor { controls.renderedControlState == .key }, "Popup selection follows its own key window, not the inactive owner")
        open()
        #expect(panels().count == 1)
        close()
        #expect(await waitFor { panels().isEmpty }, "Closing must not need an unrelated click")
        open()
        #expect(await waitFor { panels().count == 1 })
        #expect(panels().first !== first)
        // A cancelled opening must never appear after a subsequent update.
        close()
        #expect(await waitFor { panels().isEmpty })
        open()
        close()
        await Task.yield()
        parent.contentViewController = nil
        await Task.yield()
        #expect(panels().isEmpty)
    }

    @MainActor
    @Test
    func dialogBlocksOwnerActionsButKeepsFilePanelInteractiveAndRestoresOwner() throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let ownerInput = PopupClickView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        parent.contentView = ownerInput
        parent.makeKeyAndOrderFront(nil)
        let presenter = LitheCenteredPopupPresenter()
        // Native file pickers are independent windows, not children of the form.
        let picker = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        picker.isReleasedWhenClosed = false
        let pickerInput = PopupClickView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        picker.contentView = pickerInput
        defer { picker.close(); presenter.close(); parent.close() }
        func click(_ window: NSWindow) throws {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1)))
        }
        try click(parent)
        #expect(ownerInput.clicks == 1)
        let host = NSHostingController(rootView: Text("Form draft").frame(width: 340, height: 100))
        var dismissals = 0
        presenter.show(contentController: host, parent: parent, dialogTitle: "Create Patch") { dismissals += 1 }
        let panel = try #require(host.view.window)
        try click(parent)
        #expect(ownerInput.clicks == 1, "Parent toolbar cannot start another edit while a dialog is open")
        picker.makeKeyAndOrderFront(nil)
        presenter.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        try click(picker)
        #expect(pickerInput.clicks == 1)
        #expect(panel.isVisible)
        #expect(dismissals == 0, "Opening or cancelling a file picker must preserve the form draft")
        picker.close()
        panel.performClose(nil)
        try click(parent)
        #expect(ownerInput.clicks == 2, "Closing must remove the owner event filter")
        #expect(dismissals == 1)
    }

    @MainActor
    @Test
    func centersTracksParentAndCleansUpWithoutSheetChrome() throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: Text("Name").frame(width: 340, height: 78).litheContextMenuSurface())
        let presenter = LitheCenteredPopupPresenter()
        var dismissals = 0
        defer { presenter.close(); parent.close() }
        presenter.show(contentController: host, parent: parent) { dismissals += 1 }
        let panel = try #require(host.view.window as? NSPanel)
        #expect(panel.parent === parent)
        #expect(panel.styleMask == .borderless)
        #expect(panel.animationBehavior == .none)
        #expect(!panel.isOpaque)
        #expect(abs(panel.frame.midX - parent.frame.midX) < 1)
        #expect(abs(panel.frame.midY - parent.frame.midY) < 1)
        parent.setFrameOrigin(NSPoint(x: 200, y: 250))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: parent)
        #expect(abs(panel.frame.midX - parent.frame.midX) < 1)
        #expect(abs(panel.frame.midY - parent.frame.midY) < 1)
        let selector = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        selector.isReleasedWhenClosed = false
        defer { panel.removeChildWindow(selector); selector.close() }
        panel.addChildWindow(selector, ordered: .above)
        selector.orderFront(nil)
        presenter.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        #expect(panel.isVisible)
        #expect(dismissals == 0)
        panel.removeChildWindow(selector)
        selector.close()
        // A busy form must still release its child window when its owner closes.
        presenter.allowsDismiss = false
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parent)
        #expect(panel.parent == nil)
        #expect(!panel.isVisible)
        #expect(dismissals == 1)
        presenter.close()
        #expect(dismissals == 1)
    }
}

@MainActor
private final class PopupControls {
    var open: (() -> Void)?
    var close: (() -> Void)?
    var renderedLocale: String?
    var renderedControlState: ControlActiveState?
}

private struct PopupHarness: View {
    let controls: PopupControls
    @State private var shown = false

    var body: some View {
        Color.clear.frame(width: 100, height: 100)
            .background(LitheCenteredPopup(isPresented: $shown) {
                PopupLocaleContent(controls: controls)
            }.frame(width: 0, height: 0))
            .onAppear {
                controls.open = { shown = true }
                controls.close = { shown = false }
            }
    }
}

private struct PopupLocaleContent: View {
    let controls: PopupControls
    @Environment(\.locale) private var locale
    @Environment(\.controlActiveState) private var controlActiveState
    var body: some View {
        Text("Popup").frame(width: 340, height: 78).litheContextMenuSurface()
            .onAppear {
                controls.renderedLocale = locale.identifier
                controls.renderedControlState = controlActiveState
            }
            .onChange(of: controlActiveState) { controls.renderedControlState = $0 }
    }
}

@MainActor
private final class PopupClickView: NSView {
    var clicks = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1 }
}

@MainActor
private final class PopupDragRecordingWindow: NSWindow {
    var dragEvent: NSEvent?
    override func performDrag(with event: NSEvent) { dragEvent = event }
}

@MainActor
private final class PopupFittingView: NSView {
    var size = NSSize(width: 400, height: 84)
    override var fittingSize: NSSize { size }
}

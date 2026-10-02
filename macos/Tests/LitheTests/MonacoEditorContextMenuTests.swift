import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Lithe

@Suite("Monaco shared context menu", .serialized)
@MainActor
struct MonacoEditorContextMenuTests {
    private func request() throws -> MonacoEditorContextMenu.Request {
        try .decode(["x": 40, "y": 50, "items": [
            ["key": "0", "id": "lithe.goToDefinition", "title": "Go to Definition", "enabled": true, "checked": false, "shortcut": "F12"],
            ["key": "1", "id": "editor.action.clipboardPasteAction", "title": "Paste", "enabled": false, "checked": false, "shortcut": "⌘V"],
            ["key": "2", "id": "editor.action.formatDocument", "title": "Format Document", "enabled": true, "checked": true, "shortcut": "⇧⌥F"],
        ]])
    }

    @Test
    func retainsExistingActionsAndOnlyUsesAssignedIDEAIcons() throws {
        let request = try request()
        var selected: String?
        let items = MonacoEditorContextMenu.menuItems(request.items) { selected = $0 }
        #expect(items.map(\.title) == ["Go to Definition", "Paste", "Format Document"])
        #expect(items[0].icon == nil)
        #expect(items[1].icon != nil)
        #expect(!items[1].isEnabled)
        #expect(items[1].shortcut == "⌘V")
        #expect(items[2].isChecked)
        items[2].action()
        #expect(selected == "2")
        for id in ["lithe.goToDefinition", "editor.action.rename", "editor.action.changeAll", "editor.action.quickCommand"] {
            #expect(MonacoEditorContextMenu.iconPath(for: id) == nil)
        }
        for id in ["editor.action.clipboardCutAction", "editor.action.clipboardCopyAction", "editor.action.clipboardPasteAction", "editor.action.formatDocument"] {
            let path = try #require(MonacoEditorContextMenu.iconPath(for: id))
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            for resource in [path, LitheIcons.darkIdeaAssetPath(for: path)] {
                let url = root.appendingPathComponent("macos/Resources/IDEAIcons/" + resource)
                let svg = try String(contentsOf: url, encoding: .utf8)
                #expect(svg.contains("width=\"16\"") && svg.contains("height=\"16\""))
                #expect(NSImage(contentsOf: url) != nil)
            }
            let image = ImageRenderer(content: LitheIDEAIcon(resourcePath: path, size: 16, preservesOriginalColors: true))
            #expect(image.cgImage?.width == 16)
            #expect(image.cgImage?.height == 16)
        }
    }

    @Test
    func rejectsMalformedAndOversizedPresentations() {
        for body: [String: Any] in [
            ["x": Double.infinity, "y": 0, "items": []],
            ["x": 0, "y": 0, "items": []],
            ["x": 0, "y": 0, "items": [["key": "0", "id": "cut", "title": String(repeating: "x", count: 8_193), "enabled": true, "checked": false]]],
            ["x": 0, "y": 0, "items": (0..<2).map { _ in ["key": "duplicate", "id": "cut", "title": "Cut", "enabled": true, "checked": false] }],
        ] {
            #expect(throws: (any Error).self) { try MonacoEditorContextMenu.Request.decode(body) }
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func usesSharedPanelAndRepliesWithSelectionAfterDismissal(appearance: NSAppearance.Name) async throws {
        let menu = MonacoEditorContextMenu()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = webView
        defer { menu.dismiss(); window.contentView = nil; window.close() }
        var replies: [String?] = []
        menu.show(try request(), in: webView) { key, handled in
            replies.append(key)
            #expect(!handled)
        }
        let panel = try #require(window.childWindows?.first)
        #expect(panel.isVisible)
        #expect(panel.animationBehavior == .none)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.frame.height == LitheDropdownMetrics.verticalPadding + 3 * LitheDropdownMetrics.rowHeight)
        try sendKey(125, to: panel) // First enabled action.
        try sendKey(125, to: panel) // Skips the disabled Paste item.
        try sendKey(36, to: panel)
        try await waitForReplies(1, in: { replies })
        #expect(replies.count == 1)
        #expect(replies[0] == "2")
        #expect(!panel.isVisible)
        menu.show(try request(), in: webView) { key, handled in
            replies.append(key)
            #expect(!handled)
        }
        try sendKey(53, to: #require(window.childWindows?.first))
        try await waitForReplies(2, in: { replies })
        #expect(replies.count == 2)
        #expect(replies[1] == nil)
        menu.dismiss()
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test
    func nativeClipboardCommandsWorkAfterAsynchronousMenuSelection() async throws {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        let menu = MonacoEditorContextMenu()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { menu.dismiss(); webView.stopLoading(); window.contentView = nil; window.close() }
        webView.loadHTMLString("<textarea id='text'>alpha beta</textarea>", baseURL: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while webView.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!webView.isLoading, "WebKit did not load within three seconds")
        for (command, expected) in [("Copy", "alpha beta"), ("Cut", " beta"), ("Paste", "omega beta")] {
            if command == "Paste" {
                pasteboard.clearContents(); pasteboard.setString("omega", forType: .string)
            }
            _ = try await webView.evaluateJavaScript("var t=document.getElementById('text'); t.focus(); t.setSelectionRange(0, \(command == "Paste" ? 0 : 5));")
            let request = try MonacoEditorContextMenu.Request.decode(["x": 40, "y": 50, "items": [
                ["key": "0", "id": "editor.action.clipboard\(command)Action", "title": command, "enabled": true, "checked": false]
            ]])
            var replies: [String?] = []
            menu.show(request, in: webView) { key, handled in
                #expect(handled)
                replies.append(key)
            }
            let panel = try #require(window.childWindows?.first)
            try sendKey(125, to: panel); try sendKey(36, to: panel)
            try await waitForReplies(1, in: { replies })
            // Evaluating after the native command observes WebKit's ordered event delivery.
            let text = try await webView.evaluateJavaScript("document.getElementById('text').value") as? String
            #expect(text == expected)
            if command != "Paste" { #expect(pasteboard.string(forType: .string) == "alpha") }
        }
    }

    private func waitForReplies(_ count: Int, in replies: () -> [String?]) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while replies().count < count, clock.now < deadline { await Task.yield() }
        #expect(replies().count == count, "Native menu reply exceeded one second")
    }

    private func sendKey(_ code: UInt16, to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }
}

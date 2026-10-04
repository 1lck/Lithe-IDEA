import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent activity panels", .serialized)
struct AgentActivityPresentationTests {
    @Test func diffAndRollbackConfirmationCanReplaceTheSharedDropdown() async throws {
        var restored: [String] = []
        let host = NSHostingView(rootView: VStack {
            Spacer()
            AgentActivitySummaryBar(messages: [editedFile()], onRestore: { restored = $0.map(\.path) })
        }.frame(width: 700, height: 600).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            window.contentView = nil
            for popup in NSApp.windows where !initialWindows.contains(ObjectIdentifier(popup)) { popup.close() }
            window.close()
        }
        let edits = NSPoint(x: 18 + 664 * 2.5 / 3, y: 580)
        host.layoutSubtreeIfNeeded()
        try click(edits, in: host, window: window)
        let popup = try #require(await waitForPopup(excluding: initialWindows))
        let content = try #require(popup.contentView)
        let inset = (content.bounds.width - 340) / 2
        let rowCenter = content.bounds.height - inset - 29
        try click(NSPoint(x: content.bounds.width - inset - 44, y: rowCenter), in: content, window: popup)
        try #require(await waitUntil { window.attachedSheet != nil }, "Diff must open after the dropdown dismisses")
        let sheet = try #require(window.attachedSheet)
        let diff = try #require(sheet.contentView)
        diff.layoutSubtreeIfNeeded()
        #expect(diff.bounds.width >= 600)
        try capture(diff, name: "activity-file-diff")
        try click(NSPoint(x: diff.bounds.width - 32, y: 22), in: diff, window: sheet)
        try #require(await waitUntil { window.attachedSheet == nil }, "Done must dismiss the comparison")

        try click(edits, in: host, window: window)
        let nextPopup = try #require(await waitForPopup(excluding: initialWindows))
        let nextContent = try #require(nextPopup.contentView)
        try click(NSPoint(x: nextContent.bounds.width - inset - 23, y: rowCenter), in: nextContent, window: nextPopup)
        try #require(await waitUntil { window.attachedSheet != nil }, "Rollback must ask for confirmation")
        let alert = try #require(window.attachedSheet)
        let alertContent = try #require(alert.contentView)
        try capture(alertContent, name: "activity-rollback-confirmation")
        let confirm = try #require(nativeButton(in: alertContent, titles: ["Roll back", "回撤"]))
        confirm.performClick(nil)
        #expect(await waitUntil { restored == ["a.txt"] }, "Confirmation must restore the captured file selection")
    }

    @Test func everySegmentOpensItsNativePanelAndFileActionsReachTheEditorCallbacks() async throws {
        let message = editedFile()
        let plan = AgentPlan(entries: [.init(content: "Update the sample", priority: "high", status: .completed)])
        for scheme in [ColorScheme.dark, .light] {
            var opened: [String] = []
            var kept: [AgentFileChange] = []
            let host = NSHostingView(rootView: VStack {
                Spacer()
                AgentActivitySummaryBar(messages: [message], plan: plan,
                    onOpenFile: { opened.append($0.path) }, onKeep: { kept = $0 })
            }.frame(width: 320, height: 80).background(AgentPanelStyle.canvas).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 80),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            defer {
                window.contentView = nil
                for popup in NSApp.windows where !initialWindows.contains(ObjectIdentifier(popup)) { popup.close() }
                window.close()
            }
            for (index, panel) in AgentActivitySummaryBar.Panel.allCases.enumerated() {
                host.layoutSubtreeIfNeeded()
                // Each segment occupies one third of the bar inside its 18pt margins.
                let point = NSPoint(x: 18 + 284 * (CGFloat(index) + 0.5) / 3, y: 60)
                try click(point, in: host, window: window)
                let popup = try #require(await waitForPopup(excluding: initialWindows), "The \(panel.rawValue) segment must open a native panel")
                let content = try #require(popup.contentView)
                try capture(content, name: "activity-\(panel.rawValue)-\(scheme)")
                if panel == .edits {
                    // The shared presenter adds its surface inset around the 340pt panel.
                    let inset = (content.bounds.width - 340) / 2
                    let rowCenter = content.bounds.height - inset - 12 - 17
                    try click(NSPoint(x: inset + 70, y: rowCenter), in: content, window: popup)
                    #expect(await waitUntil { opened == ["a.txt"] })
                    try click(NSPoint(x: content.bounds.width - inset - 50, y: rowCenter - 36), in: content, window: popup)
                    #expect(await waitUntil { kept.map(\.path) == ["a.txt"] })
                }
                try click(point, in: host, window: window)
                #expect(await waitUntil { !popup.isVisible })
            }
        }
    }

    private func editedFile() -> AgentConversationMessage {
        var result = AgentConversationMessage(id: "edit", role: .tool, text: "Edit a.txt", toolStatus: .completed)
        result.toolDetails.merge(["kind": "edit", "content": [["type": "diff", "path": "a.txt", "oldText": "before", "newText": "after"]]])
        return result
    }

    private func nativeButton(in view: NSView, titles: [String]) -> NSButton? {
        if let button = view as? NSButton, titles.contains(button.title) { return button }
        return view.subviews.lazy.compactMap { nativeButton(in: $0, titles: titles) }.first
    }

    private func waitForPopup(excluding windows: Set<ObjectIdentifier>) async -> NSWindow? {
        func popup() -> NSWindow? { NSApp.windows.first { !windows.contains(ObjectIdentifier($0)) && $0.isVisible } }
        _ = await waitUntil { popup() != nil }
        return popup()
    }

    private func click(_ pointFromTop: NSPoint, in view: NSView, window: NSWindow) throws {
        let point = NSPoint(x: pointFromTop.x, y: view.isFlipped ? pointFromTop.y : view.bounds.height - pointFromTop.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        // Observe native presentation and callbacks; every wait has a local deadline.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            renderFrame()
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func renderFrame() {
        // Pump one native event with zero wait, as in the existing transcript tests.
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LITHE_AGENT_ACTIVITY_SCREENSHOTS"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}

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
        try capture(content, name: "activity-edits-actions")
        let rowCenter = content.bounds.height - 22
        try click(NSPoint(x: content.bounds.width - 33, y: rowCenter), in: content, window: popup)
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
        try click(NSPoint(x: nextContent.bounds.width - 13, y: rowCenter), in: nextContent, window: nextPopup)
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
        let running = AgentConversationMessage(id: "running", role: .tool, text: "Run the sample tests", toolStatus: .inProgress)
        let plan = AgentPlan(entries: [.init(content: "Update the sample", priority: "high", status: .completed)])
        for scheme in [ColorScheme.dark, .light] {
            var opened: [String] = []
            var kept: [AgentFileChange] = []
            let host = NSHostingView(rootView: VStack {
                Spacer()
                AgentActivitySummaryBar(messages: [message, running], plan: plan,
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
                #expect(abs(popup.frame.width - 284) < 1, "Every panel follows the activity bar's width")
                try capture(content, name: "activity-\(panel.rawValue)-\(scheme)")
                if panel == .edits {
                    let rowCenter = content.bounds.height - 22
                    try click(NSPoint(x: 70, y: rowCenter), in: content, window: popup)
                    #expect(await waitUntil { opened == ["a.txt"] })
                    try click(NSPoint(x: content.bounds.width - 50, y: 15), in: content, window: popup)
                    #expect(await waitUntil { kept.map(\.path) == ["a.txt"] })
                }
                try click(point, in: host, window: window)
                #expect(await waitUntil { !popup.isVisible })
            }
        }
    }

    @Test(arguments: [320.0, 700.0])
    func emptyPanelsMatchTheBarAndStayCompactInBothThemes(width: Double) async throws {
        for scheme in [ColorScheme.dark, .light] {
            let host = NSHostingView(rootView: VStack {
                Spacer()
                AgentActivitySummaryBar(messages: [])
            }.frame(width: width, height: 160).background(AgentPanelStyle.canvas).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 160),
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
            var previous: NSWindow?
            for (index, panel) in AgentActivitySummaryBar.Panel.allCases.enumerated() {
                host.layoutSubtreeIfNeeded()
                try click(NSPoint(x: 18 + (width - 36) * (Double(index) + 0.5) / 3, y: 140), in: host, window: window)
                let popup = try #require(await waitForPopup(excluding: initialWindows))
                #expect(abs(popup.frame.width - (width - 36)) < 1)
                #expect(abs(popup.frame.minX - window.frame.minX - 18) < 1)
                #expect(abs(popup.frame.minY - window.frame.minY - 36) < 1, "The card opens immediately above the bar")
                #expect(popup.frame.height >= 44 && popup.frame.height <= 56,
                        "An empty card has one centered line, without a heading or tall blank area")
                if let previous { #expect(previous === popup, "Switching tabs reuses the existing panel") }
                try capture(try #require(popup.contentView), name: "activity-empty-\(panel.rawValue)-\(scheme)-\(Int(width))")
                try capture(host, name: "activity-bar-\(panel.rawValue)-\(scheme)-\(Int(width))")
                previous = popup
            }
            // The same tab toggles closed; reopening still supports Escape and outside clicks.
            let edits = NSPoint(x: 18 + (width - 36) * 2.5 / 3, y: 140)
            try click(edits, in: host, window: window)
            #expect(await waitUntil { previous?.isVisible == false })
            try click(edits, in: host, window: window)
            let popup = try #require(await waitForPopup(excluding: initialWindows))
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: popup.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
            popup.sendEvent(escape)
            #expect(await waitUntil { !popup.isVisible })
            try click(edits, in: host, window: window)
            let reopened = try #require(await waitForPopup(excluding: initialWindows))
            // Outside-click dismissal is installed on NSApp, so the event must
            // pass through its monitor rather than going straight to NSWindow.
            try click(NSPoint(x: 10, y: 10), in: host, window: window, throughApplication: true)
            #expect(await waitUntil { !reopened.isVisible })
            try click(edits, in: host, window: window)
            let detached = try #require(await waitForPopup(excluding: initialWindows))
            window.contentView = nil
            #expect(await waitUntil { !detached.isVisible }, "Removing the conversation clears its activity panel")
        }
    }

    @Test func allThreeLongListsStayBoundedAndLastFileCanOpen() async throws {
        let plan = AgentPlan(entries: (0..<40).map {
            .init(content: "Step \($0): inspect the sample project and describe the result", priority: "medium", status: .pending)
        })
        let running = (0..<40).map {
            AgentConversationMessage(id: "running-\($0)", role: .tool, text: "Run sample task \($0)", toolStatus: .inProgress)
        }
        let files = (0..<40).map { editedFile(path: String(format: "file-%02d.txt", $0)) }
        for scheme in [ColorScheme.dark, .light] {
            var opened: String?
            let host = NSHostingView(rootView: VStack {
                Spacer()
                AgentActivitySummaryBar(messages: running + files, plan: plan, onOpenFile: { opened = $0.path })
            }.frame(width: 320, height: 400).background(AgentPanelStyle.canvas).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 400),
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
                try click(NSPoint(x: 18 + 284 * (CGFloat(index) + 0.5) / 3, y: 380), in: host, window: window)
                let popup = try #require(await waitForPopup(excluding: initialWindows))
                #expect(abs(popup.frame.width - 284) < 1)
                #expect(popup.frame.height <= 260, "Long lists use an internal viewport instead of a tall outer card")
                let content = try #require(popup.contentView)
                let scroll = try #require(scrollView(in: content))
                let document = try #require(scroll.documentView)
                #expect(document.bounds.height > scroll.contentView.bounds.height)
                document.scroll(NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                try #require(await waitUntil {
                    scroll.contentView.bounds.maxY >= document.bounds.maxY - 1
                }, "The last list row must become visible")
                try capture(content, name: "activity-long-\(panel.rawValue)-\(scheme)")
                if panel == .edits {
                    try click(NSPoint(x: 70, y: content.bounds.height - 20), in: content, window: popup)
                    #expect(await waitUntil { opened == "file-39.txt" }, "The last file retains its editor callback")
                }
            }
        }
    }

    private func editedFile(path: String = "a.txt") -> AgentConversationMessage {
        var result = AgentConversationMessage(id: "edit-\(path)", role: .tool, text: "Edit \(path)", toolStatus: .completed)
        result.toolDetails.merge(["kind": "edit", "content": [["type": "diff", "path": path, "oldText": "before", "newText": "after"]]])
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

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func click(_ pointFromTop: NSPoint, in view: NSView, window: NSWindow, throughApplication: Bool = false) throws {
        let point = NSPoint(x: pointFromTop.x, y: view.isFlipped ? pointFromTop.y : view.bounds.height - pointFromTop.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if throughApplication { NSApp.sendEvent(event) }
            else { window.sendEvent(event) }
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

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
        // Retain the snapshot: a released window's address can be reused by the
        // next popup, which would then be mistaken for a pre-existing window.
        let snapshot = NSApp.windows
        let initialWindows = Set(snapshot.map(ObjectIdentifier.init))
        defer {
            window.contentView = nil
            for popup in NSApp.windows where !initialWindows.contains(ObjectIdentifier(popup)) { popup.close() }
            window.close()
            withExtendedLifetime(snapshot) {}
        }
        host.layoutSubtreeIfNeeded()
        try await openPanel(.edits, in: host, window: window)
        let popup = try #require(await waitForPopup(in: window, updating: host))
        let content = try #require(popup.contentView)
        try capture(content, name: "activity-edits-actions")
        let rowCenter = content.bounds.height - 22
        try click(NSPoint(x: content.bounds.width - 47, y: rowCenter), in: content, window: popup)
        try #require(await waitUntil { window.attachedSheet != nil }, "Diff must open after the dropdown dismisses")
        let sheet = try #require(window.attachedSheet)
        let diff = try #require(sheet.contentView)
        diff.layoutSubtreeIfNeeded()
        #expect(diff.bounds.width >= 600)
        try capture(diff, name: "activity-file-diff")
        try click(NSPoint(x: diff.bounds.width - 32, y: 22), in: diff, window: sheet)
        try #require(await waitUntil { window.attachedSheet == nil }, "Done must dismiss the comparison")

        try await openPanel(.edits, in: host, window: window)
        let nextPopup = try #require(await waitForPopup(in: window, updating: host))
        let nextContent = try #require(nextPopup.contentView)
        try click(NSPoint(x: nextContent.bounds.width - 19, y: rowCenter), in: nextContent, window: nextPopup)
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
            // Retain the snapshot: a released window's address can be reused by the
            // next popup, which would then be mistaken for a pre-existing window.
            let snapshot = NSApp.windows
            let initialWindows = Set(snapshot.map(ObjectIdentifier.init))
            defer {
                window.contentView = nil
                for popup in NSApp.windows where !initialWindows.contains(ObjectIdentifier(popup)) { popup.close() }
                window.close()
                withExtendedLifetime(snapshot) {}
            }
            for panel in AgentActivitySummaryBar.Panel.allCases {
                host.layoutSubtreeIfNeeded()
                try await openPanel(panel, in: host, window: window)
                let popup = try #require(await waitForPopup(in: window, updating: host), "The \(panel.rawValue) segment must open a native panel")
                let content = try #require(popup.contentView)
                #expect(abs(popup.frame.width - LitheDropdownMetrics.maximumWidth) < 1)
                try capture(content, name: "activity-\(panel.rawValue)-\(scheme)")
                if panel == .edits {
                    let rowCenter = content.bounds.height - 22
                    try click(NSPoint(x: 70, y: rowCenter), in: content, window: popup)
                    #expect(await waitUntil { opened == ["a.txt"] })
                    try click(NSPoint(x: content.bounds.width - 50, y: 15), in: content, window: popup)
                    #expect(await waitUntil { kept.map(\.path) == ["a.txt"] })
                }
                try closePopup(popup)
                #expect(await waitUntil { !popup.isVisible })
            }
        }
    }

    @Test func emptyActivityHasNoDropdownAnchor() {
        let host = NSHostingView(rootView: AgentActivitySummaryBar(messages: []).frame(width: 320, height: 34))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 34),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(anchor(in: host) == nil)
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
            // Retain the snapshot: a released window's address can be reused by the
            // next popup, which would then be mistaken for a pre-existing window.
            let snapshot = NSApp.windows
            let initialWindows = Set(snapshot.map(ObjectIdentifier.init))
            defer {
                window.contentView = nil
                for popup in NSApp.windows where !initialWindows.contains(ObjectIdentifier(popup)) { popup.close() }
                window.close()
                withExtendedLifetime(snapshot) {}
            }
            for panel in AgentActivitySummaryBar.Panel.allCases {
                host.layoutSubtreeIfNeeded()
                try await openPanel(panel, in: host, window: window)
                let popup = try #require(await waitForPopup(in: window, updating: host))
                #expect(abs(popup.frame.width - LitheDropdownMetrics.maximumWidth) < 1)
                #expect(popup.frame.height <= 290, "Long lists use an internal viewport instead of a tall outer card")
                let content = try #require(popup.contentView)
                let scroll = try #require(scrollView(in: content))
                let document = try #require(scroll.documentView)
                #expect(document.bounds.height > scroll.contentView.bounds.height)
                // Rows can finish layout after the first scroll and grow the
                // document, so scroll to the current end on every poll.
                try #require(await waitUntil {
                    document.scroll(NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    return scroll.contentView.bounds.maxY >= document.bounds.maxY - 1
                }, "The last list row must become visible")
                try capture(content, name: "activity-long-\(panel.rawValue)-\(scheme)")
                if panel == .edits {
                    // SwiftUI moves hit targets one update after the clip view
                    // scrolls; retry until the click lands on the scrolled row.
                    #expect(await waitUntil {
                        if opened == nil { try? click(NSPoint(x: 70, y: content.bounds.height - 20), in: content, window: popup) }
                        return opened == "file-39.txt"
                    }, "The last file retains its editor callback")
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func headerActivityStaysToTheRightOfAgentAndHidesWhenEmpty(hasActivity: Bool) throws {
        let host = NSHostingView(rootView: AgentChatHeader(agentName: "Codex", onHistory: nil, onNew: nil,
            onOpenSettings: {}, onHide: {}, showsActions: false,
            activity: AgentActivitySummaryBar(messages: hasActivity ? [editedFile()] : []))
            .frame(width: 320, height: 34))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 34),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        if hasActivity {
            let trigger = try #require(anchor(in: host))
            #expect(trigger.convert(trigger.bounds, to: host).minX > 160)
        } else { #expect(anchor(in: host) == nil) }
        try capture(host, name: "activity-header-\(hasActivity)")
    }

    @Test func activitySVGsLoadAtNativeSizeInBothThemes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        for dark in [false, true] {
            var images: [NSImage] = []
            for panel in AgentActivitySummaryBar.Panel.allCases {
                let path = dark ? LitheIcons.darkIdeaAssetPath(for: panel.icon) : panel.icon
                let image = try #require(NSImage(contentsOf: root.appendingPathComponent(path)))
                #expect(image.size == NSSize(width: 16, height: 16))
                images.append(image)
            }
            let host = NSHostingView(rootView: HStack {
                ForEach(images.indices, id: \.self) { Image(nsImage: images[$0]).frame(width: 16, height: 16) }
            }.frame(width: 100, height: 24).background(AgentPanelStyle.canvas).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try capture(host, name: "activity-svg-\(dark)")
        }
    }

    private func anchor(in view: NSView) -> LitheDropdownAnchorView? {
        if let anchor = view as? LitheDropdownAnchorView { return anchor }
        return view.subviews.lazy.compactMap { anchor(in: $0) }.first
    }

    private func closePopup(_ popup: NSWindow) throws {
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: popup.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
    }

    private func openPanel(_ panel: AgentActivitySummaryBar.Panel, in host: NSView, window: NSWindow) async throws {
        for popup in window.childWindows ?? [] where popup.isVisible {
            try closePopup(popup)
        }
        host.layoutSubtreeIfNeeded()
        let trigger = try #require(anchor(in: host))
        let rect = trigger.convert(trigger.bounds, to: host)
        let point = NSPoint(x: rect.midX, y: host.isFlipped ? rect.midY : host.bounds.height - rect.midY)
        try click(point, in: host, window: window)
        let popup = try #require(await waitForPopup(in: window, updating: host))
        let content = try #require(popup.contentView)
        content.layoutSubtreeIfNeeded()
        try capture(content, name: "activity-menu")
        let index = try #require(AgentActivitySummaryBar.Panel.allCases.firstIndex(of: panel))
        if panel == .running {
            for code: UInt16 in [125, 125, 36] {
                NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: popup.windowNumber, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
            }
        } else {
            try click(NSPoint(x: content.bounds.midX,
                y: LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.rowHeight * (CGFloat(index) + 0.5)),
                in: content, window: popup)
        }
        try #require(await waitUntil(updating: host) {
            window.childWindows?.contains { $0.isVisible
                && $0.frame.width >= LitheDropdownMetrics.maximumWidth - 1 } == true
        }, "The \(panel.rawValue) menu action must present its activity panel")
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

    private func waitForPopup(in window: NSWindow, updating host: NSView) async -> NSWindow? {
        // The dropdown is presented after SwiftUI delivers the parent layout.
        // Drive that boundary and observe only this host's native child panel.
        host.needsLayout = true
        guard await waitUntil(updating: host, {
            window.childWindows?.contains { $0 is NSPanel && $0.isVisible } == true
        }) else { return nil }
        return window.childWindows?.first { $0 is NSPanel && $0.isVisible }
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

    private func waitUntil(updating host: NSView? = nil, _ condition: () -> Bool) async -> Bool {
        // Observe native presentation and callbacks; every wait has a local deadline.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            renderFrame()
            host?.layoutSubtreeIfNeeded()
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

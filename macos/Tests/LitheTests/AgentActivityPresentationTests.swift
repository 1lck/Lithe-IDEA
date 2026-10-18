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
        defer {
            window.contentView = nil
            for popup in window.childWindows ?? [] { popup.close() }
            window.close()
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
            defer {
                window.contentView = nil
                for popup in window.childWindows ?? [] { popup.close() }
                window.close()
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

    @Test func emptyActivityKeepsTheThreeSegmentAnchor() {
        let host = NSHostingView(rootView: AgentActivitySummaryBar(messages: []).frame(width: 320, height: 34))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 34),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(anchor(in: host) != nil, "Empty activity retains the same three entry points")
        try? capture(host, name: "activity-empty")
    }

    @Test(arguments: [ColorScheme.dark, .light], ["en", "zh-Hans"])
    func tasksShowOnlyReportedPlansWhileRunningKeepsToolCalls(scheme: ColorScheme, language: String) async throws {
        // SwiftUI publishes its accessibility nodes when an assistive client is active.
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        let fixture = AgentActivityPlanFixture()
        let host = NSHostingView(rootView: AgentActivityPlanFixtureView(fixture: fixture)
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            for popup in window.childWindows ?? [] { popup.close() }
            window.close()
        }
        func count(_ panel: AgentActivitySummaryBar.Panel) -> String? {
            let element = accessibilityElements(in: host).first {
                $0.accessibilityIdentifier?() == "agent-activity-\(panel.rawValue)"
            }
            return element.flatMap { accessibilityValue(of: $0) }
        }
        try #require(await waitUntil(updating: host) { count(.tasks) == "0" && count(.running) == "1" })
        try await openPanel(.tasks, in: host, window: window)
        let popup = try #require(await waitForPopup(in: window, updating: host))
        let content = try #require(popup.contentView)
        #expect(scrollView(in: content) == nil, "Without a plan, Tasks must show an empty state instead of the tool list")
        try capture(content, name: "tasks-no-plan-\(scheme)-\(language)")

        let plan = AgentPlan(entries: [
            .init(content: "Read project rules", status: .completed),
            .init(content: "Check the project", status: .inProgress),
            .init(content: "Summarize the result", status: .pending)
        ])
        fixture.plan = plan
        try #require(await waitUntil(updating: host) { count(.tasks) == "1/3" })
        try #require(await waitUntil(updating: content) { scrollView(in: content) != nil },
                     "A reported plan must replace the empty state with its steps")
        try capture(content, name: "tasks-reported-plan-\(scheme)-\(language)")

        // Clearing a previously visible plan must not reveal the accumulated tool history.
        fixture.plan = AgentPlan(entries: [])
        try #require(await waitUntil(updating: host) { count(.tasks) == "0" })
        try #require(await waitUntil(updating: content) { scrollView(in: content) == nil },
                     "Clearing the plan must remove its steps without revealing any tool list")
        fixture.plan = nil
        #expect(await waitUntil(updating: host) { count(.tasks) == "0" && count(.running) == "1" })

        try await openPanel(.running, in: host, window: window)
        let runningPopup = try #require(await waitForPopup(in: window, updating: host))
        let runningContent = try #require(runningPopup.contentView)
        try #require(scrollView(in: runningContent), "Running must retain its actual tool list")
        try capture(runningContent, name: "tasks-running-tools-\(scheme)-\(language)")
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
            defer {
                window.contentView = nil
                for popup in window.childWindows ?? [] { popup.close() }
                window.close()
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

    @Test func compactHeaderKeepsHistoryAndSearchIndependent() async throws {
        var opened: [String] = []
        let host = NSHostingView(rootView: AgentChatHeader(agentName: "Codex", onHistory: { opened.append("history") },
            onNew: { opened.append("new") }, onOpenSettings: {}, onHide: {}, conversationTitle: "Review sample",
            onSearch: { opened.append("search") }).frame(width: 320, height: LitheTheme.Metrics.toolWindowHeaderHeight))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: LitheTheme.Metrics.toolWindowHeaderHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == LitheTheme.Metrics.toolWindowHeaderHeight, "No duplicate Agent heading")
        // From the trailing edge: Hide, Options, History, Search, New Chat.
        for (slot, expected) in [(2, "history"), (3, "search"), (4, "new")] {
            try clickNativeView(host, at: NSPoint(x: 320 - 7 - CGFloat(slot) * 26 - 11, y: host.bounds.midY))
            #expect(await waitUntil { opened.last == expected })
        }
        #expect(opened == ["history", "search", "new"])
        try capture(host, name: "classic-header")
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

    private func accessibilityElements(in element: Any) -> [AnyObject] {
        let accessible = element as AnyObject
        let children = accessible.accessibilityChildren?() ?? []
        // The shared panel's native chrome is ignored by accessibility. Walk
        // through it to the SwiftUI host that publishes the actual content.
        let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
        return [accessible] + descendants.flatMap { accessibilityElements(in: $0) }
    }

    private func accessibilityValue(of element: AnyObject) -> String? {
        // SwiftUI nodes need not adopt a public accessibility protocol. Read the
        // Objective-C getter without choosing among AppKit's conflicting return types.
        let selector = NSSelectorFromString("accessibilityValue")
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func closePopup(_ popup: NSWindow) throws {
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: popup.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
    }

    private func openPanel(_ panel: AgentActivitySummaryBar.Panel, in host: NSView, window: NSWindow) async throws {
        for popup in window.childWindows ?? [] where popup is NSPanel && popup.isVisible {
            try closePopup(popup)
        }
        try #require(await waitUntil(updating: host) {
            guard let trigger = anchor(in: host) else { return false }
            return window.childWindows?.contains { $0 is NSPanel && $0.isVisible } != true
                && trigger.window === window && !trigger.bounds.isEmpty
        }, "The previous panel must dismiss and the activity trigger must finish layout before clicking")
        let trigger = try #require(anchor(in: host))
        let rect = trigger.convert(trigger.bounds, to: host)
        let index = try #require(AgentActivitySummaryBar.Panel.allCases.firstIndex(of: panel))
        let point = NSPoint(x: rect.minX + rect.width * (CGFloat(index) + 0.5) / 3,
                            y: host.isFlipped ? rect.midY : host.bounds.height - rect.midY)
        try click(point, in: host, window: window)
        _ = try #require(await waitForPopup(in: window, updating: host), "Each segment opens its details directly")

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
            await Task.yield()
            renderFrame()
            host?.layoutSubtreeIfNeeded()
            if condition() { return true }
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

@MainActor
private final class AgentActivityPlanFixture: ObservableObject {
    @Published var plan: AgentPlan?
    let messages = [
        AgentConversationMessage(id: "completed", role: .tool, text: "List files", toolStatus: .completed),
        AgentConversationMessage(id: "running", role: .tool, text: "Run sample tests", toolStatus: .inProgress)
    ]
}

private struct AgentActivityPlanFixtureView: View {
    @ObservedObject var fixture: AgentActivityPlanFixture

    var body: some View {
        VStack {
            Spacer()
            AgentActivitySummaryBar(messages: fixture.messages, plan: fixture.plan, isResponding: true)
        }
        .frame(width: 320, height: 100)
        .background(AgentPanelStyle.canvas)
    }
}

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

    @Test func everySummaryOpensItsNativePanelAndFileActionsReachTheEditorCallbacks() async throws {
        let message = editedFile()
        let running = AgentConversationMessage(id: "running", role: .tool, text: "Run the sample tests", toolStatus: .inProgress)
        let plan = AgentPlan(entries: [.init(content: "Update the sample", priority: "high", status: .completed)])
        for scheme in [ColorScheme.dark, .light] {
            var opened: [String] = []
            var kept: [AgentFileChange] = []
            let host = NSHostingView(rootView: VStack {
                Spacer()
                AgentActivitySummaryBar(messages: [message, running], plan: plan,
                    subagents: [.init(id: "child", parentSessionID: "root", name: "Explore", task: "Inspect sample project")],
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

    @Test func emptyActivityRemovesItsRowsAnchorAndReservedHeight() {
        let host = NSHostingView(rootView: AgentActivitySummaryBar(messages: []).frame(width: 320))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 34),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(anchor(in: host) == nil, "An empty summary does not retain invisible dropdown anchors")
        #expect(host.fittingSize.height == 0, "An empty summary must not reserve the old activity strip")
        #expect(AgentActivitySummaryBar(messages: []).composerHeight == 0)
    }

    @Test(arguments: [ColorScheme.dark, .light], ["en", "zh-Hans"])
    func tasksShowOnlyReportedPlansAndToolsDoNotBecomeSubagents(scheme: ColorScheme, language: String) async throws {
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
        try #require(await waitUntil(updating: host) { count(.tasks) == nil && count(.subagents) == nil })
        #expect(anchor(in: host) == nil, "Ordinary tool history must not create plan or subagent summaries")
        try capture(host, name: "tasks-no-plan-\(scheme)-\(language)")

        let plan = AgentPlan(entries: [
            .init(content: "Read project rules", status: .completed),
            .init(content: "Check the project", status: .inProgress),
            .init(content: "Summarize the result", status: .pending)
        ])
        fixture.plan = plan
        try #require(await waitUntil(updating: host) { count(.tasks) == "1/3" })
        let label = accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "agent-activity-tasks" }
        #expect((label?.accessibilityLabel?() ?? "").contains("Check the project"), "The summary names the real in-progress step")
        try await openPanel(.tasks, in: host, window: window)
        let popup = try #require(await waitForPopup(in: window, updating: host))
        let content = try #require(popup.contentView)
        #expect(scrollView(in: content) != nil)
        try capture(content, name: "tasks-reported-plan-\(scheme)-\(language)")

        // Clearing a previously visible plan must not reveal the accumulated tool history.
        fixture.plan = AgentPlan(entries: [])
        try #require(await waitUntil(updating: host) { count(.tasks) == nil && !popup.isVisible },
                     "Clearing the plan must remove its row and dismiss its old panel")
        fixture.plan = nil
        #expect(await waitUntil(updating: host) { count(.tasks) == nil && count(.subagents) == nil })
        fixture.plan = plan
        try #require(await waitUntil(updating: host) { count(.tasks) == "1/3" })
        #expect(window.childWindows?.contains { $0 is NSPanel && $0.isVisible } != true,
                "A newly reported plan must not reopen a stale selection")
    }

    @Test(arguments: [ColorScheme.dark, .light], ["en", "zh-Hans"])
    func subagentsExpandDeliveredOutputAndRefreshWithoutDismissing(scheme: ColorScheme, language: String) async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        let fixture = AgentActivityPlanFixture()
        fixture.subagents = [.init(id: "child", parentSessionID: "root", name: "Explore", task: "Inspect the sample project")]
        var output = AgentConversationMessage(role: .agent, text: "The sample project contains a **README**.")
        output.subagentSessionID = "child"
        fixture.messages.append(output)
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
        func count() -> String? {
            accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "agent-activity-subagents" }
                .flatMap { accessibilityValue(of: $0) }
        }
        try #require(await waitUntil(updating: host) { count() == "0/1" })
        try await openPanel(.subagents, in: host, window: window)
        let popup = try #require(await waitForPopup(in: window, updating: host))
        let content = try #require(popup.contentView)
        let collapsedHeight = content.bounds.height
        try click(NSPoint(x: 90, y: collapsedHeight - 22), in: content, window: popup)
        try #require(await waitUntil(updating: content) { content.bounds.height > collapsedHeight + 30 },
                     "Clicking a child must expand its delivered output inside the same popup")
        #expect(content.bounds.height < 320, "Expanded details remain bounded")
        try capture(content, name: "subagent-expanded-\(scheme)-\(language)")
        let expandedHeight = content.bounds.height
        fixture.subagents[0].state = .completed
        fixture.subagents[0].task = "Inspect the sample project, verify its source files and test configuration, then report the discovered entry points and their responsibilities."
        try #require(await waitUntil(updating: host) { count() == "1/1" })
        // Native panel chrome hides the SwiftUI AX subtree. A longer delivered
        // task makes the same panel's refreshed content observable through layout.
        try #require(await waitUntil(updating: content) { content.bounds.height > expandedHeight + 10 })
        #expect(popup.isVisible)
        try capture(content, name: "subagent-completed-\(scheme)-\(language)")
        try closePopup(popup)
        #expect(await waitUntil(updating: host) { !popup.isVisible })
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
                AgentActivitySummaryBar(messages: running + files, plan: plan,
                    subagents: (0..<40).map { .init(id: "child-\($0)", parentSessionID: "root", name: "Explore \($0)", task: "Inspect sample project") }, onOpenFile: { opened = $0.path })
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

    @Test(arguments: [ColorScheme.dark, .light], [280.0, 540.0])
    func compactSummariesPreserveNarrowTargetsAndReportedTotals(scheme: ColorScheme, width: Double) async throws {
        var message = editedFile()
        message.toolDetails.diffs[0].additions = 128
        message.toolDetails.diffs[0].deletions = 36
        let plan = AgentPlan(entries: [
            .init(content: "Read project rules", status: .completed),
            .init(content: "Rebuild the independent completion audit and verify all source files, test cases and configuration entries", status: .inProgress),
            .init(content: "Report the result", status: .pending)
        ])
        let summary = AgentActivitySummaryBar(messages: [message], plan: plan,
            subagents: [.init(id: "one", parentSessionID: "root", name: "Explore", task: "Inspect source"),
                        .init(id: "two", parentSessionID: "root", name: "Review", task: "Check tests")])
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Spacer()
            summary
        }.frame(width: width, height: 120).background(AgentPanelStyle.canvas)
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh-Hans")))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try #require(await waitUntil(updating: host) { anchor(in: host)?.bounds.height == summary.contentHeight })
        let trigger = try #require(anchor(in: host))
        #expect(abs(trigger.bounds.width - width) < 0.5, "The summary must stay within its native pixel bounds")
        #expect(trigger.bounds.height < 60, "Two compact rows must not become three full-width controls")
        try capture(host, name: "compact-summary-\(scheme)-\(Int(width))")
        for panel in AgentActivitySummaryBar.Panel.allCases {
            try await openPanel(panel, in: host, window: window)
            let popup = try #require(await waitForPopup(in: window, updating: host))
            try closePopup(popup)
            #expect(await waitUntil(updating: host) { !popup.isVisible })
        }
    }

    @Test func summaryTotalsRejectIncompleteEvidenceAndRespectReviewBaselines() throws {
        var first = editedFile()
        first.toolDetails.diffs[0].additions = 4
        first.toolDetails.diffs[0].deletions = 1
        var later = AgentConversationMessage(id: "later", role: .tool, text: "Edit again", toolStatus: .completed)
        later.toolDetails = first.toolDetails
        later.toolDetails.diffs[0].additions = 2
        later.toolDetails.diffs[0].deletions = 3
        let combined = AgentActivity(messages: [first, later])
        #expect(combined.files.count == 1)
        #expect(AgentActivitySummaryPresentation.lineTotals(combined.files) == AgentActivitySummaryPresentation.LineTotals(additions: 6, deletions: 4))
        let reviewed = try #require(AgentActivity(messages: [first]).files.first)
        let unreviewed = AgentActivity(messages: [first, later], reviewed: [reviewed.path: reviewed])
        #expect(AgentActivitySummaryPresentation.lineTotals(unreviewed.files) == AgentActivitySummaryPresentation.LineTotals(additions: 2, deletions: 3))
        #expect(AgentActivitySummaryBar(messages: [first], reviewed: [reviewed.path: reviewed]).composerHeight == 0)

        var unknown = later
        unknown.toolDetails.diffs[0].additions = nil
        #expect(AgentActivitySummaryPresentation.lineTotals(AgentActivity(messages: [first, unknown]).files) == nil)
        var pending = later
        pending.toolStatus = .inProgress
        #expect(AgentActivitySummaryPresentation.lineTotals(AgentActivity(messages: [first, pending]).files) == nil)
        var missing = AgentConversationMessage(id: "missing", role: .tool, text: "Edited", toolStatus: .completed)
        missing.toolDetails.kind = "edit"
        missing.toolDetails.locations = [.init(path: reviewed.path)]
        #expect(AgentActivitySummaryPresentation.lineTotals(AgentActivity(messages: [first, missing]).files) == nil)
        var largest = first
        largest.toolDetails.diffs[0].additions = .max
        var anotherFile = editedFile(path: "b.txt")
        anotherFile.toolDetails.diffs[0].additions = 1
        anotherFile.toolDetails.diffs[0].deletions = 0
        #expect(AgentActivitySummaryPresentation.lineTotals(AgentActivity(messages: [largest, anotherFile]).files) == nil)
    }

    @Test func keepingAllChangesHidesTheEditSummaryAndClosesItsPanel() async throws {
        let fixture = AgentActivityPlanFixture()
        fixture.isResponding = false
        fixture.messages = [editedFile()]
        let host = NSHostingView(rootView: AgentActivityPlanFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await openPanel(.edits, in: host, window: window)
        let popup = try #require(await waitForPopup(in: window, updating: host))
        let content = try #require(popup.contentView)
        try click(NSPoint(x: content.bounds.width - 50, y: 15), in: content, window: popup)
        #expect(await waitUntil(updating: host) { !fixture.reviewed.isEmpty && anchor(in: host) == nil && !popup.isVisible },
                "Keeping the last file removes both the summary and its popup")
        fixture.messages.append(editedFile(path: "later.txt"))
        #expect(await waitUntil(updating: host) { anchor(in: host) != nil })
        #expect(window.childWindows?.contains { $0 is NSPanel && $0.isVisible } != true)
    }

    @Test func reviewErrorsRemainReachableWithoutAnyChangedFiles() async throws {
        let summary = AgentActivitySummaryBar(messages: [], reviewError: "The original file changed outside this conversation.")
        let host = NSHostingView(rootView: summary.frame(width: 320))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: summary.contentHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await openPanel(.edits, in: host, window: window)
        let popup = try #require(await waitForPopup(in: window, updating: host))
        try capture(try #require(popup.contentView), name: "compact-summary-review-error")
        try closePopup(popup)
    }

    @Test func restoringTheLastFileDoesNotReopenAnOldPanelWhenNewChangesArrive() async throws {
        let fixture = AgentActivityPlanFixture()
        fixture.isResponding = false
        fixture.messages = [editedFile()]
        let host = NSHostingView(rootView: AgentActivityPlanFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await openPanel(.edits, in: host, window: window)
        let popup = try #require(await waitForPopup(in: window, updating: host))
        let content = try #require(popup.contentView)
        try click(NSPoint(x: content.bounds.width - 19, y: content.bounds.height - 22), in: content, window: popup)
        try #require(await waitUntil { window.attachedSheet != nil })
        let alertContent = try #require(window.attachedSheet?.contentView)
        let confirm = try #require(nativeButton(in: alertContent, titles: ["Roll back", "回撤"]))
        confirm.performClick(nil)
        try #require(await waitUntil(updating: host) { !fixture.reviewed.isEmpty && anchor(in: host) == nil })
        fixture.messages.append(editedFile(path: "later.txt"))
        try #require(await waitUntil(updating: host) { anchor(in: host) != nil })
        #expect(window.childWindows?.contains { $0 is NSPanel && $0.isVisible } != true,
                "Completing a restore must not reuse the summary captured before the file disappeared")
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
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let y = panel == .edits ? top + rect.height - AgentComposerMetrics.activityVerticalInset - AgentComposerMetrics.activityRowHeight / 2
            : top + AgentComposerMetrics.activityVerticalInset + AgentComposerMetrics.activityRowHeight / 2
        let x: CGFloat
        switch panel {
        case .tasks: x = rect.minX + 40
        case .subagents: x = rect.maxX - 40
        case .edits: x = rect.midX
        }
        try capture(host, name: "summary-before-\(panel)-\(Int(host.bounds.width))-\(Int(host.bounds.height))")
        try click(NSPoint(x: x, y: y), in: host, window: window, throughApplication: true)
        _ = try #require(await waitForPopup(in: window, updating: host),
                         "Summary \(panel.rawValue), rect \(rect), host \(host.frame), window \(window.frame), flipped \(host.isFlipped), click \(x),\(y) must open its details")

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
    @Published var isResponding = true
    @Published var reviewed: [String: AgentFileChange] = [:]
    @Published var subagents: [AgentSubagent] = []
    @Published var messages = [
        AgentConversationMessage(id: "completed", role: .tool, text: "List files", toolStatus: .completed),
        AgentConversationMessage(id: "running", role: .tool, text: "Run sample tests", toolStatus: .inProgress)
    ]
}

private struct AgentActivityPlanFixtureView: View {
    @ObservedObject var fixture: AgentActivityPlanFixture

    var body: some View {
        VStack {
            Spacer()
            AgentActivitySummaryBar(messages: fixture.messages, plan: fixture.plan, subagents: fixture.subagents,
                reviewed: fixture.reviewed, isResponding: fixture.isResponding, onKeep: { changes in
                    for change in changes { fixture.reviewed[change.path] = change }
                }, onRestore: { changes in
                    for change in changes { fixture.reviewed[change.path] = change }
                })
        }
        .frame(width: 320, height: 100)
        .background(AgentPanelStyle.canvas)
    }
}

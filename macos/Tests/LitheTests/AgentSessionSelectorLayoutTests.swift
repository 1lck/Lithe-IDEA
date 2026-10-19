import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent selector layout", .serialized)
struct AgentSessionSelectorLayoutTests {
    @Test(arguments: [true, false])
    func chatOptionsMenuInvokesEachExistingAction(showsToolbar: Bool) async throws {
        for scheme in [ColorScheme.dark, .light] {
            for target in 0..<4 {
                var invoked: Int?
                let host = NSHostingView(rootView: AgentChatHeader(agentName: "Codex", onHistory: nil,
                    onNew: {}, onOpenSettings: { invoked = 2 }, onHide: {},
                    onRename: { invoked = 0 }, onDelete: { invoked = 1 }, showsToolbar: showsToolbar,
                    onToggleToolbar: { invoked = 3 }).environment(\.colorScheme, scheme))
                let window = makeWindow(host, size: NSSize(width: 440, height: 66))
                defer { window.contentView = nil; window.close() }
                let anchor = try #require(dropdownAnchors(in: host).max {
                    $0.convert($0.bounds, to: host).midX < $1.convert($1.bounds, to: host).midX
                })
                try click(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), in: anchor, window: window)
                try #require(await waitUntil(updating: host) { popup(in: window) != nil })
                let menu = try #require(popup(in: window))
                try capture(try #require(menu.contentView), name: "chat-options-\(scheme)-\(showsToolbar)")
                for _ in 0...target { try sendKey(125, to: menu) }
                try sendKey(36, to: menu)
                #expect(await waitUntil(updating: host) { invoked == target })
                #expect(!menu.isVisible)
            }
        }
    }

    @Test
    func showToolbarRemovesAndRestoresComposerControls() async throws {
        let options = [
            AgentSessionConfigOption(id: "mode", name: "Mode", category: "mode", currentValue: "manual",
                choices: [.init(id: "manual", name: "Manual")]),
            AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "sol",
                choices: [.init(id: "sol", name: "6.1 Sol")])
        ]
        for scheme in [ColorScheme.dark, .light] {
            func composer(_ visible: Bool) -> some View {
                AgentComposerView(agents: [], selectedAgent: .init(id: "codex", name: "Codex"),
                    isResponding: false, isBlocked: false, onSend: { _, _ in }, onCancel: {},
                    onSelectAgent: { _ in }, onOpenSettings: {}, onError: { _ in },
                    configOptions: options, showsToolbar: visible).environment(\.colorScheme, scheme)
            }
            let host = NSHostingView(rootView: composer(true))
            let window = makeWindow(host, size: NSSize(width: 440, height: 140))
            defer { window.contentView = nil; window.close() }
            try #require(await waitUntil(updating: host) { dropdownAnchors(in: host).count == 4 })
            let anchor = try #require(dropdownAnchors(in: host).max {
                $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY
            })
            try click(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), in: anchor, window: window)
            try #require(await waitUntil(updating: host) { popup(in: window) != nil })
            host.rootView = composer(false)
            #expect(await waitUntil(updating: host) { dropdownAnchors(in: host).isEmpty && popup(in: window) == nil })
            try capture(host, name: "composer-toolbar-hidden-\(scheme)")
            host.rootView = composer(true)
            #expect(await waitUntil(updating: host) { dropdownAnchors(in: host).count == 4 })
        }
    }

    @Test
    func sessionDetailsKeepsOneEntryBeforeAndAfterContextUsageArrives() async throws {
        let usage = try #require(AgentContextUsage(usedTokens: 1200, capacityTokens: 10000))
        for scheme in [ColorScheme.dark, .light] {
            func composer(_ usage: AgentContextUsage?) -> some View {
                AgentComposerView(agents: [], selectedAgent: .init(id: "codex", name: "Codex"),
                    isResponding: false, isBlocked: false, onSend: { _, _ in }, onCancel: {},
                    onSelectAgent: { _ in }, onOpenSettings: {}, onError: { _ in },
                    contextUsage: usage).environment(\.colorScheme, scheme)
            }
            let host = NSHostingView(rootView: composer(nil))
            let window = makeWindow(host, size: NSSize(width: 320, height: 180))
            defer { window.contentView = nil; window.close() }
            // The shared details entry is available even before the first usage report.
            try #require(await waitUntil(updating: host) { dropdownAnchors(in: host).count == 2 })
            try capture(host, name: "context-ring-unreported-\(scheme)")
            host.rootView = composer(usage)
            try #require(await waitUntil(updating: host) { dropdownAnchors(in: host).count == 2 },
                          "Reporting context usage must not add a second details entry")
            // The ring sits in the bottom command bar, left of Send.
            let triggers = dropdownAnchors(in: host).sorted {
                let lhs = $0.convert($0.bounds, to: nil), rhs = $1.convert($0.bounds, to: nil)
                return abs(lhs.midY - rhs.midY) > 1 ? lhs.midY > rhs.midY : lhs.midX < rhs.midX
            }
            let trigger = try #require(triggers.last)
            #expect(trigger.convert(trigger.bounds, to: nil).midY < 90, "Context stays in the bottom command bar")
            try capture(host, name: "context-ring-reported-\(scheme)")
        }
    }

    @Test(arguments: [true, false], [280.0, 540.0])
    func unifiedDetailsScrollAndDismissInBothUsageStates(reported: Bool, width: CGFloat) async throws {
        let usage = try #require(AgentContextUsage(usedTokens: 1200, capacityTokens: 10000))
        var conversation = AgentConversation()
        conversation.completedTurns = [.init(id: "turn", startedAt: .now)]
        conversation.recordModelCall(try #require(AgentModelCall.parse([
            "api": "anthropicMessages", "status": 200, "streaming": true, "firstTokenMs": 700, "durationMs": 1250,
            "usage": ["inputTokens": 1200, "cacheReadTokens": 600, "cacheWriteTokens": 0, "outputTokens": 165]
        ])))
        for scheme in [ColorScheme.dark, .light] {
            for language in ["en", "zh-Hans"] {
                let locale = Locale(identifier: language)
                func composer(_ sessionID: String, showsToolbar: Bool = true) -> some View {
                    AgentComposerView(agents: [], selectedAgent: .init(id: "codex", name: "Codex"),
                        isResponding: true, isBlocked: false, onSend: { _, _ in }, onCancel: {},
                        onSelectAgent: { _ in }, onOpenSettings: {}, onError: { _ in }, sessionID: sessionID,
                        contextUsage: reported ? usage : nil, sessionStatistics: conversation.sessionStatistics,
                        showsToolbar: showsToolbar).environment(\.colorScheme, scheme).environment(\.locale, locale)
                }
                let host = NSHostingView(rootView: composer("first"))
                let window = makeWindow(host, size: NSSize(width: width, height: 180))
                defer { window.contentView = nil; window.close() }
                try #require(await waitUntil(updating: host) { dropdownAnchors(in: host).count == 2 })
                let trigger = try #require(dropdownAnchors(in: host).max {
                    $0.convert($0.bounds, to: host).midX < $1.convert($1.bounds, to: host).midX
                })
                #expect(trigger.convert(trigger.bounds, to: host).midY < 90,
                        "The single details entry stays beside Send with or without context usage")
                func openDetails() async throws -> NSPanel {
                    try click(NSPoint(x: trigger.bounds.midX, y: trigger.bounds.midY), in: trigger, window: window)
                    try #require(await waitUntil(updating: host) { popup(in: window) != nil })
                    return try #require(popup(in: window))
                }
                let panel = try await openDetails()
                let content = try #require(panel.contentView)
                #expect(panel.frame.width >= 240)
                let name = "unified-details-\(scheme)-\(language)-\(Int(width))-\(reported)"
                try capture(content, name: name)
                let scroll = try #require(scrollView(in: content))
                let document = try #require(scroll.documentView)
                #expect(document.bounds.height > scroll.contentView.bounds.height,
                        "Combined context, session and token details remain in one scrollable document")
                let bottom = max(0, document.bounds.maxY - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                try #require(await waitUntil(updating: content) {
                    abs(scroll.contentView.bounds.minY - bottom) < 1
                }, "The same popup must scroll to its final token details")
                try capture(content, name: name + "-tokens")
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                try #require(await waitUntil(updating: content) { abs(scroll.contentView.bounds.minY) < 1 })
                let inset = 14 + LitheTheme.Metrics.toolbarIconButtonSize / 2
                let y = document.isFlipped ? document.bounds.minY + inset : document.bounds.maxY - inset
                try click(NSPoint(x: document.bounds.maxX - inset, y: y), in: document, window: panel)
                try #require(await waitUntil(updating: host) { popup(in: window) == nil }, "Close dismisses all details")
                _ = try await openDetails()
                try sendKey(53, to: try #require(popup(in: window)))
                #expect(await waitUntil(updating: host) { popup(in: window) == nil }, "Escape dismisses the shared popup")
                _ = try await openDetails()
                host.rootView = composer("second")
                #expect(await waitUntil(updating: host) { popup(in: window) == nil }, "Switching sessions closes stale details")
                _ = try await openDetails()
                host.rootView = composer("second", showsToolbar: false)
                #expect(await waitUntil(updating: host) { popup(in: window) == nil && dropdownAnchors(in: host).isEmpty })
            }
        }
    }

    @Test(arguments: [280.0, 540.0])
    func subscriptionQuotaSharesTheFooterWithoutClickPopup(width: CGFloat) async throws {
        let snapshot = try #require(AgentSubscriptionQuota.parse([
            "windows": [
                ["id": "weekly", "name": "codex", "limitSeconds": 604800, "usedPercent": 36, "resetsAt": 4102444800],
                ["id": "short", "name": "codex", "limitSeconds": 18000, "usedPercent": 32, "resetsAt": 4102444800]
            ], "fetchedAt": 4102444800
        ] as [String: Any]))
        let options = [
            AgentSessionConfigOption(id: "mode", name: "Mode", category: "mode", currentValue: "manual",
                choices: [.init(id: "manual", name: "Manual")]),
            AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "sol",
                choices: [.init(id: "sol", name: "6.1 Sol")])
        ]
        for scheme in [ColorScheme.dark, .light] {
            func composer(_ session: String) -> some View {
                AgentComposerView(agents: [], selectedAgent: .init(id: "codex", name: "Codex"),
                    isResponding: false, isBlocked: false, onSend: { _, _ in }, onCancel: {},
                    onSelectAgent: { _ in }, onOpenSettings: {}, onError: { _ in }, configOptions: options,
                    sessionID: session, showsSubscriptionQuota: true, subscriptionQuota: snapshot,
                    subscriptionAccount: "person@example.test").environment(\.colorScheme, scheme)
            }
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                Spacer(minLength: 0)
                composer("first").frame(height: 180)
            }.background(LitheTheme.editor).workbenchHoverTooltipScope())
            let window = makeWindow(host, size: NSSize(width: width, height: 400))
            defer { window.contentView = nil; window.close() }
            try #require(await waitUntil(updating: host) { dropdownAnchors(in: host).count == 4 })
            let anchors = dropdownAnchors(in: host)
            let details = try #require(anchors.max { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX })
            let rect = details.convert(details.bounds, to: host)
            let summaryPoint = NSPoint(x: rect.minX - 4 - LitheTheme.Metrics.toolbarIconButtonSize / 2, y: rect.midY)
            #expect(summaryPoint.x > 0, "The quota ring stays inside the compact footer")
            #expect(anchors.allSatisfy { abs($0.convert($0.bounds, to: host).midY - rect.midY) < 1 },
                    "All dropdowns share one footer; no top strip remains")
            #expect(anchors.filter { $0 !== details }.count == 3, "Quota remains a hover source rather than another dropdown")
            try capture(host, name: "quota-summary-\(width)-\(scheme)")
            try click(summaryPoint, in: host, window: window)
            #expect(popup(in: window) == nil, "The summary must not open a persistent click panel")
            // SwiftUI hover transitions belong to WindowServer. Shared hover
            // rendering/state tests cover that owner; real pointer entry/exit
            // is checked in the preview instead of faking private tracking areas.

        }
    }

    @Test
    func subscriptionQuotaBarsRenderBothPeriodsThresholdsAndMissingValues() throws {
        for scheme in [ColorScheme.dark, .light] {
            for (name, used, weeklyOnly) in [("green", 32.0, false), ("yellow", 75.0, false),
                                             ("red", 95.0, false), ("unknown", -1.0, false), ("weekly", 36.0, true)] {
                var windows: [[String: Any]] = [
                    ["id": "weekly", "name": "codex", "limitSeconds": 604800, "usedPercent": 36, "resetsAt": 1800000200]
                ]
                if !weeklyOnly {
                    windows.append(["id": "short", "name": "codex", "limitSeconds": 18000,
                                    "usedPercent": used < 0 ? NSNull() : used as Any, "resetsAt": 1800000200])
                }
                let snapshot = try #require(AgentSubscriptionQuota.parse(["windows": windows, "fetchedAt": 1800000000]))
                let host = NSHostingView(rootView: AgentSubscriptionQuotaPanel(quota: snapshot,
                    account: "person@example.test", failure: nil, stale: false)
                    .padding(12).frame(width: 300).litheHoverTooltipSurface()
                    .environment(\.colorScheme, scheme))
                let window = makeWindow(host, size: NSSize(width: 300, height: 300))
                defer { window.contentView = nil; window.close() }
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width <= 300)
                try capture(host, name: "quota-bars-\(name)-\(scheme)")
            }
        }
    }

    @Test(arguments: [false, true])
    func compactModelPanelShowsCatalogWithoutSearchAndKeepsReasoningInline(isEmpty: Bool) async throws {
        let model = AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "sol",
            choices: isEmpty ? [] : [.init(id: "sol", name: "6.1 Sol"), .init(id: "astra", name: "6 Astra")])
        let effort = AgentSessionConfigOption(id: "effort", name: "Reasoning", category: "thought_level", currentValue: "medium",
            choices: [.init(id: "medium", name: "Medium"), .init(id: "high", name: "High")])
        for scheme in [ColorScheme.dark, .light] {
            var selected: (String, String)?
            let host = NSHostingView(rootView: AgentModelPopover(option: model, settings: [effort], agentName: "Codex") {
                selected = ($0, $1)
            }.environment(\.colorScheme, scheme))
            let window = makeWindow(host, size: host.fittingSize)
            defer { window.contentView = nil; window.close() }
            #expect(window.frame.width <= LitheDropdownMetrics.maximumWidth, "The effort row must fit the bounded shared panel")
            #expect(dropdownAnchors(in: host).isEmpty, "Reasoning choices are inline rather than a nested menu")
            let scroll = try #require(scrollView(in: host))
            let document = try #require(scroll.documentView)
            #expect(editableFields(in: host).isEmpty, "The model panel must not contain a search field")
            #expect(abs(document.bounds.height - (isEmpty ? 36 : 2 * LitheDropdownMetrics.rowHeight)) < 1,
                    "Only the complete model catalog or its empty state belongs to the scroll area")
            if !isEmpty {
                try click(NSPoint(x: 70, y: LitheDropdownMetrics.rowHeight * 1.5), in: document, window: window)
                #expect(await waitUntil(updating: host) { selected?.0 == "model" && selected?.1 == "astra" })
            }
            let effortY = host.isFlipped ? host.bounds.maxY - 21 : host.bounds.minY + 21
            try click(NSPoint(x: host.bounds.maxX - 34, y: effortY), in: host, window: window)
            #expect(await waitUntil(updating: host) { selected?.0 == "effort" && selected?.1 == "high" })
            try capture(host, name: "model-compact-no-search-\(scheme)-\(isEmpty)")
        }
    }

    @Test
    func effortKeepsTheSamePanelThroughPendingRejectedAndConfirmedChanges() async throws {
        for scheme in [ColorScheme.dark, .light] {
            let fixture = AgentEffortPanelFixture()
            let host = NSHostingView(rootView: AgentEffortPanelFixtureView(fixture: fixture)
                .environment(\.colorScheme, scheme))
            let window = makeWindow(host, size: NSSize(width: 340, height: 40))
            defer { window.contentView = nil; window.close() }
            window.makeKeyAndOrderFront(nil)
            let trigger = try #require(dropdownAnchors(in: host).first)
            try click(NSPoint(x: trigger.bounds.midX, y: trigger.bounds.midY), in: trigger, window: window)
            try #require(await waitUntil(updating: host) { popup(in: window) != nil })
            let panel = try #require(popup(in: window))
            let content = try #require(panel.contentView)
            #expect(editableFields(in: content).isEmpty)
            let document = try #require(scrollView(in: content)?.documentView)
            try #require(await waitUntil(updating: content) { abs(document.bounds.height - 2 * LitheDropdownMetrics.rowHeight) < 1 })
            // Observe the constant Effort label's rendered opacity inside the
            // popup. Its separate hosting transaction can lag the fixture update;
            // exclude the value and track so selection/focus cannot satisfy this.
            func effortLabelPixels() -> Data? {
                let y = content.isFlipped ? content.bounds.maxY - 21 : content.bounds.minY + 21
                let rect = NSRect(x: LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.itemHorizontalPadding,
                                  y: y - 8, width: 30, height: 16)
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
                content.cacheDisplay(in: rect, to: bitmap)
                return bitmap.representation(using: .png, properties: [:])
            }
            let enabledLabel = try #require(effortLabelPixels())
            func effortEnabled(_ enabled: Bool) -> Bool {
                guard let current = effortLabelPixels() else { return false }
                return (current == enabledLabel) == enabled
            }
            func selectEffort(_ index: Int) throws {
                let right = content.bounds.maxX - LitheDropdownMetrics.popupPadding - LitheDropdownMetrics.itemHorizontalPadding
                let slot = AgentReasoningEffortControl.trackWidth(for: fixture.options[1]) / 6
                let y = content.isFlipped ? content.bounds.maxY - 21 : content.bounds.minY + 21
                try click(NSPoint(x: right - slot * (5.5 - CGFloat(index)), y: y), in: content, window: panel)
            }
            try selectEffort(5)
            try #require(await waitUntil(updating: content) { fixture.requests == ["ultra"] && effortEnabled(false) })
            #expect(popup(in: window) === panel, "Configuration pending must disable the existing panel without closing it")
            try selectEffort(0)
            layoutFrame(content)
            #expect(fixture.requests == ["ultra"], "Repeated clicks while waiting cannot send another configuration request")

            // A rejection keeps the authoritative Medium value in the same panel.
            fixture.isDisabled = false
            try #require(await waitUntil(updating: content) { effortEnabled(true) })
            try selectEffort(1)
            layoutFrame(content)
            #expect(fixture.requests == ["ultra"], "The rejected value must not replace confirmed Medium")
            try selectEffort(2)
            try #require(await waitUntil(updating: content) { fixture.requests == ["ultra", "high"] && effortEnabled(false) })
            fixture.confirm("high")
            try #require(await waitUntil(updating: content) { effortEnabled(true) })
            #expect(popup(in: window) === panel)
            try selectEffort(2)
            layoutFrame(content)
            #expect(fixture.requests == ["ultra", "high"], "Confirmed High must update the control inside the same panel")
            try selectEffort(5)
            try #require(await waitUntil(updating: content) { fixture.requests == ["ultra", "high", "ultra"] && effortEnabled(false) })
            fixture.confirm("ultra")
            try #require(await waitUntil(updating: content) { effortEnabled(true) })
            try capture(content, name: "effort-panel-stays-open-\(scheme)")
            if scheme == .dark {
                try sendKey(53, to: panel)
            } else {
                try click(NSPoint(x: 70, y: LitheDropdownMetrics.rowHeight * 1.5), in: document, window: panel)
                #expect(await waitUntil(updating: host) { fixture.requests.last == "astra" })
            }
            #expect(await waitUntil(updating: host) { popup(in: window) == nil }, "Escape and choosing a model still close the panel")
        }
    }

    @Test(arguments: [2, 4, 6])
    func effortDotsUseTheActualCatalogAndKeepOneRow(count: Int) async throws {
        let names = count == 6 ? ["Low", "Medium", "High", "Xhigh", "Max", "Ultra"] : (0..<count).map { "Level \($0)" }
        let choices = names.enumerated().map { AgentSessionConfigOption.Choice(id: "provider-level-\($0.offset)", name: $0.element) }
        let option = AgentSessionConfigOption(id: "effort", name: "Reasoning", category: "thought_level",
            currentValue: choices[count == 6 ? 1 : 0].id, choices: choices)
        for scheme in [ColorScheme.dark, .light] {
            for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hans")] {
                var selections: [String] = []
                let host = NSHostingView(rootView: AgentReasoningEffortControl(option: option) { id, value in
                    #expect(id == "effort")
                    selections.append(value)
                }.background(LitheTheme.settingsPopupBackground)
                    .environment(\.colorScheme, scheme).environment(\.locale, locale))
                let width = AgentReasoningEffortControl.preferredWidth(for: option, locale: locale)
                let window = makeWindow(host, size: NSSize(width: width, height: LitheDropdownMetrics.rowHeight))
                defer { window.contentView = nil; window.close() }
                #expect(abs(host.fittingSize.height - LitheDropdownMetrics.rowHeight) < 1)
                let slot = AgentReasoningEffortControl.trackWidth(for: option) / CGFloat(count)
                let right = host.bounds.maxX - LitheDropdownMetrics.popupPadding - LitheDropdownMetrics.itemHorizontalPadding
                try click(NSPoint(x: right - slot / 2, y: host.bounds.midY), in: host, window: window)
                #expect(await waitUntil(updating: host) { selections == [choices[count - 1].id] },
                        "Each Agent's last actual choice must be selectable without an invented four-level mapping")
                try capture(host, name: "effort-dots-\(count)-\(scheme)-\(locale.identifier)")
            }
        }
    }

    @Test
    func effortDraggingCommitsOnlyOnReleaseAndDisabledControlsStayInert() async throws {
        let choices = ["Low", "Medium", "High", "Xhigh", "Max", "Ultra"].map {
            AgentSessionConfigOption.Choice(id: "upstream-\($0)", name: $0)
        }
        let option = AgentSessionConfigOption(id: "reasoning", name: "Reasoning", category: "thought_level",
            currentValue: choices[0].id, choices: choices)
        for disabled in [false, true] {
            var selections: [String] = []
            let host = NSHostingView(rootView: AgentReasoningEffortControl(option: option) { _, value in selections.append(value) }
                .disabled(disabled))
            let window = makeWindow(host, size: NSSize(width: AgentReasoningEffortControl.preferredWidth(for: option, locale: .current),
                                                      height: LitheDropdownMetrics.rowHeight))
            defer { window.contentView = nil; window.close() }
            let right = host.bounds.maxX - LitheDropdownMetrics.popupPadding - LitheDropdownMetrics.itemHorizontalPadding
            let left = right - AgentReasoningEffortControl.trackWidth(for: option)
            func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type,
                    location: host.convert(NSPoint(x: x, y: host.bounds.midY), to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            let release = try event(.leftMouseUp, x: right - 10)
            var released = false
            defer { if !released { window.sendEvent(release) } }
            window.sendEvent(try event(.leftMouseDown, x: left + 10))
            window.sendEvent(try event(.leftMouseDragged, x: left + 50))
            window.sendEvent(try event(.leftMouseDragged, x: right - 10))
            #expect(selections.isEmpty, "Dragging must not send a configuration request for every intermediate dot")
            window.sendEvent(release)
            released = true
            await withCheckedContinuation { gate in
                DispatchQueue.main.async { layoutFrame(host); gate.resume() }
            }
            #expect(await waitUntil(updating: host) { disabled ? selections.isEmpty : selections == [choices[5].id] })
        }
    }

    @Test
    func effortKeyboardStepsFromTheConfirmedUpstreamChoice() async throws {
        let option = AgentSessionConfigOption(id: "effort", name: "Reasoning", category: "thought_level", currentValue: "medium",
            choices: [.init(id: "low", name: "Low"), .init(id: "medium", name: "Medium"), .init(id: "high", name: "High")])
        var selections: [String] = []
        let host = NSHostingView(rootView: AgentReasoningEffortControl(option: option) { _, value in selections.append(value) })
        let window = makeWindow(host, size: NSSize(width: AgentReasoningEffortControl.preferredWidth(for: option, locale: .current),
                                                  height: LitheDropdownMetrics.rowHeight))
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        let right = host.bounds.maxX - LitheDropdownMetrics.popupPadding - LitheDropdownMetrics.itemHorizontalPadding
        let first = right - AgentReasoningEffortControl.trackWidth(for: option) * 5 / 6
        try click(NSPoint(x: first, y: host.bounds.midY), in: host, window: window)
        try #require(await waitUntil(updating: host) { selections == ["low"] })
        // Until an acknowledgement replaces the option, keyboard movement starts
        // from confirmed Medium, not the unconfirmed Low request.
        window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)))
        #expect(await waitUntil(updating: host) { selections == ["low", "high"] })
    }

    @Test(arguments: [false, true])
    func modelSettingFlyoutsFollowTheirRowWithoutExpandingTheModelPanel(atRightEdge: Bool) async throws {
        let model = AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "model-0",
            choices: (0..<8).map { .init(id: "model-\($0)", name: "Model \($0)") })
        let speed = AgentSessionConfigOption(id: "fast-mode", name: "Speed", category: "model_config", currentValue: "off",
            choices: [.init(id: "off", name: "Disabled"), .init(id: "on", name: "Enabled")])
        let effort = AgentSessionConfigOption(id: "effort", name: "Reasoning", category: "custom", currentValue: "high",
            choices: ["low", "medium", "high", "xhigh", "max"].map { .init(id: $0, name: $0) })
        let screen = try #require(NSScreen.main).visibleFrame
        for scheme in [ColorScheme.dark, .light] {
            var selected: (String, String)?
            let host = NSHostingView(rootView: AgentSessionSelectors(options: [model, speed, effort], agentName: "Codex",
                isDisabled: false, onSelect: { selected = ($0, $1) }).environment(\.colorScheme, scheme))
            let window = makeWindow(host, size: NSSize(width: 330, height: 36))
            window.setFrameOrigin(NSPoint(x: atRightEdge ? screen.maxX - 336 : screen.minX + 80, y: screen.midY - 100))
            defer { window.contentView = nil; window.close() }
            try #require(await waitUntil(updating: host) { dropdownAnchors(in: host).count == 1 }, "The model trigger must be laid out")
            let trigger = try #require(dropdownAnchors(in: host).first)
            try click(NSPoint(x: trigger.bounds.midX, y: trigger.bounds.midY), in: trigger, window: window)
            try #require(await waitUntil(updating: host) { popup(in: window) != nil }, "The model menu must open")
            let parent = try #require(popup(in: window))
            let parentContent = try #require(parent.contentView)
            try #require(await waitUntil(updating: parentContent) { dropdownAnchors(in: parentContent).count == 2 }, "Both settings rows must be laid out")
            let parentFrame = parent.frame
            for (index, setting) in [speed, effort].enumerated() {
                try #require(await waitUntil(updating: parentContent) {
                    dropdownAnchors(in: parentContent).count == 2
                }, "Both setting triggers must have native geometry before clicking")
                let rows = dropdownAnchors(in: parentContent).sorted {
                    parent.convertToScreen($0.convert($0.bounds, to: nil)).maxY > parent.convertToScreen($1.convert($1.bounds, to: nil)).maxY
                }
                let anchor = rows[index]
                let row = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                try click(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), in: anchor, window: parent)
                try #require(await waitUntil(updating: parentContent) { popup(in: parent) != nil },
                    "Setting \(setting.id) must open a child menu in \(scheme) mode (right edge: \(atRightEdge), parent visible: \(parent.isVisible), anchor: \(anchor.bounds))")
                let child = try #require(popup(in: parent))
                #expect(parent.isVisible && parent.frame == parentFrame,
                        "Opening a setting must not move, widen or dismiss the model panel")
                #expect(abs(child.frame.maxY - row.maxY - LitheDropdownMetrics.popupPadding) < 1,
                        "The flyout must follow its own row instead of the model panel's bottom")
                #expect(child.frame.height < parentFrame.height,
                        "Only the setting choices may contribute to the child background")
                #expect(child.frame.height > CGFloat(setting.choices.count) * LitheDropdownMetrics.rowHeight,
                        "Choice descriptions must have space beneath their titles")
                let childContent = try #require(child.contentView)
                let scroll = try #require(scrollView(in: childContent))
                let document = try #require(scroll.documentView)
                #expect(document.bounds.height <= scroll.contentView.bounds.height + 1,
                        "A short described menu must fit without hidden rows")
                if atRightEdge {
                    #expect(abs(child.frame.maxX - parentFrame.minX + LitheDropdownMetrics.submenuSpacing) < 1)
                } else {
                    #expect(abs(child.frame.minX - parentFrame.maxX - LitheDropdownMetrics.submenuSpacing) < 1)
                }
                try capture(try #require(child.contentView), name: "\(setting.id)-flyout-\(scheme)-\(atRightEdge)")
                if index == 0 {
                    try sendKey(53, to: child)
                    try #require(await waitUntil(updating: parentContent) { !child.isVisible && parent.isVisible },
                        "Escape must close just the child before opening the next setting")
                } else {
                    // A visible choice may already be hovered when keyboard navigation starts.
                    try movePointer(NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY),
                                    in: scroll.contentView, window: child)
                    // Establish the first row through the native pointer route, then
                    // wrap in both directions before confirming its upstream ID.
                    try movePointerToFirstRow(in: document, window: child)
                    try sendKey(126, to: child)
                    try sendKey(125, to: child)
                    try sendKey(36, to: child)
                    #expect(await waitUntil(updating: host) { selected?.0 == "effort" && selected?.1 == "low" },
                            "Keyboard selection must preserve the first upstream choice: rightEdge=\(atRightEdge), scheme=\(scheme), selected=\(String(describing: selected))")
                    #expect(await waitUntil(updating: host) { popup(in: window) == nil }, "Selecting a child choice closes both menus")
                    #expect(!child.isVisible, "The child must not survive as an orphaned popup")
                }
            }
        }
    }

    @Test
    func modelSettingsWithWrappedDescriptionsScrollToTheLastChoice() async throws {
        let screen = try #require(NSScreen.main).visibleFrame
        // Force overflow on every display size so this test exercises scrolling.
        let choiceCount = max(30, Int(ceil(screen.height / LitheDropdownMetrics.rowHeight)) + 1)
        let model = AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "model",
            choices: [.init(id: "model", name: "Model")])
        let setting = AgentSessionConfigOption(id: "custom", name: "Custom", category: "custom", currentValue: "choice-0",
            choices: (0..<choiceCount).map { .init(id: "choice-\($0)", name: "Choice \($0)",
                description: "An upstream explanation that wraps across the bounded menu width.\nA second line must stay inside this choice's row.") })
        for scheme in [ColorScheme.dark, .light] {
            var selected: String?
            let host = NSHostingView(rootView: AgentModelPopover(option: model, settings: [setting], agentName: "Codex") { id, value in
                #expect(id == "custom")
                selected = value
            }.environment(\.colorScheme, scheme).litheContextMenuSurface())
            let window = makeWindow(host, size: NSSize(width: 330, height: 110))
            window.setFrameOrigin(NSPoint(x: screen.minX + 80, y: screen.midY))
            defer { window.contentView = nil; window.close() }
            try #require(await waitUntil(updating: host) { dropdownAnchors(in: host).count == 1 }, "The custom setting must be laid out")
            let anchor = try #require(dropdownAnchors(in: host).first)
            try click(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), in: anchor, window: window)
            try #require(await waitUntil(updating: host) { popup(in: window) != nil }, "The long described menu must open")
            let child = try #require(popup(in: window))
            #expect(child.frame.width <= LitheDropdownMetrics.maximumWidth)
            #expect(screen.contains(child.frame), "Long described menus must stay on screen")
            let content = try #require(child.contentView)
            let scroll = try #require(scrollView(in: content))
            let document = try #require(scroll.documentView)
            #expect(document.bounds.height > scroll.contentView.bounds.height)
            // Reproduce a pointer already hovering a visible choice when the
            // keyboard takes over, without moving the user's physical cursor.
            try movePointer(NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY),
                            in: scroll.contentView, window: child)
            // Establish the first row through the real pointer route. An
            // incidental hover must not decide the keyboard's starting item.
            try movePointerToFirstRow(in: document, window: child)
            // Up from the first choice wraps to the final item and reveals it.
            try sendKey(126, to: child)
            #expect(await waitUntil(updating: content) { scroll.contentView.bounds.minY > 0 },
                    "Keyboard navigation must reveal the final choice: scheme=\(scheme), bounds=\(scroll.contentView.bounds)")
            try capture(content, name: "described-settings-scrolled-\(scheme)")
            try sendKey(36, to: child)
            #expect(await waitUntil(updating: host) { selected == "choice-\(choiceCount - 1)" },
                    "The final upstream ID must remain selectable: scheme=\(scheme), selected=\(String(describing: selected))")
            #expect(!child.isVisible)
        }
    }

    @Test(arguments: [280, 540])
    func respondingComposerOpensPermissionAndModelChoicesInBothThemes(width: CGFloat) async throws {
        let options = [
            AgentSessionConfigOption(id: "mode", name: "Mode", category: "mode", currentValue: "manual",
                choices: [.init(id: "manual", name: "Manual"), .init(id: "auto", name: "Auto")]),
            AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "model-a",
                choices: [.init(id: "model-a", name: "Model A"), .init(id: "model-b", name: "Model B")])
        ]
        for scheme in [ColorScheme.dark, .light] {
            var selections: [String: String] = [:]
            let host = NSHostingView(rootView: AgentComposerView(
                agents: [], selectedAgent: .init(id: "codex-acp", name: "Codex"),
                isResponding: true, isBlocked: false, onSend: { _, _ in }, onCancel: {},
                onSelectAgent: { _ in }, onOpenSettings: {}, onError: { _ in },
                configOptions: options, onSetConfig: { selections[$0] = $1 }
            ).environment(\.colorScheme, scheme))
            let window = makeWindow(host, size: NSSize(width: width, height: 200))
            defer {
                // Detaching the anchors dismisses their panels and removes event monitors.
                window.contentView = nil
                window.close()
            }
            for (category, value) in [("mode", "auto"), ("model", "model-b")] {
                try #require(await waitUntil(updating: host) {
                    dropdownAnchors(in: host).count == 4
                }, "The composer must lay out the Agent, approval and model triggers")
                // Agent, approval mode and model share the restored bottom strip.
                let anchors = dropdownAnchors(in: host).sorted {
                    let lhs = $0.convert($0.bounds, to: nil)
                    let rhs = $1.convert($1.bounds, to: nil)
                    return abs(lhs.midY - rhs.midY) > 1 ? lhs.midY < rhs.midY : lhs.minX < rhs.minX
                }
                let agentFrame = anchors[0].convert(anchors[0].bounds, to: nil)
                let modeFrame = anchors[1].convert(anchors[1].bounds, to: nil)
                let modelFrame = anchors[2].convert(anchors[2].bounds, to: nil)
                #expect(abs(agentFrame.midY - modelFrame.midY) < 1)
                #expect(modeFrame.minX >= agentFrame.maxX)
                #expect(modelFrame.minX >= modeFrame.maxX)
                #expect(abs(modeFrame.midY - modelFrame.midY) < 1)
                #expect(modelFrame.width > LitheTheme.Metrics.toolbarIconSize)
                try capture(host, name: "composer-model-footer-\(scheme)-\(Int(width))")
                let trigger = anchors[category == "mode" ? 1 : 2]
                try click(NSPoint(x: trigger.bounds.midX, y: trigger.bounds.midY), in: trigger, window: window)
                try #require(await waitUntil(updating: host) { popup(in: window) != nil }, "A native click must open the shared dropdown while responding")
                let panel = try #require(popup(in: window))
                let content = try #require(panel.contentView)
                let scroll = try #require(scrollView(in: content))
                let document = try #require(scroll.documentView)
                let rowHeight = document.bounds.height / 2
                try click(NSPoint(x: 100, y: rowHeight * 1.5), in: document, window: panel)
                #expect(await waitUntil(updating: host) { selections[category] == value }, "The open dropdown must preserve its selection callback")
                #expect(await waitUntil(updating: host) { popup(in: window) == nil }, "Choosing a value must dismiss the dropdown")
            }
        }
    }

    @Test(arguments: [2, 100])
    func modeUsesCompactSharedMenuAndRetainsSelection(count: Int) async throws {
        let option = AgentSessionConfigOption(id: "mode", name: "Mode", category: "mode", currentValue: "choice-0",
            choices: (0..<count).map { .init(id: "choice-\($0)", name: "Choice \($0)", description: "A long explanation must not create a tall mode card.") })
        for scheme in [ColorScheme.dark, .light] {
            var selected: String?
            let host = NSHostingView(rootView: AgentSessionSelectors(options: [option], agentName: "Codex", isDisabled: false) { _, value in selected = value }
                .frame(width: 320, height: 40).environment(\.colorScheme, scheme))
            let window = makeWindow(host, size: NSSize(width: 320, height: 40))
            defer { window.contentView = nil; window.close() }
            let anchor = try #require(dropdownAnchors(in: host).first)
            try click(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), in: anchor, window: window)
            let panel = try #require(await waitUntil(updating: host) { popup(in: window) != nil } ? popup(in: window) : nil)
            let content = try #require(panel.contentView)
            let scroll = try #require(scrollView(in: content))
            let document = try #require(scroll.documentView)
            #expect(panel.frame.width < 240, "Mode uses the measured shared menu width instead of a 350pt card")
            try capture(content, name: "mode-menu-\(scheme)-\(count)")
            if count == 2 {
                #expect(panel.frame.height < 100, "A heading and two single-line options remain compact")
                try click(NSPoint(x: 90, y: LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.rowHeight * 1.5), in: document, window: panel)
                #expect(await waitUntil(updating: host) { selected == "choice-0" })
            } else {
                for _ in 1..<count { try sendKey(125, to: panel) }
                try sendKey(36, to: panel)
                #expect(await waitUntil(updating: host) { selected == "choice-99" }, "Shared keyboard navigation reaches the final upstream mode")
            }
            #expect(!panel.isVisible, "Selection closes the shared menu")
            try capture(host, name: "mode-trigger-\(scheme)-\(count)")
        }
    }

    @Test
    func longModelListsScrollToTheirLastChoice() async throws {
        let choices: [AgentSessionConfigOption.Choice] = (0..<30).map {
            .init(id: "choice-\($0)", name: "Choice \($0)")
        }
        for scheme in [ColorScheme.dark, .light] {
            for category in ["model"] {
                let option = AgentSessionConfigOption(
                    id: category, name: category, category: category,
                    currentValue: "choice-0", choices: choices
                )
                var selected: String?
                let view = AnyView(AgentModelPopover(option: option, settings: [], agentName: "Claude") { id, value in
                        #expect(id == category)
                        selected = value
                    })
                let size = NSSize(width: 330, height: 290)
                let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
                let window = makeWindow(host, size: size)
                defer { window.close() }
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let scroll = try #require(scrollView(in: host))
                let document = try #require(scroll.documentView)
                #expect(document.bounds.height > scroll.contentView.bounds.height,
                        "A long list must exceed the viewport and remain scrollable")
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                #expect(scroll.contentView.bounds.minY > 0)
                let lastPoint = NSPoint(x: 100, y: document.bounds.maxY - 13)
                #expect(scroll.contentView.bounds.contains(lastPoint), "The final choice must be inside the scrolled viewport")
                try click(lastPoint, in: document, window: window)
                #expect(await waitUntil(updating: host) { selected == "choice-29" }, "Scrolling must make the final upstream choice selectable")
                try capture(host, name: "\(category)-scrolled-\(scheme)")
            }
        }
    }

    private func makeWindow<Content: View>(_ host: NSHostingView<Content>, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame.size = size
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap { editableFields(in: $0) }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func dropdownAnchors(in view: NSView) -> [LitheDropdownAnchorView] {
        if let anchor = view as? LitheDropdownAnchorView {
            return anchor.window != nil && !anchor.bounds.isEmpty ? [anchor] : []
        }
        return view.subviews.flatMap { dropdownAnchors(in: $0) }
    }

    private func popup(in window: NSWindow) -> NSPanel? {
        window.childWindows?.compactMap { $0 as? NSPanel }.first { $0.isVisible }
    }

    private func click(_ point: NSPoint, in view: NSView, window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            window.sendEvent(event)
        }
    }

    private func sendKey(_ code: UInt16, to window: NSWindow) throws {
        window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
    }

    private func movePointer(_ point: NSPoint, in view: NSView, window: NSWindow) throws {
        window.sendEvent(try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0
        )))
    }

    private func movePointerToFirstRow(in document: NSView, window: NSWindow) throws {
        let inset = LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.rowHeight / 2
        let y = document.isFlipped ? document.bounds.minY + inset : document.bounds.maxY - inset
        try movePointer(NSPoint(x: document.bounds.midX, y: y), in: document, window: window)
    }

    private func waitUntil(updating view: NSView, _ condition: () -> Bool) async -> Bool {
        // A mounted anchor can precede its geometry, and SwiftUI can schedule
        // another layout after a mouse action. Drive native work while waiting
        // on the actual window/callback, keeping the original local deadline.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        repeat {
            await Task.yield()
            layoutFrame(view)
            if condition() { return true }
        } while clock.now < deadline
        return condition()
    }

    private func layoutFrame(_ view: NSView) {
        // Pump one ready native source with zero wait, as in the transcript tests.
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
        view.layoutSubtreeIfNeeded()
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_SELECTOR_SCREENSHOTS"] else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}

@MainActor
private final class AgentEffortPanelFixture: ObservableObject {
    @Published var isDisabled = false
    @Published var options = [
        AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "sol",
            choices: [.init(id: "sol", name: "6.1 Sol"), .init(id: "astra", name: "6 Astra")]),
        AgentSessionConfigOption(id: "effort", name: "Reasoning", category: "thought_level", currentValue: "medium",
            choices: ["Low", "Medium", "High", "Xhigh", "Max", "Ultra"].map { .init(id: $0.lowercased(), name: $0) })
    ]
    private(set) var requests: [String] = []

    func select(_ id: String, _ value: String) {
        requests.append(value)
        isDisabled = true
    }

    func confirm(_ value: String) {
        options[1].currentValue = value
        isDisabled = false
    }
}

private struct AgentEffortPanelFixtureView: View {
    @ObservedObject var fixture: AgentEffortPanelFixture

    var body: some View {
        AgentSessionSelectors(options: fixture.options, agentName: "Codex",
                              isDisabled: fixture.isDisabled, onSelect: fixture.select)
    }
}

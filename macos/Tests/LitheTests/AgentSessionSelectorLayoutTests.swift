import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent selector layout", .serialized)
struct AgentSessionSelectorLayoutTests {
    @Test(arguments: [false, true])
    func modelSettingFlyoutsFollowTheirRowWithoutExpandingTheModelPanel(atRightEdge: Bool) async throws {
        let model = AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "model-0",
            choices: (0..<8).map { .init(id: "model-\($0)", name: "Model \($0)") })
        let speed = AgentSessionConfigOption(id: "fast-mode", name: "Speed", category: "model_config", currentValue: "off",
            choices: [.init(id: "off", name: "Disabled"), .init(id: "on", name: "Enabled")])
        let effort = AgentSessionConfigOption(id: "effort", name: "Reasoning", category: "thought_level", currentValue: "high",
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
                    // Use the real child keyboard route; selection must preserve the upstream ID.
                    try sendKey(125, to: child)
                    try sendKey(36, to: child)
                    #expect(await waitUntil(updating: host) { selected?.0 == "effort" && selected?.1 == "low" })
                    #expect(await waitUntil(updating: host) { popup(in: window) == nil }, "Selecting a child choice closes both menus")
                    #expect(!child.isVisible, "The child must not survive as an orphaned popup")
                }
            }
        }
    }

    @Test
    func modelSettingsWithWrappedDescriptionsScrollToTheLastChoice() async throws {
        let model = AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "model",
            choices: [.init(id: "model", name: "Model")])
        let setting = AgentSessionConfigOption(id: "custom", name: "Custom", category: "custom", currentValue: "choice-0",
            choices: (0..<30).map { .init(id: "choice-\($0)", name: "Choice \($0)",
                description: "An upstream explanation that wraps across the bounded menu width.\nA second line must stay inside this choice's row.") })
        for scheme in [ColorScheme.dark, .light] {
            var selected: String?
            let host = NSHostingView(rootView: AgentModelPopover(option: model, settings: [setting], agentName: "Codex") { id, value in
                #expect(id == "custom")
                selected = value
            }.environment(\.colorScheme, scheme).litheContextMenuSurface())
            let window = makeWindow(host, size: NSSize(width: 330, height: 110))
            let screen = try #require(NSScreen.main).visibleFrame
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
            // Up from an unnavigated menu selects its final item and scrolls it into view.
            try sendKey(126, to: child)
            #expect(await waitUntil(updating: content) { scroll.contentView.bounds.minY > 0 }, "Keyboard navigation must reveal the final choice")
            try capture(content, name: "described-settings-scrolled-\(scheme)")
            try sendKey(36, to: child)
            #expect(await waitUntil(updating: host) { selected == "choice-29" }, "The final upstream ID must remain selectable")
            #expect(!child.isVisible)
        }
    }

    @Test
    func respondingComposerOpensPermissionAndModelChoicesInBothThemes() async throws {
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
            let window = makeWindow(host, size: NSSize(width: 540, height: 200))
            defer {
                // Detaching the anchors dismisses their panels and removes event monitors.
                window.contentView = nil
                window.close()
            }
            for (category, value) in [("mode", "auto"), ("model", "model-b")] {
                try #require(await waitUntil(updating: host) {
                    dropdownAnchors(in: host).count == 3
                }, "The composer must lay out the Agent, approval and model triggers")
                // Shared dropdown anchors have the real trigger geometry; avoid guessed pixel offsets.
                let anchors = dropdownAnchors(in: host).sorted {
                    $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
                }
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

    @Test
    func twoLinePermissionDescriptionsHaveRoomAndKeepTheirSelectionAction() async throws {
        let description = "批准后才能修改文件。\n其他操作继续遵守权限规则。"
        let option = AgentSessionConfigOption(
            id: "mode", name: "Mode", category: "mode", currentValue: "manual",
            choices: [.init(id: "manual", name: "Manual", description: description),
                      .init(id: "auto", name: "Auto", description: description)]
        )
        for scheme in [ColorScheme.dark, .light] {
            var selected: String?
            let host = NSHostingView(rootView: AgentModePopover(option: option) { selected = $0 }
                .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh_Hans")))
            let window = makeWindow(host, size: NSSize(width: 350, height: 110))
            defer { window.close() }
            let scroll = try #require(scrollView(in: host))
            let document = try #require(scroll.documentView)
            try #require(await waitUntil(updating: host) {
                host.fittingSize.height >= document.bounds.height + 10
            }, "A short permission list must fit both description lines without scrolling")
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rowHeight = document.bounds.height / CGFloat(option.choices.count)
            #expect(rowHeight >= 48,
                    "The row must grow to fit a title and both description lines")
            #expect(rowHeight < 64,
                    "Wrapping must not restore the old excessive spacing")
            try click(NSPoint(x: 100, y: rowHeight / 2), in: document, window: window)
            #expect(await waitUntil(updating: host) { selected == "manual" }, "The rendered choice must preserve the upstream ID")
            try capture(host, name: "permission-two-lines-\(scheme)")
        }
    }

    @Test
    func longPermissionAndModelListsScrollToTheirLastChoice() async throws {
        let choices: [AgentSessionConfigOption.Choice] = (0..<30).map {
            .init(id: "choice-\($0)", name: "Choice \($0)")
        }
        for scheme in [ColorScheme.dark, .light] {
            for category in ["mode", "model"] {
                let option = AgentSessionConfigOption(
                    id: category, name: category, category: category,
                    currentValue: "choice-0", choices: choices
                )
                var selected: String?
                let view = category == "mode"
                    ? AnyView(AgentModePopover(option: option) { selected = $0 })
                    : AnyView(AgentModelPopover(option: option, settings: [], agentName: "Claude") { id, value in
                        #expect(id == category)
                        selected = value
                    })
                let size = NSSize(width: category == "mode" ? 350 : 330,
                                  height: category == "mode" ? 330 : 290)
                let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
                let window = makeWindow(host, size: size)
                defer { window.close() }
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

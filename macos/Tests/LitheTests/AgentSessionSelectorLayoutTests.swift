import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent selector layout", .serialized)
struct AgentSessionSelectorLayoutTests {
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
                try #require(await waitUntil {
                    host.layoutSubtreeIfNeeded()
                    return dropdownAnchors(in: host).count == 3
                }, "The composer must lay out the Agent, approval and model triggers")
                // Shared dropdown anchors have the real trigger geometry; avoid guessed pixel offsets.
                let anchors = dropdownAnchors(in: host).sorted {
                    $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
                }
                let trigger = anchors[category == "mode" ? 1 : 2]
                try click(NSPoint(x: trigger.bounds.midX, y: trigger.bounds.midY), in: trigger, window: window)
                try #require(await waitUntil { popup(in: window) != nil }, "A native click must open the shared dropdown while responding")
                let panel = try #require(popup(in: window))
                let content = try #require(panel.contentView)
                let scroll = try #require(scrollView(in: content))
                let document = try #require(scroll.documentView)
                let rowHeight = document.bounds.height / 2
                try click(NSPoint(x: 100, y: rowHeight * 1.5), in: document, window: panel)
                #expect(await waitUntil { selections[category] == value }, "The open dropdown must preserve its selection callback")
                #expect(await waitUntil { popup(in: window) == nil }, "Choosing a value must dismiss the dropdown")
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
            try #require(await waitUntil {
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height >= document.bounds.height + 10
            }, "A short permission list must fit both description lines without scrolling")
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rowHeight = document.bounds.height / CGFloat(option.choices.count)
            #expect(rowHeight >= 48,
                    "The row must grow to fit a title and both description lines")
            #expect(rowHeight < 64,
                    "Wrapping must not restore the old excessive spacing")
            try click(NSPoint(x: 100, y: rowHeight / 2), in: document, window: window)
            #expect(await waitUntil { selected == "manual" }, "The rendered choice must preserve the upstream ID")
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
                #expect(await waitUntil { selected == "choice-29" }, "Scrolling must make the final upstream choice selectable")
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
        if let anchor = view as? LitheDropdownAnchorView { return [anchor] }
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

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        // Native mouse events can publish a SwiftUI action asynchronously; wait on the callback, not a delay.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_SELECTOR_SCREENSHOTS"] else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}

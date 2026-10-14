import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent selector interactions", .serialized)
struct AgentSessionSelectorInteractionTests {
    @Test(arguments: ["choices", "currentValue", "description"], [ColorScheme.dark, .light])
    func upstreamSettingUpdateClosesOnlyItsSnapshot(change: String, scheme: ColorScheme) async throws {
        let state = SelectorState()
        let host = NSHostingView(rootView: SelectorHarness(state: state).environment(\.colorScheme, scheme))
        let window = makeWindow(host, size: NSSize(width: 330, height: 36))
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        let parent = try await openModelMenu(in: host, window: window)
        let content = try #require(parent.contentView)
        let field = try #require(textFields(in: content).first)
        #expect(parent.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Target", replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(await waitUntil(updating: content) { field.stringValue == "Target" }, "Model search must accept native editing")
        let anchor = try #require(anchors(in: content).first)
        try clickCenter(anchor, window: parent)
        try #require(await waitUntil(updating: content) { popup(in: parent) != nil }, "The setting child must open")
        let child = try #require(popup(in: parent))

        // A different option changes first: it must not invalidate this child.
        let parentHeight = parent.frame.height
        state.options[0].choices.append(.init(id: "another", name: "Another Target"))
        try #require(await waitUntil(updating: host) { parent.frame.height > parentHeight },
                     "The parent must render the unrelated model update before checking its child")
        #expect(field.stringValue == "Target")
        #expect(child.isVisible)
        switch change {
        case "choices": state.options[1].choices.removeLast()
        case "currentValue": state.options[1].currentValue = "low"
        default: state.options[1].choices[0].description = "Updated upstream explanation\nwith an additional line"
        }
        try #require(await waitUntil(updating: host) { !child.isVisible }, "An updated option must close its obsolete child snapshot")
        #expect(parent.isVisible && popup(in: window) === parent)
        #expect(field.stringValue == "Target", "Only the setting anchor may be rebuilt")
        #expect(state.selected == nil)

        try #require(await waitUntil(updating: content) { anchors(in: content).count == 1 }, "The replacement setting anchor must be laid out")
        try clickCenter(try #require(anchors(in: content).first), window: parent)
        try #require(await waitUntil(updating: content) { popup(in: parent) != nil }, "The updated child must reopen")
        let reopened = try #require(popup(in: parent))
        #expect(reopened !== child)
        let reopenedContent = try #require(reopened.contentView)
        let scroll = try #require(scrollView(in: reopenedContent))
        let document = try #require(scroll.documentView)
        if change == "choices" {
            // With high removed, Up must now target the sole remaining low choice.
            #expect(reopened.frame.height < child.frame.height)
        } else if change == "description" {
            #expect(reopened.frame.height > child.frame.height)
        } else {
            // The check must move from high to low after reopening.
            #expect(try checkPixels(in: document, row: 0) > checkPixels(in: document, row: 1))
        }
        try sendKey(change == "choices" ? 126 : 125, to: reopened)
        try sendKey(36, to: reopened)
        try #require(await waitUntil(updating: host) { state.selected?.1 == "low" }, "Reopened choices must use the latest upstream IDs")
        #expect(state.selected?.0 == "effort")
        #expect(await waitUntil(updating: host) { popup(in: window) == nil })
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func modelSearchCommitsIMEBeforeSubmittingTheFilteredChoice(scheme: ColorScheme) async throws {
        let state = SelectorState()
        state.options[0].choices[1].name = "你 Target"
        let host = NSHostingView(rootView: SelectorHarness(state: state).environment(\.colorScheme, scheme))
        let window = makeWindow(host, size: NSSize(width: 330, height: 36))
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        let parent = try await openModelMenu(in: host, window: window)
        let content = try #require(parent.contentView)
        let field = try #require(textFields(in: content).first)
        #expect(parent.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(parent.isVisible && state.selected == nil, "Composing must not submit or dismiss the model menu")
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        try #require(await waitUntil(updating: content) { field.stringValue == "你" }, "The committed search must reach the model filter")
        // Commit is distinct from submission; Return then selects the first filtered model.
        #expect(state.selected == nil)
        try sendKey(36, to: parent)
        try #require(await waitUntil(updating: host) { state.selected?.1 == "target" }, "Search submission must select the filtered upstream model")
        #expect(state.selected?.0 == "model")
        #expect(await waitUntil(updating: host) { popup(in: window) == nil })
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func realMouseMovementRestoresSelectionAfterKeyboardScrolling(scheme: ColorScheme) async throws {
        let state = SelectorState()
        state.options[1].choices = (0..<60).map { .init(id: "choice-\($0)", name: "Choice \($0)") }
        let host = NSHostingView(rootView: SelectorHarness(state: state).environment(\.colorScheme, scheme))
        let window = makeWindow(host, size: NSSize(width: 330, height: 36))
        defer { window.contentView = nil; window.close() }
        let parent = try await openModelMenu(in: host, window: window)
        let parentContent = try #require(parent.contentView)
        try clickCenter(try #require(anchors(in: parentContent).first), window: parent)
        try #require(await waitUntil(updating: parentContent) { popup(in: parent) != nil }, "The long child must open")
        let child = try #require(popup(in: parent))
        let childContent = try #require(child.contentView)
        let scroll = try #require(scrollView(in: childContent))
        let document = try #require(scroll.documentView)
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        try sendKey(126, to: child)
        try #require(await waitUntil(updating: childContent) { scroll.contentView.bounds.minY > 0 }, "Up must reveal the final choice")
        // A real mouseMoved event takes ownership back from keyboard navigation.
        // Target the previous visible row, then use Return to observe hover selection.
        let point = NSPoint(x: document.bounds.midX,
                            y: document.bounds.maxY - LitheDropdownMetrics.popupPadding - 1.5 * LitheDropdownMetrics.rowHeight)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: document.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: child.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))
        child.sendEvent(event)
        try sendKey(36, to: child)
        try #require(await waitUntil(updating: host) { state.selected?.1 == "choice-58" }, "Pointer hover must replace the previous keyboard target")
        #expect(await waitUntil(updating: host) { popup(in: window) == nil })
    }

    @Test(arguments: [false, true], [false, true])
    func embeddedSubmenuPointerSelectionUsesBothSidesAndSkipsDisabledRows(atRightEdge: Bool, targetsDisabled: Bool) async throws {
        var selected: String?
        let children: [LitheContextMenuItem] = [
            .action("Disabled", isEnabled: false) { selected = "disabled" },
            .action("First") { selected = "first" },
            .action("Second") { selected = "second" }
        ]
        let presenter = LitheContextMenuPresenter()
        let window = makeWindow(NSView(), size: NSSize(width: 100, height: 100))
        defer { presenter.dismiss(); window.contentView = nil; window.close() }
        let screen = try #require(NSScreen.main).visibleFrame
        presenter.show(items: [.submenu("Move", items: children)],
                       at: NSPoint(x: atRightEdge ? screen.maxX - 10 : screen.minX + 100, y: screen.midY),
                       appearance: nil, locale: Locale(identifier: "en"), parentWindow: window)
        let panel = try #require(popup(in: window))
        let content = try #require(panel.contentView)
        try sendKey(125, to: panel)
        try sendKey(124, to: panel)
        try #require(await waitUntil(updating: content) { scrollViews(in: content).count == 2 }, "The embedded child must be laid out")
        let scroll = try #require(scrollViews(in: content).first { ($0.documentView?.bounds.height ?? 0) > 40 })
        let document = try #require(scroll.documentView)
        let point = NSPoint(x: document.bounds.midX,
                            y: LitheDropdownMetrics.popupPadding + (targetsDisabled ? 0.5 : 2.5) * LitheDropdownMetrics.rowHeight)
        panel.sendEvent(try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: document.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0)))
        try sendKey(36, to: panel)
        #expect(await waitUntil(updating: content) { selected == (targetsDisabled ? "first" : "second") },
                "Pointer handoff must preserve the enabled keyboard target over a disabled row")
        #expect(!panel.isVisible)
    }

    private func openModelMenu(in host: NSView, window: NSWindow) async throws -> NSPanel {
        try #require(await waitUntil(updating: host) { anchors(in: host).count == 1 }, "The model trigger must be laid out")
        try clickCenter(try #require(anchors(in: host).first), window: window)
        try #require(await waitUntil(updating: host) { popup(in: window) != nil }, "The model menu must open")
        let parent = try #require(popup(in: window))
        let content = try #require(parent.contentView)
        try #require(await waitUntil(updating: content) { anchors(in: content).count == 1 },
                     "The setting row must be laid out")
        return parent
    }

    private func makeWindow(_ host: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 300), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame.size = size
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func anchors(in view: NSView) -> [LitheDropdownAnchorView] {
        if let anchor = view as? LitheDropdownAnchorView {
            return anchor.window != nil && !anchor.bounds.isEmpty ? [anchor] : []
        }
        return view.subviews.flatMap { anchors(in: $0) }
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap { textFields(in: $0) }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func popup(in window: NSWindow) -> NSPanel? {
        window.childWindows?.compactMap { $0 as? NSPanel }.first { $0.isVisible }
    }

    private func clickCenter(_ view: NSView, window: NSWindow) throws {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    private func sendKey(_ code: UInt16, to window: NSWindow) throws {
        window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)))
    }

    private func waitUntil(updating view: NSView, _ condition: () -> Bool) async -> Bool {
        // Finish pending native layout before checking geometry or callbacks;
        // queued dropdown updates must get an event-loop turn after a click.
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

    private func checkPixels(in view: NSView, row: Int) throws -> Int {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let rowHeight = (view.bounds.height - LitheDropdownMetrics.verticalPadding) / 2
        let middleY = LitheDropdownMetrics.popupPadding + (CGFloat(row) + 0.5) * rowHeight
        let background = try #require(bitmap.colorAt(x: Int((view.bounds.width - 9) * scale), y: Int(middleY * scale)))
        var count = 0
        for y in Int((middleY - 8) * scale)..<Int((middleY + 8) * scale) {
            for x in Int((view.bounds.width - 34) * scale)..<Int((view.bounds.width - 14) * scale) {
                let color = try #require(bitmap.colorAt(x: x, y: y))
                if abs(color.redComponent - background.redComponent) > 0.1
                    || abs(color.greenComponent - background.greenComponent) > 0.1
                    || abs(color.blueComponent - background.blueComponent) > 0.1 { count += 1 }
            }
        }
        return count
    }

}

@MainActor
private final class SelectorState: ObservableObject {
    @Published var options = [
        AgentSessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "first",
            choices: [.init(id: "first", name: "First"), .init(id: "target", name: "Target")]),
        AgentSessionConfigOption(id: "effort", name: "Reasoning", category: "thought_level", currentValue: "high",
            choices: [.init(id: "low", name: "low"), .init(id: "high", name: "high")])
    ]
    var selected: (String, String)?
}

private struct SelectorHarness: View {
    @ObservedObject var state: SelectorState

    var body: some View {
        AgentSessionSelectors(options: state.options, agentName: "Codex", isDisabled: false,
                              onSelect: { state.selected = ($0, $1) })
    }
}

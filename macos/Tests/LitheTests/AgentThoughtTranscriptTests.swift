import AppKit
import SwiftUI
import Testing
import LitheCoreContracts
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Thought transcript lifecycle", .serialized)
struct AgentThoughtTranscriptTests {
    @Test
    func alternatingThoughtsNarrationAndToolsHaveOneDisclosureAndAVisibleReply() async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        try await withTranscript { feature, host, window in
            for (kind, text) in [("agent_message_chunk", "I will read the project"),
                                 ("agent_thought_chunk", "Check the source layout")] {
                feature.receive("""
                {"kind":"update","sessionId":"first","update":{"sessionUpdate":"\(kind)",\
                "content":{"type":"text","text":"\(text)"}}}
                """)
            }
            feature.receive("""
            {"kind":"update","sessionId":"first","update":{"sessionUpdate":"tool_call",\
            "toolCallId":"read","title":"Read README","kind":"read","status":"completed"}}
            """)
            feature.receive("""
            {"kind":"update","sessionId":"first","update":{"sessionUpdate":"agent_message_chunk",\
            "content":{"type":"text","text":"This is the final answer."}}}
            """)
            feature.receive("""
            {"kind":"turnFinished","sessionId":"first"}
            """)
            @MainActor func headers() -> [AnyObject] {
                accessibilityElements(in: host).filter { $0.accessibilityIdentifier?() == "agent-process-group-header" }
            }
            try await renderUntil(host, expected: "one process disclosure") { headers().count == 1 }
            let header = try #require(headers().first)
            let frame = header.accessibilityFrame?() ?? .zero
            #expect(frame.height < 32, "Collapsed process should occupy one compact line")
            let collapsed = try snapshot(host)
            try record(host, name: "mixed-collapsed")
            try pressThought(in: host, window: window)
            try await renderUntil(host, expected: "expanded ordered process") { try snapshot(host) != collapsed }
            #expect(headers().count == 1, "Individual thoughts must not create nested thinking headers")
            try record(host, name: "mixed-expanded")
            try pressThought(in: host, window: window)
            try await renderUntil(host, expected: "compact reply after collapsing") { try snapshot(host) == collapsed }
        }
    }

    @Test
    func manualExpansionSurvivesNonmatchingSearchRemovingAndRecreatingTheRow() async throws {
        try await withTranscript { feature, host, window in
            renderFrame(host)
            let collapsed = try snapshot(host)
            try record(host, name: "collapsed")
            try pressThought(in: host, window: window)
            try await renderUntil(host, expected: "expanded thought") { try snapshot(host) != collapsed }
            let expanded = try snapshot(host)
            try record(host, name: "expanded")

            host.rootView = transcript(feature, search: "no matching thought")
            try await renderUntil(host, expected: "filtered row") { try snapshot(host) != expanded && snapshot(host) != collapsed }
            try record(host, name: "filtered")
            // Visiting a new empty session disposes the real scroll subtree while search remains active.
            // Returning must retain this session's choice even after SwiftUI's lazy row cache is gone.
            let filtered = try snapshot(host)
            feature.selectSession("empty")
            try await renderUntil(host, expected: "empty conversation") { try snapshot(host) != filtered }
            feature.selectSession("first")
            host.rootView = transcript(feature)
            try await renderUntil(host, expected: "restored manual expansion") { try snapshot(host) == expanded }
            try record(host, name: "restored")
        }
    }

    @Test
    func matchingSearchRevealsACollapsedThoughtWithoutReplacingItsPreference() async throws {
        try await withTranscript { feature, host, window in
            renderFrame(host)
            let collapsed = try snapshot(host)
            try pressThought(in: host, window: window)
            try await renderUntil(host, expected: "manual expansion") { try snapshot(host) != collapsed }
            let expanded = try snapshot(host)
            try pressThought(in: host, window: window)
            try await renderUntil(host, expected: "manual collapse") { try snapshot(host) == collapsed }

            host.rootView = transcript(feature, search: "manifest")
            try await renderUntil(host, expected: "matching thought text") { try snapshot(host) == expanded }
            try pressThought(in: host, window: window)
            renderFrame(host)
            #expect(try snapshot(host) == expanded, "Searching must keep the matched reasoning visible after a click")
            host.rootView = transcript(feature)
            try await renderUntil(host, expected: "original manual collapse") { try snapshot(host) == collapsed }
        }
    }

    @Test
    func switchingSessionsKeepsIndependentPreferencesAndClosingResetsThem() async throws {
        try await withTranscript { feature, host, window in
            seedThought(in: feature, sessionID: "second")
            renderFrame(host)
            let collapsed = try snapshot(host)
            try pressThought(in: host, window: window)
            try await renderUntil(host, expected: "first session expanded") { try snapshot(host) != collapsed }
            let expanded = try snapshot(host)

            feature.selectSession("second")
            host.rootView = transcript(feature)
            try await renderUntil(host, expected: "second session default collapse") { try snapshot(host) == collapsed }
            feature.selectSession("first")
            host.rootView = transcript(feature)
            try await renderUntil(host, expected: "first session retained expansion") { try snapshot(host) == expanded }

            feature.closeConversation("first")
            host.rootView = transcript(feature)
            try await renderUntil(host, expected: "remaining session") { try snapshot(host) == collapsed }
            // Reopening the session with replayed messages must use the fresh row's default.
            seedThought(in: feature, sessionID: "first")
            feature.selectSession("first")
            host.rootView = transcript(feature)
            try await renderUntil(host, expected: "reopened session default") { try snapshot(host) == collapsed }
        }
    }

    private func withTranscript(
        _ run: (AgentConnectionModel, NSHostingView<AnyView>, NSWindow) async throws -> Void
    ) async throws {
        let feature = AgentConnectionModel(transport: UnusedThoughtTransport())
        seedThought(in: feature, sessionID: "first")
        feature.selectSession("first")
        let host = NSHostingView(rootView: transcript(feature))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.frame.size = NSSize(width: 360, height: 300)
        window.orderFront(nil)
        do {
            try await run(feature, host, window)
            await feature.stop()
        } catch {
            await feature.stop()
            throw error
        }
    }

    private func transcript(_ feature: AgentConnectionModel, search: String = "") -> AnyView {
        AnyView(AgentTranscriptView(feature: feature, agentName: "Fixture", agentVersion: nil,
                            agents: [], onSelectAgent: { _ in }, searchText: search)
            .background(AgentPanelStyle.canvas).environment(\.colorScheme, .dark))
    }

    private func seedThought(in feature: AgentConnectionModel, sessionID: String) {
        feature.receive("""
        {"kind":"update","sessionId":"\(sessionID)","update":{"sessionUpdate":"agent_thought_chunk",\
        "content":{"type":"text","text":"Find the manifest entry point"}}}
        """)
        feature.receive("""
        {"kind":"turnFinished","sessionId":"\(sessionID)"}
        """)
    }

    private func pressThought(in host: NSView, window: NSWindow) throws {
        // The fixture's only thought is the first transcript row, inside the 12pt padding.
        let point = NSPoint(x: 80, y: host.isFlipped ? 20 : host.bounds.height - 20)
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func accessibilityElements(in element: Any) -> [AnyObject] {
        let accessible = element as AnyObject
        let children = accessible.accessibilityChildren?() ?? []
        let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
        return [accessible] + descendants.flatMap { accessibilityElements(in: $0) }
    }

    private func renderFrame(_ host: NSView) {
        // Pump one native event without waiting: SwiftUI's lazy row disposal commits on the run loop.
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
    }

    // Compare complete frames from this one host, without font- or OS-specific golden images.
    private func snapshot(_ host: NSView) throws -> Data {
        let bitmap = try renderedBitmap(host)
        let pixels = try #require(bitmap.bitmapData)
        return Data(bytes: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func renderedBitmap(_ host: NSView) throws -> NSBitmapImageRep {
        host.displayIfNeeded()
        CATransaction.flush()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let layer = try #require(host.layer)
        context.cgContext.translateBy(x: 0, y: host.bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        layer.render(in: context.cgContext)
        return bitmap
    }

    private func record(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LITHE_THOUGHT_SCREENSHOTS"] else { return }
        let bitmap = try renderedBitmap(host)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    /// Wait for observable native rendering, with no fixed delay or private SwiftUI state access.
    private func renderUntil(_ host: NSView, expected: String, condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            renderFrame(host)
            if try condition() { return }
            await Task.yield()
        }
        #expect(try condition(), "Did not render \(expected) within two seconds")
        throw ThoughtRenderError.timeout
    }
}

private enum ThoughtRenderError: Error { case timeout }

@MainActor
private struct UnusedThoughtTransport: AgentConversationTransport {
    func open(configuration: AgentLaunchConfiguration, onEvent: @escaping @Sendable (String) -> Void) throws -> any AgentConnection {
        throw AgentConversationError.notConnected
    }
}

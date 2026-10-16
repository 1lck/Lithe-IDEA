import AppKit
import Testing
import LitheAgentConversationModule
@testable import Lithe

@Suite("Agent transcript navigation", .serialized)
@MainActor
struct AgentTranscriptNavigationTests {
    @Test
    func previewsKeepPromptsAndRepliesInTheirOwnTurn() {
        let messages: [AgentConversationMessage] = [
            .init(id: "orphan", role: .agent, text: "Earlier context"),
            .init(id: "first", role: .user, text: "检查第一份文件"),
            .init(id: "reasoning", role: .thought, text: "Private reasoning"),
            .init(id: "tool", role: .tool, text: "Tool output"),
            .init(id: "answer", role: .agent, text: "第一轮回答"),
            .init(id: "second", role: .user, text: "继续检查"),
            .init(id: "second-answer", role: .agent, text: "第二轮回答"),
            .init(id: "pending", role: .user, text: "尚未回复")
        ]
        let content = AgentTranscriptNavigationContent(messages: messages)
        #expect(content.entries.map(\.id) == ["first", "second", "pending"])
        #expect(content.entries.map(\.reply) == ["第一轮回答", "第二轮回答", ""])
        #expect(content.entries.first?.prompt == "检查第一份文件")
        #expect(content.turnByMessageID["tool"] == "first")
        #expect(content.turnByMessageID["reasoning"] == "first")
        #expect(content.turnByMessageID["orphan"] == nil)
    }

    @Test
    func previewStorageStaysBoundedDuringLongStreamingReplies() {
        let content = AgentTranscriptNavigationContent(messages: [
            .init(id: "prompt", role: .user, text: String(repeating: "问", count: 10_000)),
            .init(id: "answer", role: .agent, text: String(repeating: "答", count: 100_000))
        ])
        #expect(content.entries.first?.prompt.count == 320)
        #expect(content.entries.first?.reply.count == 640)
    }

    @Test
    func nativeViewportTracksAllVisibleTurnsAndReleasesRemovedRows() throws {
        let state = AgentTranscriptNavigationState()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let document = NavigationDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let first = AgentTranscriptNavigationAnchor.Probe(frame: NSRect(x: 0, y: 0, width: 280, height: 160))
        let second = AgentTranscriptNavigationAnchor.Probe(frame: NSRect(x: 0, y: 160, width: 280, height: 200))
        let third = AgentTranscriptNavigationAnchor.Probe(frame: NSRect(x: 0, y: 360, width: 280, height: 240))
        [first, second, third].forEach(document.addSubview)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer {
            [first, second, third].forEach { $0.detach() }
            state.detach(from: scroll)
            window.contentView = nil
            window.close()
        }
        first.update(state: state, turnID: "first")
        second.update(state: state, turnID: "second")
        third.update(state: state, turnID: "third")
        state.attach(to: scroll)
        scroll.contentView.scroll(to: .zero)
        state.refreshVisibleTurns()
        #expect(state.visibleTurnIDs == ["first"])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        state.refreshVisibleTurns()
        #expect(state.visibleTurnIDs == ["first", "second"])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        state.refreshVisibleTurns()
        #expect(state.visibleTurnIDs == ["third"])
        third.removeFromSuperview()
        state.refreshVisibleTurns()
        #expect(state.visibleTurnIDs.isEmpty)
    }

    @Test
    func insetChangesRefreshVisibleTurnsWithoutScrolling() async throws {
        let state = AgentTranscriptNavigationState()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        scroll.automaticallyAdjustsContentInsets = false
        let document = NavigationDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let row = AgentTranscriptNavigationAnchor.Probe(frame: NSRect(x: 0, y: 70, width: 280, height: 20))
        let viewport = AgentTranscriptNavigationViewport.Probe(state: state)
        document.addSubview(row)
        document.addSubview(viewport)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { row.detach(); viewport.detach(); window.contentView = nil; window.close() }
        row.update(state: state, turnID: "covered")
        viewport.attach()
        scroll.contentView.scroll(to: .zero)
        // Drain the coalesced refresh, rather than directly invoking visibility:
        // changing insets alone must update the published rail markers.
        await withCheckedContinuation { gate in DispatchQueue.main.async { gate.resume() } }
        #expect(state.visibleTurnIDs == ["covered"])
        for bottom in [CGFloat(40), CGFloat(0), CGFloat(100), CGFloat(0)] {
            scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
            await withCheckedContinuation { gate in DispatchQueue.main.async { gate.resume() } }
            #expect(state.visibleTurnIDs == (bottom == 0 ? ["covered"] : []))
        }
        scroll.contentInsets = NSEdgeInsets(top: 80, left: 0, bottom: 0, right: 0)
        // AppKit may compensate the origin when adding a top inset. Keep the
        // viewport fixed here so only partial row visibility is under test.
        scroll.contentView.scroll(to: .zero)
        await withCheckedContinuation { gate in DispatchQueue.main.async { gate.resume() } }
        #expect(state.visibleTurnIDs == ["covered"])
        scroll.contentInsets = NSEdgeInsets(top: 90, left: 0, bottom: 0, right: 0)
        scroll.contentView.scroll(to: .zero)
        await withCheckedContinuation { gate in DispatchQueue.main.async { gate.resume() } }
        #expect(state.visibleTurnIDs.isEmpty)
    }

    @Test
    func explicitNavigationCancelsAnAlreadyQueuedBottomFollow() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let document = NavigationDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let follow = AgentTranscriptScrollAnchor.Probe(frame: .zero)
        document.addSubview(follow)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { follow.detach(); window.contentView = nil; window.close() }
        let navigation = AgentTranscriptNavigationState()
        navigation.attach(to: scroll)
        defer { navigation.detach(from: scroll) }
        follow.update(sessionID: "session", enabled: true, revision: .init(lastMessageID: "reply", lastText: "stream",
            lastUserMessageID: "prompt", messageCount: 2, completedTurns: 0, permissionID: nil, isResponding: true))
        navigation.beginNavigation()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        await withCheckedContinuation { gate in DispatchQueue.main.async { gate.resume() } }
        #expect(abs(scroll.contentView.bounds.minY - 40) < 1)
        document.frame.size.height = 800
        follow.update(sessionID: "session", enabled: true, revision: .init(lastMessageID: "reply", lastText: "more stream",
            lastUserMessageID: "prompt", messageCount: 2, completedTurns: 0, permissionID: nil, isResponding: true))
        await withCheckedContinuation { gate in DispatchQueue.main.async { gate.resume() } }
        #expect(abs(scroll.contentView.bounds.minY - 40) < 1)
    }
}

@MainActor
private final class NavigationDocument: NSView {
    override var isFlipped: Bool { true }
}

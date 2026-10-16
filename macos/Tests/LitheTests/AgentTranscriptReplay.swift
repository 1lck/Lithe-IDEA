import AppKit
import SwiftUI
import LitheCoreContracts
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
final class TranscriptReplay {
    private let panel: AgentConversationFeatureModel
    private let transport = ReplayTransport()
    private let phaseURL: URL
    private let preferencesDomain: String
    private let host: NSHostingView<AnyView>
    private let window: NSWindow
    private var feature: AgentConnectionModel { panel.selectedConnection! }

    init(phaseURL: URL, editorLayout: Bool = false) {
        self.phaseURL = phaseURL
        let preferencesDomain = "LitheTests.TranscriptReplay.\(UUID().uuidString)"
        self.preferencesDomain = preferencesDomain
        let preferences = UserDefaults(suiteName: preferencesDomain)!
        preferences.set(false, forKey: "lithe.agent.editor.showsDetails")
        panel = AgentConversationFeatureModel(transport: transport)
        panel.setAgents([.init(id: "fixture", name: "Fixture")])
        host = NSHostingView(rootView: AnyView(AgentConfiguredConversationView(feature: panel, setupError: nil,
            onSelectAgent: panel.selectAgent, onConnect: {}, onOpenSettings: {}, onHide: {},
            onCopySessionID: { _ in }, onOpenFile: { _ in }, isEditorLayout: editorLayout)
            .defaultAppStorage(preferences)
            .litheWorkbenchSurface(AgentPanelStyle.canvas)
            .environment(\.locale, Locale(identifier: "zh-Hans"))))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
    }

    func perform(browsingHistory: Bool, navigating: Bool = false) async throws {
        defer {
            window.contentView = nil
            window.close()
            UserDefaults.standard.removePersistentDomain(forName: preferencesDomain)
        }
        do { try await run(browsingHistory: browsingHistory, navigating: navigating); await panel.stop(); try phase("finished") }
        catch { await panel.stop(); throw error }
    }

    private func run(browsingHistory: Bool, navigating: Bool) async throws {
        try feature.connect(configuration: .init(agentID: "fixture", command: "", arguments: [],
            workspaceURL: URL(fileURLWithPath: "/example/project"),
            dataDirectory: URL(fileURLWithPath: "/example/agents"), providerProtocol: "responses",
            providerEndpoint: "https://example.invalid", apiKey: "", providerName: "Fixture",
            model: "", allowsInsecureHTTP: false))
        try receive(["kind": "ready", "agentName": "Fixture"])
        feature.prepareConversation()
        guard let token = transport.connection.commands.last?["token"] as? String else { throw ReplayError.missingSession }
        try receive(["kind": "sessionCreated", "sessionId": "replay", "token": token])
        try feature.send(String(repeating: "Read the file, fix addition, and run its tests. ", count: 20))
        try await layout("initial")
        for turn in 0..<4 {
            try update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text",
                "text": String(repeating: "历史回复第 \(turn) 步。", count: 40)]])
            try finish()
            try await layout("history-\(turn)")
            try feature.send(String(repeating: "请阅读文件并修改，然后运行测试。", count: 20))
            try await layout("history-prompt-\(turn)")
        }
        if navigating {
            window.setContentSize(NSSize(width: 1100, height: 700))
            try await layout("wide-navigation")
        }
        let scroll = try requireTranscriptScrollView(in: host)
        let clip = scroll.contentView
        if navigating {
            let scrollRect = scroll.convert(scroll.bounds, to: host)
            guard abs(scrollRect.maxX - host.bounds.maxX) <= 2 else { throw ReplayError.scrollbarWasNotAtEdge }
            try capture("wide-before-jump")
            let id = feature.selectedConversation!.messages.first(where: { $0.role == .user })!.id
            let button = try requireNavigationButton(id: "agent-turn-navigation-\(id)", in: host)
            guard button.accessibilityPerformPress?() == true else { throw ReplayError.navigationFailed(stage: "press-button") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while clip.bounds.minY > 20 {
                guard ContinuousClock.now < deadline else { throw ReplayError.navigationFailed(stage: "scroll-to-first-turn") }
                try await layout("jumping-to-first-turn")
            }
            let anchors = navigationAnchors(in: host).filter { $0.turnID == id }
            // SwiftUI lays out against the document width, which can differ from the native clip width.
            guard let document = scroll.documentView, let first = anchors.first else {
                throw ReplayError.navigationFailed(stage: "first-turn-anchor")
            }
            let row = first.convert(first.bounds, to: document)
            let column = document.bounds.width * AgentPanelStyle.editorContentWidthFraction
            guard abs(row.width - (column - 24)) < 1,
                  abs(row.minX - ((document.bounds.width - column) / 2 + 12)) < 1,
                  first.convert(first.bounds, to: clip).intersects(clip.bounds) else {
                throw ReplayError.navigationFailed(stage: "first-turn-column: \(row), document \(document.bounds)")
            }
            try capture("wide-after-jump")
        } else if browsingHistory { userScroll(scroll, to: clip.documentRect.minY) }
        let browsingY = clip.bounds.minY

        for tool in 0..<2 {
            try update(["sessionUpdate": "tool_call", "toolCallId": "read-\(tool)",
                "title": "Read file-\(tool).txt", "kind": "read", "status": "completed"])
            try await layout("read-\(tool)")
        }
        try await layout("after-tools-while-browsing")
        if browsingHistory {
            guard abs(clip.bounds.minY - browsingY) < 1 else { throw ReplayError.historyPositionWasLost }
        }
        try update(["sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "已阅读文件，准备修复并执行测试。"]])
        for (id, kind, title) in [("edit", "edit", "Edit sum.cjs"), ("test", "execute", "node sum.test.cjs")] {
            try update(["sessionUpdate": "tool_call", "toolCallId": id,
                "title": title, "kind": kind, "status": "in_progress"])
            try await layout("tool-\(id)")
            try receive(["kind": "permission", "sessionId": "replay", "requestId": id,
                "request": ["toolCall": ["toolCallId": id, "title": title, "kind": kind,
                    "status": "in_progress", "rawInput": ["command": title]],
                    "options": [["optionId": "allow_once", "name": "Yes, once", "kind": "allow_once"],
                                ["optionId": "reject_once", "name": "No", "kind": "reject_once"]]]])
            try update(["sessionUpdate": "notice", "severity": "warning", "title": "Tool advisory",
                        "description": "The tool is waiting for your permission. Existing history must remain readable."])
            guard let noticeID = feature.selectedConversation?.notice?.id else { throw ReplayError.missingNotice }
            try await layout("permission-\(id)")
            if !browsingHistory {
                // Inset changes queue native bottom-following after the render.
                // Await its visible result, rather than assuming one layout runs it.
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while clip.bounds.maxY - scroll.contentInsets.bottom < (scroll.documentView?.frame.maxY ?? 0) - 1 {
                    guard ContinuousClock.now < deadline else {
                        throw ReplayError.latestReplyWasNotVisible(document: scroll.documentView?.frame.maxY ?? 0,
                            viewport: clip.bounds.maxY, frame: clip.frame.maxY, inset: scroll.contentInsets.bottom)
                    }
                    try await layout("following-permission-\(id)")
                }
            }
            guard feature.selectedConversation?.permission?.id == id else { throw ReplayError.missingPermission }
            feature.answerPermission(optionID: "allow_once")
            try await layout("permission-answer-\(id)")
            guard feature.selectedConversation?.permission == nil else { throw ReplayError.remainingPermission }
            guard feature.selectedConversation?.notice?.id == noticeID else { throw ReplayError.missingNotice }
            feature.dismissNotice(noticeID, in: "replay")
            try await layout("notice-dismiss-\(id)")
            guard feature.selectedConversation?.notice == nil else { throw ReplayError.remainingNotice }
            if browsingHistory {
                guard abs(clip.bounds.minY - browsingY) < 1 else { throw ReplayError.historyPositionWasLost }
            }
            try update(["sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed"])
        }
        try update(["sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "Changes complete.\n\n```text\nTEST_PASSED\n```"]])
        try finish()
        for value in [280.0, 350, 620, 350] {
            window.setContentSize(NSSize(width: value, height: 600))
            try await layout("finished-width-\(value)")
        }
        guard feature.selectedConversation?.completedTurns.count == 5,
              feature.selectedConversation?.messages.last?.text.contains("TEST_PASSED") == true else {
            throw ReplayError.missingReply
        }
        if browsingHistory {
            userScroll(scroll, to: clip.documentRect.maxY - clip.bounds.height)
            try feature.send("继续检查这个临时项目。")
            try update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text",
                "text": String(repeating: "新的输出应保持在底部。", count: 40)]])
            try finish()
            try await layout("resumed-following")
        }
        try await layout("settled-bottom")
        // Native bottom following is queued after viewport changes; one render
        // transaction does not guarantee that the final follow operation ran.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while clip.documentRect.maxY - clip.bounds.maxY >= 2 {
            guard ContinuousClock.now < deadline else {
                throw ReplayError.latestReplyWasNotVisible(document: clip.documentRect.maxY, viewport: clip.bounds.maxY,
                    frame: scroll.documentView?.frame.maxY ?? 0, inset: scroll.contentInsets.bottom)
            }
            try await layout("settling-bottom")
        }
    }

    private func userScroll(_ scroll: NSScrollView, to y: CGFloat) {
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        var bounds = scroll.contentView.bounds
        bounds.origin.y = y
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    private func layout(_ name: String) async throws {
        try phase(name)
        await withCheckedContinuation { gate in
            DispatchQueue.main.async {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
                self.host.needsLayout = true
                self.host.layoutSubtreeIfNeeded()
                self.host.displayIfNeeded()
                CATransaction.flush()
                gate.resume()
            }
        }
    }

    private func capture(_ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LITHE_TRANSCRIPT_CAPTURE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: root.appendingPathComponent("\(name).png"))
    }

    private func requireTranscriptScrollView(in root: NSView) throws -> NSScrollView {
        if let scroll = root as? NSScrollView, scroll.contentView.documentRect.height > scroll.contentView.bounds.height,
           scroll.contentView.bounds.height > 200 { return scroll }
        for child in root.subviews {
            if let scroll = try? requireTranscriptScrollView(in: child) { return scroll }
        }
        throw ReplayError.missingScrollView
    }

    private func requireNavigationButton(id: String, in root: Any) throws -> AnyObject {
        // SwiftUI accessibility nodes expose selectors without adopting the
        // entire AppKit protocol. Bound traversal and skip repeated nodes.
        var pending: [AnyObject] = [root as AnyObject]
        var visited: Set<ObjectIdentifier> = []
        while let element = pending.popLast(), visited.count < 4096 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            if element.accessibilityIdentifier?() == id { return element }
            pending.append(contentsOf: (element.accessibilityChildren?() ?? []).map { $0 as AnyObject })
        }
        throw ReplayError.navigationFailed(stage: "find-accessible-button")
    }

    private func navigationAnchors(in root: NSView) -> [AgentTranscriptNavigationAnchor.Probe] {
        if let anchor = root as? AgentTranscriptNavigationAnchor.Probe { return [anchor] }
        return root.subviews.flatMap { navigationAnchors(in: $0) }
    }

    private func phase(_ name: String) throws { try name.write(to: phaseURL, atomically: true, encoding: .utf8) }
    private func finish() throws {
        try receive(["kind": "turnFinished", "sessionId": "replay", "stopReason": "end_turn",
            "usage": ["totalTokens": 25000, "inputTokens": 18000, "outputTokens": 2000]])
    }
    private func update(_ value: [String: Any]) throws { try receive(["kind": "update", "sessionId": "replay", "update": value]) }
    private func receive(_ value: [String: Any]) throws {
        feature.receive(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}

@MainActor
private final class ReplayTransport: AgentConversationTransport {
    let connection = ReplayConnection()
    func open(configuration: AgentLaunchConfiguration, onEvent: @escaping @Sendable (String) -> Void) throws -> any AgentConnection { connection }
}
@MainActor
private final class ReplayConnection: AgentConnection {
    var commands: [[String: Any]] = []
    func send(commandJSON: String) throws {
        guard let value = try JSONSerialization.jsonObject(with: Data(commandJSON.utf8)) as? [String: Any] else { throw ReplayError.invalidCommand }
        commands.append(value)
    }
    func close() async {}
}
private enum ReplayError: Error {
    case missingSession, missingPermission, remainingPermission, missingNotice, remainingNotice, missingReply, invalidCommand, missingScrollView, historyPositionWasLost
    case scrollbarWasNotAtEdge, navigationFailed(stage: String)
    case latestReplyWasNotVisible(document: CGFloat, viewport: CGFloat, frame: CGFloat, inset: CGFloat)
}

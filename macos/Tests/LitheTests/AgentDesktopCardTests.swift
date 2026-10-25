import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Claude Desktop cards")
struct AgentDesktopCardTests {
    private func tool(_ id: String, _ title: String, status: AgentConversationMessage.ToolStatus = .completed,
                      card: [String: Any]) -> AgentConversationMessage {
        var message = AgentConversationMessage(id: id, role: .tool, text: title, toolStatus: status)
        message.toolDetails.merge(["kind": "other", "_meta": ["lithe": ["claudeDesktop": card]]])
        return message
    }

    @Test
    func cardsParseFromHostMetadataAndRejectWhatTheyCannotShow() {
        #expect(AgentDesktopCard(["card": "chapter", "title": " Setup ", "summary": ""]) == .chapter(title: "Setup", summary: nil))
        #expect(AgentDesktopCard(["card": "nextStep", "actions": [["label": "Ship", "message": "Open the PR"], ["label": "", "message": "x"]]])
            == .nextStep(actions: [.init(label: "Ship", message: "Open the PR")]))
        #expect(AgentDesktopCard(["card": "nextStep", "actions": []]) == nil)
        #expect(AgentDesktopCard(["card": "task", "title": "Fix CI", "prompt": "Fix it", "state": "handedOff"])
            == .task(title: "Fix CI", summary: nil, prompt: "Fix it", state: .handedOff))
        #expect(AgentDesktopCard(["card": "task", "title": "Fix CI", "state": "unknown"])
            == .task(title: "Fix CI", summary: nil, prompt: nil, state: .proposed))
        // A pull request link is a button, so only web links are accepted.
        #expect(AgentDesktopCard(["card": "pullRequest", "action": "bound", "url": "file:///etc/passwd"]) == nil)
        #expect(AgentDesktopCard(["card": "pullRequest", "action": "monitored", "url": "https://github.com/o/r/pull/7", "number": 7, "autoFix": true])
            == .pullRequest(action: .monitored, url: URL(string: "https://github.com/o/r/pull/7")!, number: 7, autoFix: true, enabled: nil))
        #expect(AgentDesktopCard(["card": "directory", "action": "changed", "path": "/tmp/w"]) == .directory(action: .changed, path: "/tmp/w"))
        #expect(AgentDesktopCard(["card": "widget", "title": "Flow", "code": NSNull()]) == nil)
        #expect(AgentDesktopCard(["card": "future"]) == nil)
    }

    @Test
    func aLaterUpdateRestatesTheCardWithoutAnUpdateWithoutOneClearingIt() {
        var details = AgentToolDetails()
        details.merge(["_meta": ["lithe": ["claudeDesktop": ["card": "task", "title": "Fix CI", "state": "proposed"]]]])
        details.merge(["status": "completed", "rawOutput": "task_7 proposed"])
        #expect(details.desktopCard == .task(title: "Fix CI", summary: nil, prompt: nil, state: .proposed))
        details.merge(["_meta": ["lithe": ["claudeDesktop": ["card": "task", "title": "Fix CI", "state": "started"]]]])
        #expect(details.desktopCard == .task(title: "Fix CI", summary: nil, prompt: nil, state: .started))
    }

    @Test
    func completedCardsStandAloneWhileDeniedOnesStayInTheProcess() {
        let messages = [
            AgentConversationMessage(id: "user", role: .user, text: "Go"),
            AgentConversationMessage(id: "read", role: .tool, text: "Read file", toolStatus: .completed),
            tool("chapter", "Chapter: Setup", card: ["card": "chapter", "title": "Setup"]),
            tool("denied", "Chapter: Denied", status: .failed, card: ["card": "chapter", "title": "Denied"]),
            AgentConversationMessage(id: "reply", role: .agent, text: "Done"),
        ]
        let items = AgentTranscriptItem.grouped(messages)
        #expect(items.map(\.id) == ["user", "process:read", "chapter", "process:denied", "reply"])
        #expect(items.filter { $0.matches("Setup") }.map(\.id) == ["chapter"])
    }

    @Test
    func suggestedRepliesFollowTheTurnSummaryAndOnlyAnswerTheLatestTurn() {
        let start = ContinuousClock.Instant.now
        var turn = AgentTurnStatistics(id: "user", startedAt: start)
        turn.finish(at: start.advanced(by: .seconds(3)), endingMessageID: "wrap#next", usage: nil)
        let messages = [
            AgentConversationMessage(id: "user", role: .user, text: "Go"),
            AgentConversationMessage(id: "read", role: .tool, text: "Read file", toolStatus: .completed),
            AgentConversationMessage(id: "recap", role: .agent, text: "Finished. Open a PR?"),
            tool("wrap#next", "Suggested replies", card: ["card": "nextStep", "actions": [["label": "Yes", "message": "Open the PR"]]]),
        ]
        let items = AgentTranscriptItem.grouped(messages, turns: [turn])
        #expect(items.map(\.id) == ["user", "process:read", "recap", "turn:user", "wrap#next"])
        guard case .turnSummary(_, let reply) = items[3] else {
            Issue.record("Expected the turn summary before the suggested replies")
            return
        }
        #expect(reply == "Finished. Open a PR?")
        let replies = items[4]
        #expect(!replies.isStaleNextStep(lastMessageID: "wrap#next", isResponding: false))
        #expect(replies.isStaleNextStep(lastMessageID: "wrap#next", isResponding: true))
        #expect(replies.isStaleNextStep(lastMessageID: "later", isResponding: false))
    }

    @Test
    func desktopEventsAndHarnessNoticesAreContextNotUserWords() {
        #expect(AgentClaudeCodeMarkup.parse("<ci-monitor-event pr=\"7\">Checks failed</ci-monitor-event>")
            == [.context(name: "ci-monitor-event", body: "Checks failed")])
        #expect(AgentClaudeCodeMarkup.parse("[Cross-session idle notice] \"Docs\" is idle now.")
            == [.context(name: "Cross-session idle notice", body: "\"Docs\" is idle now.")])
        // Attributes are accepted only on Desktop's event wrappers.
        #expect(AgentClaudeCodeMarkup.parse("<bash-input x=\"1\">ls</bash-input>") == nil)
        #expect(AgentClaudeCodeMarkup.parse("[Cross-session note] mine") == nil)
    }

    @Test
    func widgetPageForbidsNetworkLoadsAndCarriesDesktopThemeVariables() {
        let page = AgentDesktopWidgetWebView.document(code: "<svg></svg>", isDark: true)
        let policy = page.range(of: "default-src 'none'")
        let code = page.range(of: "<svg></svg>")
        #expect(policy != nil && code != nil && policy!.lowerBound < code!.lowerBound, "The policy must precede the agent's markup")
        #expect(page.contains("--text-primary:") && page.contains("--surface-1:") && page.contains("color-scheme:dark"))
        #expect(!page.contains("connect-src"))
    }

    @Test
    func widgetPageUsesSharedMediaCaptureDenier() throws {
        let host = NSHostingView(rootView: AnyView(AgentDesktopWidgetWebView(
            code: "<svg></svg>", isDark: false, height: .constant(160), onPrompt: { _ in })
            .frame(width: 300, height: 160)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            host.rootView = AnyView(EmptyView())
            host.layoutSubtreeIfNeeded()
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        func findWebView(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        let webView = try #require(findWebView(host))
        defer { webView.stopLoading() }
        #expect(webView.uiDelegate === WebMediaCaptureDenier.shared)
        let selector = NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")
        #expect(webView.uiDelegate?.responds(to: selector) == true)
    }

    @Test
    func cardsFitANarrowPanelInBothThemes() throws {
        let cards: [AgentDesktopCard] = [
            .chapter(title: "Investigate the release pipeline and its signing step", summary: "Long"),
            .nextStep(actions: [.init(label: "Open the PR", message: "Open"), .init(label: "Run the full test suite", message: "Run"),
                                .init(label: "Explain", message: "Explain")]),
            .task(title: "Fix the flaky Windows job", summary: "The job times out on cold caches.", prompt: "Fix it", state: .proposed),
            .pullRequest(action: .monitored, url: URL(string: "https://github.com/o/r/pull/1421")!, number: 1421, autoFix: true, enabled: nil),
            .directory(action: .changed, path: "/Users/someone/Dev/a/very/long/path/to/a/worktree"),
            .widget(title: "Architecture", code: "<svg></svg>"),
        ]
        for scheme in [ColorScheme.dark, .light] {
            let width = 300.0
            let host = NSHostingView(rootView: VStack(spacing: 14) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in AgentDesktopCardView(card: card, onDraft: { _, _ in }) }
            }.padding(8).frame(width: width).background(AgentPanelStyle.canvas).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            // Theme colours follow the window's appearance, not only the SwiftUI scheme.
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame.size = NSSize(width: width, height: 600)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width)
            #expect(host.fittingSize.height <= 600, "Cards must wrap within a narrow panel")
            if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_STATISTICS_SCREENSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("desktop-cards-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    @Test
    func widgetPromptsCountOnlyRightAfterAUserGesture() {
        typealias Widget = AgentDesktopWidgetWebView
        #expect(!Widget.isFollowingUserGesture(nil, now: 100), "A page that runs on its own never fills the composer")
        #expect(Widget.isFollowingUserGesture(99.5, now: 100))
        #expect(Widget.isFollowingUserGesture(100, now: 100))
        #expect(!Widget.isFollowingUserGesture(100 - Widget.gestureWindow - 0.1, now: 100), "A stale gesture is not the user's")
        #expect(!Widget.isFollowingUserGesture(101, now: 100), "A gesture cannot come from the future")
    }

    @Test
    func widgetPagesCannotNavigateOrOpenLinksByThemselves() throws {
        typealias Widget = AgentDesktopWidgetWebView
        #expect(Widget.allowsNavigation(.other, url: URL(string: "about:blank")))
        // A script's own `a.click()` is reported as a link activation, like a user's.
        #expect(!Widget.allowsNavigation(.linkActivated, url: URL(string: "https://example.invalid/?d=secret")))
        #expect(!Widget.allowsNavigation(.formSubmitted, url: URL(string: "https://example.invalid/")))
        #expect(!Widget.allowsNavigation(.other, url: URL(string: "https://example.invalid/")))
        #expect(!Widget.allowsNavigation(.other, url: nil))
    }
}

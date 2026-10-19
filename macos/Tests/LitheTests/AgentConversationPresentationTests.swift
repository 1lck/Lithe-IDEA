import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent conversation presentation")
struct AgentConversationPresentationTests {
    @Test
    func liveSessionNoticeFitsNarrowAndWidePanelsInBothThemes() throws {
        let notice = try #require(AgentSessionNotice.parse(["severity": "warning", "title": "Auto mode unavailable",
            "description": "The selected model does not support Auto mode; using Accept edits instead."]))
        for scheme in [ColorScheme.dark, .light] {
            for width in [280.0, 620.0] {
                let host = NSHostingView(rootView: AgentSessionNoticeView(notice: notice, onDismiss: {})
                    .frame(width: width).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 180),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.frame.size = NSSize(width: width, height: 180)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width <= width)
                #expect(host.fittingSize.height <= 180, "Notice must wrap and retain the shared dismiss control")
                if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_STATISTICS_SCREENSHOTS"] {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: folder).appendingPathComponent("notice-\(scheme)-\(Int(width)).png"))
                }
            }
        }
    }

    @Test
    func contextRingStaysBesideSendInBothThemes() throws {
        let usage = try #require(AgentContextUsage(usedTokens: 5, capacityTokens: 100))
        for scheme in [ColorScheme.dark, .light] {
            for width in [320.0, 417.0] {
                let host = NSHostingView(rootView: AgentComposerView(
                    agents: [], selectedAgent: nil, isResponding: false, isBlocked: false,
                    onSend: { _, _ in }, onCancel: {}, onSelectAgent: { _ in }, onOpenSettings: {}, onError: { _ in },
                    contextUsage: usage).frame(width: width, height: 150).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 150),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                func anchors(in view: NSView) -> [LitheDropdownAnchorView] {
                    (view as? LitheDropdownAnchorView).map { [$0] } ?? view.subviews.flatMap { anchors(in: $0) }
                }
                let anchor = try #require(anchors(in: host).sorted {
                    let lhs = $0.convert($0.bounds, to: nil), rhs = $1.convert($1.bounds, to: nil)
                    return abs(lhs.midY - rhs.midY) > 1 ? lhs.midY < rhs.midY : lhs.midX > rhs.midX
                }.first)
                #expect(anchor.convert(anchor.bounds, to: nil).midY < 75, "Context stays in the bottom command bar")
                let rect = anchor.convert(anchor.bounds, to: host)
                #expect(abs(rect.width - LitheTheme.Metrics.toolbarIconButtonSize) < 1)
                #expect(abs(rect.maxX - (width - AgentComposerMetrics.horizontalInset - AgentComposerMetrics.toolbarHorizontalInset
                    - LitheTheme.Metrics.toolbarIconButtonSize - 4)) < 1, "Only Send follows the context ring")
                let region = NSRect(x: rect.minX + 3, y: rect.minY, width: 16, height: rect.height)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: region))
                host.cacheDisplay(in: region, to: bitmap)
                let background = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
                var visible = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if abs(color.redComponent - background.redComponent) > 0.04 { visible += 1 }
                    }
                }
                #expect(visible > 8, "The native context ring must remain visible in both themes")
            }
        }
    }

    @Test
    func quietNoticeFitsBothAppearancesAndPreservesPermissionAndStopPriority() throws {
        for status in [AgentResponseStatus.waitingForPermission, .stopping] {
            #expect(!AgentResponseStatusRow(responseStatus: status, isQuiet: true).showsQuietNotice)
        }
        for status in [AgentResponseStatus.runningTools, .retrying] {
            for (name, scheme, width) in [("dark-narrow", ColorScheme.dark, 280.0), ("light-narrow", .light, 280.0),
                                         ("dark-wide", .dark, 620.0), ("light-wide", .light, 620.0)] {
                let row = AgentResponseStatusRow(responseStatus: status, isQuiet: true)
                #expect(row.showsQuietNotice)
                if status == .retrying {
                    #expect(row.quietNotice == String(localized: "Connection recovery is taking longer. The Agent is still retrying."))
                }
                let host = NSHostingView(rootView: row.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(AgentPanelStyle.canvas).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.frame.size = NSSize(width: width, height: 160)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height <= 160, "Quiet notice and actions must fit a narrow panel")
                if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_STATISTICS_SCREENSHOTS"] {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("quiet-\(status == .retrying ? "recovery" : "tools")-\(name).png"))
                }
            }
        }
    }

    @Test
    func turnFootersRemainAfterTheirToolsAndBeforeTheNextUserMessage() throws {
        let start = ContinuousClock.Instant.now
        var first = AgentTurnStatistics(id: "user-1", startedAt: start)
        first.finish(at: start.advanced(by: .seconds(65)), endingMessageID: "read", usage: nil)
        var second = AgentTurnStatistics(id: "user-2", startedAt: start)
        second.finish(at: start.advanced(by: .seconds(2)), endingMessageID: "user-2", usage: nil)
        let messages = [AgentConversationMessage(id: "user-1", role: .user, text: "Read this"),
                        AgentConversationMessage(id: "list", role: .tool, text: "List files"),
                        AgentConversationMessage(id: "read", role: .tool, text: "Read file"),
                        AgentConversationMessage(id: "user-2", role: .user, text: "Continue")]
        let items = AgentTranscriptItem.grouped(messages, turns: [first, second])
        #expect(items.map(\.id) == ["user-1", "tools:list", "turn:user-1", "user-2", "turn:user-2"])
        #expect(items.filter { $0.matches("Read") }.map(\.id) == ["user-1", "tools:list"])
        #expect(AgentTranscriptItem.grouped(messages).map(\.id) == ["user-1", "tools:list", "user-2"])
    }

    @Test
    func turnPresentationUsesElapsedUnitsAndExactReportedCounts() throws {
        #expect(AgentTurnStatisticsPresentation.duration(-1) == "0s")
        #expect(AgentTurnStatisticsPresentation.duration(59.9) == "59s")
        #expect(AgentTurnStatisticsPresentation.duration(60) == "1m 0s")
        #expect(AgentTurnStatisticsPresentation.duration(3661) == "1h 1m 1s")
        let usage = try #require(AgentTurnUsage.parse(["totalTokens": 25000, "inputTokens": 18000,
                                                     "outputTokens": 2000, "cachedReadTokens": 3000]))
        let locale = Locale(identifier: "en_US")
        #expect(AgentTurnStatisticsPresentation.input(usage, locale: locale) == "Input: 18,000")
        #expect(AgentTurnStatisticsPresentation.output(usage, locale: locale) == "Output: 2,000")
        let details = AgentTurnStatisticsPresentation.details(usage, locale: locale)
        #expect(details.contains("Total tokens: 25,000"))
        #expect(details.contains("Cache read tokens: 3,000"))
        #expect(!details.contains("Reasoning tokens:"))
        #expect(!details.contains("Cache write tokens:"))
    }

    @Test
    func statisticsFooterFitsNarrowAndWidePanelsInBothAppearances() throws {
        let start = ContinuousClock.Instant.now
        var turn = AgentTurnStatistics(id: "sample-turn", startedAt: start)
        let usage = try #require(AgentTurnUsage.parse(["totalTokens": 25000, "inputTokens": 18000,
                                                     "outputTokens": 2000, "thoughtTokens": 1000]))
        turn.finish(at: start.advanced(by: .seconds(3661)), endingMessageID: "sample-reply", usage: usage)
        for (name, scheme, width) in [("dark-narrow", ColorScheme.dark, 280.0), ("light-narrow", .light, 280.0),
                                      ("dark-wide", .dark, 620.0), ("light-wide", .light, 620.0)] {
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 14) {
                Text("The requested changes are complete.").font(.system(size: 13))
                AgentTurnStatisticsView(statistics: turn)
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AgentPanelStyle.canvas).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 140),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.frame.size = NSSize(width: width, height: 140)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height <= 140, "Footer must fit without clipping its token counts")
            if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_STATISTICS_SCREENSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("statistics-\(name).png"))
            }
        }
    }

    @Test
    func adjacentMixedToolsShareOneStableTimelineWithoutHidingNarration() throws {
        func tool(_ id: String, kind: String) -> AgentConversationMessage {
            var message = AgentConversationMessage(id: id, role: .tool, text: id, toolStatus: .pending)
            message.toolDetails.kind = kind
            return message
        }

        let messages = [
            tool("list", kind: "search"),
            tool("read-1", kind: "read"),
            tool("read-2", kind: "read"),
            AgentConversationMessage(id: "reply", role: .agent, text: "I found two files"),
            tool("command", kind: "execute"),
            tool("edit", kind: "edit"),
            AgentConversationMessage(id: "follow-up", role: .user, text: "Continue"),
            tool("next-command", kind: "execute")
        ]
        let grouped = AgentTranscriptItem.grouped(messages)
        #expect(grouped.map(\.id) == ["tools:list", "reply", "tools:command", "follow-up", "tools:next-command"])
        if case .toolGroup(let first) = try #require(grouped.first) {
            #expect(first.map(\.id) == ["list", "read-1", "read-2"])
        } else {
            Issue.record("Adjacent file tools were not grouped")
        }

        var updated = messages
        updated[0].toolStatus = .failed
        #expect(AgentTranscriptItem.grouped(updated).map(\.id) == grouped.map(\.id))
    }

    @Test
    func planReasoningAndCommandListsFitNarrowAndWidePanelsInBothAppearances() throws {
        let plan = AgentPlan(entries: [
            .init(content: "Read the manifest and the build scripts of the sample project", priority: "high", status: .completed),
            .init(content: "Run the tests", priority: "medium", status: .inProgress),
            .init(content: "Summarize the results", priority: "low", status: .pending)
        ])
        let commands = [AgentCommand(name: "review", description: "Review the current changes before committing", hint: "optional focus"),
                        AgentCommand(name: "compact", description: "Summarize the conversation to free context", hint: nil)]
        for (name, scheme, width) in [("dark-narrow", ColorScheme.dark, 280.0), ("light-narrow", .light, 280.0),
                                      ("dark-wide", .dark, 620.0), ("light-wide", .light, 620.0)] {
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 10) {
                AgentThoughtRow(text: "The manifest names the entry point, so read it first.", isStreaming: true,
                                expansion: .constant(AgentThoughtExpansion()))
                AgentCommandSuggestionList(commands: commands, highlightedIndex: 0, onSelect: { _ in })
                AgentPlanView(plan: plan, isResponding: true)
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AgentPanelStyle.canvas).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 260),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.frame.size = NSSize(width: width, height: 260)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height <= 260, "Reasoning, commands and plan summary must fit a short panel")
            if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_STATISTICS_SCREENSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("guidance-\(name).png"))
            }
        }
    }

    @Test
    func reasoningSplitsToolTimelinesAndIsSearchableButNotCountedAsAMessage() throws {
        let messages = [
            AgentConversationMessage(id: "list", role: .tool, text: "List files"),
            AgentConversationMessage(id: "why", role: .thought, text: "The manifest names the entry point"),
            AgentConversationMessage(id: "read", role: .tool, text: "Read file"),
            AgentConversationMessage(id: "reply", role: .agent, text: "Done")
        ]
        let items = AgentTranscriptItem.grouped(messages)
        #expect(items.map(\.id) == ["tools:list", "why", "tools:read", "reply"])
        #expect(items.filter { $0.matches("entry point") }.map(\.id) == ["why"])

        var conversation = AgentConversation()
        conversation.isAttached = true
        conversation.messages = [AgentConversationMessage(role: .user, text: "Explain")] + messages
        #expect(AgentHistoryPresentation.messageCount(conversation) == 2)
    }

    @Test
    func thoughtSearchRevealsAManuallyCollapsedMatchAndRestoresItsPreference() {
        var expansion = AgentThoughtExpansion()
        #expect(expansion.isExpanded(isStreaming: true, isSearching: false))
        expansion.toggle(isStreaming: true, isSearching: false)
        #expect(!expansion.isExpanded(isStreaming: true, isSearching: false))

        // Search changes the effective disclosure without replacing the stored preference.
        #expect(expansion.isExpanded(isStreaming: false, isSearching: true))
        expansion.toggle(isStreaming: false, isSearching: true)
        #expect(expansion.isExpanded(isStreaming: false, isSearching: true))
        #expect(!expansion.isExpanded(isStreaming: false, isSearching: false))

        expansion.toggle(isStreaming: false, isSearching: false)
        #expect(expansion.isExpanded(isStreaming: false, isSearching: true))
        #expect(expansion.isExpanded(isStreaming: false, isSearching: false))
    }

    @Test
    func thoughtStreamingCollapsesAutomaticallyButKeepsManualExpansion() {
        var expansion = AgentThoughtExpansion()
        #expect(expansion.isExpanded(isStreaming: true, isSearching: false))
        #expect(!expansion.isExpanded(isStreaming: false, isSearching: false))
        #expect(expansion.isExpanded(isStreaming: false, isSearching: true))
        #expect(!expansion.isExpanded(isStreaming: false, isSearching: false))
        expansion.toggle(isStreaming: false, isSearching: false)
        #expect(expansion.isExpanded(isStreaming: true, isSearching: false))
        #expect(expansion.isExpanded(isStreaming: false, isSearching: false))
    }

    @Test
    func commandKeysCompleteWithoutSendingAndSubmitFullInvocations() {
        let commands = [AgentCommand(name: "review", description: "Review"),
                        AgentCommand(name: "compact", description: "Compact"),
                        AgentCommand(name: "$pdf", description: "Read PDFs")]
        var completion = AgentCommandCompletion()
        completion.draft = "/"
        #expect(completion.handle(.up, commands: commands, isResponding: false) == .handled)
        #expect(completion.highlightedIndex == 2)
        #expect(completion.handle(.down, commands: commands, isResponding: false) == .handled)
        #expect(completion.highlightedIndex == 0)
        #expect(completion.handle(.down, commands: commands, isResponding: false) == .handled)
        #expect(completion.handle(.tab, commands: commands, isResponding: false) == .handled)
        #expect(completion.draft == "/compact ")
        #expect(completion.suggestions(in: commands) == nil)
        #expect(completion.handle(.submit, commands: commands, isResponding: false) == .send)

        completion.draft = "/re"
        #expect(completion.handle(.submit, commands: commands, isResponding: false) == .handled)
        #expect(completion.draft == "/review ")
        completion.draft = "/review"
        #expect(completion.handle(.submit, commands: commands, isResponding: false) == .send)
        #expect(completion.draft == "/review")
        completion.draft = "$pd"
        #expect(completion.handle(.tab, commands: commands, isResponding: false) == .handled)
        #expect(completion.draft == "$pdf ")
    }

    @Test
    func escapeDismissesSuggestionsBeforeCancellingAndEditingReopensThem() {
        let commands = [AgentCommand(name: "review", description: "Review")]
        var completion = AgentCommandCompletion()
        completion.draft = "/"
        #expect(completion.handle(.escape, commands: commands, isResponding: true) == .handled)
        #expect(completion.draft == "/")
        #expect(completion.suggestions(in: commands) == nil)
        #expect(completion.handle(.escape, commands: commands, isResponding: true) == .cancel)
        #expect(completion.handle(.escape, commands: commands, isResponding: false) == .ignored)
        completion.draft = "/r"
        #expect(completion.suggestions(in: commands)?.count == 1)
        completion.draft = "/"
        #expect(completion.suggestions(in: commands)?.count == 1)
        completion.draft = "/missing"
        #expect(completion.suggestions(in: commands)?.isEmpty == true)
        #expect(completion.handle(.escape, commands: commands, isResponding: true) == .handled)
        #expect(completion.handle(.escape, commands: commands, isResponding: true) == .cancel)
    }

    @Test
    func unavailableCommandKeysLeaveOrdinaryTypingAndChangedListsUsable() {
        let commands = [AgentCommand(name: "review", description: "Review"),
                        AgentCommand(name: "compact", description: "Compact")]
        var completion = AgentCommandCompletion()
        for draft in ["text", "$", "/missing", "/review argument"] {
            completion.draft = draft
            for key in [AgentCommandCompletion.Key.up, .down, .tab] {
                #expect(completion.handle(key, commands: commands, isResponding: false) == .ignored)
                #expect(completion.draft == draft)
            }
            #expect(completion.handle(.submit, commands: commands, isResponding: false) == .send)
        }
        completion.draft = "/"
        #expect(completion.handle(.up, commands: commands, isResponding: false) == .handled)
        // A fresh upstream list can be shorter while the same draft is focused.
        #expect(completion.handle(.tab, commands: Array(commands.prefix(1)), isResponding: false) == .handled)
        #expect(completion.draft == "/review ")
        completion.draft = "/"
        #expect(completion.handle(.tab, commands: [], isResponding: false) == .ignored)
    }

    @Test
    func activeThoughtKeepsOneThinkingLabelAndTheWaitingTimer() {
        #expect(AgentResponseStatusRow().status == String(localized: "Waiting for Agent response…"))
        #expect(AgentResponseStatusRow(responseStatus: .thinking).status == String(localized: "Thinking…"))
        #expect(AgentResponseStatusRow(responseStatus: .thinking, hasStreamingThought: true).status == String(localized: "Responding…"))
        #expect(AgentResponseStatusRow(responseStatus: .stopping, hasStreamingThought: true).status == String(localized: "Stopping…"))
        #expect(AgentResponseStatusRow(responseStatus: .preparing).status == String(localized: "Preparing conversation…"))
        #expect(AgentResponseStatusRow(responseStatus: .retrying).status == String(localized: "Reconnecting…"))
        #expect(AgentResponseStatusRow(responseStatus: .retrying, hasStreamingThought: true, retryAttempt: 2, retryMaxAttempts: 5).status == String(format: String(localized: "Reconnecting %d/%d…"), 2, 5))
        #expect(AgentResponseStatusRow(responseStatus: .runningTools).status == String(localized: "Running tools…"))
        #expect(AgentResponseStatusRow(responseStatus: .waitingForPermission).status == String(localized: "Waiting for permission…"))
    }

    @Test
    func commandSuggestionsKeepTwoWritingLinesAtDefaultAndMinimumComposerHeights() throws {
        let commands = (0..<200).map {
            AgentCommand(name: "command-\($0)", description: "An upstream command with a long description", hint: nil)
        }
        let attachment = try AgentFileReference(url: URL(fileURLWithPath: "/example/project/README.md"))
        for height in [400.0, 700.0] {
            for width in [280.0, 620.0] {
                for files in [[], [attachment]] {
                    for count in [0, 1, 40, 200] {
                        var editor: NSView?
                        var composer: NSView?
                        let host = NSHostingView(rootView: AgentConversationLayout {
                            Color.clear
                        } composer: {
                            AgentComposerContent(files: files, commands: Array(commands.prefix(count)), highlightedIndex: 0,
                                                 onSelect: { _ in }, onRemoveFile: { _ in }, onFocus: {}) {
                                TextField("Message the Agent", text: .constant("/"), axis: .vertical)
                                    .textFieldStyle(.plain).font(LitheTheme.uiFont).lineLimit(AgentComposerMetrics.minimumWritingLines...)
                                    .background(AgentDraftFrameProbe { editor = $0 })
                                    .padding(.horizontal, 8).padding(.vertical, AgentComposerMetrics.writingVerticalInset)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            } toolbar: {
                                Color.clear.frame(height: AgentComposerMetrics.toolbarHeight - 2)
                            }
                            .padding(.horizontal, 8).padding(.bottom, AgentComposerMetrics.bottomInset)
                            .background(AgentDraftFrameProbe { composer = $0 })
                        })
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                              styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        defer { window.close() }
                        window.contentView = host
                        host.frame.size = NSSize(width: width, height: height)
                        host.layoutSubtreeIfNeeded()
                        let input = try #require(editor)
                        let frame = host.convert(input.bounds, from: input)
                        let composerView = try #require(composer)
                        let pane = host.convert(composerView.bounds, from: composerView)
                        #expect(pane.height + AgentComposerMetrics.splitTopInset >= AgentComposerMetrics.minimumHeight(hasFiles: !files.isEmpty) - 0.5)
                        #expect(frame.height > 0, "The actual text field must survive \(count) commands and \(files.count) attachments")
                        #expect(pane.insetBy(dx: -0.5, dy: -0.5).contains(frame), "The writing line must stay inside the sized pane")
                        if files.isEmpty, count == 0 {
                            let inputHeight = pane.height - AgentComposerMetrics.bottomInset
                            #expect(abs(inputHeight - 78) < 0.5, "Two writing lines and one toolbar stay compact without a top strip")
                        }
                        let writingScroll = try #require(enclosingScroll(of: input))
                        #expect(writingScroll.bounds.height >= AgentComposerMetrics.minimumWritingHeight - 0.5)
                        if count > 0 {
                            let list = try #require(commandScroll(in: host, excluding: input))
                            let listFrame = host.convert(list.bounds, from: list)
                            #expect(listFrame.height >= 26, "Suggestions must retain a complete, selectable row")
                            #expect(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(listFrame),
                                    "The floating list must stay inside its conversation scope")
                            let isAboveInput = host.isFlipped ? listFrame.maxY <= frame.minY + 0.5
                                : listFrame.minY >= frame.maxY - 0.5
                            #expect(isAboveInput, "The floating list must not cover the writing line")
                        }
                    }
                }
            }
        }
    }

    @Test
    func toolSearchKeepsTheOriginalGroupWhenEvidenceMatches() throws {
        var first = AgentConversationMessage(id: "list", role: .tool, text: "List files")
        first.toolDetails.kind = "search"
        first.toolDetails.input = "{\"path\":\"sample-project\"}"
        var second = AgentConversationMessage(id: "read", role: .tool, text: "Read file")
        second.toolDetails.kind = "read"
        second.toolDetails.locations = [.init(path: "sample-project/README.md", line: 1)]
        let group = try #require(AgentTranscriptItem.grouped([first, second]).first)
        #expect(group.matches("sample-project"))
        #expect(group.matches("README.md"))
        #expect(!group.matches("missing file"))
        if case .toolGroup(let tools) = group {
            #expect(tools.map(\.id) == ["list", "read"])
        } else {
            Issue.record("Search changed the tool group")
        }
    }

    @Test
    func toolSearchFindsFilePathsReportedOnlyInDiffContent() throws {
        var edit = AgentConversationMessage(id: "edit", role: .tool, text: "Apply changes")
        edit.toolDetails.merge(["content": [["type": "diff", "path": "src/example.swift",
                                             "oldText": "before", "newText": "after"]]])
        let other = AgentConversationMessage(id: "read", role: .tool, text: "Read file")
        let group = try #require(AgentTranscriptItem.grouped([other, edit]).first)

        #expect(group.matches("example.swift"))
        #expect(group.matches("src/example.swift"))
        #expect(group.matches("after"))
        #expect(!group.matches("missing.swift"))
        #expect([other, edit].filter { AgentTranscriptItem.toolMatches($0, "example.swift") }.map(\.id) == ["edit"])
    }

    @Test
    func subscriptionQuotaPreservesWindowLengthsUnknownUsageAndStaleness() throws {
        let windows: [[String: Any]] = [
            ["id": "weekly", "name": "codex", "limitSeconds": 604800, "usedPercent": 68, "resetsAt": 1800000200],
            ["id": "short", "name": "codex", "limitSeconds": 18000, "usedPercent": NSNull()]
        ]
        let value: [String: Any] = ["windows": windows, "fetchedAt": 1800000000]
        let snapshot = try #require(AgentSubscriptionQuota.parse(value))
        #expect(AgentSubscriptionQuotaPresentation.duration(snapshot.windows[0].limitSeconds) == "7d")
        #expect(AgentSubscriptionQuotaPresentation.duration(snapshot.windows[1].limitSeconds) == "5h")
        #expect(snapshot.mostUsedWindow?.id == "weekly")
        #expect(AgentSubscriptionQuotaPresentation.ringWindow(snapshot)?.id == "weekly",
                "The compact ring follows the most used window, not the 5h one listed first")
        #expect(AgentSubscriptionQuotaPresentation.ringWindow(nil) == nil)
        #expect(snapshot.windows[1].usedPercent == nil)
        #expect(!snapshot.isStale(at: Date(timeIntervalSince1970: 1800000100)))
        #expect(snapshot.isStale(at: Date(timeIntervalSince1970: 1800000121)))
        #expect(AgentSubscriptionQuota.parse(["windows": [], "fetchedAt": 1] as [String: Any]) == nil)
    }

    @Test
    func subscriptionQuotaColorsUseRequestedThresholdsAndKeepUnknownMuted() {
        #expect(AgentSubscriptionQuotaPresentation.level(0) == .normal)
        #expect(AgentSubscriptionQuotaPresentation.level(60) == .normal)
        #expect(AgentSubscriptionQuotaPresentation.level(60.1) == .warning)
        #expect(AgentSubscriptionQuotaPresentation.level(90) == .warning)
        #expect(AgentSubscriptionQuotaPresentation.level(90.1) == .error)
        #expect(AgentSubscriptionQuotaPresentation.level(100) == .error)
        #expect(AgentSubscriptionQuotaPresentation.level(nil) == .unknown)
        #expect(AgentSubscriptionQuotaPresentation.level(95, stale: true) == .unknown)
    }

    @Test
    func subscriptionQuotaPrefersFiveHoursAndFallsBackToActualWeeklyWindow() throws {
        let windows: [[String: Any]] = [
            ["id": "weekly", "name": "codex", "limitSeconds": 604800, "usedPercent": 95],
            ["id": "short", "name": "codex", "limitSeconds": 18000, "usedPercent": 32],
            ["id": "other", "name": "codex", "limitSeconds": 7200, "usedPercent": 40]
        ]
        func quota(_ windows: [[String: Any]]) throws -> AgentSubscriptionQuota {
            try #require(AgentSubscriptionQuota.parse(["windows": windows, "fetchedAt": 1800000000]))
        }
        let both = AgentSubscriptionQuotaPresentation.windows(try quota(windows))
        #expect(both.map(\.id) == ["short", "weekly", "other"])
        let weekly = AgentSubscriptionQuotaPresentation.windows(try quota([windows[0]]))
        #expect(weekly.count == 1 && weekly.first?.limitSeconds == 604800)
        var unknown = windows[1]
        unknown["usedPercent"] = NSNull()
        let missing = AgentSubscriptionQuotaPresentation.windows(try quota([windows[0], unknown]))
        #expect(missing.first?.id == "short" && missing.first?.usedPercent == nil,
                "An unreported five-hour value is unknown, not an absent window or a healthy zero")
        #expect(AgentSubscriptionQuotaPresentation.windows(nil).isEmpty)
        #expect(AgentSubscriptionQuotaPresentation.percentage(missing.first, locale: Locale(identifier: "en")) == "—")
    }

    @Test
    func sessionStatusHidesProxyOnlyFactsAndCardsFitBothAppearances() throws {
        let locale = Locale(identifier: "en_US")
        #expect(AgentSessionStatusPresentation.compactTokens(999, locale: locale) == "999")
        #expect(AgentSessionStatusPresentation.compactTokens(43_600, locale: locale) == "43.6K")
        #expect(AgentSessionStatusPresentation.compactTokens(3_685_001, locale: locale) == "3.7M")
        var conversation = AgentConversation()
        conversation.completedTurns = [AgentTurnStatistics(id: "turn", startedAt: .now)]
        // Without proxy observations, steps and speed are absent rather than estimated.
        #expect(AgentSessionStatusPresentation.summary(conversation.sessionStatistics, locale: locale) == "1 turns")
        let call = try #require(AgentModelCall.parse([
            "api": "anthropicMessages", "status": 200, "streaming": true, "firstTokenMs": 500, "durationMs": 2500,
            "usage": ["inputTokens": 100, "cacheReadTokens": 900, "cacheWriteTokens": 0, "outputTokens": 400],
            "context": ["systemPromptTokens": 100, "toolTokens": 200, "mcpToolTokens": 300, "messageTokens": 400,
                        "toolCount": 3, "mcpToolCount": 2, "scaledToUsage": true]
        ]))
        conversation.recordModelCall(call)
        let statistics = conversation.sessionStatistics
        #expect(AgentSessionStatusPresentation.summary(statistics, locale: locale) == "1 turns 1 steps · 200 tok/s")
        #expect(AgentSessionStatusPresentation.tokenSummary(try #require(statistics.tokens), locale: locale) == "1.4K tok · Cache hit 90%")
        var partial = try #require(statistics.tokens)
        partial.callsMissingUsage = 2
        #expect(AgentSessionStatusPresentation.tokenSummary(partial, locale: locale) == "≥1.4K tok · Cache hit 90%")
        let usage = try #require(AgentContextUsage(usedTokens: 1_000, capacityTokens: 200_000))
        for scheme in [ColorScheme.dark, .light] {
            for card in [AnyView(AgentSessionSummaryCard(statistics: statistics)),
                         AnyView(AgentTokenUsageCard(tokens: try #require(statistics.tokens))),
                         AnyView(AgentContextUsageCard(usage: usage, composition: statistics.modelCalls?.latestContext))] {
                let host = NSHostingView(rootView: card.environment(\.colorScheme, scheme).environment(\.locale, locale))
                let size = host.fittingSize
                #expect(size.width == AgentStatusCardMetrics.width, "Cards keep the shared width")
                #expect(size.height > 40 && size.height < 400, "Cards wrap footnotes without clipping")
            }
            let emptyContext = NSHostingView(rootView: AgentContextUsageCard(usage: nil, composition: nil)
                .environment(\.colorScheme, scheme).environment(\.locale, locale))
            #expect(emptyContext.fittingSize.width == 240)
            #expect(emptyContext.fittingSize.height > 30 && emptyContext.fittingSize.height < 80,
                    "Unknown context stays compact without reserving an empty progress bar")
        }
        if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_STATUS_SCREENSHOTS"] {
            try captureStatusScreenshots(folder: URL(fileURLWithPath: folder))
        }
    }

    @Test
    func contextBreakdownUsesReportedWindowInsteadOfNormalizingTheRequestToFull() throws {
        let locale = Locale(identifier: "en_US")
        let context = try #require(AgentModelCall.parse([
            "api": "responses", "status": 200, "streaming": true, "durationMs": 100,
            "context": ["systemPromptTokens": 11700, "toolTokens": 33900, "messageTokens": 30300,
                        "mcpToolTokens": 300, "toolCount": 18, "mcpToolCount": 2, "scaledToUsage": true]
        ])?.context)
        let usage = try #require(AgentContextUsage(usedTokens: 76200, capacityTokens: 300000))
        let breakdown = AgentContextBreakdown(usage: usage, composition: context)
        #expect(breakdown.share(context.systemPromptTokens, locale: locale) == "3.9%")
        #expect(breakdown.share(context.toolTokens, locale: locale) == "11.3%")
        #expect(breakdown.share(context.messageTokens, locale: locale) == "10.1%")
        #expect(breakdown.share(context.mcpToolTokens, locale: locale) == "0.1%")
        #expect(breakdown.capacity(locale: locale) == "76.2K / 300.0K")
        let unknownWindow = AgentContextBreakdown(usage: nil, composition: context)
        #expect(unknownWindow.share(context.messageTokens, locale: locale) == "—",
                "Observed request sizes cannot establish the model window or its occupancy")
    }

    @Test
    func referenceContextPanelFitsDetailsAndPopupWithAndWithoutBreakdown() throws {
        let resourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let bundle = try #require(Bundle(url: resourceURL))
        let composition = try #require(AgentModelCall.parse([
            "api": "responses", "status": 200, "streaming": true, "durationMs": 100,
            "context": ["systemPromptTokens": 11700, "toolTokens": 33900, "messageTokens": 30300,
                        "mcpToolTokens": 300, "toolCount": 18, "mcpToolCount": 2, "scaledToUsage": true]
        ])?.context)
        let usage = try #require(AgentContextUsage(usedTokens: 76200, capacityTokens: 300000))
        for language in ["en", "zh-Hans"] {
            for scheme in [ColorScheme.dark, .light] {
                for width in [AgentEditorConversationMetrics.detailsWidth, AgentContextPanel.popoverWidth] {
                    for hasBreakdown in [true, false] {
                        let host = NSHostingView(rootView: AgentContextPanel(usage: usage,
                            composition: hasBreakdown ? composition : nil, onClose: {}, bundle: bundle)
                            .padding(14).frame(width: width).background(AgentPanelStyle.canvas)
                            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme))
                        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        let size = host.fittingSize
                        #expect(size.width == width)
                        #expect(size.height > 180 && size.height < 330, "Summary, categories and any unavailable-data guidance stay compact")
                        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                              styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.contentView = host
                        defer { window.contentView = nil; window.close() }
                        host.layoutSubtreeIfNeeded()
                        if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_STATUS_SCREENSHOTS"] {
                            let bitmap = try nativeSRGBCapture(host)
                            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                                URL(fileURLWithPath: folder).appendingPathComponent(
                                    "context-reference-\(language)-\(scheme)-\(Int(width))-\(hasBreakdown).png"))
                        }
                    }
                }
            }
        }
    }

    @Test
    func defaultWidthDetailsCardsKeepAllReportedStatistics() throws {
        var conversation = AgentConversation()
        conversation.completedTurns = [AgentTurnStatistics(id: "turn", startedAt: .now)]
        conversation.recordModelCall(try #require(AgentModelCall.parse([
            "api": "anthropicMessages", "status": 200, "streaming": true, "firstTokenMs": 700, "durationMs": 1250,
            "usage": ["inputTokens": 62063, "cacheReadTokens": 61696, "cacheWriteTokens": 0, "outputTokens": 165]
        ])))
        let usage = try #require(AgentContextUsage(usedTokens: 62_000, capacityTokens: 1_000_000))
        // Compact summary cards remain reusable inside the on-demand details panel.
        for scheme in [ColorScheme.dark, .light] {
            let composer = AgentComposerView(
                agents: [], selectedAgent: nil, isResponding: false, isBlocked: false,
                onSend: { _, _ in }, onCancel: {}, onSelectAgent: { _ in }, onOpenSettings: {}, onError: { _ in },
                contextUsage: usage, sessionStatistics: conversation.sessionStatistics)
            let host = NSHostingView(rootView: composer.frame(width: 417, height: 150)
                .background(AgentPanelStyle.canvas).environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en_US")))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 417, height: 150),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.frame.size = NSSize(width: 417, height: 150)
            host.layoutSubtreeIfNeeded()
            // The bar's width at 417pt, less composer and bar insets, the
            // divider and the attach control collapsed to its icon.
            let available: CGFloat = 417 - 16 - 20 - 1 - 16 - 14
            for statistics in [conversation.sessionStatistics, try longSession()] {
                let width = { (view: AnyView) in NSHostingView(rootView: view.font(LitheTheme.uiFont(size: 11))).fittingSize.width }
                let required = width(AnyView(AgentSessionSummaryView(statistics: statistics, showsRate: false)))
                    + width(AnyView(AgentTokenUsageView(tokens: try #require(statistics.tokens))))
                    + width(AnyView(AgentContextUsageView(usage: usage))) + 16
                #expect(required <= available, "All reported figures remain available through the details cards")
            }
            if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_STATUS_SCREENSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder)
                    .appendingPathComponent("status-composer-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// 7 turns and 54 streamed calls with a multi-million token cached prompt.
    private func longSession() throws -> AgentSessionStatistics {
        var conversation = AgentConversation()
        conversation.completedTurns = (0..<7).map { AgentTurnStatistics(id: "turn-\($0)", startedAt: .now) }
        for _ in 0..<54 {
            conversation.recordModelCall(try #require(AgentModelCall.parse([
                "api": "anthropicMessages", "status": 200, "streaming": true, "firstTokenMs": 950, "durationMs": 7400,
                "usage": ["inputTokens": 1100, "cacheReadTokens": 65600, "cacheWriteTokens": 900, "outputTokens": 1500]
            ])))
        }
        return conversation.sessionStatistics
    }

    /// Opt-in visual review of the status bar and its cards in the review language.
    private func captureStatusScreenshots(folder: URL) throws {
        let locale = Locale(identifier: "en_US")
        // A long session: 7 turns, 54 streamed calls with a large cached prompt.
        var conversation = AgentConversation()
        let start = ContinuousClock.Instant.now
        conversation.completedTurns = (0..<7).map { index in
            var turn = AgentTurnStatistics(id: "turn-\(index)", startedAt: start)
            turn.setToolsRunning(true, at: start)
            turn.setToolsRunning(false, at: start.advanced(by: .seconds(29)))
            turn.finish(at: start.advanced(by: .seconds(87)), endingMessageID: "reply-\(index)", usage: nil, toolCallCount: 7)
            return turn
        }
        for index in 0..<54 {
            let call = try #require(AgentModelCall.parse([
                "api": "anthropicMessages", "status": 200, "streaming": true,
                "firstTokenMs": 900 + index * 4, "durationMs": 7400,
                "usage": ["inputTokens": 1100, "cacheReadTokens": 65600, "cacheWriteTokens": 900, "outputTokens": 1500],
                "context": ["systemPromptTokens": 4500, "toolTokens": 7500, "mcpToolTokens": 14000,
                            "messageTokens": 85600 + index * 400, "toolCount": 18, "mcpToolCount": 40,
                            "scaledToUsage": true]
            ]))
            conversation.recordModelCall(call)
        }
        let statistics = conversation.sessionStatistics
        let usage = try #require(AgentContextUsage(usedTokens: 133_000, capacityTokens: 1_000_000))
        let views: [(String, AnyView)] = [
            ("bar", AnyView(AgentSessionStatusView(statistics: statistics, contextUsage: usage)
                .font(LitheTheme.uiFont(size: 11)).foregroundStyle(AgentPanelStyle.secondary)
                .padding(.horizontal, 10).frame(height: 26).background(AgentPanelStyle.context))),
            ("session", AnyView(AgentSessionSummaryCard(statistics: statistics))),
            ("tokens", AnyView(AgentTokenUsageCard(tokens: try #require(statistics.tokens)))),
            ("context", AnyView(AgentContextUsageCard(usage: usage, composition: statistics.modelCalls?.latestContext))),
            ("context-off", AnyView(AgentContextUsageCard(usage: usage, composition: nil))),
        ]
        for (name, view) in views {
            for (theme, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
                let host = NSHostingView(rootView: view.padding(12).background(AgentPanelStyle.canvas)
                    .environment(\.colorScheme, scheme).environment(\.locale, locale))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent("status-\(name)-\(theme).png"))
            }
        }
    }

    @Test
    func contextIndicatorDistinguishesUnknownZeroAndReportedCounts() throws {
        let locale = Locale(identifier: "en_US")
        let usage = try #require(AgentContextUsage(usedTokens: 18700, capacityTokens: 258400))
        #expect(AgentContextUsagePresentation.percentage(nil, locale: locale) == "—")
        #expect(AgentContextUsagePresentation.details(nil, locale: locale).contains("not reported"))
        #expect(!AgentContextUsagePresentation.details(nil, locale: locale).contains("/"))
        #expect(AgentContextUsagePresentation.percentage(usage, locale: locale) == "7%")
        #expect(AgentContextUsagePresentation.details(usage, locale: locale) == "7.2% · 18.7K / 258.4K context used")
        let reference = try #require(AgentContextUsage(usedTokens: 125300, capacityTokens: 300000))
        #expect(AgentContextUsagePresentation.details(reference, locale: locale) == "41.8% · 125.3K / 300.0K context used")
        let zero = try #require(AgentContextUsage(usedTokens: 0, capacityTokens: 100))
        #expect(AgentContextUsagePresentation.percentage(zero, locale: locale) == "0%")
        #expect(AgentContextUsagePresentation.details(zero, locale: locale) == "0.0% · 0 / 100 context used")
        let over = try #require(AgentContextUsage(usedTokens: 150, capacityTokens: 100))
        #expect(AgentContextUsagePresentation.percentage(over, locale: locale) == "150%")
        #expect(AgentContextUsagePresentation.details(over, locale: locale).contains("150 / 100"))
        let largest = try #require(AgentContextUsage(usedTokens: .max, capacityTokens: 1))
        #expect(largest.fraction.isFinite)
        #expect(AgentContextUsage(usedTokens: 0, capacityTokens: 0) == nil)
    }

    @Test
    func unknownSessionSelectorsKeepUpstreamLabelsAndChoiceDescriptions() throws {
        let option = try #require(AgentSessionConfigOption.parse([[
            "id": "custom-mode", "name": "Custom control", "category": "custom", "type": "select", "currentValue": "custom-choice",
            "options": [["value": "custom-choice", "name": "Custom choice", "description": "Upstream detail"]]
        ]]).first)
        #expect(AgentSessionSelectorPresentation.title(option) == "Custom control")
        #expect(AgentSessionSelectorPresentation.currentTitle(option) == "Custom choice")
        #expect(option.choices.first?.description == "Upstream detail")
    }

    @Test
    func menuMarksKeepTheirNativeSizeWithoutMutatingTheHero() throws {
        let hero = try #require(AgentBrandIconLoader.image(name: "Codex", size: 60))
        let menu = try #require(AgentBrandIconLoader.image(name: "Codex", size: 16))
        let model = try #require(AgentBrandIconLoader.image(name: "Codex", size: 12))
        #expect(hero.size == NSSize(width: 60, height: 60))
        #expect(menu.size == NSSize(width: 16, height: 16))
        #expect(model.size == NSSize(width: 12, height: 12))
        #expect(hero !== menu)
    }

    @Test
    func bundledVendorMarksHaveVisiblePixels() throws {
        for name in ["Codex", "Claude"] {
            let image = try #require(AgentBrandIconLoader.image(name: name))
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 64, height: 64))
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            var opaquePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                        opaquePixels += 1
                    }
                }
            }
            #expect(opaquePixels > 100)
            #expect(opaquePixels < bitmap.pixelsWide * bitmap.pixelsHigh)
        }
        #expect(AgentBrandIconLoader.image(name: "Custom") == nil)
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func conversationHeaderKeepsOneCompactRow(scheme: ColorScheme) throws {
        let host = NSHostingView(rootView: AgentChatHeader(agentName: "Codex", onHistory: {}, onNew: {},
            onOpenSettings: {}, onHide: {}, conversationTitle: "Review a long sample conversation title",
            onSearch: {}).environment(\.colorScheme, scheme))
        let height = LitheTheme.Metrics.toolWindowHeaderHeight
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == height, "The title and actions occupy one row at the narrow panel width")
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["LITHE_AGENT_ICON_ALIGNMENT_SCREENSHOTS"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("header-\(scheme).png"))
        }
    }

    @Test(arguments: [false, true])
    func composerGrowsWithDraftAndShrinksAfterClearing(editorLayout: Bool) async throws {
        let draft = AgentGrowingComposerDraft()
        var composer: NSView?
        let host = NSHostingView(rootView: AgentGrowingComposerFixture(draft: draft, editorLayout: editorLayout,
            onComposer: { composer = $0 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        func verticalScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller { return scroll }
            return view.subviews.lazy.compactMap { verticalScroll(in: $0) }.first
        }
        var stage = 0
        func layout(until condition: () -> Bool) async throws {
            stage += 1
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                await withCheckedContinuation { gate in
                    DispatchQueue.main.async {
                        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
                        host.needsLayout = true
                        host.layoutSubtreeIfNeeded()
                        gate.resume()
                    }
                }
                if condition() { return }
            } while ContinuousClock.now < deadline
            try #require(condition(), "Native composer stage \(stage) failed: writing=\(verticalScroll(in: host)?.bounds.height ?? -1), composer=\(composer?.bounds.height ?? -1)")
        }
        try await layout { composer != nil && abs((verticalScroll(in: host)?.bounds.height ?? 0) - 50) < 0.5 }
        let pane = try #require(composer)
        let scroll = try #require(verticalScroll(in: host))
        let emptyHeight = pane.bounds.height
        #expect(emptyHeight < 140, "Empty production composer must reserve two writing lines")
        #expect(abs(pane.bounds.width - (editorLayout ? 880 : 1100)) < 1)

        draft.text = "First line\nSecond line\nThird line\nFourth line"
        try await layout { scroll.bounds.height > 60 && pane.bounds.height > emptyHeight + 15 }
        let fourLineHeight = scroll.bounds.height
        #expect(fourLineHeight < 120, "Four lines should use their natural height")
        #expect(abs((pane.bounds.height - emptyHeight) - (fourLineHeight - 50)) < 1,
                "The composer must grow by the additional writing height above its two-line baseline")

        draft.text = (0..<80).map { "Line \($0): 输入越多，书写区会增高。" }.joined(separator: "\n")
        try await layout { scroll.bounds.height > fourLineHeight && (scroll.documentView?.bounds.height ?? 0) > 700 }
        #expect(scroll.bounds.height <= 240.5)
        #expect(pane.bounds.height + AgentComposerMetrics.splitTopInset <= 700 * 0.6 + 1)
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.maxY >= document.bounds.maxY - 1, "The end of a capped draft stays reachable")

        draft.files = [try AgentFileReference(url: URL(fileURLWithPath: "/example/project/README.md"))]
        draft.text = ""
        try await layout { abs(scroll.bounds.height - 50) < 0.5 && pane.bounds.height > emptyHeight + 25 }
        #expect(abs(pane.bounds.height - emptyHeight - 34) < 1)
        draft.files = []
        try await layout { abs(pane.bounds.height - emptyHeight) < 0.5 }

        draft.text = String(repeating: "输入内容应按当前窗口宽度换行。 Draft grows with its content. ", count: 8)
        try await layout { scroll.bounds.height > 50 }
        let wideHeight = scroll.bounds.height
        window.setContentSize(NSSize(width: 320, height: 400))
        try await layout { scroll.bounds.height > wideHeight + 15 && pane.bounds.width < 321 }
        #expect(abs(pane.bounds.width - (editorLayout ? 256 : 320)) < 1)
        #expect(pane.bounds.height + AgentComposerMetrics.splitTopInset <= 400 * 0.6 + 1)
        draft.text = ""
        try await layout { abs(scroll.bounds.height - 50) < 0.5 && abs(pane.bounds.height - emptyHeight) < 1 }
    }

    private func enclosingScroll(of view: NSView) -> NSScrollView? {
        if let scroll = view.superview as? NSScrollView { return scroll }
        return view.superview.flatMap { enclosingScroll(of: $0) }
    }

    private func commandScroll(in view: NSView, excluding editor: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.hasVerticalScroller, !editor.isDescendant(of: scroll) { return scroll }
        return view.subviews.lazy.compactMap { commandScroll(in: $0, excluding: editor) }.first
    }
}

@MainActor
private final class AgentGrowingComposerDraft: ObservableObject {
    @Published var text = ""
    @Published var files: [AgentFileReference] = []
    @Published var fileMentionRevision: UUID?
}

private struct AgentGrowingComposerFixture: View {
    @ObservedObject var draft: AgentGrowingComposerDraft
    let editorLayout: Bool
    let onComposer: (NSView) -> Void
    var findFiles: ((String) async -> [AgentFileMention])? = nil

    var body: some View {
        AgentConversationLayout {
            Color.clear
        } composer: {
            AgentComposerView(agents: [], selectedAgent: nil, isResponding: false, isBlocked: false,
                onSend: { _, _ in }, onCancel: {}, onSelectAgent: { _ in }, onOpenSettings: {}, onError: { _ in },
                findFiles: findFiles, fileMentionRevision: draft.fileMentionRevision,
                draftText: $draft.text, draftFiles: $draft.files)
                .background(AgentDraftFrameProbe(onCreate: onComposer))
                .modifier(AgentEditorColumn(isEditor: editorLayout))
        }
    }
}

/// Observe the actual native editor frame assigned by SwiftUI, without a run loop delay.
private struct AgentDraftFrameProbe: NSViewRepresentable {
    let onCreate: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onCreate(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension AgentConversationPresentationTests {
    @Test(arguments: ["@", "＠"], [ColorScheme.dark, .light])
    func bareFileMentionOpensTheProductionComposerList(trigger: String, scheme: ColorScheme) async throws {
        let draft = AgentGrowingComposerDraft()
        let file = AgentFileMention(path: "Sources/示例.swift", url: URL(fileURLWithPath: "/example/project/Sources/示例.swift"))
        var inventory: [AgentFileMention] = []
        var queries: [String] = []
        let host = NSHostingView(rootView: AgentGrowingComposerFixture(draft: draft, editorLayout: false,
            onComposer: { _ in }, findFiles: { query in queries.append(query); return inventory })
            .environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        func input(in view: NSView) -> NSTextField? {
            (view as? NSTextField) ?? view.subviews.lazy.compactMap { input(in: $0) }.first
        }
        func list() -> NSScrollView? {
            guard let field = input(in: host) else { return nil }
            return commandScroll(in: host, excluding: field)
        }
        func layout(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                await withCheckedContinuation { gate in
                    DispatchQueue.main.async {
                        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
                        host.needsLayout = true
                        host.layoutSubtreeIfNeeded()
                        gate.resume()
                    }
                }
                if condition() { return }
            } while ContinuousClock.now < deadline
            try #require(condition(), "The production composer did not update its file candidates")
        }
        // Exercise the real binding and task before the initial workspace scan finishes.
        draft.text = trigger
        try await layout { !queries.isEmpty }
        #expect(queries == [""], "Typing @ must request the workspace inventory without a keyword")
        inventory = [file]
        draft.fileMentionRevision = UUID()
        try await layout { list()?.bounds.height ?? 0 >= 26 }
        #expect(queries == ["", ""], "Loaded files must appear without deleting and retyping @")
        let suggestions = try #require(list(), "The production composer must display file candidates for a bare @")
        #expect(suggestions.bounds.height >= 26)
        #expect(draft.text == trigger && draft.files.isEmpty, "Opening candidates must not attach or send a file")

        if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_FILE_MENTION_SCREENSHOTS"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: folder).appendingPathComponent("bare-\(trigger == "@" ? "ascii" : "fullwidth")-\(scheme).png"))
        }
    }

    @Test(arguments: ["@", "＠", "review @"])
    func bareFileMentionSupportsSelectionDismissalAndKeywordReplacement(draft: String) {
        let first = AgentCommand.fileMention(AgentFileMention(path: "README.md", url: URL(fileURLWithPath: "/example/project/README.md")))
        let second = AgentCommand.fileMention(AgentFileMention(path: "Sources/示例.swift", url: URL(fileURLWithPath: "/example/project/Sources/示例.swift")))
        var completion = AgentCommandCompletion()
        completion.draft = draft
        completion.setFileMentions([first, second], for: "")
        #expect(completion.suggestions(in: []) == [first, second])
        #expect(completion.handle(.down, commands: [], isResponding: false) == .handled)
        #expect(completion.handle(.tab, commands: [], isResponding: false) == .attach(second))
        #expect(completion.draft == String(draft.dropLast()))
        #expect(completion.suggestions(in: []) == nil)

        completion.draft = draft
        completion.setFileMentions([first, second], for: "")
        #expect(completion.handle(.escape, commands: [], isResponding: true) == .handled)
        #expect(completion.suggestions(in: []) == nil)
        completion.draft += "Read"
        #expect(completion.suggestions(in: []) == nil, "Default candidates cannot be selected for a newer keyword")
        completion.setFileMentions([first], for: "Read")
        #expect(completion.handle(.submit, commands: [], isResponding: false) == .attach(first))
        #expect(completion.draft == String(draft.dropLast()))
    }

    @Test
    func chineseInputTriggersOpenCommandsAndSkills() {
        let commands = [AgentCommand(name: "review", description: "Review"),
                        AgentCommand(name: "$pdf", description: "Read PDFs")]
        for draft in ["¥", "￥", "$"] {
            #expect(AgentCommand.suggestions(for: draft, in: commands)?.map(\.name) == ["$pdf"])
        }
        #expect(AgentCommand.suggestions(for: "、re", in: commands)?.map(\.name) == ["review"])
        var completion = AgentCommandCompletion()
        completion.draft = "¥p"
        #expect(completion.handle(.tab, commands: commands, isResponding: false) == .handled)
        #expect(completion.draft == "$pdf ")
    }

    @Test
    func fileMentionsCompleteByRemovingTheQueryAndAttachingTheFile() throws {
        #expect(AgentCommand.mentionQuery(in: "look at @App") == "App")
        #expect(AgentCommand.mentionQuery(in: "＠") == "")
        #expect(AgentCommand.mentionQuery(in: "look at @App ") == nil)
        #expect(AgentCommand.mentionQuery(in: "mail user@host") == nil)

        let file = AgentCommand.fileMention(AgentFileMention(path: "Sources/App.swift",
                                                             url: URL(fileURLWithPath: "/w/Sources/App.swift")))
        #expect(file.isFileMention && file.invocation == "@Sources/App.swift" && file.description == "Sources")
        var completion = AgentCommandCompletion()
        completion.draft = "fix @App"
        #expect(completion.suggestions(in: []) == nil, "No rows until the file search returns")
        completion.setFileMentions([file], for: "App")
        #expect(completion.suggestions(in: [])?.map(\.name) == ["@Sources/App.swift"])
        #expect(completion.handle(.submit, commands: [], isResponding: false) == .attach(file))
        #expect(completion.draft == "fix ")
        #expect(completion.fileMentions.isEmpty)
    }

    @Test
    func fileMentionsForAnEarlierQueryCannotBeSelected() throws {
        let file = AgentCommand.fileMention(AgentFileMention(path: "App.swift", url: URL(fileURLWithPath: "/w/App.swift")))
        var completion = AgentCommandCompletion()
        completion.draft = "@App"
        completion.setFileMentions([file], for: "App")
        completion.draft = "@Read"
        #expect(completion.suggestions(in: []) == nil)
        #expect(completion.handle(.tab, commands: [], isResponding: false) == .ignored)
        #expect(completion.draft == "@Read")
    }

    @Test
    func returnOnAFullyTypedFileNameAttachesInsteadOfSending() throws {
        let readme = AgentCommand.fileMention(AgentFileMention(path: "README.md", url: URL(fileURLWithPath: "/w/README.md")))
        var completion = AgentCommandCompletion()
        completion.draft = "@README.md"
        completion.setFileMentions([readme], for: "README.md")
        #expect(completion.handle(.submit, commands: [], isResponding: false) == .attach(readme))
        #expect(completion.draft.isEmpty)
    }

    @Test
    func turnFooterShowsCompletionTimeAndCompactUsage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15, minute: 30)))
        let earlier = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9, minute: 5)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 23, minute: 59)))
        #expect(AgentTurnStatisticsPresentation.completionTime(earlier, now: now, calendar: calendar, locale: Locale(identifier: "en_US")) == "09:05")
        #expect(AgentTurnStatisticsPresentation.completionTime(yesterday, now: now, calendar: calendar, locale: Locale(identifier: "en_US")) == "2026-10-15 23:59")

        let start = ContinuousClock.Instant.now
        var turn = AgentTurnStatistics(id: "turn", startedAt: start)
        turn.finish(at: start.advanced(by: .seconds(62)), endingMessageID: "reply", usage: nil, completedAt: earlier)
        #expect(turn.completedAt == earlier)
        #expect(AgentTurnStatisticsPresentation.pill(turn, locale: Locale(identifier: "en_US")) == "1m 2s")
        let usage = try #require(AgentTurnUsage.parse(["totalTokens": 25400, "inputTokens": 24000, "outputTokens": 1400]))
        turn.finish(at: start.advanced(by: .seconds(62)), endingMessageID: "reply", usage: usage, completedAt: earlier)
        #expect(AgentTurnStatisticsPresentation.pill(turn, locale: Locale(identifier: "en_US")) == "1m 2s · 25.4K tok")
    }

    @Test
    func turnSummaryCarriesTheEndingReplyForItsCopyButton() {
        let start = ContinuousClock.Instant.now
        var turn = AgentTurnStatistics(id: "user-1", startedAt: start)
        turn.finish(at: start, endingMessageID: "agent-1", usage: nil)
        let items = AgentTranscriptItem.grouped([
            AgentConversationMessage(id: "user-1", role: .user, text: "Hi"),
            AgentConversationMessage(id: "agent-1", role: .agent, text: "Done.")
        ], turns: [turn])
        guard case .turnSummary(_, let reply) = items.last else {
            Issue.record("expected a turn summary: \(items.map(\.id))")
            return
        }
        #expect(reply == "Done.")
        #expect(AgentTranscriptItem.repliesCopiedFromFooter([turn], searchText: "") == ["agent-1"])
        #expect(AgentTranscriptItem.repliesCopiedFromFooter([turn], searchText: "Done").isEmpty,
                "Search hides the footer, so the reply keeps its own copy button")
    }

    @Test
    func pasteboardFilesAndImagesBecomeAttachmentsButTextPastes() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lithe-agent-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        #expect(AgentPasteboardAttachment.read(from: pasteboard) == .files([file]))

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        guard case .image(let png) = AgentPasteboardAttachment.read(from: pasteboard) else {
            Issue.record("expected a pasted image")
            return
        }
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        #expect(AgentPasteboardAttachment.read(from: pasteboard) == nil)

        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-16T06:03:21Z"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(AgentPastedImage.fileName(date: date, timeZone: utc, suffix: "ab12")
                == "Pasted image 2026-10-16 06.03.21 ab12.png")
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(AgentPastedImage.fileName(date: date, timeZone: losAngeles, suffix: "ab12")
                == "Pasted image 2026-10-15 23.03.21 ab12.png", "Names use local wall-clock time")
    }
}

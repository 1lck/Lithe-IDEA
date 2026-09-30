import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent conversation presentation")
struct AgentConversationPresentationTests {
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
        #expect(snapshot.windows[1].usedPercent == nil)
        #expect(!snapshot.isStale(at: Date(timeIntervalSince1970: 1800000100)))
        #expect(snapshot.isStale(at: Date(timeIntervalSince1970: 1800000121)))
        #expect(AgentSubscriptionQuota.parse(["windows": [], "fetchedAt": 1] as [String: Any]) == nil)
    }

    @Test
    func contextIndicatorUsesZeroPlaceholderAndReportedCountsWhenInUse() throws {
        let locale = Locale(identifier: "en_US")
        let usage = try #require(AgentContextUsage(usedTokens: 18700, capacityTokens: 258400))
        #expect(AgentContextUsagePresentation.percentage(nil, locale: locale) == "0%")
        #expect(AgentContextUsagePresentation.details(nil, locale: locale).contains("0.0%"))
        #expect(!AgentContextUsagePresentation.details(nil, locale: locale).contains("/"))
        #expect(AgentContextUsagePresentation.percentage(usage, locale: locale) == "7%")
        #expect(AgentContextUsagePresentation.details(usage, locale: locale).contains("7.2% · 18.7k / 258.4k"))
        let zero = try #require(AgentContextUsage(usedTokens: 0, capacityTokens: 100))
        #expect(AgentContextUsagePresentation.percentage(zero, locale: locale) == "0%")
        #expect(AgentContextUsagePresentation.details(zero, locale: locale) == AgentContextUsagePresentation.details(nil, locale: locale))
        let over = try #require(AgentContextUsage(usedTokens: 150, capacityTokens: 100))
        #expect(AgentContextUsagePresentation.percentage(over, locale: locale) == "150%")
        #expect(AgentContextUsagePresentation.details(over, locale: locale).contains("150 / 100"))
        let largest = try #require(AgentContextUsage(usedTokens: .max, capacityTokens: 1))
        #expect(largest.fraction.isFinite)
        #expect(AgentContextUsage(usedTokens: 0, capacityTokens: 0) == nil)
    }

    @Test
    func modelSearchUsesUpstreamNamesIDsAndGroupsWithoutChangingSelection() throws {
        let option = try #require(AgentSessionConfigOption.parse([[
            "id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "model-b",
            "options": [["name": "Provider", "options": [["value": "model-a", "name": "Alpha"],
                ["value": "model-b", "name": "Béta"]]]]
        ]]).first)
        let filter = { AgentSessionSelectorPresentation.filteredChoices(option, query: $0).map(\.id) }
        #expect(filter("  ") == ["model-a", "model-b"])
        #expect(filter("alpha") == ["model-a"])
        #expect(filter("MODEL-B") == ["model-b"])
        #expect(filter("beta") == ["model-b"])
        #expect(filter("Provider") == ["model-a", "model-b"])
        #expect(filter("absent") == [])
        #expect(option.currentValue == "model-b")
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

    @Test
    func inputSplitStaysWithinNarrowAndWidePanels() throws {
        let host = NSHostingView(rootView: AgentConversationLayout {
            AgentHeroView(agentName: "Codex", agentVersion: "1.13.1", onTap: {})
        } composer: {
            Color.clear
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        for size in [NSSize(width: 320, height: 500), NSSize(width: 760, height: 1000),
                     NSSize(width: 320, height: 300)] {
            host.frame.size = size
            host.layoutSubtreeIfNeeded()
            let handle = try #require(splitHandle(in: host))
            let rect = handle.convert(handle.bounds, to: host)
            #expect(rect.minY >= 0 && rect.maxY <= size.height)
            #expect(rect.width == size.width)
            #expect(rect.height == SplitHandleView.hitThickness)
        }
    }

    private func splitHandle(in view: NSView) -> SplitHandleInteractionView? {
        if let handle = view as? SplitHandleInteractionView { return handle }
        return view.subviews.lazy.compactMap { splitHandle(in: $0) }.first
    }
}

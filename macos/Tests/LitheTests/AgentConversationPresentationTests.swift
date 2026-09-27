import AppKit
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent conversation presentation")
struct AgentConversationPresentationTests {
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

import Foundation
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent selector names")
struct AgentSessionSelectorPresentationTests {
    @Test
    func approvalMenuAndCurrentValueKeepAgentNamesDespiteChineseTranslationCollisions() throws {
        let chinese = try localizationBundle("zh-Hans")
        // The unrelated app translation must remain available while Agent names bypass it.
        #expect(AgentSessionSelectorPresentation.localized("Plan", bundle: chinese) == "计划")
        let names = ["Manual", "Accept edits", "Plan", "Auto", "Bypass permissions", "Future mode"]
        let ids = ["manual", "acceptEdits", "plan", "auto", "bypassPermissions", "future"]
        var option = AgentSessionConfigOption(
            id: "mode", name: "Mode", category: "mode", currentValue: "plan",
            choices: zip(ids, names).map { .init(id: $0.0, name: $0.1) }
        )
        for language in ["zh-Hans", "en"] {
            let bundle = try localizationBundle(language)
            #expect(option.choices.map {
                AgentSessionSelectorPresentation.choiceTitle($0, in: option, bundle: bundle)
            } == names)
            for choice in option.choices {
                option.currentValue = choice.id
                #expect(AgentSessionSelectorPresentation.currentTitle(option, bundle: bundle) == choice.name)
            }
        }
    }

    @Test
    func thinkingAndModelNamesUseTheSameUpstreamRuleInBothLanguages() throws {
        let names = ["Low", "Medium", "High", "Xhigh", "Max", "Ultra"]
        for language in ["zh-Hans", "en"] {
            let bundle = try localizationBundle(language)
            for category in ["thought_level", "model"] {
                var option = AgentSessionConfigOption(
                    id: category, name: category, category: category, currentValue: "Medium",
                    choices: names.map { .init(id: $0, name: $0) }
                )
                for choice in option.choices {
                    option.currentValue = choice.id
                    #expect(AgentSessionSelectorPresentation.choiceTitle(choice, in: option, bundle: bundle) == choice.name)
                    #expect(AgentSessionSelectorPresentation.currentTitle(option, bundle: bundle) == choice.name)
                }
            }
        }
    }

    @Test
    func speedAndOtherControlsStillUseTheSelectedLanguage() throws {
        let bundle = try localizationBundle("zh-Hans")
        let speed = AgentSessionConfigOption(
            id: "fast-mode", name: "Speed", category: "model_config", currentValue: "on",
            choices: [.init(id: "off", name: "Disabled"), .init(id: "on", name: "Enabled")]
        )
        #expect(AgentSessionSelectorPresentation.currentTitle(speed, bundle: bundle)
            == bundle.localizedString(forKey: "Fast", value: nil, table: nil))
        let other = AgentSessionConfigOption(
            id: "other", name: "Other", category: "custom", currentValue: "plan",
            choices: [.init(id: "plan", name: "Plan")]
        )
        #expect(AgentSessionSelectorPresentation.currentTitle(other, bundle: bundle) == "计划")
    }

    private func localizationBundle(_ language: String) throws -> Bundle {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try #require(Bundle(url: repository.appendingPathComponent("macos/Resources/\(language).lproj")))
    }
}

import Foundation
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent selector names")
struct AgentSessionSelectorPresentationTests {
    @Test
    func knownApprovalModesFollowTheInterfaceLanguageAndUnknownModesKeepAgentNames() throws {
        // Claude Agent and Codex modes are translated only when both the upstream
        // id and its English name match; anything else keeps the Agent's name.
        let claude = [("default", "Manual"), ("acceptEdits", "Accept edits"), ("plan", "Plan"), ("auto", "Auto"),
                      ("bypassPermissions", "Bypass permissions"), ("future", "Future mode")]
        let codex = [("read-only", "Ask for approval"), ("agent", "Approve for me"), ("agent-full-access", "Full access")]
        let other = [("default", "Default"), ("plan", "Planning")]
        let expected: [String: [[String]]] = [
            "zh-Hans": [["手动", "接受编辑", "计划", "自动", "跳过权限确认", "Future mode"],
                        ["请求批准", "替我审批", "完全访问"], ["Default", "Planning"]],
            "en": [claude.map(\.1), codex.map(\.1), other.map(\.1)],
        ]
        for (language, titles) in expected {
            let bundle = try localizationBundle(language)
            for (choices, titles) in zip([claude, codex, other], titles) {
                var option = AgentSessionConfigOption(
                    id: "mode", name: "Mode", category: "mode", currentValue: choices[0].0,
                    choices: choices.map { .init(id: $0.0, name: $0.1) })
                #expect(option.choices.map {
                    AgentSessionSelectorPresentation.choiceTitle($0, in: option, bundle: bundle)
                } == titles, "\(language)")
                for (choice, title) in zip(option.choices, titles) {
                    option.currentValue = choice.id
                    #expect(AgentSessionSelectorPresentation.currentTitle(option, bundle: bundle) == title)
                }
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

    @Test
    func choiceHintsPreferUpstreamDescriptionsAndLeaveUnknownLevelsAlone() throws {
        let chinese = try localizationBundle("zh-Hans")
        let effort = AgentSessionConfigOption(id: "effort", name: "Reasoning", category: "thought_level",
            currentValue: "high", choices: [])
        #expect(AgentSessionSelectorPresentation.choiceDescription(.init(id: "high", name: "High"), in: effort, bundle: chinese)
            == "深度推理，适合复杂任务")
        #expect(AgentSessionSelectorPresentation.choiceDescription(
            .init(id: "high", name: "High", description: "Agent-specific explanation"), in: effort, bundle: chinese)
            == "Agent-specific explanation")
        #expect(AgentSessionSelectorPresentation.choiceDescription(.init(id: "future", name: "Future"), in: effort, bundle: chinese) == nil)
        let custom = AgentSessionConfigOption(id: "custom", name: "Custom", category: "custom", currentValue: "high", choices: [])
        #expect(AgentSessionSelectorPresentation.choiceDescription(.init(id: "high", name: "High"), in: custom, bundle: chinese) == nil)
    }
}

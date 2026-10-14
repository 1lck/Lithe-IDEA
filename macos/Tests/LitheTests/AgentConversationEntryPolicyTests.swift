import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import Testing
@testable import Lithe

@MainActor
struct AgentConversationEntryPolicyTests {
    @Test
    func welcomeRemainsUntilAnAgentIsChosen() throws {
        let suite = "lithe-agent-welcome-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AgentWelcomeVisit.shouldShow(defaults: defaults))
        #expect(AgentWelcomeVisit.shouldShow(defaults: defaults), "Opening and leaving the panel must not consume the welcome page")
        defaults.set(true, forKey: AppSettings.agentSelectionPreferenceKey)
        #expect(AgentWelcomeVisit.shouldShow(defaults: defaults), "The legacy first-open flag is not a user selection")
        #expect(AgentWelcomeVisit.chosenAgentID(defaults: defaults) == nil,
                "The legacy Boolean must not become a nonexistent Agent ID")
        AgentWelcomeVisit.markAgentChosen(agentID: "codex-acp", defaults: defaults)
        #expect(!AgentWelcomeVisit.shouldShow(defaults: defaults))
        #expect(AgentWelcomeVisit.chosenAgentName(defaults: defaults) == "Codex")
        AgentWelcomeVisit.markAgentChosen(agentID: "claude-acp", defaults: defaults)
        #expect(AgentWelcomeVisit.chosenAgentName(defaults: defaults) == "Claude Agent")
    }

    @Test
    func disabledAgentKeepsItsSetupEntryAcrossEnableAndDisableWithoutConstruction() async throws {
        let runtime = ModuleRuntime()
        var factoryCalls = 0
        let manifest = try #require(BuiltInModuleCatalog.manifest(for: .agentConversation))
        #expect(manifest.defaultState == .disabled)
        try runtime.register(ModuleFactory(
            manifest: manifest,
            contributions: BuiltInModuleCatalog.contributions(for: .agentConversation)
        ) {
            factoryCalls += 1
            throw UnexpectedModuleConstruction()
        })

        for enabled in [false, true, false] {
            try await runtime.setEnabled(enabled, for: .agentConversation)
            let active = runtime.availableContributions().values.flatMap { $0 }
            let entries = AgentConversationEntryPolicy.rightSidebarContributions(from: active)
            let agent = try #require(entries.first { $0.id == "agent.conversation" })
            let dockEntry = try #require(AgentConversationEntryPolicy.contribution(
                for: "agent.conversation", from: active
            ))
            #expect(entries.count == 1)
            #expect(agent.actionID == "agent.conversation.toggle")
            #expect(agent.rendererID == "agent.conversation")
            #expect(dockEntry.id == agent.id)
            #expect(WorkbenchModuleUIComposition.builtIn.renderer(for: dockEntry) != nil)
            try WorkbenchModuleUIComposition.builtIn.validate(contributions: entries)
            #expect(try runtime.snapshot(for: .agentConversation).isInstantiated == false)
            #expect(runtime.capability(.agentConversation) == nil)
            #expect(factoryCalls == 0)
        }
        await runtime.shutdownAll()
    }

    @Test
    func agentEntryDoesNotExposeOtherDisabledModulesOrDuplicateEnabledTools() throws {
        let execution = BuiltInModuleCatalog.contributions(for: .execution)
        let enabled = execution + BuiltInModuleCatalog.contributions(for: .agentConversation)
        let entries = AgentConversationEntryPolicy.rightSidebarContributions(from: enabled)
        #expect(entries.filter { $0.id == "agent.conversation" }.count == 1)
        #expect(entries.contains { $0.id == "execution.maven" })
        #expect(!entries.contains { $0.id == "execution.maven.output" })
        #expect(entries.allSatisfy { $0.placement == .rightSidebar })
        let disabled = AgentConversationEntryPolicy.rightSidebarContributions(from: [])
        #expect(disabled.map(\.id) == ["agent.conversation"])
        #expect(AgentConversationEntryPolicy.contribution(for: "execution.maven", from: []) == nil)
        try WorkbenchModuleUIComposition.builtIn.validate(contributions: entries)
    }
}

private struct UnexpectedModuleConstruction: Error {}

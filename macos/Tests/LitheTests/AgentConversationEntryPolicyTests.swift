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

        let settings = AppSettings(store: MacUserDefaultsStore(defaults: defaults))
        #expect(settings.preferredConversationAgentID == nil)
        defaults.set(true, forKey: AppSettings.agentSelectionPreferenceKey)
        #expect(settings.preferredConversationAgentID == nil,
                "The legacy first-open Boolean is not a user selection and must not become a nonexistent Agent ID")
        settings.preferredConversationAgentID = "codex-acp"
        #expect(AppSettings(store: MacUserDefaultsStore(defaults: defaults)).preferredConversationAgentID == "codex-acp")
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
            let dockEntry = try #require(AgentConversationEntryPolicy.contributions(from: active)
                .first { $0.rendererID == "agent.conversation" })
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
        #expect(!entries.contains { $0.id == "execution.build.output" })
        #expect(entries.allSatisfy { $0.placement == .rightSidebar })
        let disabled = AgentConversationEntryPolicy.rightSidebarContributions(from: [])
        #expect(disabled.map(\.id) == ["agent.conversation"])
        #expect(!AgentConversationEntryPolicy.contributions(from: []).contains { $0.id == "execution.build.output" })
        try WorkbenchModuleUIComposition.builtIn.validate(contributions: entries)
    }
}

private struct UnexpectedModuleConstruction: Error {}

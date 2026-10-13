import LitheApplicationKernel
import LitheModuleAPI
import Testing
@testable import Lithe

@MainActor
struct AgentConversationEntryPolicyTests {
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
            let entries = AgentConversationEntryPolicy.rightSidebarContributions(
                from: runtime.availableContributions().values.flatMap { $0 }
            )
            let agent = try #require(entries.first { $0.id == "agent.conversation" })
            #expect(entries.count == 1)
            #expect(agent.actionID == "agent.conversation.toggle")
            #expect(agent.rendererID == "agent.conversation")
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
        try WorkbenchModuleUIComposition.builtIn.validate(contributions: entries)
    }
}

private struct UnexpectedModuleConstruction: Error {}

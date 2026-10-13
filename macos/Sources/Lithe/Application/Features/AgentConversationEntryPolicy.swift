import LitheModuleAPI

/// The Agent setup entry is available before its optional module is enabled.
/// Only static metadata is read; module construction remains with the runtime.
enum AgentConversationEntryPolicy {
    static func rightSidebarContributions(from enabledContributions: [ModuleContribution]) -> [ModuleContribution] {
        var entries = enabledContributions.filter { $0.placement == .rightSidebar }
        let existingIDs = Set(entries.map(\.id))
        entries += BuiltInModuleCatalog.contributions(for: .agentConversation).filter {
            $0.placement == .rightSidebar && !existingIDs.contains($0.id)
        }
        return entries.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }
}

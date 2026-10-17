import Testing
@testable import Lithe

/// Protects the settings sidebar hierarchy.
///
/// The group of a page used to be written in three separate `switch` statements,
/// so a new page could be listed under one group and labelled with another. These
/// tests pin the single source of truth and the ownership table in
/// `.agents/notes/implemented/feature/2026-10-15-macos-settings-hierarchy.md`.
@Suite("Settings sidebar layout")
struct SettingsSidebarLayoutTests {
    @Test func everyPageIsReachableExactlyOnceFromTheSidebar() {
        var reachable: [SettingsCategory] = []
        for item in SettingsSidebarItem.layout {
            switch item {
            case .group(let group): reachable += group.categories
            case .page(let category): reachable.append(category)
            }
        }

        #expect(reachable.count == Set(reachable).count, "a page appears twice: \(reachable)")
        #expect(Set(reachable) == Set(SettingsCategory.allCases))
    }

    @Test func groupLookupMatchesGroupMembership() {
        for group in SettingsGroup.allCases {
            for category in group.categories {
                #expect(category.group == group)
            }
        }
        #expect(SettingsCategory.plugins.group == nil)
    }

    @Test func pagesLiveInTheGroupsDescribedByTheOwnershipRules() {
        #expect(SettingsGroup.appearance.categories == [.general, .updates, .editor, .keymap, .processTermination])
        #expect(SettingsGroup.versionControl.categories == [.git])
        #expect(SettingsGroup.build.categories == [.project, .run])
        #expect(SettingsGroup.languages.categories == [.lsp])
        #expect(SettingsGroup.tools.categories == [.terminal, .diagnostics])
        #expect(SettingsGroup.ai.categories == [.mcp, .ai, .agents, .providers])
    }
}

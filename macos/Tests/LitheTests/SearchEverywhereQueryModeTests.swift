import Testing
@testable import Lithe

@Suite("Search Everywhere query mode")
struct SearchEverywhereQueryModeTests {
    @Test
    func ordinaryTextSearchesTheWorkspaceWithoutEnteringCommandMode() {
        let mode = SearchEverywhereQueryMode(query: "l")

        #expect(mode.workspaceQuery == "l")
        #expect(mode.workspaceSearchTaskID == "workspace:l")
        #expect(mode.commandQuery == nil)
    }

    @Test
    func slashListsAllCommandsWithoutSearchingTheWorkspace() {
        let mode = SearchEverywhereQueryMode(query: "/")

        #expect(mode.workspaceQuery.isEmpty)
        #expect(mode.workspaceSearchTaskID == "commands")
        #expect(mode.commandQuery == "")
    }

    @Test
    func slashPrefixIsRemovedBeforeFilteringCommands() {
        let mode = SearchEverywhereQueryMode(query: "/run")

        #expect(mode.workspaceQuery.isEmpty)
        #expect(mode.workspaceSearchTaskID == "commands")
        #expect(mode.commandQuery == "run")
    }
}

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
        #expect(SearchEverywhereResultSource(queryMode: mode, scope: .all) == .combinedWorkspaceNames)
    }

    @Test
    func slashListsAllCommandsWithoutSearchingTheWorkspace() {
        let mode = SearchEverywhereQueryMode(query: "/")

        #expect(mode.workspaceQuery.isEmpty)
        #expect(mode.workspaceSearchTaskID == "commands")
        #expect(mode.commandQuery == "")
        #expect(SearchEverywhereResultSource(queryMode: mode, scope: .files) == .commands(""))
    }

    @Test
    func slashPrefixIsRemovedBeforeFilteringCommands() {
        let mode = SearchEverywhereQueryMode(query: "/run")

        #expect(mode.workspaceQuery.isEmpty)
        #expect(mode.workspaceSearchTaskID == "commands")
        #expect(mode.commandQuery == "run")
        #expect(SearchEverywhereResultSource(queryMode: mode, scope: .symbols) == .commands("run"))
    }

    @Test
    func commandModeUsesCommandSpecificEmptyStateRegardlessOfSelectedScope() {
        let source = SearchEverywhereResultSource(
            queryMode: SearchEverywhereQueryMode(query: "/missing"),
            scope: .files
        )

        #expect(source.emptyResultsMessage == "No matching commands")
    }

    @Test
    func actionsScopeUsesTheOrdinaryQueryOutsideCommandMode() {
        let source = SearchEverywhereResultSource(
            queryMode: SearchEverywhereQueryMode(query: "run"),
            scope: .actions
        )

        #expect(source == .actions("run"))
        #expect(source.emptyResultsMessage == "No matches in Actions")
    }
}

import Testing
@testable import Lithe

@Suite("Search session")
@MainActor
struct SearchSessionFeatureModelTests {
    @Test
    func resetClearsAllTransientSearchState() {
        let session = SearchSessionFeatureModel()
        session.query = "needle"
        session.isSearchEverywhereVisible = true
        session.everywhereQuery = "action"
        session.isProjectReplaceVisible = true
        session.replacementQuery = "old"
        session.replacementText = "new"
        session.replacementOptions = .default
        session.selectedReplacementPaths = ["A.swift", "B.swift"]
        session.sidebarFocusRequest = 4

        session.reset()

        #expect(session.query.isEmpty)
        #expect(!session.isSearchEverywhereVisible)
        #expect(session.everywhereQuery.isEmpty)
        #expect(!session.isProjectReplaceVisible)
        #expect(session.replacementQuery.isEmpty)
        #expect(session.replacementText.isEmpty)
        #expect(session.selectedReplacementPaths.isEmpty)
        #expect(session.sidebarFocusRequest == 4)
    }
}

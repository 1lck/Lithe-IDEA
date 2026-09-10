import Combine
import LitheSearchModule

/// Owns transient search and project-replacement presentation state.
@MainActor
final class SearchSessionFeatureModel: ObservableObject {
    @Published var query = ""
    @Published var isSearchEverywhereVisible = false
    var everywhereQuery = ""
    @Published var isProjectReplaceVisible = false
    @Published var replacementQuery = ""
    @Published var replacementText = ""
    @Published var replacementOptions = ProjectSearchOptions.default
    @Published var selectedReplacementPaths: Set<String> = []
    @Published var sidebarFocusRequest = 0

    func reset() {
        query = ""
        isSearchEverywhereVisible = false
        everywhereQuery = ""
        isProjectReplaceVisible = false
        replacementQuery = ""
        replacementText = ""
        selectedReplacementPaths = []
    }
}

import Combine
import LitheSearchModule
import LitheGitModule

enum SearchEverywhereScope: String, CaseIterable, Identifiable {
    case all = "All"
    case classes = "Classes"
    case files = "Files"
    case symbols = "Symbols"
    case actions = "Actions"
    case text = "Text"

    var id: String { rawValue }
}

/// Owns transient search and project-replacement presentation state.
@MainActor
final class SearchSessionFeatureModel: ObservableObject {
    @Published var query = ""
    @Published var isSearchEverywhereVisible = false
    @Published var everywhereGitStatus = GitTreeStatusProjection(changes: [])
    var everywhereQuery = ""
    @Published var everywhereScope: SearchEverywhereScope = .all
    private var everywhereHistory: [(query: String, scope: SearchEverywhereScope)] = []

    // Community SearchHistoryList: per-source deduplication, 50 entries, All merges sources.
    func everywhereHistoryItems(for scope: SearchEverywhereScope) -> [String] {
        var seen = Set<String>()
        let items = everywhereHistory.filter { scope == .all || $0.scope == scope }
            .map(\.query).filter { seen.insert($0).inserted }
        return Array(items.suffix(50))
    }

    func beginSearchEverywhere(scope: SearchEverywhereScope = .all, query: String? = nil) {
        everywhereScope = scope
        // Reopening All resumes the draft, including an explicitly cleared query.
        everywhereQuery = query ?? (scope == .all ? everywhereQuery : everywhereHistoryItems(for: scope).last ?? "")
        isSearchEverywhereVisible = true
    }

    func endSearchEverywhere() {
        guard isSearchEverywhereVisible else { return }
        if !everywhereQuery.isEmpty {
            everywhereHistory.removeAll { $0.query == everywhereQuery && $0.scope == everywhereScope }
            everywhereHistory.append((everywhereQuery, everywhereScope))
            if everywhereHistory.filter({ $0.scope == everywhereScope }).count > 50,
               let oldest = everywhereHistory.firstIndex(where: { $0.scope == everywhereScope }) {
                everywhereHistory.remove(at: oldest)
            }
        }
        isSearchEverywhereVisible = false
    }

    @Published var enabledEverywhereProviders = Set(SearchEverywhereProvider.allCases)
    @Published var isEverywherePreviewVisible = false
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
        everywhereGitStatus = GitTreeStatusProjection(changes: [])
        everywhereScope = .all
        everywhereHistory.removeAll()
        enabledEverywhereProviders = Set(SearchEverywhereProvider.allCases)
        isEverywherePreviewVisible = false
        isProjectReplaceVisible = false
        replacementQuery = ""
        replacementText = ""
        selectedReplacementPaths = []
    }
}

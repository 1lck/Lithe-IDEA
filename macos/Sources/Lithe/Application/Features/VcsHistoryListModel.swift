import Combine
import Foundation
import LitheCoreContracts

/// One presented revision list. Provider cursors are opaque; a failed page
/// remains explicitly retryable, while exhausted/non-progressing pages stop.
@MainActor
final class VcsHistoryListModel: ObservableObject {
    @Published private(set) var entries: [VcsHistoryEntry] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?
    private var hasLoaded = false
    private var visitedCursors: Set<String> = []
    private var generation = UUID()

    func reset() {
        generation = UUID()
        entries = []
        nextCursor = nil
        hasLoaded = false
        visitedCursors = []
        isLoading = false
        failure = nil
    }

    func load(automatically: Bool = false, using fetch: (String?) async throws -> VcsHistoryPage) async {
        guard !isLoading, !hasLoaded || nextCursor != nil,
              !(automatically && failure != nil) else { return }
        let generation = generation
        let cursor = nextCursor
        isLoading = true
        failure = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            let page = try await fetch(cursor)
            guard self.generation == generation, !Task.isCancelled else { return }
            var known = Set(entries.map(\.id))
            let fresh = page.entries.filter { known.insert($0.id).inserted }
            entries += fresh
            hasLoaded = true
            if let cursor { visitedCursors.insert(cursor) }
            nextCursor = page.nextCursor.flatMap { next in
                fresh.isEmpty || next == cursor || visitedCursors.contains(next) ? nil : next
            }
        } catch is CancellationError {
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            failure = VcsProvidersFeatureModel.message(for: error)
        }
    }
}

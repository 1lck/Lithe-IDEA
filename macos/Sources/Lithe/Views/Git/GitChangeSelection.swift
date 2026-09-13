import Foundation
import LitheGitModule

/// File-list selection is independent of the file currently previewed in the diff.
struct GitChangeSelection {
    private(set) var ids: Set<String> = []
    private(set) var anchor: String?

    mutating func select(_ id: String, orderedIDs: [String], command: Bool, shift: Bool) {
        retain(orderedIDs)
        guard orderedIDs.contains(id) else { return }
        if shift, let anchor, let start = orderedIDs.firstIndex(of: anchor),
           let end = orderedIDs.firstIndex(of: id) {
            let range = Set(orderedIDs[min(start, end)...max(start, end)])
            ids = command ? ids.union(range) : range
        } else {
            if command {
                if !ids.insert(id).inserted { ids.remove(id) }
            } else {
                ids = [id]
            }
            anchor = id
        }
    }

    func actionTargets(in changes: [GitChange], clicked: GitChange? = nil) -> [GitChange] {
        if let clicked, !ids.contains(clicked.id) {
            return changes.filter { $0.id == clicked.id }
        }
        return changes.filter { ids.contains($0.id) }
    }

    mutating func retain(_ orderedIDs: [String]) {
        let available = Set(orderedIDs)
        ids.formIntersection(available)
        if let anchor, !available.contains(anchor) { self.anchor = nil }
    }
}

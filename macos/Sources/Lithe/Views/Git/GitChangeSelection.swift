import Foundation
import LitheGitModule

/// File-list selection is independent of the file currently previewed in the diff.
struct GitChangeSelection {
    private(set) var ids: Set<String> = []
    private(set) var anchor: String?

    mutating func select(_ id: String, orderedIDs: [String], command: Bool, shift: Bool) {
        retain(orderedIDs)
        guard orderedIDs.contains(id) else { return }
        ids = LitheTreeListSelection.select(
            id, in: orderedIDs, selected: ids, anchor: anchor,
            extending: shift, toggling: command)
        if !shift || anchor == nil { anchor = id }
    }

    mutating func replace(with ids: Set<String>) {
        self.ids = ids
        if let anchor, !ids.contains(anchor) { self.anchor = nil }
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

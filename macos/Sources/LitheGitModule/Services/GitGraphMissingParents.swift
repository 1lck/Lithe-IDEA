import Foundation

/// Projects unloaded ancestors through hidden commits without storing a full
/// reachable-hash set at every hidden node. All input rows are topological.
enum GitGraphMissingParents {
    /// Shared boundary DAG: local unloaded hashes and links to older groups.
    /// Equal groups share an ID; single-parent paths with no local boundary
    /// reuse their parent's ID instead of creating another traversal step.
    private struct Group: Hashable {
        let hashes: [String]
        let parents: [Int]
    }

    static func project(
        commits: [GitCommit], byHash: [String: Int], parents: [[Int]], visible: [Int],
        add: (Int, String) -> Void
    ) {
        guard !visible.isEmpty, !Task.isCancelled else { return }
        let visibleRows = Set(visible)
        var groupForRow = [Int?](repeating: nil, count: commits.count)
        var groups: [Group] = []
        var groupIDs: [Group: Int] = [:]
        for row in commits.indices.reversed() {
            guard !Task.isCancelled else { return }
            // A visible ancestor owns its own continuation. Duplicate page
            // entries and unrelated hidden roots cannot introduce fake edges.
            guard !visibleRows.contains(row), byHash[commits[row].hash] == row else { continue }
            let hashes = Set(commits[row].parentHashes.filter { byHash[$0] == nil }).sorted()
            let inherited = Set(parents[row].compactMap { groupForRow[$0] }).sorted()
            if hashes.isEmpty, inherited.count <= 1 {
                groupForRow[row] = inherited.first
            } else {
                let group = Group(hashes: hashes, parents: inherited)
                if let id = groupIDs[group] {
                    groupForRow[row] = id
                } else {
                    let id = groups.count
                    groups.append(group)
                    groupIDs[group] = id
                    groupForRow[row] = id
                }
            }
        }
        guard !groups.isEmpty else { return }

        // A traversal stamp avoids clearing an O(history-size) visited array
        // for each visible commit. Only that commit's output hashes accumulate.
        var visited = [Int](repeating: -1, count: groups.count)
        for row in visible {
            guard !Task.isCancelled else { return }
            var pending = parents[row].compactMap { groupForRow[$0] }
            var missing = Set<String>()
            while let id = pending.popLast() {
                guard !Task.isCancelled else { return }
                guard visited[id] != row else { continue }
                visited[id] = row
                missing.formUnion(groups[id].hashes)
                pending.append(contentsOf: groups[id].parents)
            }
            let direct = Set(commits[row].parentHashes)
            for hash in missing.sorted() where !direct.contains(hash) {
                guard !Task.isCancelled else { return }
                add(row, hash)
            }
        }
    }
}

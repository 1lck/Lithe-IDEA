// Portions adapted from JetBrains IntelliJ Community, Copyright 2000-2024
// JetBrains s.r.o. and contributors, under the Apache License, Version 2.0.
// Swift adaptation: Lithe contributors. See docs/architecture/macos-git-graph.md
// and macos/Resources/GitGraph/NOTICE.txt for the pinned sources and license.
import Foundation

/// Permanent layout indices are deliberately independent of compact screen
/// columns. This is the macOS projection; it performs no I/O or native drawing.
struct GitGraphProjection {
    private struct Edge {
        let up: Int
        let down: Int?
        let parentHash: String
        let dotted: Bool
        var id: String { "\(up):\(down.map(String.init) ?? parentHash):\(dotted)" }
    }

    private enum Element {
        case node(Int)
        case edge(Int)
    }

    private let commits: [GitCommit]
    private let labels: [[GitGraphLabel]]
    private let visible: [Int]
    private let indices: [Int]
    private let colors: [Int]
    private let edges: [Edge]

    init(commits: [GitCommit], labels: [[GitGraphLabel]], visibleHashes: Set<String>?, permanentGraph: GitGraphProjection? = nil) {
        self.commits = commits
        self.labels = labels
        // History normally has unique IDs. First occurrence wins for defensive
        // handling of overlapping pages without making Dictionary trap.
        var byHash: [String: Int] = [:]
        for (row, commit) in commits.enumerated() where byHash[commit.hash] == nil {
            byHash[commit.hash] = row
        }
        var parents = [[Int]](repeating: [], count: commits.count)
        var children = parents
        for (row, commit) in commits.enumerated() {
            var seen = Set<Int>()
            for hash in commit.parentHashes {
                if let parent = byHash[hash], parent > row, seen.insert(parent).inserted {
                    parents[row].append(parent)
                    children[parent].append(row)
                }
            }
        }
        if let permanentGraph {
            let permanentRows = Dictionary(uniqueKeysWithValues: permanentGraph.commits.enumerated().map { ($1.hash, $0) })
            indices = commits.map { permanentGraph.indices[permanentRows[$0.hash]!] }
            colors = commits.map { permanentGraph.colors[permanentRows[$0.hash]!] }
        } else {
            let heads = GitGraphHeadOrdering.sortedHeads(labels: labels, children: children)
            (indices, colors) = Self.permanentLayout(labels: labels, parents: parents, heads: heads)
        }
        visible = commits.indices.filter { byHash[commits[$0].hash] == $0 && (visibleHashes?.contains(commits[$0].hash) ?? true) }
        let visibleRows = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1, $0) })
        var result: [Edge] = []
        var pairs = Set<String>()
        func add(_ up: Int, _ down: Int, dotted: Bool) {
            guard let u = visibleRows[up], let d = visibleRows[down], u < d,
                  pairs.insert("\(u):\(d)").inserted else { return }
            result.append(Edge(up: u, down: d, parentHash: commits[down].hash, dotted: dotted))
        }
        for row in visible {
            for parent in parents[row] where visibleRows[parent] != nil { add(row, parent, dotted: false) }
            var seen = Set<String>()
            for hash in commits[row].parentHashes where byHash[hash] == nil && seen.insert(hash).inserted {
                result.append(Edge(up: visibleRows[row]!, down: nil, parentHash: hash, dotted: false))
            }
        }
        if visibleHashes != nil {
            Self.dottedEdges(parents: parents, children: children, visible: Set(visible), add: { add($0, $1, dotted: true) })
            GitGraphMissingParents.project(commits: commits, byHash: byHash, parents: parents, visible: visible) { row, hash in
                result.append(Edge(up: visibleRows[row]!, down: nil, parentHash: hash, dotted: true))
            }
        }
        edges = result.sorted {
            if $0.up != $1.up { return $0.up < $1.up }
            if $0.down != $1.down { return ($0.down ?? Int.max) < ($1.down ?? Int.max) }
            return $0.parentHash < $1.parentHash
        }
    }

    private static func permanentLayout(labels: [[GitGraphLabel]], parents: [[Int]], heads: [Int]) -> ([Int], [Int]) {
        var indices = [Int](repeating: 0, count: parents.count)
        var colors = indices
        var nextParent = indices
        var layoutIndex = 1
        for head in heads {
            guard indices[head] == 0 else { continue }
            var stack = [head]
            let headIndex = layoutIndex
            let headColor = GitGraphHeadOrdering.colorID(for: labels[head])
            while let node = stack.last {
                let firstVisit = indices[node] == 0
                if firstVisit {
                    indices[node] = layoutIndex
                    // GraphColorGetterByHead + GraphColorManagerImpl: the head
                    // fragment uses its reference name; side fragments use LI.
                    colors[node] = layoutIndex == headIndex ? headColor : layoutIndex
                }
                while nextParent[node] < parents[node].count && indices[parents[node][nextParent[node]]] != 0 {
                    nextParent[node] += 1
                }
                if nextParent[node] < parents[node].count {
                    stack.append(parents[node][nextParent[node]])
                } else {
                    if firstVisit { layoutIndex += 1 }
                    stack.removeLast()
                }
            }
        }
        return (indices, colors)
    }

    /// IntelliJ DottedFilterEdgesGenerator's two directional number walks.
    /// Nearest-visible propagation avoids an exponential ancestor path search.
    private static func dottedEdges(parents: [[Int]], children: [[Int]], visible: Set<Int>, add: (Int, Int) -> Void) {
        var numbers = [Int](repeating: Int.min, count: parents.count)
        for node in parents.indices {
            if visible.contains(node) {
                var nearest = Int.min
                var adjacent = Int.min
                for child in children[node] {
                    if visible.contains(child) { adjacent = max(adjacent, numbers[child]) }
                    else { nearest = max(nearest, numbers[child]) }
                }
                if nearest == adjacent || nearest == Int.min { numbers[node] = adjacent }
                else { add(nearest, node); numbers[node] = nearest }
            } else {
                numbers[node] = children[node].reduce(Int.min) {
                    max($0, visible.contains($1) ? $1 : numbers[$1])
                }
            }
        }
        numbers = [Int](repeating: Int.max, count: parents.count)
        for node in parents.indices.reversed() {
            if visible.contains(node) {
                var nearest = Int.max
                var adjacent = Int.max
                for parent in parents[node] {
                    if visible.contains(parent) { adjacent = min(adjacent, numbers[parent]) }
                    else { nearest = min(nearest, numbers[parent]) }
                }
                if nearest == adjacent || nearest == Int.max { numbers[node] = adjacent }
                else { add(node, nearest); numbers[node] = nearest }
            } else {
                numbers[node] = parents[node].reduce(Int.max) {
                    min($0, visible.contains($1) ? $1 : numbers[$1])
                }
            }
        }
    }

    func layout(options: GitGraphDisplayOptions) -> GitGraphLayout {
        guard !visible.isEmpty else { return GitGraphLayout(rows: [], laneCount: 0, hasMissingParents: false) }
        // Values from the pinned PrintElementGeneratorImpl. Even expanded mode
        // caps extreme edges while retaining direction arrows for ordinary long edges.
        let longEdgeSize = options.longEdgeSize
        let visiblePartSize = options.visiblePartSize
        var elements = visible.indices.map { [Element.node($0)] }
        var adjacent = [[Int]](repeating: [], count: visible.count)
        for (id, edge) in edges.enumerated() {
            adjacent[edge.up].append(id)
            if let down = edge.down {
                adjacent[down].append(id)
                guard down > edge.up + 1 else { continue }
                if down - edge.up < longEdgeSize {
                    for row in (edge.up + 1)..<down { elements[row].append(.edge(id)) }
                } else {
                    for row in (edge.up + 1)...(edge.up + visiblePartSize) { elements[row].append(.edge(id)) }
                    for row in (down - visiblePartSize)..<down { elements[row].append(.edge(id)) }
                }
            } else if edge.up + 1 < visible.count {
                elements[edge.up + 1].append(.edge(id))
            }
        }
        var positions = [[Int: Int]](repeating: [:], count: visible.count)
        var nodePositions = [Int](repeating: 0, count: visible.count)
        for row in visible.indices {
            elements[row].sort {
                let order = compare($0, $1)
                return order == 0 ? stableElementKey($0) < stableElementKey($1) : order < 0
            }
            for (position, element) in elements[row].enumerated() {
                switch element {
                case .node:
                    nodePositions[row] = position
                    for edge in adjacent[row] { positions[row][edge] = position }
                case .edge(let edge): positions[row][edge] = position
                }
            }
        }
        var rows: [GitGraphRow] = []
        for row in visible.indices {
            if Task.isCancelled { return GitGraphLayout(rows: [], laneCount: 0, hasMissingParents: false) }
            var prints: [GitGraphPrintElement] = []
            for (position, element) in elements[row].enumerated() {
                let ids: [Int]
                if case .edge(let id) = element { ids = [id] } else { ids = adjacent[row] }
                for id in ids {
                    let edge = edges[id]
                    for direction in [GitGraphPrintElement.Direction.up, .down] {
                        let next = row + (direction == .up ? -1 : 1)
                        let nextPosition = positions.indices.contains(next) ? positions[next][id] : nil
                        let arrow: Bool
                        if let down = edge.down {
                            let span = down - edge.up
                            let offset = direction == .down ? row - edge.up : down - row
                            arrow = (span >= longEdgeSize && offset == visiblePartSize)
                                || (span >= options.edgeWithArrowSize && offset == 1)
                        } else {
                            // IDEA places unloaded-parent arrows on the next
                            // row, never stacked on the last visible node.
                            arrow = direction == .down && row == edge.up + 1
                        }
                        guard nextPosition != nil || arrow else { continue }
                        // Nodes never draw a terminal for a normal edge without
                        // a neighbour; only long-edge intermediate elements do.
                        prints.append(GitGraphPrintElement(
                            edgeID: edge.id, position: position, adjacentPosition: nextPosition ?? position,
                            direction: direction, colorIndex: edgeColor(edge), isDotted: edge.dotted,
                            hasArrow: arrow, isTerminal: nextPosition == nil,
                            targetHash: edge.down.map { commits[visible[direction == .down ? $0 : edge.up]].hash }
                        ))
                    }
                }
            }
            let node = visible[row]
            rows.append(GitGraphRow(
                commit: commits[node], lane: nodePositions[row], laneCount: elements[row].count,
                incomingLaneColors: elements[row].map { element in
                    if case .edge(let id) = element { return edgeColor(edges[id]) }
                    return colors[node]
                },
                parentEdges: adjacent[row].compactMap { id in
                    let edge = edges[id]
                    guard edge.up == row else { return nil }
                    return GitGraphEdge(id: edge.id, parentHash: edge.parentHash,
                                        targetLane: row + 1 < visible.count ? positions[row + 1][id] : nil,
                                        colorIndex: edgeColor(edge), isMissing: edge.down == nil)
                },
                labels: labels[node], layoutIndex: indices[node],
                nodeColorIndex: colors[node], printElements: prints
            ))
        }
        return GitGraphLayout(rows: rows, laneCount: elements.map(\.count).max() ?? 0,
                              hasMissingParents: edges.contains { $0.down == nil },
                              recommendedLaneCount: recommendedWidth(options: options))
    }

    /// IntelliJ's weighted mean plus deviation. Difference intervals produce
    /// the same per-row edge counts without scanning every live edge per row.
    private func recommendedWidth(options: GitGraphDisplayOptions) -> Int {
        let count = min(20_000, visible.count)
        guard count > 1 else { return count }
        var changes = [Int](repeating: 0, count: visible.count + 1)
        var missing = [Int](repeating: 0, count: visible.count)
        func add(_ lower: Int, _ upper: Int) {
            changes[lower] += 1
            changes[upper] -= 1
        }
        for edge in edges {
            guard let down = edge.down else { missing[edge.up] += 1; continue }
            if down - edge.up < options.longEdgeSize {
                add(edge.up, down)
            } else {
                add(edge.up, edge.up + options.visiblePartSize + 1)
                add(down - options.visiblePartSize, down)
            }
        }
        let weightRatio = 0.1
        var current = 0, previous = 0
        var sum = 0.0, squares = 0.0
        for row in 0..<count {
            current += changes[row]
            let width = Double(max(previous, current + missing[row]))
            let weight = 2 / (Double(count) * (weightRatio + 1))
                * (1 + (weightRatio - 1) * Double(row) / Double(count - 1))
            sum += width * weight
            squares += width * width * weight
            previous = current
        }
        return Int((sum + sqrt(max(0, squares - sum * sum))).rounded())
    }

    private func edgeColor(_ edge: Edge) -> Int {
        let up = visible[edge.up]
        guard let down = edge.down.map({ visible[$0] }) else { return colors[up] }
        return colors[indices[up] > indices[down] ? up : down]
    }

    private func stableElementKey(_ element: Element) -> Int {
        switch element { case .node: -1; case .edge(let id): id }
    }

    /// Direct translation of GraphElementComparatorByLayoutIndex. These rules
    /// also order crossing edges without keeping unrelated empty lane slots.
    private func compare(_ lhs: Element, _ rhs: Element) -> Int {
        switch (lhs, rhs) {
        case (.node, .node): return 0
        case (.edge(let e), .node(let n)): return compare(edge: edges[e], node: n)
        case (.node(let n), .edge(let e)): return -compare(edge: edges[e], node: n)
        case (.edge(let a), .edge(let b)):
            let first = edges[a], second = edges[b]
            guard let firstDown = first.down else { return -compare(edge: second, node: first.up) }
            guard let secondDown = second.down else { return compare(edge: first, node: second.up) }
            if first.up == second.up {
                return firstDown < secondDown ? -compare(edge: second, node: firstDown) : compare(edge: first, node: secondDown)
            }
            return first.up < second.up ? compare(edge: first, node: second.up) : -compare(edge: second, node: first.up)
        }
    }

    private func compare(edge: Edge, node: Int) -> Int {
        let nodeIndex = indices[visible[node]]
        guard let down = edge.down else { return indices[visible[edge.up]] - nodeIndex }
        let edgeIndex = max(indices[visible[edge.up]], indices[visible[down]])
        return edgeIndex != nodeIndex ? edgeIndex - nodeIndex : edge.up - node
    }
}

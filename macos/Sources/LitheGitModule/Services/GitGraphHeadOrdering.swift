// Adapted from IntelliJ GitRefManager, HeadCommitsComparator and NaturalComparator.
// Copyright 2000-2024 JetBrains s.r.o. and contributors. Apache-2.0.
// Swift adaptation: Lithe contributors. See macos/Resources/GitGraph/NOTICE.txt.
import Foundation
import LitheCoreContracts

package enum GitGraphHeadOrdering {
    static func sortedHeads(labels: [[GitGraphLabel]], children: [[Int]]) -> [Int] {
        let best = labels.map(bestReference)
        // A referenced branch may already have children. It still seeds DFS
        // before less important graph tips; tags alone do not create a head.
        return labels.indices.filter {
            children[$0].isEmpty || labels[$0].contains { $0.kind != .tag }
        }.sorted { left, right in
            switch (best[left], best[right]) {
            case let (a?, b?):
                if a == b { return left < right }
                return precedes(a, b)
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
    }

    static func bestReference(_ labels: [GitGraphLabel]) -> GitGraphLabel? {
        labels.min(by: precedes)
    }

    /// Java String.hashCode, used by IDEA's GraphColorManagerImpl for the
    /// principal fragment of a referenced head. Unreferenced heads use zero.
    static func colorID(for labels: [GitGraphLabel]) -> Int {
        guard let ref = bestReference(labels) else { return 0 }
        let hash = ref.title.utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
        return Int(hash)
    }

    private static func precedes(_ left: GitGraphLabel, _ right: GitGraphLabel) -> Bool {
        let a = priority(left), b = priority(right)
        return a == b ? naturalCompare(Array(left.title.utf16), Array(right.title.utf16)) < 0 : a < b
    }

    private static func priority(_ ref: GitGraphLabel) -> Int {
        switch ref.kind {
        case .remote: return ["origin/main", "origin/master"].contains(ref.title) ? 0 : 1
        case .branch: return ["main", "master"].contains(ref.title) ? 2 : 3
        case .tag: return 4
        case .head: return 6
        }
    }

    /// IntelliJ `NaturalComparator` order for ref names. The algorithm is shared
    /// with the Project tree through `NaturalNameOrder` in LitheCoreContracts.
    package static func naturalCompare(_ a: [UInt16], _ b: [UInt16], ignoreCase: Bool = true) -> Int {
        NaturalNameOrder.compare(a, b, ignoreCase: ignoreCase)
    }
}

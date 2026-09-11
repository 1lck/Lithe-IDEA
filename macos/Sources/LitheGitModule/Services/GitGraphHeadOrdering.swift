// Adapted from IntelliJ GitRefManager, HeadCommitsComparator and NaturalComparator.
// Copyright 2000-2024 JetBrains s.r.o. and contributors. Apache-2.0.
// Swift adaptation: Lithe contributors. See macos/Resources/GitGraph/NOTICE.txt.
import Foundation

enum GitGraphHeadOrdering {
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

    /// The upstream natural-name comparator compares digit runs without an
    /// integer conversion, including leading-zero length and a case tie-break.
    /// UTF-16 preserves Java's ordering for supplementary characters as well.
    static func naturalCompare(_ a: [UInt16], _ b: [UInt16], ignoreCase: Bool = true) -> Int {
        var i = 0, j = 0
        func digit(_ c: UInt16) -> Bool { (48...57).contains(c) }
        func numberRange(_ value: [UInt16], _ offset: Int) -> Range<Int> {
            var start = offset
            while start < value.count && value[start] == 32 { start += 1 }
            while start < value.count && value[start] == 48 { start += 1 }
            var end = start
            while end < value.count && digit(value[end]) { end += 1 }
            return start..<end
        }
        func compareRange(_ start: Int, _ other: Int, _ end: Int) -> Int {
            for offset in 0..<(end - start) {
                let difference = Int(a[start + offset]) - Int(b[other + offset])
                if difference != 0 { return difference }
            }
            return 0
        }
        while i < a.count && j < b.count {
            let first = a[i], second = b[j]
            if (digit(first) || first == 32) && (digit(second) || second == 32) {
                let r1 = numberRange(a, i), r2 = numberRange(b, j)
                if r1.count != r2.count { return r1.count - r2.count }
                let numberDifference = compareRange(r1.lowerBound, r2.lowerBound, r1.upperBound)
                if numberDifference != 0 { return numberDifference }
                let lengthDifference = (r1.upperBound - i) - (r2.upperBound - j)
                if lengthDifference != 0 { return lengthDifference }
                let leadingDifference = compareRange(i, j, r1.lowerBound)
                if leadingDifference != 0 { return leadingDifference }
                i = r1.upperBound
                j = r2.upperBound
            } else {
                if first == 32 && second > 32 && second < 48 { return 1 }
                if second == 32 && first > 32 && first < 48 { return -1 }
                var difference = Int(first) - Int(second)
                if difference != 0 && ignoreCase {
                    let upper1 = caseUnit(first, uppercase: true), upper2 = caseUnit(second, uppercase: true)
                    difference = Int(upper1) - Int(upper2)
                    if difference != 0 {
                        difference = Int(caseUnit(upper1, uppercase: false)) - Int(caseUnit(upper2, uppercase: false))
                    }
                }
                if difference != 0 { return difference }
                i += 1
                j += 1
            }
        }
        if i < a.count { return 1 }
        if j < b.count { return -1 }
        if a.count != b.count { return a.count - b.count }
        return ignoreCase ? naturalCompare(a, b, ignoreCase: false) : 0
    }

    private static func caseUnit(_ value: UInt16, uppercase: Bool) -> UInt16 {
        // U+0130 has a two-scalar full lowercase mapping, but Java Character
        // uses its simple mapping to U+0069.
        if !uppercase && value == 0x0130 { return 0x0069 }
        guard let scalar = UnicodeScalar(value) else { return value }
        let string = String(scalar)
        let mapped = Array((uppercase ? string.uppercased() : string.lowercased()).utf16)
        // Java Character mappings stay one UTF-16 unit, never expand a letter.
        return mapped.count == 1 ? mapped[0] : value
    }
}

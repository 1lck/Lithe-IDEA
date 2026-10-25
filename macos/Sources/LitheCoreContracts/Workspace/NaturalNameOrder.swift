// Adapted from IntelliJ NaturalComparator and FileNameComparator.
// Copyright 2000-2024 JetBrains s.r.o. and contributors. Apache-2.0.
// Swift adaptation: Lithe contributors. See macos/Resources/GitGraph/NOTICE.txt.

/// "Sorting for Humans" name order as IntelliJ IDEA applies it.
///
/// Branch names use `NaturalComparator` directly. Project tree rows use
/// `FileNameComparator` (`ignoreCase` and `likeFileNames`), which is what IDEA's
/// `AlphaComparator` calls for same-level nodes: digit runs compare by value, so
/// `v0.1.4` precedes `v0.1.12`. Rust Core orders the loaded directory listings with
/// the same algorithm; `shared/fixtures/workspace/file-name-order-v1.json` keeps
/// the ports aligned.
package enum NaturalNameOrder {
    /// Compares two names the way the Project view orders siblings.
    package static func compareFileNames(_ left: String, _ right: String) -> Int {
        compare(Array(left.utf16), Array(right.utf16), ignoreCase: true, likeFileNames: true)
    }

    /// Directories first, then file-name order. Each name is converted once, so
    /// sorting a large directory does not allocate per comparison.
    package static func sortedAsProjectTreeSiblings<Element>(
        _ elements: [Element],
        isDirectory: (Element) -> Bool,
        name: (Element) -> String
    ) -> [Element] {
        elements
            .map { (element: $0, isDirectory: isDirectory($0), key: Array(name($0).utf16)) }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return compare(left.key, right.key, ignoreCase: true, likeFileNames: true) < 0
            }
            .map(\.element)
    }

    /// The upstream natural-name comparator compares digit runs without an
    /// integer conversion, including leading-zero length and a case tie-break.
    /// UTF-16 preserves Java's ordering for supplementary characters as well.
    /// `likeFileNames` ranks `-` next to `_` (IDEA-80435).
    package static func compare(
        _ a: [UInt16],
        _ b: [UInt16],
        ignoreCase: Bool = true,
        likeFileNames: Bool = false
    ) -> Int {
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
                if first != second {
                    let difference = compareUnits(first, second, ignoreCase: ignoreCase, likeFileNames: likeFileNames)
                    if difference != 0 { return difference }
                }
                i += 1
                j += 1
            }
        }
        if i < a.count { return 1 }
        if j < b.count { return -1 }
        if a.count != b.count { return a.count - b.count }
        return ignoreCase ? compare(a, b, ignoreCase: false, likeFileNames: likeFileNames) : 0
    }

    private static func compareUnits(
        _ first: UInt16,
        _ second: UInt16,
        ignoreCase: Bool,
        likeFileNames: Bool
    ) -> Int {
        // `-` ranks like `_` unless the other side already is `_`, so `foo-bar` and
        // `foo_bar` stay together. Upstream maps before its transitivity fix below.
        if likeFileNames {
            if first == 45 && second != 95 {
                return compareUnits(95, second, ignoreCase: ignoreCase, likeFileNames: false)
            }
            if second == 45 && first != 95 {
                return compareUnits(first, 95, ignoreCase: ignoreCase, likeFileNames: false)
            }
        }
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
        return difference
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

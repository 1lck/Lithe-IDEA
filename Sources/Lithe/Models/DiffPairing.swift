import Foundation

/// Aligns a block of removed lines against a block of added lines by content
/// similarity instead of position.
///
/// This mirrors `pair_diff_entries` in `rust/lithe-core/src/git.rs`: git-backed
/// diffs are paired in Rust, Local History diffs here, and both need to agree or
/// the same edit renders differently depending on where it came from.
enum DiffPairing {
    /// Largest `removed.count * added.count` product we will align. Beyond this
    /// the quadratic table costs more than the pairing is worth.
    static let maximumAlignmentCells = 4_096

    /// Minimum Dice coefficient for two lines to read as a modification of each
    /// other rather than an unrelated delete plus insert.
    static let minimumPairSimilarity: Double = 0.5

    /// Character-bigram Dice coefficient over the trimmed lines, in [0, 1].
    ///
    /// Bigrams tolerate the reindentation and small edits that dominate real
    /// diffs, where a prefix/suffix comparison scores a mid-line change at zero.
    static func similarity(_ left: String, _ right: String) -> Double {
        let left = left.trimmingCharacters(in: .whitespaces)
        let right = right.trimmingCharacters(in: .whitespaces)
        if left == right { return 1 }
        if left.isEmpty || right.isEmpty { return 0 }

        func bigrams(_ text: String) -> [String] {
            let characters = Array(text)
            guard characters.count >= 2 else {
                // Treat a single character as one bigram against itself so short
                // lines can still match rather than always scoring zero.
                return [String(repeating: String(characters[0]), count: 2)]
            }
            return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
        }

        let leftBigrams = bigrams(left)
        var rightBigrams = bigrams(right)
        let total = leftBigrams.count + rightBigrams.count

        // Multiset intersection: each right bigram is consumed by one match.
        var shared = 0
        for bigram in leftBigrams {
            if let position = rightBigrams.firstIndex(of: bigram) {
                rightBigrams.remove(at: position)
                shared += 1
            }
        }

        return Double(2 * shared) / Double(total)
    }

    /// Returns index pairs into `removed` and `added`. A pair with both sides set
    /// is a modification; one-sided pairs are a removal or an addition. The
    /// matching never crosses, so line numbers stay monotonic when rendered.
    static func pairs(removed: [String], added: [String]) -> [(Int?, Int?)] {
        let rows = removed.count
        let columns = added.count

        // A lone removal against a lone addition has no competing alignment, so
        // it reads as a modification however dissimilar the lines are. Applying
        // the floor here would split every single-line edit in two.
        if rows == 1, columns == 1 { return [(0, 0)] }

        if rows == 0 || columns == 0 || rows * columns > maximumAlignmentCells {
            return (0..<max(rows, columns)).map { index in
                (index < rows ? index : nil, index < columns ? index : nil)
            }
        }

        // score[i][j] = best total similarity aligning removed[i...] with added[j...].
        var score = Array(
            repeating: Array(repeating: 0.0, count: columns + 1),
            count: rows + 1
        )
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                let bestSkip = max(score[i + 1][j], score[i][j + 1])
                let value = similarity(removed[i], added[j])
                let paired = value >= minimumPairSimilarity
                    ? value + score[i + 1][j + 1]
                    : -Double.infinity
                score[i][j] = max(paired, bestSkip)
            }
        }

        var result: [(Int?, Int?)] = []
        result.reserveCapacity(max(rows, columns))
        var i = 0
        var j = 0
        while i < rows, j < columns {
            let value = similarity(removed[i], added[j])
            let paired = value >= minimumPairSimilarity
                ? value + score[i + 1][j + 1]
                : -Double.infinity

            if paired >= score[i + 1][j], paired >= score[i][j + 1] {
                result.append((i, j))
                i += 1
                j += 1
            } else if score[i + 1][j] >= score[i][j + 1] {
                result.append((i, nil))
                i += 1
            } else {
                result.append((nil, j))
                j += 1
            }
        }
        while i < rows {
            result.append((i, nil))
            i += 1
        }
        while j < columns {
            result.append((nil, j))
            j += 1
        }

        return result
    }
}

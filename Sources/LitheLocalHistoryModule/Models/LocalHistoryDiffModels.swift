import Foundation

public enum LocalHistoryDiffRowKind: Sendable, Equatable {
    case context
    case changed
    case addition
    case removal
}

public struct LocalHistoryDiffRow: Identifiable, Sendable {
    public let id: String
    public let oldLine: Int?
    public let newLine: Int?
    public let left: String?
    public let rightText: String?
    public let kind: LocalHistoryDiffRowKind
    public let sequence: Int

    public init(oldLine: Int?, newLine: Int?, left: String?, right: String?, kind: LocalHistoryDiffRowKind, sequence: Int) {
        self.id = "\(oldLine ?? 0):\(newLine ?? 0):\(sequence)"
        self.oldLine = oldLine
        self.newLine = newLine
        self.left = left
        self.rightText = kind == .context ? (right ?? left) : right
        self.kind = kind
        self.sequence = sequence
    }
}

enum LocalHistoryDiffPairing {
    static let maximumAlignmentCells = 4_096
    static let minimumPairSimilarity = 0.5

    static func similarity(_ left: String, _ right: String) -> Double {
        let left = left.trimmingCharacters(in: .whitespaces)
        let right = right.trimmingCharacters(in: .whitespaces)
        if left == right { return 1 }
        if left.isEmpty || right.isEmpty { return 0 }
        func bigrams(_ text: String) -> [String] {
            let characters = Array(text)
            guard characters.count >= 2 else { return [String(repeating: String(characters[0]), count: 2)] }
            return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
        }
        let leftBigrams = bigrams(left)
        var rightBigrams = bigrams(right)
        var shared = 0
        for bigram in leftBigrams {
            if let index = rightBigrams.firstIndex(of: bigram) {
                rightBigrams.remove(at: index)
                shared += 1
            }
        }
        return Double(2 * shared) / Double(leftBigrams.count + bigrams(right).count)
    }

    static func pairs(removed: [String], added: [String]) -> [(Int?, Int?)] {
        let rows = removed.count, columns = added.count
        if rows == 1, columns == 1 { return [(0, 0)] }
        if rows == 0 || columns == 0 || rows * columns > maximumAlignmentCells {
            return (0..<max(rows, columns)).map { ($0 < rows ? $0 : nil, $0 < columns ? $0 : nil) }
        }
        var score = Array(repeating: Array(repeating: 0.0, count: columns + 1), count: rows + 1)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                let value = similarity(removed[i], added[j])
                let paired = value >= minimumPairSimilarity ? value + score[i + 1][j + 1] : -Double.infinity
                score[i][j] = max(paired, score[i + 1][j], score[i][j + 1])
            }
        }
        var result: [(Int?, Int?)] = [], i = 0, j = 0
        while i < rows, j < columns {
            let value = similarity(removed[i], added[j])
            let paired = value >= minimumPairSimilarity ? value + score[i + 1][j + 1] : -Double.infinity
            if paired >= score[i + 1][j], paired >= score[i][j + 1] { result.append((i, j)); i += 1; j += 1 }
            else if score[i + 1][j] >= score[i][j + 1] { result.append((i, nil)); i += 1 }
            else { result.append((nil, j)); j += 1 }
        }
        while i < rows { result.append((i, nil)); i += 1 }
        while j < columns { result.append((nil, j)); j += 1 }
        return result
    }
}

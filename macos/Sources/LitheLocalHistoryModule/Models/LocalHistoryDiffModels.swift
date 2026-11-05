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

import Foundation
import LitheGitModule
import LitheLocalHistoryModule

extension DiffRow {
    init(_ row: LocalHistoryDiffRow) {
        self.init(
            oldLine: row.oldLine, newLine: row.newLine, left: row.left, right: row.rightText,
            kind: {
                switch row.kind {
                case .context: .context
                case .changed: .changed
                case .addition: .addition
                case .removal: .removal
                }
            }(),
            sequence: row.sequence
        )
    }
}

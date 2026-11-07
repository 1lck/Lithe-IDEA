import Foundation
import LitheModuleAPI
import LitheLocalHistoryModule

extension RustCoreBridge {
    private struct CompareTextsRequest: Encodable {
        let oldText: String
        let newText: String
    }

    private struct CompareTextsPayload: Decodable {
        struct Row: Decodable {
            let oldLine: Int?
            let newLine: Int?
            let left: String?
            let right: String?
            let kind: String
        }
        let rows: [Row]
    }

    /// Core owns line splitting, matching, and pairing. Call off the main actor
    /// for anything larger than a small excerpt.
    func compareTexts(old oldText: String, current currentText: String) -> [LocalHistoryDiffRow]? {
        let result: Result<CompareTextsPayload, CoreCallError> = executeResult(
            command: "diff.compareTexts",
            payload: CompareTextsRequest(oldText: oldText, newText: currentText)
        )
        switch result {
        case .success(let payload):
            return payload.rows.enumerated().map { index, row in
                LocalHistoryDiffRow(
                    oldLine: row.oldLine,
                    newLine: row.newLine,
                    left: row.left,
                    right: row.right,
                    kind: Self.textComparisonKind(row.kind),
                    sequence: index
                )
            }
        case .failure(let error):
            coreLogSink?.emit(AppCoreFallbackSelected(error: LitheModuleAPI.LogFailure(domain: "RustCore", code: error.code), stage: "diff.compareTexts"))
            return nil
        }
    }

    private static func textComparisonKind(_ value: String) -> LocalHistoryDiffRowKind {
        switch value {
        case "changed": .changed
        case "addition": .addition
        case "removal": .removal
        default: .context
        }
    }
}

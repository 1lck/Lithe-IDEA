import Foundation
import LitheCoreContracts

/// Rust Core implementation of the shared language-tooling rules
/// (`lsp.activationPolicy`, `lsp.mergeCompletions`).
extension RustCoreBridge: LanguageToolingPolicyCore {
    package func languageServerActivation(
        state: LanguageServerActivationState?,
        event: LanguageServerActivationEvent,
        nowMs: UInt64
    ) -> Result<LanguageServerActivationOutcome, LanguageToolingPolicyFailure> {
        struct Request: Encodable {
            let state: LanguageServerActivationState?
            let event: LanguageServerActivationEvent
            let nowMs: UInt64

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                // Core distinguishes "no history" (`null`) from a missing field.
                try container.encode(state, forKey: .state)
                try container.encode(event, forKey: .event)
                try container.encode(nowMs, forKey: .nowMs)
            }

            enum CodingKeys: String, CodingKey { case state, event, nowMs }
        }
        let result: Result<LanguageServerActivationOutcome, CoreCallError> = executeResult(
            command: "lsp.activationPolicy", payload: Request(state: state, event: event, nowMs: nowMs))
        return result.mapError { LanguageToolingPolicyFailure(code: $0.code) }
    }

    package func mergeCompletions(
        labels lists: [[String]], incomplete: [Bool]
    ) -> Result<CompletionMergeSelection, LanguageToolingPolicyFailure> {
        struct List: Encodable { let labels: [String]; let isIncomplete: Bool }
        struct Request: Encodable { let lists: [List] }
        struct Response: Decodable { let keep: [[Int]]; let isIncomplete: Bool }
        let request = Request(lists: zip(lists, incomplete).map { List(labels: $0, isIncomplete: $1) })
        let result: Result<Response, CoreCallError> = executeResult(command: "lsp.mergeCompletions", payload: request)
        return result
            .map { CompletionMergeSelection(keep: $0.keep, isIncomplete: $0.isIncomplete) }
            .mapError { LanguageToolingPolicyFailure(code: $0.code) }
    }
}

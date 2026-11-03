import Foundation

extension RustCoreBridge {
    private struct ActionSearchRequest: Encodable {
        struct Candidate: Encodable { let texts: [String] }
        let query: String
        let candidates: [Candidate]
    }

    private struct ActionSearchResponse: Decodable { let indices: [Int] }

    /// One small native action snapshot, with matching and input budgets owned by Core.
    func searchActions(query: String, texts: [[String]]) throws -> [Int] {
        let response: Result<ActionSearchResponse, CoreCallError> = executeResult(
            command: "search.actions",
            payload: ActionSearchRequest(query: query, candidates: texts.map(ActionSearchRequest.Candidate.init))
        )
        return try response.get().indices
    }
}

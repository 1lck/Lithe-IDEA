import Foundation
import LitheModuleAPI

extension RustCoreBridge {
    /// One natively enumerated sibling sent to `workspace.orderEntries`.
    struct OrderedEntry: Encodable, Sendable {
        let name: String
        let isDirectory: Bool
    }

    /// Core's Project-view order (IDEA's FileNameComparator) as indices into
    /// `entries`. Swift never compares names itself; nil means Core rejected
    /// the request, which was logged here.
    func orderEntries(_ entries: [OrderedEntry], directoriesFirst: Bool = true) -> [Int]? {
        guard entries.count > 1 else { return Array(entries.indices) }
        struct Request: Encodable { let entries: [OrderedEntry]; let directoriesFirst: Bool }
        struct Response: Decodable { let order: [Int] }
        let result: Result<Response, CoreCallError> = executeResult(
            command: "workspace.orderEntries",
            payload: Request(entries: entries, directoriesFirst: directoriesFirst)
        )
        switch result {
        case .success(let response):
            guard response.order.count == entries.count,
                  Set(response.order) == Set(entries.indices) else { return nil }
            return response.order
        case .failure(let error):
            coreLogSink?.emit(AppCoreFallbackSelected(
                error: LitheModuleAPI.LogFailure(domain: "RustCore", code: error.code),
                stage: "workspace.orderEntries"
            ))
            return nil
        }
    }
}

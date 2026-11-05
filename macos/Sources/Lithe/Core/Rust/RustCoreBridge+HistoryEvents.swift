import Foundation
import LitheCoreContracts
import LitheModuleAPI

extension RustCoreBridge {
    /// Snapshots Core records for an editing event; nil means Core rejected it, which was
    /// logged here.
    func historyPlanEvent(_ event: LocalHistoryEvent) -> [LocalHistorySnapshotPlan]? {
        struct Request: Encodable { let event: String }
        struct Snapshot: Decodable { let source: String; let reason: String }
        struct Response: Decodable { let snapshots: [Snapshot] }
        let result: Result<Response, CoreCallError> = executeResult(
            command: "history.planEvent", payload: Request(event: event.rawValue)
        )
        switch result {
        case .success(let response):
            let plans = response.snapshots.compactMap { snapshot -> LocalHistorySnapshotPlan? in
                guard let source = LocalHistorySnapshotPlan.Source(rawValue: snapshot.source),
                      let reason = LocalHistoryReason(rawValue: snapshot.reason) else { return nil }
                return LocalHistorySnapshotPlan(source: source, reason: reason)
            }
            return plans.count == response.snapshots.count ? plans : nil
        case .failure(let error):
            coreLogSink?.emit(AppCoreFallbackSelected(
                error: LitheModuleAPI.LogFailure(domain: "RustCore", code: error.code),
                stage: "history.planEvent"
            ))
            return nil
        }
    }
}

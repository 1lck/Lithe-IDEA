import Foundation

enum DebugStartOrContinueAction: String, Decodable {
    case start, `continue`, none
}

extension RustCoreBridge {
    /// Uses Core's shared debugger state decision for the combined shortcut.
    func debugStartOrContinue(active: Bool, paused: Bool, requestPending: Bool) throws -> DebugStartOrContinueAction {
        struct Request: Encodable { let active: Bool; let paused: Bool; let requestPending: Bool }
        struct Response: Decodable { let action: DebugStartOrContinueAction }
        let result: Result<Response, CoreCallError> = executeResult(
            command: "debug.startOrContinue", payload: Request(active: active, paused: paused, requestPending: requestPending))
        return try result.get().action
    }
}

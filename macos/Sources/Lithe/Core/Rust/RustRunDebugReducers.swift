import Foundation
import LitheCoreContracts

/// Pure Core reducers for test verdicts and debugger paging; no native I/O.
extension RustCoreBridge: DebugPagingCoreCommandExecuting, TestRunOutcomeCoreCommandExecuting {
    func executeDebugPagingCommand<Payload: Encodable, Response: Decodable>(
        _ command: String,
        payload: Payload
    ) throws -> Response {
        try executeResult(command: command, payload: payload).get()
    }

    func executeTestRunOutcomeCommand<Payload: Encodable, Response: Decodable>(
        _ command: String,
        payload: Payload
    ) throws -> Response {
        try executeResult(command: command, payload: payload).get()
    }
}

import Foundation
import LitheCoreContracts

extension RustRemoteConnectionOperations: RemoteProcessRunning {
    func runProcess(
        _ request: RemoteProcessRequest, session: String, timeout: Duration?,
        onEvent: @escaping @Sendable (RemoteProcessEvent) -> Void
    ) async throws -> RemoteProcessResult {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let params: RemoteProcessRequest
            let timeoutMilliseconds: UInt64?
        }
        struct Event: Decodable {
            struct Parameters: Decodable { let stream: String; let data: String }
            let type: String
            let event: String
            let params: Parameters
        }
        let milliseconds = timeout.map { duration -> UInt64 in
            let parts = duration.components
            let seconds = max(0, parts.seconds)
            let fractional = max(0, parts.attoseconds / 1_000_000_000_000_000)
            return UInt64(min(seconds, 86_400)) * 1_000 + UInt64(fractional)
        }
        let result: Result<RemoteProcessResult, RemoteProbeFailure> = await run(
            "remote.runProcess",
            payload: Payload(sessionId: session, params: request, timeoutMilliseconds: milliseconds),
            onPrompt: { _ in }, onEvent: { raw in
                guard let event = try? JSONDecoder().decode(Event.self, from: Data(raw.utf8)),
                      event.type == "remote", event.event == "process.output",
                      let bytes = Data(base64Encoded: event.params.data) else { return }
                onEvent(.output(bytes, standardError: event.params.stream == "stderr"))
            }
        )
        try Task.checkCancellation()
        return try result.get()
    }
}

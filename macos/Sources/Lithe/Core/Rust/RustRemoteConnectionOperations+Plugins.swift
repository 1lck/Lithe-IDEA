import Foundation
import LitheCoreContracts

extension RustRemoteConnectionOperations: RemotePluginFileAccess {
    func pluginHost(session: String) async throws -> RemotePluginHost {
        let result: Result<RemotePluginHost, RemoteProbeFailure> = await run(
            "remote.hostInfo", payload: ["sessionId": session], onPrompt: { _ in })
        try Task.checkCancellation()
        return try result.get()
    }

    func pluginRequest(_ method: String, params: ToolingJSONValue, session: String) async throws -> ToolingJSONValue {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let method: String
            let params: ToolingJSONValue
        }
        let result: Result<ToolingJSONValue, RemoteProbeFailure> = await run(
            "remote.hostRequest", payload: Payload(sessionId: session, method: method, params: params), onPrompt: { _ in })
        try Task.checkCancellation()
        return try result.get()
    }

    func uploadPluginFile(_ source: URL, to path: String, sha256: String, mode: UInt32, session: String) async throws {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let sourcePath: String
            let path: String
            let sha256: String
            let mode: UInt32
        }
        let result: Result<ToolingJSONValue, RemoteProbeFailure> = await run("remote.uploadFile",
            payload: Payload(sessionId: session, sourcePath: source.path, path: path, sha256: sha256, mode: mode), onPrompt: { _ in })
        try Task.checkCancellation()
        _ = try result.get()
    }
}

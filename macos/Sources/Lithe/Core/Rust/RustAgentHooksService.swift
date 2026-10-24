import Foundation
import LitheCoreContracts

struct RustAgentHooksService: AgentHooksService {
    let core: RustCoreBridge
    let directory: URL

    private struct Request: Encodable, Sendable {
        let dataDirectory: String
        let action: String
        var expectedRevision: String? = nil
        var files: [AgentHookFileGuard]? = nil
        var hook: AgentHook? = nil
        var id: String? = nil
    }

    func load() async throws -> AgentHookLibrary { try await run(Request(dataDirectory: directory.path, action: "read")) }
    func save(_ hook: AgentHook, library: AgentHookLibrary) async throws -> AgentHookLibrary {
        try await run(Request(dataDirectory: directory.path, action: "save", expectedRevision: library.revision,
                              files: library.targets.compactMap(\.file), hook: hook))
    }
    func remove(id: String, library: AgentHookLibrary) async throws -> AgentHookLibrary {
        try await run(Request(dataDirectory: directory.path, action: "remove", expectedRevision: library.revision,
                              files: library.targets.compactMap(\.file), id: id))
    }
    func sync(library: AgentHookLibrary) async throws -> AgentHookLibrary {
        try await run(Request(dataDirectory: directory.path, action: "sync", expectedRevision: library.revision,
                              files: library.targets.compactMap(\.file)))
    }
    private func run(_ request: Request) async throws -> AgentHookLibrary {
        let core = core
        let operationID = UUID().uuidString
        let cancellation = RustCoreCancellation(core: core, operationID: operationID)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                if cancellation.isCancelled { throw CancellationError() }
                let result: Result<AgentHookLibrary, RustCoreBridge.CoreCallError> = core.executeResult(
                    command: "agent.hooks", payload: request, operationID: operationID,
                    onEvent: { cancellation.receive($0) })
                return try result.get()
            }.value
        } onCancel: { cancellation.cancel() }
    }
}

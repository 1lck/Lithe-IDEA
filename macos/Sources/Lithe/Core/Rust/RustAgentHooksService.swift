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

    private struct DraftRequest: Encodable, Sendable {
        struct Draft: Encodable, Sendable {
            let id, name, description: String
            let event: AgentHookEvent
            let matcher: AgentHookMatcher
            let command, timeoutText: String
            let agents: [String]
        }
        struct Existing: Encodable, Sendable { let id, name: String }
        let hook: Draft
        let existingHooks: [Existing]
    }

    func validateDraft(_ hook: AgentHook, timeoutText: String, library: AgentHookLibrary) throws -> AgentHookDraftValidation {
        let request = DraftRequest(
            hook: .init(id: hook.id, name: hook.name, description: hook.description, event: hook.event,
                        matcher: hook.matcher, command: hook.command, timeoutText: timeoutText, agents: hook.agents),
            existingHooks: library.hooks.map { .init(id: $0.id, name: $0.hook.name) })
        let result: Result<AgentHookDraftValidation, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "agent.hooks.validateDraft", payload: request)
        return try result.get()
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

import Foundation
import LitheCoreContracts

struct RustAgentInstructionsService: AgentInstructionsService {
    let core: RustCoreBridge
    var sharedDirectory: URL? = nil
    private struct Read: Encodable, Sendable { let agentId: String }
    private struct Save: Encodable, Sendable {
        let agentId: String
        let content: String
        let expectedPath: String
        let expectedRevision: String
    }

    func read(agent: AgentInstructionKind) async throws -> AgentInstructionFile {
        try await run("agent.instructions.read", Read(agentId: agent.rawValue))
    }

    func save(file: AgentInstructionFile, content: String) async throws -> AgentInstructionFile {
        try await run("agent.instructions.save", Save(agentId: file.agentId, content: content,
                      expectedPath: file.path, expectedRevision: file.revision))
    }

    private struct SharedGuard: Encodable, Sendable {
        let agentId: String
        let path: String
        let revision: String
        init(_ file: AgentInstructionFile) { agentId = file.agentId; path = file.path; revision = file.revision }
    }
    private struct SharedRequest: Encodable, Sendable {
        let dataDirectory: String
        let action: String
        var content: String? = nil
        var expectedRevision: String? = nil
        var files: [SharedGuard]? = nil
        var agentId: String? = nil
        var enabled: Bool? = nil
        var file: SharedGuard? = nil
    }

    func readShared() async throws -> SharedInstructionLibrary {
        try await run("agent.instructions.shared", SharedRequest(dataDirectory: try directory(), action: "read"))
    }

    func saveShared(content: String, library: SharedInstructionLibrary) async throws -> SharedInstructionLibrary {
        try await run("agent.instructions.shared", SharedRequest(dataDirectory: try directory(), action: "save",
            content: content, expectedRevision: library.file.revision,
            files: library.agents.compactMap { $0.file.map(SharedGuard.init) }))
    }

    func setSharedEnabled(_ enabled: Bool, agent: AgentInstructionKind, library: SharedInstructionLibrary) async throws -> SharedInstructionLibrary {
        guard let file = library.agents.first(where: { $0.agentId == agent.rawValue })?.file else {
            throw CocoaError(.fileReadUnknown)
        }
        return try await run("agent.instructions.shared", SharedRequest(dataDirectory: try directory(), action: "setEnabled",
            expectedRevision: library.file.revision, agentId: agent.rawValue, enabled: enabled, file: SharedGuard(file)))
    }

    private func directory() throws -> String {
        guard let sharedDirectory else { throw CocoaError(.featureUnsupported) }
        return sharedDirectory.path
    }

    private func run<Result: Decodable & Sendable, Payload: Encodable & Sendable>(_ command: String, _ payload: Payload) async throws -> Result {
        let core = core
        let operationID = UUID().uuidString
        let cancellation = RustCoreCancellation(core: core, operationID: operationID)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                if cancellation.isCancelled { throw CancellationError() }
                let result: Swift.Result<Result, RustCoreBridge.CoreCallError> = core.executeResult(
                    command: command, payload: payload, operationID: operationID, onEvent: { cancellation.receive($0) })
                return try result.get()
            }.value
        } onCancel: { cancellation.cancel() }
    }
}

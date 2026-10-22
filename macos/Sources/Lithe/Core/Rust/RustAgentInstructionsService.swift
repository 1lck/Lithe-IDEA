import Foundation
import LitheCoreContracts

struct RustAgentInstructionsService: AgentInstructionsService {
    let core: RustCoreBridge
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

    private func run<Payload: Encodable & Sendable>(_ command: String, _ payload: Payload) async throws -> AgentInstructionFile {
        let core = core
        let operationID = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try core.executeResult(command: command, payload: payload, operationID: operationID).get()
            }.value
        } onCancel: { core.cancel(operationID: operationID) }
    }
}

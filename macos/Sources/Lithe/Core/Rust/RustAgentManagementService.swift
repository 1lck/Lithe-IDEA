import Foundation
import LitheCoreContracts

/// Runs `agent.*` Core commands off the main thread; cancelling the calling
/// task cancels the Core operation, which stops a running npm install.
struct RustAgentManagementService: AgentManagementService {
    let core: RustCoreBridge

    private struct StatusPayload: Encodable { let dataDirectory: String }
    private struct AgentPayload: Encodable { let dataDirectory: String; let agentId: String }
    private struct InstallResult: Decodable { let installedVersion: String }
    private struct UninstallResult: Decodable { let agentId: String }

    func status(dataDirectory: URL) async throws -> AgentManagementStatus {
        try await run("agent.status", StatusPayload(dataDirectory: dataDirectory.path))
    }

    func install(agentID: String, dataDirectory: URL) async throws -> String {
        let result: InstallResult = try await run(
            "agent.install", AgentPayload(dataDirectory: dataDirectory.path, agentId: agentID)
        )
        return result.installedVersion
    }

    func uninstall(agentID: String, dataDirectory: URL) async throws {
        let _: UninstallResult = try await run(
            "agent.uninstall", AgentPayload(dataDirectory: dataDirectory.path, agentId: agentID)
        )
    }

    private func run<Payload: Encodable & Sendable, Result: Decodable & Sendable>(
        _ command: String, _ payload: Payload
    ) async throws -> Result {
        let operationID = UUID().uuidString
        let core = core
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try core.executeResult(command: command, payload: payload, operationID: operationID).get()
            }.value
        } onCancel: {
            core.cancel(operationID: operationID)
        }
    }
}

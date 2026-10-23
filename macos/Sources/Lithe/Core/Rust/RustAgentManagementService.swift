import Foundation
import LitheCoreContracts
import LitheRustCore

/// Runs `agent.*` Core commands off the main thread; cancelling the calling
/// task cancels the Core operation, which stops a running npm install.
struct RustAgentManagementService: AgentManagementService {
    let core: RustCoreBridge

    private struct SkillsPayload: Encodable, Sendable {
        var action = "list"
        let agentId: String
        let workspace: String?
    }
    private struct SkillDirectoriesResult: Decodable, Sendable { let directories: [String: String] }
    func skillDirectories(agentID: String, workspace: URL?) async throws -> [String: String] {
        let result: SkillDirectoriesResult = try await run("agent.skills", SkillsPayload(action: "directories", agentId: agentID, workspace: workspace?.path))
        return result.directories
    }
    private struct SkillReadPayload: Encodable, Sendable {
        let action = "read"
        let agentId: String
        let source: String
    }
    private struct SkillReadResult: Decodable, Sendable { let content: String }
    func readSkill(at url: URL, agentID: String) async throws -> String {
        let result: SkillReadResult = try await run("agent.skills", SkillReadPayload(agentId: agentID, source: url.path))
        return result.content
    }
    private struct SkillWriteResult: Decodable, Sendable { let path: String }

    func listSkills(agentID: String, workspace: URL?) async throws -> AgentSkillListing {
        try await run("agent.skills", SkillsPayload(agentId: agentID, workspace: workspace?.path))
    }

    func writeSkill(_ request: AgentSkillWrite) async throws -> URL {
        let result: SkillWriteResult = try await run("agent.skills", request)
        return URL(fileURLWithPath: result.path)
    }

    func setSkillEnabled(_ request: AgentSkillEnablement) async throws -> AgentSkillListing {
        try await run("agent.skills", request)
    }

    private struct StatusPayload: Encodable { let dataDirectory: String }
    private struct AgentPayload: Encodable { let dataDirectory: String; let agentId: String }
    private struct InstallResult: Decodable { let installedVersion: String }
    private struct UninstallResult: Decodable { let agentId: String }
    private struct InstallEvent: Decodable {
        let kind: String
        let operationId: String
        let progress: AgentInstallProgress
    }

    func status(dataDirectory: URL) async throws -> AgentManagementStatus {
        try await run("agent.status", StatusPayload(dataDirectory: dataDirectory.path))
    }

    func install(agentID: String, dataDirectory: URL) async throws -> String {
        try await install(agentID: agentID, dataDirectory: dataDirectory, onProgress: { _ in })
    }

    func install(agentID: String, dataDirectory: URL,
                 onProgress: @escaping @Sendable (AgentInstallProgress) -> Void) async throws -> String {
        let result: InstallResult = try await run(
            "agent.install", AgentPayload(dataDirectory: dataDirectory.path, agentId: agentID), onProgress: onProgress
        )
        return result.installedVersion
    }

    func uninstall(agentID: String, dataDirectory: URL) async throws {
        let _: UninstallResult = try await run(
            "agent.uninstall", AgentPayload(dataDirectory: dataDirectory.path, agentId: agentID)
        )
    }

    func installCli(agentID: String, dataDirectory: URL) async throws -> AgentCliUpdateResult {
        try await installCli(agentID: agentID, dataDirectory: dataDirectory, onProgress: { _ in })
    }

    func installCli(agentID: String, dataDirectory: URL,
                    onProgress: @escaping @Sendable (AgentInstallProgress) -> Void) async throws -> AgentCliUpdateResult {
        try await run(
            "agent.installCli", AgentPayload(dataDirectory: dataDirectory.path, agentId: agentID), onProgress: onProgress
        )
    }

    private func run<Payload: Encodable & Sendable, Result: Decodable & Sendable>(
        _ command: String, _ payload: Payload,
        onProgress: (@Sendable (AgentInstallProgress) -> Void)? = nil
    ) async throws -> Result {
        let operationID = UUID().uuidString
        let core = core
        let cancellation = RustCoreCancellation(core: core, operationID: operationID)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                if cancellation.isCancelled { throw CancellationError() }
                let result: Swift.Result<Result, RustCoreBridge.CoreCallError> = core.executeResult(
                    command: command, payload: payload, operationID: operationID, onEvent: { event in
                        cancellation.receive(event)
                        guard let onProgress, let data = event.data(using: .utf8),
                              let decoded = try? JSONDecoder().decode(InstallEvent.self, from: data),
                              decoded.kind == "agentInstallProgress", decoded.operationId == operationID else { return }
                        onProgress(decoded.progress)
                    })
                return try result.get()
            }.value
        } onCancel: { cancellation.cancel() }
    }
}

/// The existing event ABI is synchronous: the owned callback remains alive until
/// the call returns, including cancellation and failure paths.
private final class AgentInstallEventCallback {
    let receive: @Sendable (String) -> Void
    init(_ receive: @escaping @Sendable (String) -> Void) { self.receive = receive }
}

extension RustCoreBridge {
    func executeAgentObserving(_ request: String, receive: @escaping @Sendable (String) -> Void) -> UnsafeMutablePointer<CChar>? {
        let callback = AgentInstallEventCallback(receive)
        return withExtendedLifetime(callback) {
            let context = Unmanaged.passUnretained(callback).toOpaque()
            return request.withCString { lithe_bridge_execute_json_with_events($0, agentInstallEventCallback, context) }
        }
    }
}

private func agentInstallEventCallback(_ event: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let event, let context else { return }
    Unmanaged<AgentInstallEventCallback>.fromOpaque(context).takeUnretainedValue().receive(String(cString: event))
}

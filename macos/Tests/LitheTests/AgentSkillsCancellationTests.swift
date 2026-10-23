import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct AgentSkillsCancellationTests {
    @Test(arguments: ["create", "import", "disable"])
    func cancelledBeforeServiceEntryLeavesSkillAndNativeConfigurationUnchanged(action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { remove(root) }
        let service = RustAgentManagementService(core: RustCoreBridge())
        let existing = AgentSkillWrite(agentID: "claude-acp", workspace: root, scope: "repo", name: "existing",
            description: "Cancellation fixture", instructions: "Read local files.")
        let source = try await service.writeSkill(existing)
        let settings = root.appendingPathComponent(".claude/settings.local.json")
        try Data(#"{"keep":"original","skillOverrides":{"existing":"on"}}"#.utf8).write(to: settings)
        let imported = root.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        try Data("---\nname: imported\ndescription: Cancellation fixture\n---\nRead local files.\n".utf8)
            .write(to: imported.appendingPathComponent("SKILL.md"))
        let before = try snapshot(root)
        let request = action == "import"
            ? AgentSkillWrite(agentID: "claude-acp", workspace: root, scope: "repo", source: imported)
            : AgentSkillWrite(agentID: "claude-acp", workspace: root, scope: "repo", name: "cancelled",
                description: "Must not be created", instructions: "Do not publish.")
        let skill = AgentSkill(name: "existing", description: "Cancellation fixture", path: source.path, scope: "repo", enabled: true)
        let task = Task {
            if action == "disable" {
                _ = try await service.setSkillEnabled(.init(agentID: "claude-acp", workspace: root, skill: skill, enabled: false))
            } else {
                _ = try await service.writeSkill(request)
            }
        }
        // Both caller and task are MainActor-isolated; cancellation precedes
        // the service entry, without a sleep or dependence on worker speed.
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled skill mutation must not succeed")
        } catch { #expect(error is CancellationError) }
        #expect(try snapshot(root) == before)
    }

    @Test func cancellationDuringEncodingIsReplayedBeforeSkillPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { remove(root) }
        let core = RustCoreBridge()
        let operationID = UUID().uuidString
        let cancellation = RustCoreCancellation(core: core, operationID: operationID)
        let request = AgentSkillWrite(agentID: "claude-acp", workspace: root, scope: "repo", name: "registered",
            description: "Valid fixture", instructions: "Only publish when allowed.")
        let result: Result<SkillPath, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "agent.skills", payload: CancelDuringSkillEncoding(value: request, cancellation: cancellation),
            operationID: operationID, onEvent: { cancellation.receive($0) })
        switch result {
        case .success: Issue.record("Pre-registration cancellation must prevent skill dispatch")
        case .failure(let error): #expect(error.code == "cancelled")
        }
        #expect(try snapshot(root).isEmpty)
        #expect(!core.cancel(operationID: operationID))
        // The request is valid and the cancelled registration does not affect a
        // subsequent operation. All paths stay in this isolated Claude project.
        let path = try await RustAgentManagementService(core: core).writeSkill(request)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        let urls = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
        var result: [String: Data] = [:]
        for case let url as URL in urls {
            let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            result[String(url.path.dropFirst(root.path.count))] = directory ? Data() : try Data(contentsOf: url)
        }
        return result
    }

    private func remove(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Skill cancellation fixture cleanup: \(error)") }
    }
}

private struct SkillPath: Decodable, Sendable { let path: String }
private struct CancelDuringSkillEncoding: Encodable {
    let value: AgentSkillWrite
    let cancellation: RustCoreCancellation
    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
        cancellation.cancel()
    }
}

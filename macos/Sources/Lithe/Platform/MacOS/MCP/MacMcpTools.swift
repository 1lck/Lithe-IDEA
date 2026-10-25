import Foundation
import LitheModuleAPI

/// Native policy snapshots use the same guarded writer and backups as server
/// settings. SDK inventory and argv parsing are shared Core/Host operations.
@MainActor
final class MacMcpTools: McpToolsManaging {
    private let core: RustCoreBridge
    private let store: any McpConfigurationStore
    private let ledger: any KeyValueStore
    private let claudeSettings: URL
    private var snapshots: [UUID: Snapshot] = [:]
    private struct Snapshot {
        let file: McpConfigurationFile
        let content: String?
        let rowID: String
        let server: String
        let tools: [String]
        let owned: [String]
        let sourceHash: String?
    }
    private struct PolicyRequest: Encodable {
        let source: String
        let content: String
        let server: String
        let tools: [String]
        let owned: [String]
        var tool: String? = nil
        var enabled: Bool? = nil
    }
    private struct PolicyResult: Decodable {
        let content: String
        let changed: Bool
        let owned: [String]
        let tools: [McpToolPermission]
        let hasRestrictions: Bool
    }

    init(core: RustCoreBridge, store: any McpConfigurationStore, ledger: any KeyValueStore,
         storage: any FileStorage, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.core = core; self.store = store; self.ledger = ledger
        let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? storage.homeDirectory().appendingPathComponent(".claude")
        claudeSettings = directory.appendingPathComponent("settings.json")
    }

    func probe(_ definition: McpServerDefinition) async throws -> McpProbeResult {
        struct Payload: Encodable, Sendable {
            let transport: McpTransport
            let command: String?
            let args: [String]
            let env: [McpKeyValue]
            let url: String?
            let headers: [McpKeyValue]
        }
        let payload = Payload(transport: definition.transport, command: definition.command, args: definition.args,
                              env: definition.env, url: definition.url, headers: definition.headers)
        let core = core; let operation = UUID().uuidString
        let cancellation = RustCoreCancellation(core: core, operationID: operation)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Debug SDK/TLS futures exceed the Swift executor's small stack.
                // This bounded blocking C ABI call owns a native thread instead.
                let worker = Thread {
                    if cancellation.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let result: Result<McpProbeResult, RustCoreBridge.CoreCallError> = core.executeResult(
                        command: "mcp.probe", payload: payload, operationID: operation, onEvent: { cancellation.receive($0) })
                    continuation.resume(with: result.mapError { $0 as any Error })
                }
                worker.name = "Lithe MCP inspection"
                worker.qualityOfService = .userInitiated
                worker.stackSize = 8 * 1024 * 1024
                worker.start()
            }
        } onCancel: { cancellation.cancel() }
    }

    func policy(for target: McpToolTarget, agent: McpAgent, tools: [String]) throws -> McpToolPolicySnapshot {
        guard let source = target.files.first(where: { $0.agent == agent }) else { throw McpConfigurationError.changedOnDisk }
        let native = try store.read(source)
        guard let definition = try store.parse(source, content: native ?? "").first(where: { $0.name == target.definition.name }),
              definition.definitionHash == target.definition.definitionHash else { throw McpConfigurationError.changedOnDisk }
        let file = agent == .codex ? source : McpConfigurationFile(agent: agent, scope: .global, url: claudeSettings, projectPath: nil)
        let content = agent == .codex ? native : try store.read(file)
        let owned = ledger.stringArray(forKey: key(file, target.definition.name)) ?? []
        let request = PolicyRequest(source: agent.sourceName, content: content ?? "", server: target.definition.name, tools: tools, owned: owned)
        let result: PolicyResult = try core.executeResult(command: "mcp.toolPolicy", payload: request).get()
        return remember(Snapshot(file: file, content: content, rowID: target.definition.id, server: target.definition.name, tools: tools, owned: owned,
                                 sourceHash: definition.sourceHash), result: result, previous: nil)
    }

    func setEnabled(_ enabled: Bool, tool: String, target: McpToolTarget, snapshot: McpToolPolicySnapshot) throws -> McpToolPolicySnapshot {
        guard let old = snapshots[snapshot.id], old.rowID == target.definition.id, old.tools.contains(tool) else { throw McpConfigurationError.changedOnDisk }
        guard (ledger.stringArray(forKey: key(old.file, old.server)) ?? []) == old.owned else { throw McpConfigurationError.changedOnDisk }
        // Recheck the connection too: Claude's deny rules live in another file.
        guard let source = target.files.first(where: { $0.agent == snapshot.agent }),
              let current = try store.parse(source, content: store.read(source) ?? "").first(where: { $0.name == target.definition.name }),
              current.definitionHash == target.definition.definitionHash else { throw McpConfigurationError.changedOnDisk }
        let result: PolicyResult = try core.executeResult(command: "mcp.toolPolicy", payload: PolicyRequest(
            source: snapshot.agent.sourceName, content: old.content ?? "", server: old.server,
            tools: old.tools, owned: old.owned, tool: tool, enabled: enabled)).get()
        if result.changed { _ = try store.write(result.content, to: old.file, replacing: old.content) }
        else if try store.read(old.file) != old.content { throw McpConfigurationError.changedOnDisk }
        ledger.set(result.owned, forKey: key(old.file, old.server))
        let updated = snapshot.agent == .codex ? try store.parse(old.file, content: result.content).first(where: { $0.name == old.server })?.sourceHash : current.sourceHash
        snapshots.removeValue(forKey: snapshot.id)
        return remember(Snapshot(file: old.file, content: result.changed ? result.content : old.content, rowID: old.rowID,
                                 server: old.server, tools: old.tools, owned: result.owned, sourceHash: updated), result: result, previous: current.sourceHash)
    }

    func release(_ values: [McpToolPolicySnapshot]) { for value in values { snapshots.removeValue(forKey: value.id) } }

    func serverRenamed(from previousName: String, to name: String, in file: McpConfigurationFile) {
        guard file.agent == .codex, previousName != name else { return }
        // The native table already moved atomically with its exact restrictions.
        // Move only our names at this profile path, never adopt external rules
        // or stale ownership left at the destination by an older server.
        let previousKey = key(file, previousName)
        ledger.set(ledger.stringArray(forKey: previousKey), forKey: key(file, name))
        ledger.set(nil, forKey: previousKey)
    }

    func validateRename(_ target: McpToolTarget) throws {
        guard target.files.contains(where: { $0.agent == .claudeCode }) else { return }
        let file = McpConfigurationFile(agent: .claudeCode, scope: .global, url: claudeSettings, projectPath: nil)
        let result: PolicyResult = try core.executeResult(command: "mcp.toolPolicy", payload: PolicyRequest(
            source: "claude", content: store.read(file) ?? "", server: target.definition.name, tools: [], owned: [])).get()
        if result.hasRestrictions { throw RenameError.restricted }
    }

    private enum RenameError: LocalizedError {
        case restricted
        var errorDescription: String? {
            L10n.string("Claude Code has MCP tool restrictions. Update its native rules before renaming a server so disabled tools do not become available under a new name.")
        }
    }

    func commandLine(command: String, args: [String]) throws -> String {
        struct Payload: Encodable { let action = "format"; let command: String; let args: [String] }
        struct Result: Decodable { let line: String }
        let result: Result = try core.executeResult(command: "mcp.commandLine", payload: Payload(command: command, args: args)).get()
        return result.line
    }

    func parseCommandLine(_ line: String) throws -> (command: String, args: [String]) {
        struct Payload: Encodable { let action = "parse"; let line: String }
        struct Result: Decodable { let command: String; let args: [String] }
        let result: Result = try core.executeResult(command: "mcp.commandLine", payload: Payload(line: line)).get()
        return (result.command, result.args)
    }

    private func remember(_ value: Snapshot, result: PolicyResult, previous: String?) -> McpToolPolicySnapshot {
        let id = UUID(); snapshots[id] = value
        return McpToolPolicySnapshot(id: id, agent: value.file.agent, tools: result.tools,
                                    previousSourceHash: previous, sourceHash: value.sourceHash)
    }
    private func key(_ file: McpConfigurationFile, _ name: String) -> String {
        "settings.mcpToolExclusions.\(file.agent.rawValue).\(file.url.path).\(name)"
    }
}

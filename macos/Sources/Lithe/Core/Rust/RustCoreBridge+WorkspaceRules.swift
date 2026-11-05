import Foundation
import LitheCoreContracts
import LitheModuleAPI

extension RustCoreBridge {
    /// Name for a copy of `name` that avoids the sibling names in `existing`. Core owns the
    /// rule; nil means Core rejected the request, which was logged here.
    func copyName(for name: String, isDirectory: Bool, existing: [String], duplicate: Bool) -> String? {
        struct Item: Encodable { let name: String; let isDirectory: Bool }
        struct DuplicateRequest: Encodable {
            let name: String; let isDirectory: Bool; let existing: [String]
        }
        struct PasteRequest: Encodable { let items: [Item]; let existing: [String] }
        struct DuplicateResponse: Decodable { let name: String }
        struct PasteResponse: Decodable { let names: [String] }
        if duplicate {
            let result: Result<DuplicateResponse, CoreCallError> = executeResult(
                command: "workspace.planDuplicate",
                payload: DuplicateRequest(name: name, isDirectory: isDirectory, existing: existing)
            )
            return logged(result, stage: "workspace.planDuplicate")?.name
        }
        let result: Result<PasteResponse, CoreCallError> = executeResult(
            command: "workspace.planPaste",
            payload: PasteRequest(items: [Item(name: name, isDirectory: isDirectory)], existing: existing)
        )
        return logged(result, stage: "workspace.planPaste")?.names.first
    }

    /// Applies a directory action to the persisted rules in Core.
    func reduceDirectoryAction(
        _ action: WorkspaceDirectoryAction, at path: String, rules: WorkspaceDirectoryRules
    ) -> WorkspaceDirectoryReduction? {
        struct Action: Encodable { let kind: String; let role: String? }
        struct Request: Encodable { let path: String; let action: Action; let rules: WorkspaceDirectoryRules }
        struct Response: Decodable { let changed: Bool; let rules: WorkspaceDirectoryRules }
        let wire: Action
        switch action {
        case .exclude: wire = Action(kind: "exclude", role: nil)
        case .cancelExclusion: wire = Action(kind: "cancelExclusion", role: nil)
        case .setRole(let role): wire = Action(kind: "setRole", role: role.rawValue)
        }
        let result: Result<Response, CoreCallError> = executeResult(
            command: "workspace.reduceDirectoryAction",
            payload: Request(path: path, action: wire, rules: rules)
        )
        return logged(result, stage: "workspace.reduceDirectoryAction")
            .map { WorkspaceDirectoryReduction(changed: $0.changed, rules: $0.rules) }
    }

    /// Migrates the persisted rules after a move (or a delete, without a destination).
    func relocateDirectoryRules(
        _ rules: WorkspaceDirectoryRules, moving source: String, to destination: String?
    ) -> WorkspaceDirectoryRules? {
        struct Request: Encodable { let source: String; let destination: String?; let rules: WorkspaceDirectoryRules }
        struct Response: Decodable { let rules: WorkspaceDirectoryRules }
        let result: Result<Response, CoreCallError> = executeResult(
            command: "workspace.relocateDirectoryRules",
            payload: Request(source: source, destination: destination, rules: rules)
        )
        return logged(result, stage: "workspace.relocateDirectoryRules")?.rules
    }

    private func logged<Value>(_ result: Result<Value, CoreCallError>, stage: String) -> Value? {
        switch result {
        case .success(let value): return value
        case .failure(let error):
            coreLogSink?.emit(AppCoreFallbackSelected(
                error: LitheModuleAPI.LogFailure(domain: "RustCore", code: error.code), stage: stage
            ))
            return nil
        }
    }
}

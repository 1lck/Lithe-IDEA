import Foundation
import LitheCoreContracts

/// Public document/editor methods reuse the existing live-buffer owner and
/// Monaco undo boundary. No disk fallback is allowed for a missing editor.
@MainActor
final class PluginDocumentHostService: PluginHostServiceHandling {
    let service = "editor"
    let methods: Set<String> = Set([
        "documents/list", "documents/getSnapshot", "editor/getActive", "editor/getSelections",
        "editor/applyEdits", "editor/replaceSelections", "editor/insertText",
    ].map { "lithe/host/" + $0 })
    private let contexts: PluginWorkspaceContexts

    init(contexts: PluginWorkspaceContexts) { self.contexts = contexts }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        do {
            let scope = try PluginHostAPIContext(call, contexts: contexts)
            guard let editor = scope.window.hostDocumentService else { throw EditorDocumentServiceError.editorUnavailable }
            let method = String(call.request.method.split(separator: "/").last ?? "")
            let allowed: Set<String>
            switch method {
            case "list", "getActive": allowed = ["context"]
            case "getSnapshot", "getSelections": allowed = ["context", "documentID"]
            case "applyEdits": allowed = ["context", "documentID", "expectedVersion", "edits"]
            case "insertText": allowed = ["context", "documentID", "expectedVersion", "at", "text"]
            case "replaceSelections": allowed = ["context", "documentID", "expectedVersion", "selections", "replacements"]
            default: throw PluginHostArguments.invalid
            }
            let args = try PluginHostArguments(call.params, allowed: allowed)
            if method == "list" { return .success(.object(["documents": .array(try editor.listDocuments(scope: scope.editorScope).map(PluginHostAPIValues.summary))])) }
            if method == "getActive" { return .success(try editor.activeDocument(scope: scope.editorScope).map(PluginHostAPIValues.summary) ?? .null) }
            guard let id = UUID(uuidString: try args.string("documentID")) else { throw PluginHostArguments.invalid }
            if method == "getSnapshot" {
                let result = try editor.snapshot(scope: scope.editorScope, documentID: id)
                guard result.text.utf8.count <= 128 * 1024 else { throw PluginWorkspaceFileError.limitExceeded(.directoryEntries) }
                return .success(.object(["document": PluginHostAPIValues.summary(result.summary), "text": .string(result.text)]))
            }
            if method == "getSelections" {
                let result = try await editor.selections(scope: scope.editorScope, documentID: id)
                _ = try PluginHostAPIContext(call, contexts: contexts)
                return .success(.object([
                    "documentID": .string(id.uuidString), "version": .integer(Int(clamping: result.version)),
                    "primaryIndex": result.primaryIndex.map(ToolingJSONValue.integer) ?? .null,
                    "selections": .array(result.selections.map { .object([
                        "anchor": PluginHostAPIValues.position($0.anchor), "active": PluginHostAPIValues.position($0.active),
                    ]) }),
                ]))
            }
            let version = UInt64(try args.integer("expectedVersion"))
            let result: EditorDocumentEditResult
            switch method {
            case "applyEdits":
                let values = try args.array("edits")
                guard values.count <= 1_000 else { throw PluginWorkspaceFileError.limitExceeded(.directoryEntries) }
                let edits = try values.map { value -> EditorTextEdit in
                    guard case .object(let object) = value else { throw PluginHostArguments.invalid }
                    let edit = try PluginHostArguments(object, allowed: ["range", "text"])
                    return try EditorTextEdit(range: PluginHostArguments.range(edit.values["range"] ?? .null), text: edit.string("text"))
                }
                result = try await editor.applyEdits(scope: scope.editorScope, documentID: id, expectedVersion: version, edits: edits)
            case "insertText":
                result = try await editor.insertText(scope: scope.editorScope, documentID: id, expectedVersion: version,
                    at: PluginHostArguments.position(args.values["at"] ?? .null), text: args.string("text"))
            default:
                let values = try args.array("selections")
                guard values.count <= 1_000 else { throw PluginWorkspaceFileError.limitExceeded(.directoryEntries) }
                let selections = try values.map { value -> EditorSelection in
                    guard case .object(let object) = value else { throw PluginHostArguments.invalid }
                    let item = try PluginHostArguments(object, allowed: ["anchor", "active"])
                    return try EditorSelection(anchor: PluginHostArguments.position(item.values["anchor"] ?? .null),
                                               active: PluginHostArguments.position(item.values["active"] ?? .null))
                }
                let replacements = try args.array("replacements").map { value -> String in
                    guard case .string(let text) = value else { throw PluginHostArguments.invalid }; return text
                }
                result = try await editor.replaceSelections(scope: scope.editorScope,
                    selections: EditorSelectionsSnapshot(documentID: id, version: version, selections: selections, primaryIndex: nil),
                    replacements: replacements)
            }
            return .success(.object(["documentID": .string(id.uuidString), "version": .integer(Int(clamping: result.version)), "applied": .bool(result.applied)]))
        } catch { return .failure(PluginHostAPIValues.failure(error)) }
    }
}

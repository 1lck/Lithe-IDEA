import Foundation
import LitheCoreContracts

/// Public window actions use the same context resolver as file and document
/// access, and return document identity so opening and editing compose.
@MainActor
final class PluginWindowHostService: PluginHostServiceHandling {
    let service = "window"
    let methods = Set(["editor/open", "editor/reveal", "preview/openHTML", "browser/openExternal",
                       "window/showInformation", "window/showWarning", "window/showError"].map { "lithe/host/" + $0 })
    private let contexts: PluginWorkspaceContexts
    private let metadata: PluginWorkspaceHostService
    private let services: PluginHostWindowServices
    private let directory: PluginContextWindowDirectory

    init(contexts: PluginWorkspaceContexts, metadata: PluginWorkspaceHostService, fileStorage: any FileStorage, platformUI: any PlatformUI) {
        self.contexts = contexts; self.metadata = metadata
        directory = PluginContextWindowDirectory(contexts: contexts)
        services = PluginHostWindowServices(directory: directory, fileStorage: fileStorage, platformUI: platformUI)
    }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        do {
            let scope = try PluginHostAPIContext(call, contexts: contexts)
            let context = scope.windowScope(pluginID: call.pluginID)
            let method = String(call.request.method.split(separator: "/").last ?? "")
            let allowed: Set<String>
            switch method {
            case "open", "reveal": allowed = ["context", "resource", "activation", "range", "tab"]
            case "openHTML": allowed = ["context", "resource", "presentation", "range"]
            case "openExternal": allowed = ["context", "resource", "url", "unsaved"]
            default: allowed = ["context", "text", "actions"]
            }
            let args = try PluginHostArguments(call.params, allowed: allowed)
            if method.hasPrefix("show") {
                let actions = try (args.values["actions"] == nil ? [] : args.array("actions")).map { value -> String in
                    guard case .string(let title) = value else { throw PluginHostArguments.invalid }; return title
                }
                let severity: PluginHostMessageSeverity = method == "showError" ? .error : method == "showWarning" ? .warning : .information
                let outcome = try await services.messages.show(PluginHostMessageRequest(context: context, severity: severity,
                                                                                       text: args.string("text"), actions: actions))
                switch outcome {
                case .selected(let index): return .success(.object(["selectedIndex": .integer(index)]))
                case .dismissed: return .success(.object(["selectedIndex": .null]))
                }
            }
            if method == "openExternal", let url = try args.optionalString("url") {
                guard args.values["resource"] == nil else { throw PluginHostArguments.invalid }
                _ = try await services.browser.openExternal(PluginHostExternalOpenRequest(context: context, target: .webURL(url)))
                return .success(.object(["opened": .bool(true), "source": .string("web")]))
            }
            let raw = try PluginHostArguments(args.object("resource"), allowed: ["rootID", "path"])
            let root = try raw.string("rootID")
            guard scope.workspace.folders.contains(where: { metadata.rootID(of: $0, pluginID: call.pluginID) == root }) else { throw PluginHostError.unknownRoot }
            let resource = try PluginHostResource(rootID: PluginHostResource.workspaceRootID, relativePath: raw.string("path"))
            var range: PluginHostTextRange?
            if let value = args.values["range"] {
                let decoded = try PluginHostArguments.range(value)
                range = PluginHostTextRange(start: .init(line: decoded.start.line, column: decoded.start.column),
                                           end: .init(line: decoded.end.line, column: decoded.end.column))
            }
            if method == "openExternal" {
                let unsaved = try args.string("unsaved", default: "openSavedFile")
                guard ["openSavedFile", "requireSaved"].contains(unsaved) else { throw PluginHostError.unsupportedOption }
                let result = try await services.browser.openExternal(PluginHostExternalOpenRequest(context: context, target: .workspaceFile(resource),
                    unsaved: unsaved == "requireSaved" ? .requireSaved : .openSavedFile))
                let dirty: Bool = if case .savedFile(let value) = result.content { value } else { false }
                return .success(.object(["opened": .bool(true), "source": .string("disk"), "hasUnsavedChanges": .bool(dirty)]))
            }
            let result: PluginHostEditorOpenResult
            if method == "openHTML" {
                let mode = try args.string("presentation", default: "editorAndPreview")
                guard ["editorAndPreview", "previewOnly"].contains(mode) else { throw PluginHostError.unsupportedOption }
                let preview = try await services.preview.openHTML(PluginHostPreviewOpenRequest(context: context, resource: resource,
                    presentation: mode == "previewOnly" ? .previewOnly : .editorAndPreview, range: range))
                result = preview.editor
            } else {
                let activation = try args.string("activation", default: "select"), tab = try args.string("tab", default: "regular")
                guard ["select", "background"].contains(activation), tab == "regular" else { throw PluginHostError.unsupportedOption }
                let request = PluginHostEditorOpenRequest(context: context, resource: resource, range: range,
                    activation: activation == "background" ? .background : .select)
                result = try await method == "reveal" ? services.editor.reveal(request) : services.editor.open(request)
            }
            _ = try PluginHostAPIContext(call, contexts: contexts)
            var object: [String: ToolingJSONValue] = [
                "documentID": result.document.documentID.map { .string($0.uuidString) } ?? .null,
                "version": result.document.version.map { .integer(Int(clamping: $0)) } ?? .null,
                "isActive": .bool(result.document.isActive), "isReadOnly": .bool(result.document.isReadOnly),
                "hasUnsavedChanges": .bool(result.document.hasUnsavedChanges), "wasAlreadyOpen": .bool(result.wasAlreadyOpen),
                "windowIsForeground": .bool(result.windowIsForeground),
            ]
            if case .caret(let at) = result.appliedSelection {
                object["appliedSelection"] = .object(["kind": .string("caret"), "line": .integer(at.line), "column": .integer(at.column)])
            } else { object["appliedSelection"] = .null }
            if method == "openHTML" { object["usesLiveBuffer"] = .bool(true); object["presentation"] = .string(try args.string("presentation", default: "editorAndPreview")) }
            return .success(.object(object))
        } catch { return .failure(PluginHostAPIValues.failure(error)) }
    }
}

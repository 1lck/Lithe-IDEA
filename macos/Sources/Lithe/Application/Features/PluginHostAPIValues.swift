import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Strict decoding at the public host boundary. Unknown options are rejected
/// before any side effect; the SDK must not assume an ignored option took effect.
struct PluginHostArguments {
    let values: [String: ToolingJSONValue]

    init(_ values: [String: ToolingJSONValue], allowed: Set<String>) throws {
        if let option = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw PluginHostServiceError(.unsupportedOption, L10n.string("The host does not support the requested option yet."),
                                         details: ["option": .string(option)])
        }
        self.values = values
    }

    static var invalid: PluginHostServiceError {
        PluginHostServiceError(.invalidParams, L10n.string("The plugin host request parameters are invalid."))
    }

    func string(_ key: String, default fallback: String? = nil) throws -> String {
        guard let value = values[key] else {
            if let fallback { return fallback }
            throw Self.invalid
        }
        guard case .string(let text) = value else { throw Self.invalid }
        return text
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        return try string(key)
    }

    func integer(_ key: String, default fallback: Int? = nil) throws -> Int {
        guard let value = values[key] else {
            if let fallback { return fallback }
            throw Self.invalid
        }
        guard case .integer(let number) = value, number >= 0 else { throw Self.invalid }
        return number
    }

    func bool(_ key: String, default fallback: Bool = false) throws -> Bool {
        guard let value = values[key] else { return fallback }
        guard case .bool(let flag) = value else { throw Self.invalid }
        return flag
    }

    func object(_ key: String) throws -> [String: ToolingJSONValue] {
        guard case .object(let object)? = values[key] else { throw Self.invalid }
        return object
    }

    func array(_ key: String) throws -> [ToolingJSONValue] {
        guard case .array(let array)? = values[key] else { throw Self.invalid }
        return array
    }

    static func position(_ value: ToolingJSONValue) throws -> EditorTextPosition {
        guard case .object(let object) = value else { throw invalid }
        let args = try Self(object, allowed: ["line", "column"])
        let line = try args.integer("line"), column = try args.integer("column")
        guard line > 0, line <= 10_000_000, column > 0, column <= 1_000_000 else { throw invalid }
        return EditorTextPosition(line: line, column: column)
    }

    static func range(_ value: ToolingJSONValue) throws -> EditorTextRange {
        guard case .object(let object) = value else { throw invalid }
        let args = try Self(object, allowed: ["start", "end"])
        let start = try position(args.values["start"] ?? .null), end = try position(args.values["end"] ?? .null)
        guard start <= end else { throw invalid }
        return EditorTextRange(start: start, end: end)
    }
}

/// Converts internal errors once; neither OS paths nor arbitrary NSError text
/// crosses this boundary. Cancellation does not imply rollback of a committed edit.
enum PluginHostAPIValues {
    static func failure(_ error: Error) -> PluginHostServiceError {
        if let error = error as? PluginHostServiceError { return error }
        let code: PluginHostErrorCode
        var details: [String: ToolingJSONValue]?
        switch error {
        case is CancellationError: code = .cancelled
        case let error as EditorDocumentServiceError:
            switch error {
            case .contextMismatch: code = .contextExpired
            case .documentNotFound: code = .notFound
            case .readOnly: code = .readOnly
            case .versionConflict(let expected, let actual):
                code = .versionConflict
                details = ["expectedVersion": .integer(Int(clamping: expected)), "currentVersion": .integer(Int(clamping: actual))]
            case .compositionInProgress, .editorUnavailable: code = .busy
            default: code = .invalidParams
            }
        case let error as PluginWorkspaceFileError:
            switch error {
            case .unsupportedAuthority: code = .authorityUnsupported
            case .staleWorkspace: code = .contextExpired
            case .notFound: code = .notFound
            case .permissionDenied, .symbolicLinkNotFollowed: code = .permissionDenied
            case .limitExceeded: code = .limitExceeded
            case .cancelled: code = .cancelled
            case .searchUnavailable: code = .busy
            case .io: code = .failed
            default: code = .invalidParams
            }
        case let error as PluginHostError:
            switch error {
            case .windowUnavailable, .workspaceChanged: code = .contextExpired
            case .remoteWorkspaceUnsupported: code = .authorityUnsupported
            case .resourceNotFound, .documentNotOpen: code = .notFound
            case .outsideWorkspace, .unknownRoot: code = .permissionDenied
            case .unsupportedOption: code = .unsupportedOption
            case .unsavedChanges: code = .preconditionFailed
            case .rateLimited: code = .rateLimited
            case .messageQueueFull: code = .limitExceeded
            case .browserUnavailable, .openFailed: code = .failed
            default: code = .invalidParams
            }
        default: code = .failed
        }
        return PluginHostServiceError(code, L10n.string("The plugin host request could not be completed."), details: details)
    }

    static func position(_ position: EditorTextPosition) -> ToolingJSONValue {
        .object(["line": .integer(position.line), "column": .integer(position.column)])
    }

    static func summary(_ value: EditorDocumentSummary) -> ToolingJSONValue {
        .object([
            "documentID": .string(value.documentID.uuidString), "version": .integer(Int(clamping: value.version)),
            "path": value.workspaceRelativePath.map(ToolingJSONValue.string) ?? .null,
            "languageID": value.languageID.map(ToolingJSONValue.string) ?? .null,
            "isReadOnly": .bool(value.isReadOnly), "isDirty": .bool(value.isDirty),
            "encoding": .string(value.encoding.rawValue), "lineEnding": .string(value.lineEnding.rawValue),
        ])
    }
}

/// A resolved context plus its current window. All public services use this
/// resolver; legacy internal scope values are derived here, never supplied by a backend.
@MainActor
struct PluginHostAPIContext {
    let workspace: PluginWorkspaceContext
    let window: any PluginHostWindowPort
    let snapshot: PluginHostWindowSnapshot

    init(_ call: PluginHostCall, contexts: PluginWorkspaceContexts) throws {
        try Task.checkCancellation()
        guard let workspace = call.context else { throw PluginHostArguments.invalid }
        _ = try contexts.resolve(workspace.reference).get()
        guard workspace.authority == .local else {
            throw PluginHostServiceError(.authorityUnsupported, L10n.string("Remote workspaces are not supported by this operation yet."))
        }
        guard let window = contexts.owner(of: workspace) as? any PluginHostWindowPort,
              let snapshot = window.hostSnapshot, !snapshot.isRemoteWorkspace,
              snapshot.workspaceURL == workspace.folders.first?.localURL else {
            throw PluginHostServiceError(.contextExpired, L10n.string("The window is closed or has no workspace open."))
        }
        self.workspace = workspace
        self.window = window
        self.snapshot = snapshot
    }

    var editorScope: EditorDocumentScope { EditorDocumentScope(windowID: snapshot.windowID, workspaceURL: snapshot.workspaceURL) }

    func windowScope(pluginID: String) -> PluginHostCallContext {
        PluginHostCallContext(caller: PluginHostCaller(pluginID: pluginID, pluginName: pluginID),
                             windowID: snapshot.windowID, workspaceURL: snapshot.workspaceURL,
                             workspaceGeneration: snapshot.workspaceGeneration)
    }
}

import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Exposes only the files in a short-lived snapshot to its owning backend.
@MainActor
final class MacKeymapImportHostService: PluginHostServiceHandling {
    let service = "keymapImport"
    let methods: Set<String> = ["lithe/host/keymapImport/listInputs", "lithe/host/keymapImport/readChunk"]
    let snapshots = MacKeymapImportSnapshots()

    func endSession(pluginID: String, sessionID: String) {
        snapshots.endSession(pluginID: pluginID, sessionID: sessionID)
    }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        let invalid = PluginHostServiceError(.invalidParams, L10n.string("The plugin host request parameters are invalid."))
        guard case let .string(token) = call.params["snapshotID"],
              case let .string(providerID) = call.params["providerID"] else { return .failure(invalid) }
        let snapshot: MacKeymapImportSnapshot
        do { snapshot = try snapshots.snapshot(token, pluginID: call.pluginID, sessionID: call.sessionID, providerID: providerID) }
        // log-exempt: 预期的缺失：会话结束或快照撤销后迟到的读取返回过期
        catch { return .failure(PluginHostServiceError(.contextExpired, L10n.string("The plugin host request could not be completed."))) }

        switch call.request.method {
        case "lithe/host/keymapImport/listInputs":
            return .success(.object(["files": .array(snapshot.files.map { file in
                .object(["id": .string(file.id), "path": .string(file.path), "byteCount": .integer(file.byteCount)])
            })]))
        case "lithe/host/keymapImport/readChunk":
            guard case let .string(fileID) = call.params["fileID"],
                  case let .integer(offset) = call.params["offset"],
                  case let .integer(maximumBytes) = call.params["maximumBytes"] else { return .failure(invalid) }
            let task = Task.detached { try snapshot.read(fileID: fileID, offset: offset, maximumBytes: maximumBytes) }
            do {
                let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard try snapshots.snapshot(token, pluginID: call.pluginID, sessionID: call.sessionID, providerID: providerID) === snapshot else {
                    throw MacKeymapImportSnapshots.Failure.expired
                }
                return .success(.object(["data": .string(data.base64EncodedString())]))
            } catch {
                let code: PluginHostErrorCode
                switch error {
                case is CancellationError: code = .cancelled
                case MacKeymapImportSnapshots.Failure.expired, MacKeymapImportSnapshot.Failure.closed: code = .contextExpired
                case MacKeymapImportSnapshot.Failure.sourceChanged: code = .versionConflict
                case MacKeymapImportSnapshot.Failure.limitExceeded: code = .limitExceeded
                case MacKeymapImportSnapshot.Failure.unknownFile: code = .notFound
                case MacKeymapImportSnapshot.Failure.invalidRange: code = .invalidParams
                default: code = .failed
                }
                return .failure(PluginHostServiceError(code, L10n.string("The plugin host request could not be completed.")))
            }
        default:
            return .failure(PluginHostServiceError(.unavailable, L10n.string("The plugin host request could not be completed.")))
        }
    }
}

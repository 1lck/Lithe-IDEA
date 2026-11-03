import Foundation
import LitheCoreContracts

/// Adds a plugin-provided keymap to an already discovered settings source.
/// Detection is metadata-only; only an explicitly selected source starts a backend.
@MainActor
final class MacEditorKeymapImportService {
    typealias Provider = MacPluginBackendSessions.KeymapProvider
    typealias ImportResult = MacPluginBackendSessions.KeymapImportResult
    private let find: (URL) async throws -> [Provider]
    private let importProvider: (Provider, URL) async throws -> ImportResult
    private let operations: RustKeymapImportOperations

    init(find: @escaping (URL) async throws -> [Provider],
         importProvider: @escaping (Provider, URL) async throws -> ImportResult,
         operations: RustKeymapImportOperations) {
        self.find = find
        self.importProvider = importProvider
        self.operations = operations
    }

    func importing(_ source: EditorSettingsImportSource) async throws -> EditorSettingsImportSource {
        let candidates = try await find(source.directory)
        guard let provider = candidates.first else { return source }
        guard candidates.count == 1 else { throw EditorSettingsImportError.ambiguousShortcutProviders }
        let imported = try await importProvider(provider, source.directory)
        try Task.checkCancellation()
        guard case let .object(envelope) = imported.response,
              case let .object(response)? = envelope["response"],
              let reply = response["result"], response["error"] == nil else {
            throw EditorSettingsImportError.invalid
        }
        let operations = operations
        let commandIDs = LitheCommandCatalog.commands.map(\.id)
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let bindings = try operations.decodeImport(commandIDs: commandIDs, reply: reply)
            var commands: [String: [KeyboardShortcutBinding]] = [:]
            for binding in bindings {
                try Task.checkCancellation()
                commands[binding.commandID] = try binding.nativeBindings()
            }
            return commands
        }
        let commands = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        var result = source
        result.revision += "|\(provider.pluginID)|\(provider.id)|\(imported.sourceDigest)"
        if !commands.isEmpty {
            result.values["keymap"] = EditorImportKeymap(preset: "", commands: commands).encoded
            result.approximateFields.insert("keymap")
            if imported.sourceFileCount == 0 { result.defaultFields.insert("keymap") }
            let warning = "Reference shortcuts are merged with supported user overrides. Conditional rules, chords and removals suppress the affected mappings; extension keymaps are skipped."
            if !result.warnings.contains(warning) { result.warnings.append(warning) }
        }
        return result
    }
}

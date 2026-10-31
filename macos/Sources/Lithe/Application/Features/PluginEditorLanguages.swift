import Combine
import Foundation
import LitheCoreContracts

// Note: 插件语法高亮与运行标记的决策见 .agents/notes/implemented/architecture/2026-10-31-plugin-grammars-and-run-markers.md

/// A plugin backend's Run marker provider for one language (`runMarkers` 1).
struct PluginRunMarkerProvider: Equatable {
    let pluginID: String
    /// The normalized manifest Rust Core checks the provider's answers against.
    let manifest: Data
    let languageID: String
    let functionID: String
    let commandID: String
}

/// The Run marker a command was run from, sent to the backend as
/// `lithe/host/commands/didRun` `runMarker`.
struct PluginRunMarkerInvocation: Equatable {
    let id: String
    let languageID: String
    /// Workspace-relative, `/`-separated.
    let path: String
    /// 0-based, as the provider reported it.
    let line: Int
    /// The document version the marker was computed for.
    let version: Int

    var json: ToolingJSONValue {
        .object([
            "id": .string(id), "languageID": .string(languageID), "path": .string(path),
            "line": .integer(line), "version": .integer(version),
        ])
    }
}

/// What the editor gets from plugins right now: the languages with a
/// grammar Rust Core accepted, and the languages whose Run markers a plugin
/// backend provides.
struct PluginEditorLanguageSet: Equatable {
    /// `plugins.declarative.decodeGrammar` languages, for the editor's
    /// `setPluginLanguages`.
    var languages: [ToolingJSONValue] = []
    var runMarkerProviders: [String: PluginRunMarkerProvider] = [:]

    /// The editor's `setPluginLanguages` payload.
    var editorPayload: [String: Any] {
        let languages = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(languages))) ?? []
        return ["languages": languages, "runMarkerLanguages": runMarkerProviders.keys.sorted()]
    }
}

/// The plugin grammars and Run marker providers of the active plugins.
/// A grammar-only plugin applies without a restart, so the set follows the
/// live plugin registry and module enablement.
@MainActor
protocol PluginEditorLanguageProviding: AnyObject {
    /// Fires after `current()` may have changed.
    var changes: AnyPublisher<Void, Never> { get }
    func current() -> PluginEditorLanguageSet
    /// Rust Core's check of a provider's answer for a document of `lineCount` lines.
    func decodeRunMarkers(
        _ provider: PluginRunMarkerProvider, lineCount: Int, result: ToolingJSONValue
    ) throws -> [PluginRunMarker]
}

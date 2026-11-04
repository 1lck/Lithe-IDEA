import Foundation
import LitheCoreContracts

// Note: 编辑器 Provider 与语言服务器的合并取舍见 .agents/notes/implemented/architecture/2026-10-31-plugin-editor-extension-apis.md

/// Definition providers supplement the language server's answer; they never
/// replace it. Core owns the merge rule, this file only converts locations.
extension AppModel {
    /// Starts the matching plugin definition providers for the caret, or
    /// returns nil when no registration matches the file so the language
    /// server path runs exactly as it did before. The task never fails; a
    /// late, failed or malformed provider answer contributes no locations.
    func pluginDefinitionQuery(
        for document: EditorDocument, line: Int, utf16Column: Int
    ) -> Task<[LanguageServerLocation], Never>? {
        guard let service = services.pluginEditorProviders, let backends = pluginWebBackends,
              let context = pluginWebWorkspaceContext,
              services.pluginWorkspaceContexts?.contexts.contains(where: {
                  $0.reference == context && $0.authority == .local
              }) == true,
              document.text.utf8.count <= PluginEditorProviderHostService.snapshotLimitBytes else { return nil }
        // The editor frontend names the language itself for its own requests;
        // this path knows only the language provider that owns the file.
        let language = languageProviderCatalog.provider(for: document.url)?.id ?? ""
        let filename = document.url.lastPathComponent
        guard !service.registrations(context: context, filename: filename, language: language, type: "definition").isEmpty
        else { return nil }
        let version = document.contentVersion
        let item = PluginEditorProviderDocument(
            documentID: document.id.uuidString, version: version, filename: filename, language: language)
        return Task { @MainActor [weak self, weak document] in
            let answers = await service.query(
                type: "definition", document: item, context: context, position: (line, utf16Column),
                triggerCharacter: nil, backends: backends,
                isCurrent: { [weak self, weak document] in
                    guard let self, let document else { return false }
                    return document.contentVersion == version
                        && self.documentFeature.editorDocuments.contains { $0 === document }
                })
            return answers.flatMap { Self.pluginLocations(in: $0.result).compactMap(Self.languageServerLocation) }
        }
    }

    /// The language server's locations first, then the plugin locations it
    /// did not already give. A server location that is the requested place
    /// itself yields when a plugin answered. Core validates and decides; when
    /// it refuses a list the language server's answer stands alone.
    func mergePluginDefinitions(
        server: [LanguageServerLocation], plugin: [LanguageServerLocation],
        documentURL: URL, line: Int, utf16Column: Int
    ) -> [LanguageServerLocation] {
        guard !plugin.isEmpty, let service = services.pluginEditorProviders else { return server }
        do {
            let kept = try service.mergeDefinitions(
                documentURL: documentURL, line: line, character: utf16Column,
                server: server.map(Self.locationValue), plugin: plugin.map(Self.locationValue))
            return kept.server.compactMap { server.indices.contains($0) ? server[$0] : nil }
                + kept.plugin.compactMap { plugin.indices.contains($0) ? plugin[$0] : nil }
        } catch {
            showNotification("The plugin host request could not be completed.", logReference: nil)
            return server
        }
    }

    /// Presents locations a clicked editor action asked the host to reveal.
    func revealPluginLocations(_ reveal: PluginEditorReveal) {
        let locations = reveal.locations.compactMap(Self.languageServerLocation)
        guard !locations.isEmpty else { return }
        presentGenericNavigationValues(locations, kind: .definitions, navigateToSingleResult: true, providerID: nil)
    }

    /// Opens a clicked document link a plugin provided: a file inside the
    /// workspace in the editor, a web address in the default browser. Other
    /// targets were already dropped; a file outside the workspace is ignored.
    func openPluginDocumentLink(_ url: URL) {
        guard url.isFileURL else { platformUI.open(url); return }
        guard let root = workspaceURL?.standardizedFileURL.resolvingSymlinksInPath() else { return }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { return }
        openFile(file)
    }

    private static func pluginLocations(in result: ToolingJSONValue) -> [PluginEditorReveal.Location] {
        struct Response: Decodable { let locations: [PluginEditorReveal.Location] }
        do {
            return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(result)).locations
        } catch {
            // log-exempt: Core 已校验形状；解码失败只表示这一个 Provider 没有可补充的位置
            return []
        }
    }

    /// Plugin locations are file locations only; any other scheme is dropped.
    private static func languageServerLocation(_ location: PluginEditorReveal.Location) -> LanguageServerLocation? {
        guard let url = URL(string: location.uri), url.isFileURL else { return nil }
        func position(_ value: PluginEditorReveal.Position) -> LanguageServerPosition {
            LanguageServerPosition(line: value.line, utf16Column: value.character)
        }
        return LanguageServerLocation(
            url: url.standardizedFileURL,
            range: LanguageServerRange(start: position(location.range.start), end: position(location.range.end)))
    }

    private static func locationValue(_ location: LanguageServerLocation) -> ToolingJSONValue {
        func position(_ value: LanguageServerPosition) -> ToolingJSONValue {
            .object(["line": .integer(value.line), "character": .integer(value.utf16Column)])
        }
        return .object([
            "uri": .string(location.url.standardizedFileURL.absoluteString),
            "range": .object(["start": position(location.range.start), "end": position(location.range.end)]),
        ])
    }
}

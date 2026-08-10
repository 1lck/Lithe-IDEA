import Foundation

enum LanguageServerResponseParser {
    static func requiredFeature(forRequestMethod method: String) -> LanguageServerFeatureSet {
        switch method {
        case "textDocument/definition": .definition
        case "textDocument/references": .references
        case "textDocument/implementation": .implementation
        case "textDocument/hover": .hover
        case "textDocument/completion": .completion
        case "completionItem/resolve": .completionResolve
        case "textDocument/rename": .rename
        case "textDocument/formatting": .formatting
        case "textDocument/codeAction": .codeActions
        case "codeAction/resolve": .codeActionResolve
        case "workspace/executeCommand": .executeCommand
        default: []
        }
    }

    static func registeredFeatures(
        for method: String,
        registerOptions: Any? = nil
    ) -> LanguageServerFeatureSet {
        let options = registerOptions as? [String: Any]
        switch method {
        case "textDocument/definition":
            return .definition
        case "textDocument/references":
            return .references
        case "textDocument/implementation":
            return .implementation
        case "textDocument/hover":
            return .hover
        case "textDocument/completion":
            var features: LanguageServerFeatureSet = .completion
            if options?["resolveProvider"] as? Bool == true {
                features.insert(.completionResolve)
            }
            return features
        case "textDocument/rename":
            return .rename
        case "textDocument/formatting":
            return .formatting
        case "textDocument/codeAction":
            var features: LanguageServerFeatureSet = .codeActions
            if options?["resolveProvider"] as? Bool == true {
                features.insert(.codeActionResolve)
            }
            return features
        case "workspace/executeCommand":
            return .executeCommand
        default:
            return []
        }
    }

    static func serverFeatures(fromInitializeResult value: Any) -> LanguageServerFeatureSet {
        guard let result = value as? [String: Any],
              let capabilities = result["capabilities"] as? [String: Any] else { return [] }
        var features: LanguageServerFeatureSet = []
        func supports(_ key: String) -> Bool {
            if let value = capabilities[key] as? Bool { return value }
            return capabilities[key] is [String: Any]
        }
        if supports("definitionProvider") { features.insert(.definition) }
        if supports("referencesProvider") { features.insert(.references) }
        if supports("implementationProvider") { features.insert(.implementation) }
        if supports("hoverProvider") { features.insert(.hover) }
        if supports("completionProvider") {
            features.insert(.completion)
            if (capabilities["completionProvider"] as? [String: Any])?["resolveProvider"] as? Bool == true {
                features.insert(.completionResolve)
            }
        }
        if supports("renameProvider") { features.insert(.rename) }
        if supports("documentFormattingProvider") { features.insert(.formatting) }
        if supports("codeActionProvider") {
            features.insert(.codeActions)
            if (capabilities["codeActionProvider"] as? [String: Any])?["resolveProvider"] as? Bool == true {
                features.insert(.codeActionResolve)
            }
        }
        if supports("executeCommandProvider") { features.insert(.executeCommand) }
        return features
    }

    static func locations(_ value: Any) -> [LanguageServerLocation] {
        let values = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
        return values.compactMap { value in
            let uri = (value["uri"] as? String) ?? (value["targetUri"] as? String)
            let rawRange = (value["range"] as? [String: Any])
                ?? (value["targetSelectionRange"] as? [String: Any])
                ?? (value["targetRange"] as? [String: Any])
            guard let uri, let url = URL(string: uri), let rawRange,
                  let range = range(rawRange) else { return nil }
            return LanguageServerLocation(url: url.standardizedFileURL, range: range)
        }
    }

    static func hover(_ value: Any) -> LanguageServerHover? {
        guard !(value is NSNull), let object = value as? [String: Any] else { return nil }
        let parsed = markup(object["contents"])
        guard !parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LanguageServerHover(
            contents: parsed.text,
            isMarkdown: parsed.markdown,
            range: (object["range"] as? [String: Any]).flatMap(range)
        )
    }

    static func completionItems(_ value: Any) -> [LanguageServerCompletionItem] {
        let values = (value as? [[String: Any]])
            ?? ((value as? [String: Any])?["items"] as? [[String: Any]])
            ?? []
        return values.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let rawTextEdit = item["textEdit"] as? [String: Any]
            let textEdit = rawTextEdit.flatMap(textEdit)
            let documentation = markup(item["documentation"])
            return LanguageServerCompletionItem(
                label: label,
                detail: item["detail"] as? String,
                documentation: documentation.text.isEmpty ? nil : documentation.text,
                insertText: (rawTextEdit?["newText"] as? String) ?? (item["insertText"] as? String) ?? label,
                sortText: item["sortText"] as? String,
                filterText: item["filterText"] as? String,
                kind: item["kind"] as? Int,
                textEdit: textEdit,
                additionalTextEdits: textEdits(item["additionalTextEdits"] as Any),
                data: item["data"].flatMap(ToolingJSONValue.fromFoundation)
            )
        }.sorted {
            ($0.sortText ?? $0.label).localizedStandardCompare($1.sortText ?? $1.label) == .orderedAscending
        }
    }

    static func textEdits(_ value: Any) -> [LanguageServerTextEdit] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard let rawRange = value["range"] as? [String: Any],
                  let range = range(rawRange),
                  let newText = value["newText"] as? String else { return nil }
            return LanguageServerTextEdit(range: range, newText: newText)
        }
    }

    static func workspaceEdit(_ value: Any) -> LanguageServerWorkspaceEdit {
        guard let object = value as? [String: Any] else { return LanguageServerWorkspaceEdit() }
        var changes: [URL: [LanguageServerTextEdit]] = [:]
        if let rawChanges = object["changes"] as? [String: Any] {
            for (uri, rawEdits) in rawChanges {
                guard let url = URL(string: uri) else { continue }
                changes[url.standardizedFileURL] = textEdits(rawEdits)
            }
        }
        if let documentChanges = object["documentChanges"] as? [[String: Any]] {
            for change in documentChanges {
                guard let document = change["textDocument"] as? [String: Any],
                      let uri = document["uri"] as? String,
                      let url = URL(string: uri) else { continue }
                changes[url.standardizedFileURL, default: []].append(contentsOf: textEdits(change["edits"] as Any))
            }
        }
        return LanguageServerWorkspaceEdit(changes: changes)
    }

    static func codeActions(_ value: Any) -> [LanguageServerCodeAction] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { raw in
            guard let action = raw as? [String: Any], let title = action["title"] as? String else { return nil }
            return LanguageServerCodeAction(
                title: title,
                kind: action["kind"] as? String,
                isPreferred: action["isPreferred"] as? Bool ?? false,
                edit: action["edit"].map(workspaceEdit),
                command: command(action["command"]) ?? command(action),
                data: action["data"].flatMap(ToolingJSONValue.fromFoundation)
            )
        }.sorted {
            if $0.isPreferred != $1.isPreferred { return $0.isPreferred }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func range(_ value: [String: Any]) -> LanguageServerRange? {
        guard let start = value["start"] as? [String: Any],
              let end = value["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startColumn = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endColumn = end["character"] as? Int else { return nil }
        return LanguageServerRange(
            start: LanguageServerPosition(line: startLine, utf16Column: startColumn),
            end: LanguageServerPosition(line: endLine, utf16Column: endColumn)
        )
    }

    static func completionItem(_ value: Any) -> LanguageServerCompletionItem? {
        completionItems([value]).first
    }

    static func codeAction(_ value: Any) -> LanguageServerCodeAction? {
        codeActions([value]).first
    }

    static func foundationCompletionItem(_ item: LanguageServerCompletionItem) -> [String: Any] {
        var value: [String: Any] = ["label": item.label, "insertText": item.insertText]
        if let detail = item.detail { value["detail"] = detail }
        if let documentation = item.documentation {
            value["documentation"] = ["kind": "markdown", "value": documentation]
        }
        if let sortText = item.sortText { value["sortText"] = sortText }
        if let filterText = item.filterText { value["filterText"] = filterText }
        if let kind = item.kind { value["kind"] = kind }
        if let textEdit = item.textEdit { value["textEdit"] = foundationTextEdit(textEdit) }
        if !item.additionalTextEdits.isEmpty {
            value["additionalTextEdits"] = item.additionalTextEdits.map(foundationTextEdit)
        }
        if let data = item.data { value["data"] = data.foundationObject }
        return value
    }

    static func foundationCodeAction(_ action: LanguageServerCodeAction) -> [String: Any] {
        var value: [String: Any] = ["title": action.title, "isPreferred": action.isPreferred]
        if let kind = action.kind { value["kind"] = kind }
        if let edit = action.edit { value["edit"] = foundationWorkspaceEdit(edit) }
        if let command = action.command { value["command"] = foundationCommand(command) }
        if let data = action.data { value["data"] = data.foundationObject }
        return value
    }

    private static func textEdit(_ value: [String: Any]) -> LanguageServerTextEdit? {
        guard let rawRange = value["range"] as? [String: Any],
              let range = range(rawRange),
              let newText = value["newText"] as? String else { return nil }
        return LanguageServerTextEdit(range: range, newText: newText)
    }

    private static func command(_ value: Any?) -> LanguageServerCommand? {
        guard let object = value as? [String: Any],
              let title = object["title"] as? String,
              let identifier = object["command"] as? String else { return nil }
        return LanguageServerCommand(
            title: title,
            command: identifier,
            arguments: (object["arguments"] as? [Any] ?? []).compactMap(ToolingJSONValue.fromFoundation)
        )
    }

    private static func foundationRange(_ range: LanguageServerRange) -> [String: Any] {
        [
            "start": ["line": range.start.line, "character": range.start.utf16Column],
            "end": ["line": range.end.line, "character": range.end.utf16Column]
        ]
    }

    private static func foundationTextEdit(_ edit: LanguageServerTextEdit) -> [String: Any] {
        ["range": foundationRange(edit.range), "newText": edit.newText]
    }

    private static func foundationWorkspaceEdit(_ edit: LanguageServerWorkspaceEdit) -> [String: Any] {
        ["changes": Dictionary(uniqueKeysWithValues: edit.changes.map {
            ($0.key.absoluteString, $0.value.map(foundationTextEdit))
        })]
    }

    private static func foundationCommand(_ command: LanguageServerCommand) -> [String: Any] {
        [
            "title": command.title,
            "command": command.command,
            "arguments": command.arguments.map(\.foundationObject)
        ]
    }

    private static func markup(_ value: Any?) -> (text: String, markdown: Bool) {
        if let text = value as? String { return (text, false) }
        if let object = value as? [String: Any], let text = object["value"] as? String {
            return (text, object["kind"] as? String == "markdown" || object["language"] != nil)
        }
        if let values = value as? [Any] {
            let parsed = values.map(markup).filter { !$0.text.isEmpty }
            return (parsed.map(\.text).joined(separator: "\n\n"), parsed.contains(where: \.markdown))
        }
        return ("", false)
    }
}

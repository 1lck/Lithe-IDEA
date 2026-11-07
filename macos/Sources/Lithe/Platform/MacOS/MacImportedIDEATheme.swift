import Foundation

/// Resolve only named schemes from the reader's bounded, read-only file snapshot.
enum MacImportedIDEATheme {
    static func resolve(_ active: ImportXML, documents: [String: ImportXML]) throws -> ImportedEditorTheme? {
        let bases: [String: Bool] = ["Default": false, "IntelliJ Light": false, "Islands Light": false,
                                    "Darcula": true, "Dark": true, "Islands Dark": true]
        var visited: Set<String> = []
        var colors: [String: String] = [:], attributes: [String: [String: String]] = [:], links: [String: String] = [:]
        func inherit(_ scheme: ImportXML) throws -> Bool? {
            guard let name = scheme.schemeName, visited.insert(name).inserted, visited.count <= 64,
                  scheme.schemeVersion.map({ (0...142).contains($0) }) == true else { throw EditorSettingsImportError.invalid }
            let parent = scheme.schemeParent ?? "Default"
            let matches = documents.filter { $0.key.hasPrefix("colors/") && $0.value.schemeName == parent }.map(\.value)
            guard matches.count <= 1 else { throw EditorSettingsImportError.invalid }
            let dark: Bool?
            if scheme.schemeParent == nil, parent == name, let base = bases[name] { dark = base }
            else if let ancestor = matches.first { dark = try inherit(ancestor) }
            else { dark = bases[parent] }
            guard let dark else { return nil }
            colors.merge(scheme.themeColors) { _, child in child }
            for (key, value) in scheme.attributes {
                // TextAttributes is an override as a whole, not a per-property merge with the parent.
                attributes[key] = value
                links[key] = scheme.attributeBases[key]
            }
            return dark
        }
        guard let dark = try inherit(active) else { return nil }
        func style(_ key: String, seen: Set<String> = []) throws -> [String: String] {
            guard !seen.contains(key), seen.count < 128 else { throw EditorSettingsImportError.invalid }
            if let base = links[key] { return try style(base, seen: seen.union([key])) }
            return attributes[key] ?? [:]
        }
        func color(_ value: String?) throws -> String? {
            guard let value else { return nil }
            guard value.count <= 6, !value.isEmpty, value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw EditorSettingsImportError.invalid }
            return "#" + String(repeating: "0", count: 6 - value.count) + value.uppercased()
        }
        var result = ImportedEditorTheme(name: active.schemeName ?? "", dark: dark, colors: [:], tokens: [:])
        let surfaces = ["CARET_COLOR": "cursor", "SELECTION_BACKGROUND": "selection", "CARET_ROW_COLOR": "lineHighlight",
                        "LINE_NUMBERS_COLOR": "lineNumber", "LINE_NUMBER_ON_CARET_ROW_COLOR": "activeLineNumber",
                        "INDENT_GUIDE": "guide", "SELECTED_INDENT_GUIDE": "activeGuide"]
        for (key, role) in surfaces { if let value = try color(colors[key]) { result.colors[role] = value } }
        let text = try style("TEXT")
        result.colors["background"] = try color(text["BACKGROUND"])
        result.colors["foreground"] = try color(text["FOREGROUND"])
        // General roles first, language-specific overrides last. Unsupported effects are disclosed.
        let roles: [(String, [String])] = [
            ("DEFAULT_LINE_COMMENT", ["comment.line"]), ("DEFAULT_BLOCK_COMMENT", ["comment.block"]),
            ("DEFAULT_DOC_COMMENT", ["documentationComment", "comment.documentation"]),
            ("DEFAULT_KEYWORD", ["keyword"]), ("DEFAULT_STRING", ["string"]), ("DEFAULT_NUMBER", ["number"]),
            ("DEFAULT_OPERATION_SIGN", ["operator"]), ("DEFAULT_IDENTIFIER", ["variable", "identifier"]),
            ("DEFAULT_CLASS_NAME", ["type", "class"]), ("DEFAULT_INSTANCE_FIELD", ["field", "property"]),
            ("DEFAULT_PARAMETER", ["parameter"]), ("DEFAULT_FUNCTION_DECLARATION", ["functionDeclaration"]),
            ("DEFAULT_FUNCTION_CALL", ["functionCall"]),
            ("METHOD_DECLARATION_ATTRIBUTES", ["method.declaration", "functionDeclaration"]),
            ("METHOD_CALL_ATTRIBUTES", ["method", "functionCall"]), ("STATIC_METHOD_ATTRIBUTES", ["method.static", "method.declaration.static"]),
            ("INSTANCE_FIELD_ATTRIBUTES", ["field", "property"]), ("STATIC_FIELD_ATTRIBUTES", ["property.static"]),
        ]
        for (key, tokens) in roles where attributes[key] != nil || links[key] != nil {
            let options = try style(key)
            if links[key] != nil && options.isEmpty { continue }
            let font: String?
            switch options["FONT_TYPE"] ?? "0" {
            case "0": font = ""
            case "1": font = "bold"
            case "2": font = "italic"
            case "3": font = "bold italic"
            default: font = nil
            }
            for token in tokens { result.tokens[token] = .init(foreground: try color(options["FOREGROUND"]), fontStyle: font) }
        }
        guard !result.tokens.isEmpty || !result.colors.isEmpty else { return nil }
        guard ImportedEditorTheme.decode(result.encoded) != nil else { throw EditorSettingsImportError.invalid }
        return result
    }
}

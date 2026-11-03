import LitheModuleAPI
import Foundation
import CryptoKit
import CoreFoundation

/// Read-only, bounded configuration discovery. No launch, network, recursive home scan or source writes.
enum MacEditorSettingsImportReader {
    static func scan(directory: URL?, logSink: (any LogSink)? = nil) async throws -> [EditorSettingsImportSource] {
        let fonts = await MainActor.run { Set(MacEditorFontCatalog.editorFamilies()) }
        return try await Task.detached(priority: .userInitiated) {
            try scan(home: FileManager.default.homeDirectoryForCurrentUser, directory: directory, fonts: fonts, logSink: logSink)
        }.value
    }

    static func scan(home: URL, directory: URL? = nil, fonts: Set<String>, logSink: (any LogSink)? = nil) throws -> [EditorSettingsImportSource] {
        let fm = FileManager.default
        let support = home.appendingPathComponent("Library/Application Support")
        let products = [("Code", "VS Code"), ("Code - Insiders", "VS Code Insiders"), ("Cursor", "Cursor")]
        var roots: [(URL, String)] = []
        func children(_ url: URL) throws -> [URL] {
            guard fm.fileExists(atPath: url.path) else { return [] }
            let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let directories = try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            guard directories.count <= 256 else { throw EditorSettingsImportError.read }
            return directories.sorted { $0.path < $1.path }
        }
        if let directory { roots = [(directory, directory.lastPathComponent)] }
        else {
            for (product, title) in products {
                let user = support.appendingPathComponent("\(product)/User")
                roots.append((user, title))
                for profile in try children(user.appendingPathComponent("profiles")) {
                    roots.append((profile, "\(title) · \(profile.lastPathComponent)"))
                }
            }
            for base in [support.appendingPathComponent("JetBrains"), home.appendingPathComponent("Library/Preferences")] {
                for root in try children(base) where root.lastPathComponent.hasPrefix("IntelliJIdea") || root.lastPathComponent.hasPrefix("IdeaIC") {
                    roots.append((root, root.lastPathComponent))
                }
            }
        }
        guard roots.count <= 128 else { throw EditorSettingsImportError.read }
        var result: [EditorSettingsImportSource] = []
        for (root, discoveredTitle) in roots {
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let product = products.first { product, _ in
                let user = support.appendingPathComponent("\(product)/User").standardizedFileURL
                return root.standardizedFileURL.path == user.path
                    || root.deletingLastPathComponent().standardizedFileURL.path == user.appendingPathComponent("profiles").path
            }
            let title = product.map { root.lastPathComponent == "User" ? $0.1 : "\($0.1) · \(root.lastPathComponent)" } ?? discoveredTitle
            let vscode = product != nil || fm.fileExists(atPath: root.appendingPathComponent("settings.json").path) || fm.fileExists(atPath: root.appendingPathComponent("keybindings.json").path)
            let idea = fm.fileExists(atPath: root.appendingPathComponent("options").path)
            guard vscode || idea else { continue }
            var source = EditorSettingsImportSource(directory: root, title: title, revision: "", values: [:], warnings: [], isVSCode: vscode)
            do { source = try read(root: root, title: title, vscode: vscode, fonts: fonts, logSink: logSink) }
            // log-exempt: 用户取消：退出后不再读取或报告该来源
            catch is CancellationError { throw CancellationError() }
            catch {
                logSink?.emit(EditorSettingsImportFailed(error: EditorSettingsImportError.logFailure(error), stage: "source-read"))
                source.readFailed = true
            }
            source.isCursor = product?.0 == "Cursor"
            if source.isCursor || root.deletingLastPathComponent().lastPathComponent == "profiles" {
                source.approximateFields.formUnion(source.defaultFields)
            }
            result.append(source)
        }
        return result
    }

    private static func read(root: URL, title: String, vscode: Bool, fonts: Set<String>, logSink: (any LogSink)?) throws -> EditorSettingsImportSource {
        let fm = FileManager.default
        var files: [String: Data] = [:]
        var names = vscode ? ["settings.json"] : ["options/editor.xml", "options/editor-font.xml", "options/colors.scheme.xml", "options/laf.xml", "options/code.style.schemes.xml"]
        if !vscode {
            let colors = root.appendingPathComponent("colors")
            if fm.fileExists(atPath: colors.path) {
                guard colors.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw EditorSettingsImportError.read }
                let schemes = try fm.contentsOfDirectory(at: colors, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension == "icls" }
                guard schemes.count <= 64 else { throw EditorSettingsImportError.read }
                names += schemes.map { "colors/" + $0.lastPathComponent }.sorted()
            }
        }
        if !vscode {
            for folder in ["codestyles"] {
                let directory = root.appendingPathComponent(folder)
                if fm.fileExists(atPath: directory.path) {
                    guard directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw EditorSettingsImportError.read }
                    let candidates = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension == "xml" }
                    guard candidates.count <= 64 else { throw EditorSettingsImportError.read }
                    names += candidates.map { folder + "/" + $0.lastPathComponent }.sorted()
                }
            }
        }
        var totalBytes = 0
        for name in names {
            let url = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw EditorSettingsImportError.read }
            // FileHandle's bounded read also covers a file growing after the metadata check.
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw EditorSettingsImportError.read }
            let handle = try FileHandle(forReadingFrom: url)
            defer { do { try handle.close() } catch { logSink?.emit(AppStorageMaintenanceFailed(error: error, stage: "file-close")) } }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw EditorSettingsImportError.read }
            totalBytes += data.count
            guard totalBytes <= 8_388_608 else { throw EditorSettingsImportError.read }
            files[name] = data
        }
        var digest = SHA256()
        for name in names { digest.update(data: Data(name.utf8)); digest.update(data: files[name] ?? Data()) }
        // ponytail: parse at most 8 MiB twice to distinguish explicit values from reference defaults.
        // Carry provenance during parsing only if additional formats make this bounded cost material.
        let parsed = try vscode ? parseVSCode(files["settings.json"] ?? Data("{}".utf8), fonts: fonts) : parseIDEA(files, fonts: fonts)
        var resolved = try vscode
            ? parseVSCode(files["settings.json"] ?? Data("{}".utf8), fonts: fonts, includeAppearanceDefaults: true)
            : parseIDEA(files, fonts: fonts, includeAppearanceDefaults: true)
        if resolved.0["colorScheme"] != nil, resolved.0["customTheme"] == nil { resolved.0["customTheme"] = "" }
        var defaults = Set(resolved.0.keys).subtracting(parsed.0.keys)
        // Pixel height is explicit even when its conversion depends on the reference font size.
        if vscode, resolved.2 != nil { defaults.remove("lineHeight") }
        var approximate: Set<String> = resolved.0["colorScheme"] == nil ? [] : ["colorScheme"]
        if !vscode { approximate.formUnion(defaults); if resolved.0["lineHeight"] != nil { approximate.insert("lineHeight") } }
        return EditorSettingsImportSource(directory: root, title: title,
            revision: digest.finalize().map { String(format: "%02x", $0) }.joined(), values: resolved.0, warnings: resolved.1, lineHeightFontSize: resolved.2, isVSCode: vscode, settingsFileMissing: vscode && files["settings.json"] == nil, defaultFields: defaults, approximateFields: approximate)
    }

    static func parseVSCode(_ data: Data, fonts: Set<String>, includeAppearanceDefaults: Bool = false) throws -> ([String: String], [String], String?) {
        guard data.count <= 1_048_576,
              var json = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            throw EditorSettingsImportError.invalid
        }
        if includeAppearanceDefaults {
            // VS Code desktop/macOS reference defaults; metadata marks compatible products/profiles as approximate.
            let defaults: [String: Any] = ["editor.fontFamily": "Menlo, Monaco, 'Courier New', monospace",
                "editor.fontSize": 12, "editor.lineHeight": 1.5, "editor.fontLigatures": false,
                "workbench.colorTheme": "Dark 2026",
                "editor.tabSize": 4, "editor.insertSpaces": true, "editor.detectIndentation": true,
                "editor.lineNumbers": "on", "editor.renderWhitespace": "selection",
                "editor.guides.indentation": true, "editor.wordWrap": "off",
                "editor.minimap.enabled": true, "editor.stickyScroll.enabled": true,
                "editor.cursorStyle": "line", "editor.cursorBlinking": "blink",
                "editor.smoothScrolling": false, "editor.scrollBeyondLastLine": true,
                "editor.renderLineHighlight": "line"]
            for (key, value) in defaults where json[key] == nil { json[key] = value }
        }
        var values: [String: String] = [:], warnings: [String] = []
        var lineHeightFontSize: String?
        func put(_ field: EditorSettingsImportField, _ value: String?) {
            guard let value else { return }
            if field.accepts(value) { values[field.rawValue] = value }
            else { warnings.append("Some settings have unsupported values and were skipped.") }
        }
        func number(_ key: String) -> Double? {
            guard let value = json[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        if let size = number("editor.tabSize"), size.rounded() == size, (1...16).contains(size) {
            if json["editor.indentSize"] == nil || (json["editor.indentSize"] as? String) == "tabSize" || number("editor.indentSize") == size {
                put(.tabSize, String(Int(size)))
            } else { warnings.append("Some settings have unsupported values and were skipped.") }
        } else if json["editor.tabSize"] != nil { warnings.append("Some settings have unsupported values and were skipped.") }
        for (key, field) in [
            "editor.insertSpaces": EditorSettingsImportField.insertSpaces, "editor.detectIndentation": .detectIndentation,
            "editor.fontLigatures": .fontLigatures, "editor.guides.indentation": .indentGuides,
            "editor.minimap.enabled": .minimap, "editor.stickyScroll.enabled": .stickyScroll,
            "editor.smoothScrolling": .smoothScrolling, "editor.scrollBeyondLastLine": .scrollBeyondLastLine,
        ] {
            if let value = json[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { put(field, value.boolValue ? "true" : "false") }
            else if json[key] != nil { warnings.append("Some settings have unsupported values and were skipped.") }
        }
        for (key, field) in ["editor.lineNumbers": EditorSettingsImportField.lineNumbers, "editor.renderWhitespace": .whitespace,
                             "editor.cursorStyle": .cursorStyle, "editor.cursorBlinking": .cursorBlinking] {
            put(field, json[key] as? String)
        }
        for key in ["editor.fontSize", "editor.lineHeight"] where json[key] != nil && number(key) == nil {
            warnings.append("Some settings have unsupported values and were skipped.")
        }
        if let size = number("editor.fontSize") { put(.fontSize, String(size)) }
        if let height = number("editor.lineHeight") {
            if height == 0 { put(.lineHeight, "0.0") }
            else if height < 8 { put(.lineHeight, String(height)) }
            else if let size = number("editor.fontSize"), size > 0, values["fontSize"] != nil {
                put(.lineHeight, String(height / size))
                if values["lineHeight"] != nil { lineHeightFontSize = values["fontSize"] }
            } else { warnings.append("Pixel line height needs an explicit supported font size; line height was skipped.") }
        }
        if let font = json["editor.fontFamily"] as? String {
            let choices = font.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            if let selected = choices.first(where: { fonts.contains($0) }) {
                put(.fontFamily, selected)
                if choices.count > 1 { warnings.append("Only one installed font family is imported; fallback lists and font weights are not supported.") }
            } else { warnings.append("The requested font is not installed; the current Lithe font is preserved.") }
        }
        if let wrap = json["editor.wordWrap"] as? String {
            if ["on", "off"].contains(wrap) { put(.softWrap, wrap == "on" ? "true" : "false") }
            else { warnings.append("Column-based wrapping is not supported and was skipped.") }
        }
        if let highlight = json["editor.renderLineHighlight"] as? String {
            if ["line", "none"].contains(highlight) { put(.highlightCurrentLine, highlight == "line" ? "true" : "false") }
            else { warnings.append("Some settings have unsupported values and were skipped.") }
        }
        let knownThemes = ["Default Dark Modern", "Default Light Modern", "Dark 2026", "Light 2026", "Default Dark+", "Default Light+"]
        let detect = json["window.autoDetectColorScheme"] as? NSNumber
        if json["window.autoDetectColorScheme"] != nil && (detect == nil || CFGetTypeID(detect!) != CFBooleanGetTypeID()) {
            warnings.append("Some settings have unsupported values and were skipped.")
        } else if detect?.boolValue == true {
            put(.themePreference, "system")
            let dark = json["workbench.preferredDarkColorTheme"] as? String ?? (json["workbench.preferredDarkColorTheme"] == nil && includeAppearanceDefaults ? "Dark 2026" : "")
            let light = json["workbench.preferredLightColorTheme"] as? String ?? (json["workbench.preferredLightColorTheme"] == nil && includeAppearanceDefaults ? "Light 2026" : "")
            if knownThemes.contains(dark), knownThemes.contains(light) { put(.colorScheme, "vscode") }
            else { warnings.append("Custom themes are not supported; the current Lithe palette is preserved.") }
        } else if let theme = json["workbench.colorTheme"] as? String {
            if knownThemes.contains(theme) {
                put(.themePreference, theme.contains("Light") ? "light" : "dark")
                put(.colorScheme, "vscode")
            } else { warnings.append("Custom themes are not supported; the current Lithe palette is preserved.") }
        }
        if values["colorScheme"] != nil {
            warnings.append("The bundled palette is an approximation; custom theme colors are not imported.")
        }
        // Reuse the validated editor overlay; settings.json is already revision-checked.
        // ponytail: exact common scopes only; compound selectors and extension themes need a scope resolver.
        if values["colorScheme"] == "vscode", values["themePreference"] != "system" {
            var overlay = ImportedEditorTheme(name: json["workbench.colorTheme"] as? String ?? "VS Code",
                dark: values["themePreference"] != "light", colors: [:], tokens: [:])
            let colorKeys = ["editor.background": "background", "editor.foreground": "foreground",
                "editorCursor.foreground": "cursor", "editor.selectionBackground": "selection",
                "editor.lineHighlightBackground": "lineHighlight", "editorLineNumber.foreground": "lineNumber",
                "editorLineNumber.activeForeground": "activeLineNumber", "editorIndentGuide.background1": "guide",
                "editorIndentGuide.activeBackground1": "activeGuide"]
            if let colors = json["workbench.colorCustomizations"] as? [String: Any] {
                for (key, value) in colors {
                    if let target = colorKeys[key], let color = value as? String, ImportedEditorTheme.validColor(color) {
                        overlay.colors[target] = color
                    } else { warnings.append("Some settings have unsupported values and were skipped.") }
                }
            }
            let roles = ["comments": "comment", "strings": "string", "numbers": "number",
                "keywords": "keyword", "types": "type", "functions": "function", "variables": "variable"]
            if let custom = json["editor.tokenColorCustomizations"] as? [String: Any] {
                for (key, value) in custom {
                    guard let token = roles[key] else {
                        warnings.append("Some settings have unsupported values and were skipped."); continue
                    }
                    if let color = value as? String, ImportedEditorTheme.validColor(color) {
                        overlay.tokens[token] = .init(foreground: color)
                    } else { warnings.append("Some settings have unsupported values and were skipped.") }
                }
            }
            if !overlay.colors.isEmpty || !overlay.tokens.isEmpty {
                guard ImportedEditorTheme.decode(overlay.encoded) != nil else { throw EditorSettingsImportError.invalid }
                values["customTheme"] = overlay.encoded
                warnings.removeAll { $0 == "The bundled palette is an approximation; custom theme colors are not imported." }
                warnings.append("Imported theme colors are applied to source editors. Unmapped effects and language-specific rules are skipped; built-in base colors are approximate.")
            }
        }
        warnings.append("Appearance defaults are labeled separately. Workspace and language overrides, formatters, extensions and account data are skipped.")
        return (values, Array(Set(warnings)).sorted(), lineHeightFontSize)
    }

    static func parseIDEA(_ files: [String: Data], fonts: Set<String>, includeAppearanceDefaults: Bool = false) throws -> ([String: String], [String], String?) {
        var documents: [String: ImportXML] = [:]
        for (path, data) in files { documents[path] = try ImportXML.read(data) }
        let editor = documents["options/editor.xml"]?.components["EditorSettings"] ?? [:]
        var font = documents["options/editor-font.xml"]?.components["DefaultFont"]
            ?? documents["options/editor.xml"]?.components["DefaultFont"] ?? [:]
        let schemeName = documents["options/colors.scheme.xml"]?.scheme
        let matches = documents.filter { $0.key.hasPrefix("colors/") && $0.value.schemeName == schemeName && schemeName != nil }.map(\.value)
        guard matches.count <= 1 else { throw EditorSettingsImportError.invalid }
        let activeScheme = matches.first
        if includeAppearanceDefaults {
            // Standard JetBrains Runtime reference appearance, not a claim about an unknown custom runtime.
            for (key, value) in ["FONT_FAMILY": "JetBrains Mono", "FONT_SIZE": "13", "LINE_SPACING": "1.2", "USE_LIGATURES": "false"] where font[key] == nil {
                font[key] = value
            }
        }
        if let activeScheme {
            guard activeScheme.schemeVersion.map({ (0...142).contains($0) }) == true else { throw EditorSettingsImportError.invalid }
            // AbstractColorsScheme delegates to AppEditorFontOptions, NOT parent_scheme fonts.
            // Parent schemes own colors; no recursive font traversal or path resolution is needed.
            var overrides = activeScheme.schemeFont
            if !activeScheme.schemeFonts.isEmpty {
                let usable = activeScheme.schemeFonts.filter { $0["EDITOR_FONT_NAME"] != nil }
                guard let selected = usable.first(where: { fonts.contains($0["EDITOR_FONT_NAME"]!) }) ?? usable.first else {
                    throw EditorSettingsImportError.invalid
                }
                overrides.merge(selected) { _, new in new }
            }
            for (from, to) in ["EDITOR_FONT_NAME": "FONT_FAMILY", "EDITOR_FONT_SIZE": "FONT_SIZE", "LINE_SPACING": "LINE_SPACING", "EDITOR_LIGATURES": "USE_LIGATURES"] {
                if let value = overrides[from] {
                    font[to] = value
                    if from == "EDITOR_FONT_SIZE" {
                        font.removeValue(forKey: "FONT_SIZE_2D")
                        font["FONT_SCALE"] = overrides["FONT_SCALE"] ?? "1.0"
                    }
                }
            }
        }
        var values: [String: String] = [:], warnings: [String] = []
        func put(_ field: EditorSettingsImportField, _ value: String?) {
            guard let value else { return }
            if field.accepts(value) { values[field.rawValue] = value }
            else { warnings.append("Some settings have unsupported values and were skipped.") }
        }
        for (key, field) in ["IS_INDENT_GUIDES_SHOWN": EditorSettingsImportField.indentGuides,
                             "IS_ANIMATED_SCROLLING": .smoothScrolling, "SHOW_STICKY_LINES": .stickyScroll] { put(field, editor[key]) }
        if let shown = editor["ARE_LINE_NUMBERS_SHOWN"], ["true", "false"].contains(shown) {
            if shown == "false" { put(.lineNumbers, "off") }
            else if editor["LINE_NUMERATION"] == nil || editor["LINE_NUMERATION"] == "ABSOLUTE" { put(.lineNumbers, "on") }
        }
        if editor["ARE_LINE_NUMBERS_SHOWN"] != "false", editor["LINE_NUMERATION"] == "RELATIVE" { put(.lineNumbers, "relative") }
        if let value = editor["IS_BLOCK_CURSOR"], ["true", "false"].contains(value) { put(.cursorStyle, value == "true" ? "block" : "line") }
        if let value = editor["IS_CARET_BLINKING"], ["true", "false"].contains(value) { put(.cursorBlinking, value == "true" ? "blink" : "solid") }
        if editor["IS_WHITESPACES_SHOWN"] == "false" { put(.whitespace, "none") }
        if editor["IS_WHITESPACES_SHOWN"] == "true" {
            warnings.append("IDEA whitespace subsets cannot be mapped exactly and were skipped.")
        }
        if let wrap = editor["USE_SOFT_WRAPS"] {
            if !wrap.split(separator: ":").contains("MAIN_EDITOR") { put(.softWrap, "false") }
            else if editor["SOFT_WRAP_FILE_MASKS"] == "*" { put(.softWrap, "true") }
            else { warnings.append("File-specific soft wrapping is not supported and was skipped.") }
        }
        if let family = font["FONT_FAMILY"] {
            if fonts.contains(family) { put(.fontFamily, family) }
            else { warnings.append("The requested font is not installed; the current Lithe font is preserved.") }
        }
        // AppFontOptions uses the legacy integer when FONT_SIZE_2D is still its default 13.
        let fontSize = font["FONT_SIZE_2D"].flatMap(Double.init) == 13 ? font["FONT_SIZE"] ?? font["FONT_SIZE_2D"] : font["FONT_SIZE_2D"] ?? font["FONT_SIZE"]
        if let size = fontSize.flatMap(Double.init) {
            if font["FONT_SCALE"] == nil || Double(font["FONT_SCALE"]!) == 1 { put(.fontSize, String(size)) }
            else { warnings.append("Scaled IDEA font sizes are not supported and were skipped.") }
        }
        if let height = font["LINE_SPACING"].flatMap(Double.init) { put(.lineHeight, String(height)) }
        put(.fontLigatures, font["USE_LIGATURES"])
        let laf = documents["options/laf.xml"]?.components["LafManager"] ?? [:]
        if laf["autodetect"] == "true" { put(.themePreference, "system") }
        else if let theme = laf["themeId"] {
            if ["Islands Dark", "Darcula", "Dark"].contains(theme) { put(.themePreference, "dark") }
            else if ["Islands Light", "IntelliJ Light", "Light"].contains(theme) { put(.themePreference, "light") }
            else { warnings.append("Custom themes are not supported; the current Lithe palette is preserved.") }
        } else if laf["class-name"] == "com.intellij.ide.ui.laf.darcula.DarculaLaf" {
            put(.themePreference, "dark")
        } else if includeAppearanceDefaults && laf.isEmpty { put(.themePreference, "dark") }
        if let scheme = documents["options/colors.scheme.xml"]?.scheme {
            if ["Islands Dark", "Islands Light", "Light", "Default", "Darcula"].contains(scheme) {
                put(.colorScheme, "idea"); warnings.append("The bundled palette is an approximation; custom theme colors are not imported.")
            } else {
                // Scheme-specific editor fonts can override DefaultFont. Do not misrepresent those global values as effective.
                if activeScheme == nil {
                    for key in ["fontFamily", "fontSize", "lineHeight", "fontLigatures"] { values.removeValue(forKey: key) }
                    warnings.append("Custom IDEA schemes may override fonts; scheme colors and font settings were skipped.")
                } else { warnings.append("Custom themes are not supported; the current Lithe palette is preserved.") }
            }
        }
        if let activeScheme {
            let theme = try MacImportedIDEATheme.resolve(activeScheme, documents: documents)
            if let theme {
                warnings.removeAll { $0 == "Custom themes are not supported; the current Lithe palette is preserved." }
                put(.customTheme, theme.encoded)
                put(.colorScheme, "idea")
                warnings.append("Imported theme colors are applied to source editors. Unmapped effects and language-specific rules are skipped; built-in base colors are approximate.")
            }
        }
        let codeName = documents["options/code.style.schemes.xml"]?.components["CodeStyleSchemeSettings"]?["CURRENT_SCHEME_NAME"] ?? "Default"
        let codeMatches = documents.filter { $0.key.hasPrefix("codestyles/") && $0.value.codeName == codeName }.map(\.value)
        guard codeMatches.count <= 1 else { throw EditorSettingsImportError.invalid }
        let code = codeMatches.first
        let knownCodeBase = (code != nil || codeName == "Default") && (code?.codeParent == nil || code?.codeParent == "Default")
        var indent = includeAppearanceDefaults && knownCodeBase
            ? ["TAB_SIZE": "4", "INDENT_SIZE": "4", "USE_TAB_CHARACTER": "false"] : [:]
        indent.merge(code?.indentOptions ?? [:]) { _, explicit in explicit }
        if let size = indent["TAB_SIZE"], indent["INDENT_SIZE"] == nil || indent["INDENT_SIZE"] == size { put(.tabSize, size) }
        if let tabs = indent["USE_TAB_CHARACTER"], ["true", "false"].contains(tabs) { put(.insertSpaces, tabs == "false" ? "true" : "false") }
        put(.detectIndentation, code?.codeOptions["AUTODETECT_INDENTS"] ?? (includeAppearanceDefaults && knownCodeBase ? "true" : nil))
        if code != nil || includeAppearanceDefaults { warnings.append("Only global indentation is imported. Language-specific code styles and formatter rules are skipped.") }

        warnings.append("Appearance defaults are labeled separately. Workspace and language overrides, formatters, extensions and account data are skipped.")
        if let version = font["VERSION"], !["0", "1"].contains(version) {
            for key in ["fontFamily", "fontSize", "lineHeight", "fontLigatures"] { values.removeValue(forKey: key) }
            warnings.append("Some settings have unsupported values and were skipped.")
        }
        if activeScheme?.schemeFonts.count ?? 0 > 1 {
            warnings.append("Only one installed font family is imported; fallback lists and font weights are not supported.")
        }
        if includeAppearanceDefaults, documents["options/colors.scheme.xml"]?.scheme == nil { put(.colorScheme, "idea") }
        warnings.append("IDEA font spacing is mapped approximately; rendering can differ between editors.")
        return (values, Array(Set(warnings)).sorted(), nil)
    }
}

/// XMLParser never resolves external entities; declarations are rejected before parsing.
final class ImportXML: NSObject, XMLParserDelegate {
    var components: [String: [String: String]] = [:]
    var codeName: String?
    var codeParent: String?
    var codeOptions: [String: String] = [:]
    var indentOptions: [String: String] = [:]
    private var optionNames: [String?] = []
    var schemeParent: String?
    var attributes: [String: [String: String]] = [:]
    var attributeBases: [String: String] = [:]
    var themeColors: [String: String] = [:]
    var scheme: String?
    var schemeName: String?
    var schemeVersion: Int?
    var schemeFont: [String: String] = [:]
    var schemeFonts: [[String: String]] = []
    private var elements: [String] = []
    private var component: String?
    static func read(_ data: Data) throws -> ImportXML {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw EditorSettingsImportError.invalid }
        let delegate = ImportXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw EditorSettingsImportError.invalid }
        return delegate
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let parent = elements.last
        elements.append(elementName)
        optionNames.append(elementName == "option" ? attributes["name"] : nil)
        if elementName == "code_scheme", elements.count == 1 { codeName = attributes["name"]; codeParent = attributes["parent_scheme"] }
        if elementName == "option", let name = attributes["name"], let value = attributes["value"], codeName != nil {
            if parent == "code_scheme", elements.count == 2 { codeOptions[name] = value }
            if elements.count == 4, elements[1] == "option", optionNames[1] == "OTHER_INDENT_OPTIONS", elements[2] == "value" {
                indentOptions[name] = value
            }
        }
        if elementName == "scheme", elements.count == 1 {
            schemeName = attributes["name"]
            schemeParent = attributes["parent_scheme"]
            schemeVersion = Int(attributes["version"] ?? "0")
        }
        if schemeName != nil, elementName == "option" {
            if elements.count == 3, parent == "attributes", let name = attributes["name"] {
                self.attributes[name] = [:]
                attributeBases[name] = attributes["baseAttributes"]
            }
            if elements.count == 5, elements[1] == "attributes", elements[3] == "value",
               let key = optionNames[2], let name = attributes["name"], let value = attributes["value"] {
                self.attributes[key, default: [:]][name] = value
            }
            if elements.count == 3, parent == "colors", let name = attributes["name"], let value = attributes["value"] { themeColors[name] = value }
        }
        if elementName == "font", parent == "scheme", elements.count == 2 { schemeFonts.append([:]) }
        if elementName == "option", schemeName != nil, let name = attributes["name"], let value = attributes["value"] {
            if parent == "scheme", elements.count == 2 { schemeFont[name] = value }
            if parent == "font", elements.count == 3, !schemeFonts.isEmpty { schemeFonts[schemeFonts.count - 1][name] = value }
        }
        if elementName == "component" {
            component = attributes["name"]
            if component == "LafManager", let detect = attributes["autodetect"] { components["LafManager", default: [:]]["autodetect"] = detect }
        }
        if elementName == "laf", component == "LafManager" {
            for key in ["themeId", "class-name"] { if let value = attributes[key] { components["LafManager", default: [:]][key] = value } }
        }
        if elementName == "option", let component, ["EditorSettings", "DefaultFont", "CodeStyleSchemeSettings"].contains(component),
           let name = attributes["name"], let value = attributes["value"] { components[component, default: [:]][name] = value }
        if elementName == "global_color_scheme", component == "EditorColorsManager" { scheme = attributes["name"] }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        optionNames.removeLast()
        if elementName == "component" { component = nil }
        elements.removeLast()
    }
}

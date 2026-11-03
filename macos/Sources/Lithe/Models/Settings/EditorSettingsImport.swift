import Foundation
import LitheModuleAPI

/// Only editor preferences with an existing live settings path may cross the import boundary.
struct EditorSettingsImportSource: Identifiable, Equatable, Sendable {
    var id: String { directory.path }
    let directory: URL
    let title: String
    var revision: String
    var values: [String: String]
    var warnings: [String]
    var lineHeightFontSize: String? = nil
    var isVSCode = false
    var readFailed = false
    var settingsFileMissing = false
    var isCursor = false
    var defaultFields: Set<String> = []
    var approximateFields: Set<String> = []
}

enum EditorSettingsImportField: String, CaseIterable, Sendable {
    case customTheme, keymap, tabSize, insertSpaces, detectIndentation
    case themePreference, fontFamily, fontSize, lineHeight, fontLigatures, colorScheme, lineNumbers, whitespace
    case indentGuides, softWrap, minimap, cursorStyle, cursorBlinking, stickyScroll
    case smoothScrolling, scrollBeyondLastLine, highlightCurrentLine

    var isAppearance: Bool {
        switch self {
        case .customTheme, .themePreference, .fontFamily, .fontSize, .lineHeight, .fontLigatures, .colorScheme: true
        default: false
        }
    }

    var category: String {
        switch self {
        case .keymap: "keymap"
        case .tabSize, .insertSpaces, .detectIndentation: "code"
        default: isAppearance ? "appearance" : "preferences"
        }
    }

    var title: String {
        switch self {
        case .customTheme: "Imported editor theme"
        case .keymap: "Keyboard shortcuts"
        case .tabSize: "Tab size"
        case .insertSpaces: "Insert spaces"
        case .detectIndentation: "Detect indentation"
        case .themePreference: "Appearance"
        case .fontFamily: "Font"
        case .fontSize: "Font size"
        case .lineHeight: "Line spacing"
        case .fontLigatures: "Font ligatures"
        case .colorScheme: "Syntax highlighting"
        case .lineNumbers: "Line numbers"
        case .whitespace: "Whitespace"
        case .indentGuides: "Indent guides"
        case .softWrap: "Soft wrap"
        case .minimap: "Minimap"
        case .cursorStyle: "Cursor style"
        case .cursorBlinking: "Cursor blinking"
        case .stickyScroll: "Sticky scroll"
        case .smoothScrolling: "Smooth scrolling"
        case .scrollBeyondLastLine: "Scroll beyond last line"
        case .highlightCurrentLine: "Highlight current line"
        }
    }

    func accepts(_ value: String) -> Bool {
        switch self {
        case .customTheme: value.isEmpty || ImportedEditorTheme.decode(value) != nil
        case .keymap: EditorImportKeymap.decode(value) != nil
        case .tabSize: Int(value).map { (1...16).contains($0) } ?? false
        case .themePreference: AppThemePreference(rawValue: value) != nil
        case .fontFamily:
            !value.isEmpty && value.count <= 128 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        case .fontSize: Double(value).map { $0.isFinite && (6...72).contains($0) } ?? false
        case .lineHeight: Double(value).map { $0.isFinite && ($0 == 0 || (1...3).contains($0)) } ?? false
        case .colorScheme: EditorAppearanceSettings.ColorScheme(rawValue: value) != nil
        case .lineNumbers: EditorAppearanceSettings.LineNumbers(rawValue: value) != nil
        case .whitespace: EditorAppearanceSettings.Whitespace(rawValue: value) != nil
        case .cursorStyle: EditorAppearanceSettings.CursorStyle(rawValue: value) != nil
        case .cursorBlinking: EditorAppearanceSettings.CursorBlinking(rawValue: value) != nil
        default: value == "true" || value == "false"
        }
    }
}

struct EditorSettingsImportJournal: Codable {
    var before: [String: String]
    var after: [String: String]
    var pending: Bool
}

enum EditorSettingsImportError: Error, LocalizedError {
    case changed, invalid, storage, read, fontSizeDependency
    case ambiguousShortcutProviders
    case shortcutConflict(String)
    /// Keep source paths and provider-supplied prose out of diagnostic fields.
    static func logFailure(_ error: any Error) -> LogFailure {
        if let failure = error as? EditorSettingsImportError {
            let code: String
            switch failure {
            case .changed: code = "changed"
            case .invalid: code = "invalid"
            case .storage: code = "storage"
            case .read: code = "read"
            case .fontSizeDependency: code = "font_size_dependency"
            case .ambiguousShortcutProviders: code = "ambiguous_providers"
            case .shortcutConflict: code = "shortcut_conflict"
            }
            return LogFailure(domain: "editor.settings_import", code: code)
        }
        let native = error as NSError
        if [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(native.domain) {
            return LogFailure(domain: native.domain, code: String(native.code))
        }
        return LogFailure(domain: "editor.settings_import", code: "source_failure")
    }
    var errorDescription: String? {
        if case .shortcutConflict(let command) = self {
            return String(format: L10n.string("Keyboard shortcut conflicts with %@. Adjust your keymap before importing."), L10n.string(key: command))
        }
        return L10n.string(key: messageKey)
    }
    private var messageKey: String {
        switch self {
        case .ambiguousShortcutProviders: "More than one plugin can import shortcuts from this source. Disable duplicate providers and scan again."
        case .shortcutConflict: "Keyboard shortcuts"
        case .fontSizeDependency: "Select the source font size together with pixel line height, or keep the current line height."
        case .changed: "Settings changed. Scan again before importing or restoring."
        case .invalid: "This configuration contains unsupported or invalid settings."
        case .storage: "Settings could not be verified. The recovery backup has been retained."
        case .read: "The configuration could not be read. Check the selected directory and file permissions."
        }
    }
}

/// One existing keymap preset and its overrides, encoded canonically for conflict/undo checks.
struct EditorImportKeymap: Codable, Equatable {
    var preset: String
    var commands: [String: [KeyboardShortcutBinding]]
    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
    static func decode(_ text: String) -> Self? {
        guard text.utf8.count <= 16_384, let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              value.preset.isEmpty || KeyboardShortcutPreset(rawValue: value.preset) != nil,
              value.commands.count <= LitheCommandCatalog.commands.count,
              value.commands.allSatisfy({ LitheCommandCatalog.command(id: $0.key) != nil && $0.value.count <= 8
                  && $0.value.allSatisfy(\.isAssignable) && Set($0.value).count == $0.value.count }) else { return nil }
        return value
    }
}

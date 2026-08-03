import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let language = "settings.language"
        static let editorFontSize = "settings.editorFontSize"
        static let tabWidth = "settings.tabWidth"
        static let showCodeVision = "settings.showCodeVision"
        static let autoSave = "settings.autoSave"
        static let autoSaveDelay = "settings.autoSaveDelay"
        static let terminalShell = "settings.terminalShell"
        static let hiddenDirectories = "settings.hiddenDirectories"
        static let hiddenFilePatterns = "settings.hiddenFilePatterns"
    }

    private let defaults: any KeyValueStore

    @Published var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    @Published var editorFontSize: Double { didSet { defaults.set(editorFontSize, forKey: Key.editorFontSize) } }
    @Published var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: Key.tabWidth) } }
    @Published var showCodeVision: Bool { didSet { defaults.set(showCodeVision, forKey: Key.showCodeVision) } }
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: Key.autoSave) } }
    @Published var autoSaveDelay: Double { didSet { defaults.set(autoSaveDelay, forKey: Key.autoSaveDelay) } }
    @Published var terminalShell: TerminalShell { didSet { defaults.set(terminalShell.rawValue, forKey: Key.terminalShell) } }
    @Published var hiddenDirectoryNames: [String] {
        didSet {
            defaults.set(hiddenDirectoryNames, forKey: Key.hiddenDirectories)
            onFileVisibilityRulesChanged?()
        }
    }
    @Published var hiddenFilePatterns: [String] {
        didSet {
            defaults.set(hiddenFilePatterns, forKey: Key.hiddenFilePatterns)
            onFileVisibilityRulesChanged?()
        }
    }

    var onFileVisibilityRulesChanged: (() -> Void)?

    init(store: any KeyValueStore) {
        self.defaults = store
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
        editorFontSize = defaults.object(forKey: Key.editorFontSize) as? Double ?? 13
        tabWidth = defaults.object(forKey: Key.tabWidth) as? Int ?? 4
        showCodeVision = defaults.object(forKey: Key.showCodeVision) as? Bool ?? true
        autoSave = defaults.object(forKey: Key.autoSave) as? Bool ?? false
        autoSaveDelay = defaults.object(forKey: Key.autoSaveDelay) as? Double ?? 1.5
        terminalShell = TerminalShell(rawValue: defaults.string(forKey: Key.terminalShell) ?? "") ?? .system
        hiddenDirectoryNames = defaults.stringArray(forKey: Key.hiddenDirectories)
            ?? FileVisibilityRules.default.hiddenDirectoryNames
        hiddenFilePatterns = defaults.stringArray(forKey: Key.hiddenFilePatterns)
            ?? FileVisibilityRules.default.hiddenFilePatterns
    }

    var terminalShellPath: String? { terminalShell.path }

    var fileVisibilityRules: FileVisibilityRules {
        FileVisibilityRules(
            hiddenDirectoryNames: hiddenDirectoryNames,
            hiddenFilePatterns: hiddenFilePatterns
        )
    }

    func restoreDefaults() {
        language = .english
        editorFontSize = 13
        tabWidth = 4
        showCodeVision = true
        autoSave = false
        autoSaveDelay = 1.5
        terminalShell = .system
        hiddenDirectoryNames = FileVisibilityRules.default.hiddenDirectoryNames
        hiddenFilePatterns = FileVisibilityRules.default.hiddenFilePatterns
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

enum TerminalShell: String, CaseIterable, Identifiable {
    case system
    case zsh
    case bash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System default"
        case .zsh: "zsh"
        case .bash: "bash"
        }
    }

    var path: String? {
        switch self {
        case .system: nil
        case .zsh: "/bin/zsh"
        case .bash: "/bin/bash"
        }
    }
}

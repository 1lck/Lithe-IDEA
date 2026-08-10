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
        static let gitSaveChangesPolicy = "settings.gitSaveChangesPolicy"
        static let projectOpenBehavior = "settings.projectOpenBehavior"
        static let commitMessageAI = "settings.commitMessageAI"
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
            notifyFileVisibilityRulesObservers()
        }
    }
    @Published var hiddenFilePatterns: [String] {
        didSet {
            defaults.set(hiddenFilePatterns, forKey: Key.hiddenFilePatterns)
            notifyFileVisibilityRulesObservers()
        }
    }
    @Published var gitSaveChangesPolicy: GitSaveChangesPolicy {
        didSet { defaults.set(gitSaveChangesPolicy.rawValue, forKey: Key.gitSaveChangesPolicy) }
    }
    @Published var projectOpenBehavior: ProjectOpenBehavior {
        didSet { defaults.set(projectOpenBehavior.rawValue, forKey: Key.projectOpenBehavior) }
    }
    @Published var commitMessageAI: CommitMessageAISettings {
        didSet { saveCommitMessageAI() }
    }

    private var fileVisibilityRulesObservers: [UUID: () -> Void] = [:]

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
        gitSaveChangesPolicy = GitSaveChangesPolicy(
            rawValue: defaults.string(forKey: Key.gitSaveChangesPolicy) ?? ""
        ) ?? .stash
        projectOpenBehavior = ProjectOpenBehavior(
            rawValue: defaults.string(forKey: Key.projectOpenBehavior) ?? ""
        ) ?? .ask
        if let data = defaults.data(forKey: Key.commitMessageAI),
           let saved = try? JSONDecoder().decode(CommitMessageAISettings.self, from: data) {
            commitMessageAI = saved
        } else {
            commitMessageAI = .default
        }
    }

    var terminalShellPath: String? { terminalShell.path }

    var fileVisibilityRules: FileVisibilityRules {
        FileVisibilityRules(
            hiddenDirectoryNames: hiddenDirectoryNames,
            hiddenFilePatterns: hiddenFilePatterns
        )
    }

    @discardableResult
    func addFileVisibilityRulesObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        fileVisibilityRulesObservers[id] = observer
        return id
    }

    func removeFileVisibilityRulesObserver(_ id: UUID) {
        fileVisibilityRulesObservers[id] = nil
    }

    private func notifyFileVisibilityRulesObservers() {
        for observer in fileVisibilityRulesObservers.values {
            observer()
        }
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
        gitSaveChangesPolicy = .stash
        projectOpenBehavior = .ask
        commitMessageAI = .default
    }

    var activeCommitMessageProvider: AIProviderProfile? {
        commitMessageAI.activeProvider
    }

    func updateActiveCommitMessageProvider(_ update: (inout AIProviderProfile) -> Void) {
        var value = commitMessageAI
        value.updateActiveProvider(update)
        commitMessageAI = value
    }

    func selectCommitMessageProvider(_ id: UUID?) {
        var value = commitMessageAI
        value.selectProvider(id)
        commitMessageAI = value
    }

    func addCommitMessageProvider() {
        var value = commitMessageAI
        _ = value.addProvider()
        value.codexImportCompleted = true
        commitMessageAI = value
    }

    func removeActiveCommitMessageProvider() {
        var value = commitMessageAI
        value.removeActiveProvider()
        commitMessageAI = value
    }

    @discardableResult
    func importAIConfiguration(
        _ snapshot: AIConfigurationSnapshot
    ) -> AIProviderProfile {
        let importedKeyIdentifier = "lithe.(snapshot.source.rawValue).imported.apiKey"
        let credentialSource = snapshot.source.credentialSource
        let existing = commitMessageAI.providers.first {
            $0.apiKeyIdentifier == importedKeyIdentifier || $0.credentialSource == credentialSource
        }
        let provider = AIProviderProfile(
            id: existing?.id ?? UUID(),
            name: snapshot.providerName.isEmpty
                ? "\(snapshot.source.title) (imported)"
                : "\(snapshot.source.title) · \(snapshot.providerName)",
            endpoint: snapshot.endpoint,
            model: snapshot.model,
            apiProtocol: snapshot.apiProtocol,
            authentication: snapshot.authentication,
            allowsInsecureHTTP: existing?.allowsInsecureHTTP ?? false,
            apiKeyIdentifier: importedKeyIdentifier,
            requiresAPIKey: snapshot.requiresAPIKey,
            credentialSource: credentialSource
        )

        var value = commitMessageAI
        value.providers.removeAll {
            $0.apiKeyIdentifier == importedKeyIdentifier || $0.credentialSource == credentialSource
        }
        value.providers.insert(provider, at: 0)
        value.activeProviderID = provider.id
        value.codexImportCompleted = true

        // Codex's reasoning setting is useful as a source hint, but commit
        // messages default to low effort because this is a latency-sensitive
        // one-shot task. Users can select any supported effort in Settings.
        if let importedEffort = snapshot.reasoningEffort,
           importedEffort != .max,
           value.reasoningEffort == .low {
            value.reasoningEffort = importedEffort
        }
        commitMessageAI = value
        return provider
    }

    @discardableResult
    func importCodexConfiguration(
        _ snapshot: CodexConfigurationSnapshot
    ) -> AIProviderProfile {
        importAIConfiguration(snapshot)
    }

    private func saveCommitMessageAI() {
        guard let data = try? JSONEncoder().encode(commitMessageAI) else { return }
        defaults.set(data, forKey: Key.commitMessageAI)
    }
}

enum ProjectOpenBehavior: String, CaseIterable, Identifiable {
    case ask
    case thisWindow
    case newWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask every time"
        case .thisWindow: "This window"
        case .newWindow: "New window"
        }
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

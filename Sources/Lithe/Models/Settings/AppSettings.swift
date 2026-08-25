import Combine
import Foundation
import LitheCoreContracts
import LitheGitModule

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let colorTheme = "settings.colorTheme"
        static let themePreference = "settings.themePreference"
        static let language = "settings.language"
        static let editorFontSize = "settings.editorFontSize"
        static let projectTreeRowHeight = "settings.projectTreeRowHeight"
        static let tabWidth = "settings.tabWidth"
        static let editorTabLayoutMode = "settings.editorTabLayoutMode"
        static let showCodeVision = "settings.showCodeVision"
        static let autoSave = "settings.autoSave"
        static let autoSaveDelay = "settings.autoSaveDelay"
        static let terminalShell = "settings.terminalShell"
        static let hiddenDirectories = "settings.hiddenDirectories"
        static let hiddenFilePatterns = "settings.hiddenFilePatterns"
        static let gitSaveChangesPolicy = "settings.gitSaveChangesPolicy"
        static let projectOpenBehavior = "settings.projectOpenBehavior"
        static let commitMessageAI = "settings.commitMessageAI"
        static let keyboardShortcutOverrides = "settings.keyboardShortcutOverrides"
        static let customLogDirectory = "settings.customLogDirectory"
        static let workbenchBackground = "settings.workbenchBackground"
    }

    private struct KeyboardShortcutOverridesPayload: Codable {
        static let currentVersion = 1

        let version: Int
        let commands: [String: [KeyboardShortcutBinding]]
    }

    private let defaults: any KeyValueStore
    private let logDirectoryProvider: any LogDirectoryProviding

    @Published var colorTheme: AppColorTheme {
        didSet {
            AppThemeRuntime.shared.activate(colorTheme)
            defaults.set(colorTheme.rawValue, forKey: Key.colorTheme)
        }
    }
    @Published var themePreference: AppThemePreference {
        didSet { defaults.set(themePreference.rawValue, forKey: Key.themePreference) }
    }
    @Published var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    @Published var editorFontSize: Double { didSet { defaults.set(editorFontSize, forKey: Key.editorFontSize) } }
    @Published var projectTreeRowHeight: Double {
        didSet { defaults.set(projectTreeRowHeight, forKey: Key.projectTreeRowHeight) }
    }
    @Published var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: Key.tabWidth) } }
    @Published var editorTabLayoutMode: EditorTabLayoutMode {
        didSet { defaults.set(editorTabLayoutMode.rawValue, forKey: Key.editorTabLayoutMode) }
    }
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
    @Published private(set) var keyboardShortcutOverrides: [String: [KeyboardShortcutBinding]]
    @Published private(set) var customLogDirectory: URL?
    @Published private(set) var workbenchBackground: WorkbenchBackgroundConfiguration
    @Published var workbenchBackgroundOpacity: Double {
        didSet {
            let normalizedOpacity = min(max(workbenchBackgroundOpacity, 0.05), 1)
            if workbenchBackgroundOpacity != normalizedOpacity {
                workbenchBackgroundOpacity = normalizedOpacity
                return
            }
            workbenchBackground.opacity = workbenchBackgroundOpacity
            saveWorkbenchBackgroundConfiguration()
        }
    }

    private var fileVisibilityRulesObservers: [UUID: () -> Void] = [:]
    private var logDirectoryObservers: [UUID: (URL) -> Void] = [:]
    private let workbenchBackgroundSourceDidChange = PassthroughSubject<Void, Never>()

    init(
        store: any KeyValueStore,
        logDirectoryProvider: any LogDirectoryProviding
    ) {
        self.defaults = store
        self.logDirectoryProvider = logDirectoryProvider
        colorTheme = AppColorTheme(
            rawValue: defaults.string(forKey: Key.colorTheme) ?? ""
        ) ?? .lithe
        themePreference = AppThemePreference(
            rawValue: defaults.string(forKey: Key.themePreference) ?? ""
        ) ?? .dark
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
        editorFontSize = defaults.object(forKey: Key.editorFontSize) as? Double ?? 13
        projectTreeRowHeight = defaults.object(forKey: Key.projectTreeRowHeight) as? Double ?? 24
        tabWidth = defaults.object(forKey: Key.tabWidth) as? Int ?? 4
        editorTabLayoutMode = EditorTabLayoutMode(
            rawValue: defaults.string(forKey: Key.editorTabLayoutMode) ?? ""
        ) ?? .singleLine
        showCodeVision = defaults.object(forKey: Key.showCodeVision) as? Bool ?? true
        autoSave = defaults.object(forKey: Key.autoSave) as? Bool ?? true
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
        keyboardShortcutOverrides = Self.loadKeyboardShortcutOverrides(from: defaults)
        customLogDirectory = defaults.string(forKey: Key.customLogDirectory).flatMap { path in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let backgroundConfiguration = Self.loadWorkbenchBackgroundConfiguration(from: defaults)
        workbenchBackground = backgroundConfiguration
        workbenchBackgroundOpacity = backgroundConfiguration.opacity
        if let data = defaults.data(forKey: Key.commitMessageAI),
           let saved = try? JSONDecoder().decode(CommitMessageAISettings.self, from: data) {
            commitMessageAI = saved
        } else {
            commitMessageAI = .default
        }
        AppThemeRuntime.shared.activate(colorTheme)
    }

    var terminalShellPath: String? { terminalShell.path }

    var defaultLogDirectory: URL {
        logDirectoryProvider.defaultLogDirectory
    }

    var logDirectory: URL { customLogDirectory ?? defaultLogDirectory }

    func setCustomLogDirectory(_ url: URL?) {
        customLogDirectory = url?.standardizedFileURL
        defaults.set(customLogDirectory?.path, forKey: Key.customLogDirectory)
        for observer in logDirectoryObservers.values {
            observer(logDirectory)
        }
    }

    var hasConfiguredWorkbenchBackground: Bool {
        workbenchBackground.source.isCustom || workbenchBackgroundPreset != nil
    }

    var workbenchBackgroundPreset: WorkbenchBackgroundPreset? {
        guard let slot = workbenchBackground.source.bundledSlot else {
            return nil
        }
        return WorkbenchBackgroundPreset(bundledSlot: slot)
    }

    func setWorkbenchBackgroundCustomImage() {
        updateWorkbenchBackground(.custom(opacity: workbenchBackgroundOpacity))
    }

    func setWorkbenchBackgroundPreset(_ preset: WorkbenchBackgroundPreset) {
        updateWorkbenchBackground(.bundled(slot: preset.bundledImageSlot, opacity: workbenchBackgroundOpacity))
    }

    func clearWorkbenchBackground() {
        updateWorkbenchBackground(.none(opacity: workbenchBackgroundOpacity))
    }

    var workbenchBackgroundSourceChanges: AnyPublisher<Void, Never> {
        workbenchBackgroundSourceDidChange.eraseToAnyPublisher()
    }

    @discardableResult
    func addLogDirectoryObserver(_ observer: @escaping (URL) -> Void) -> UUID {
        let id = UUID()
        logDirectoryObservers[id] = observer
        return id
    }

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
        colorTheme = .lithe
        themePreference = .dark
        language = .english
        editorFontSize = 13
        projectTreeRowHeight = 24
        tabWidth = 4
        editorTabLayoutMode = .singleLine
        showCodeVision = true
        autoSave = true
        autoSaveDelay = 1.5
        terminalShell = .system
        hiddenDirectoryNames = FileVisibilityRules.default.hiddenDirectoryNames
        hiddenFilePatterns = FileVisibilityRules.default.hiddenFilePatterns
        gitSaveChangesPolicy = .stash
        projectOpenBehavior = .ask
        commitMessageAI = .default
        setCustomLogDirectory(nil)
        clearWorkbenchBackground()
        workbenchBackgroundOpacity = 0.22
        setKeyboardShortcutOverrides([:])
    }

    func setKeyboardShortcutOverrides(_ value: [String: [KeyboardShortcutBinding]]) {
        keyboardShortcutOverrides = value
        saveKeyboardShortcutOverrides()
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

    private func saveKeyboardShortcutOverrides() {
        let payload = KeyboardShortcutOverridesPayload(
            version: KeyboardShortcutOverridesPayload.currentVersion,
            commands: keyboardShortcutOverrides
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Key.keyboardShortcutOverrides)
    }

    private static func loadKeyboardShortcutOverrides(
        from defaults: any KeyValueStore
    ) -> [String: [KeyboardShortcutBinding]] {
        guard let data = defaults.data(forKey: Key.keyboardShortcutOverrides),
              let payload = try? JSONDecoder().decode(KeyboardShortcutOverridesPayload.self, from: data),
              payload.version == KeyboardShortcutOverridesPayload.currentVersion else {
            return [:]
        }

        let knownCommandIDs = Set(LitheCommandCatalog.commands.map(\.id))
        return payload.commands.filter { commandID, bindings in
            knownCommandIDs.contains(commandID)
                && bindings.allSatisfy(\.isAssignable)
                && Set(bindings).count == bindings.count
        }
    }

    private func saveWorkbenchBackgroundConfiguration() {
        guard let data = try? JSONEncoder().encode(workbenchBackground.normalized) else { return }
        defaults.set(data, forKey: Key.workbenchBackground)
    }

    private func updateWorkbenchBackground(_ configuration: WorkbenchBackgroundConfiguration) {
        let sourceChanged = workbenchBackground.source != configuration.source
        workbenchBackground = configuration
        saveWorkbenchBackgroundConfiguration()
        if sourceChanged { workbenchBackgroundSourceDidChange.send() }
    }

    private static func loadWorkbenchBackgroundConfiguration(
        from defaults: any KeyValueStore
    ) -> WorkbenchBackgroundConfiguration {
        if let data = defaults.data(forKey: Key.workbenchBackground),
           let configuration = try? JSONDecoder().decode(WorkbenchBackgroundConfiguration.self, from: data) {
            return configuration.normalized
        }
        return .none()
    }
}

struct WorkbenchBackgroundConfiguration: Codable, Equatable {
    static let version = 1

    var version: Int
    var source: WorkbenchBackgroundSource
    var opacity: Double

    static func none(opacity: Double = 0.22) -> Self {
        Self(version: version, source: .none, opacity: opacity)
    }

    static func bundled(slot: String, opacity: Double) -> Self {
        Self(version: version, source: .bundled(bundledSlot: slot), opacity: opacity)
    }

    static func custom(opacity: Double) -> Self {
        Self(version: version, source: .custom, opacity: opacity)
    }

    var normalized: Self {
        let normalizedOpacity = min(max(opacity, 0.05), 1)
        guard version == Self.version else { return .none(opacity: normalizedOpacity) }
        switch source {
        case .none, .custom:
            return Self(version: Self.version, source: source, opacity: normalizedOpacity)
        case let .bundled(bundledSlot) where WorkbenchBackgroundPreset.validBundledSlots.contains(bundledSlot):
            return Self(version: Self.version, source: source, opacity: normalizedOpacity)
        case .bundled:
            return .none(opacity: normalizedOpacity)
        }
    }
}

enum WorkbenchBackgroundSource: Codable, Equatable {
    case none
    case bundled(bundledSlot: String)
    case custom

    private enum CodingKeys: String, CodingKey { case kind, bundledSlot }
    private enum Kind: String, Codable { case none, bundled, custom }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .custom:
            self = .custom
        case .bundled:
            self = .bundled(bundledSlot: try container.decode(String.self, forKey: .bundledSlot))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .custom:
            try container.encode(Kind.custom, forKey: .kind)
        case let .bundled(bundledSlot):
            try container.encode(Kind.bundled, forKey: .kind)
            try container.encode(bundledSlot, forKey: .bundledSlot)
        }
    }

    var isCustom: Bool {
        switch self {
        case .custom: true
        case .none, .bundled: false
        }
    }

    var bundledSlot: String? {
        guard case let .bundled(slot) = self else { return nil }
        return slot
    }
}

enum WorkbenchBackgroundPreset: String, CaseIterable, Identifiable {
    case builtIn01
    case builtIn02
    case builtIn03
    case builtIn04
    case builtIn05
    case builtIn06
    case builtIn07
    case builtIn08
    case builtIn09
    case builtIn10

    var id: String { rawValue }

    static let validBundledSlots = Set(allCases.map(\.bundledImageSlot))

    init?(bundledSlot: String) {
        self.init(rawValue: "builtIn\(bundledSlot)")
    }

    var title: String {
        switch self {
        case .builtIn01: "01"
        case .builtIn02: "02"
        case .builtIn03: "03"
        case .builtIn04: "04"
        case .builtIn05: "05"
        case .builtIn06: "06"
        case .builtIn07: "07"
        case .builtIn08: "08"
        case .builtIn09: "09"
        case .builtIn10: "10"
        }
    }

    var bundledImageSlot: String {
        switch self {
        case .builtIn01: "01"
        case .builtIn02: "02"
        case .builtIn03: "03"
        case .builtIn04: "04"
        case .builtIn05: "05"
        case .builtIn06: "06"
        case .builtIn07: "07"
        case .builtIn08: "08"
        case .builtIn09: "09"
        case .builtIn10: "10"
        }
    }
}

enum AppColorTheme: String, CaseIterable, Identifiable {
    case lithe
    case codex
    case linear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lithe: "Lithe"
        case .codex: "Codex"
        case .linear: "Linear"
        }
    }
}

final class AppThemeRuntime: @unchecked Sendable {
    static let shared = AppThemeRuntime()

    private let lock = NSLock()
    private var value: AppColorTheme = .lithe

    private init() {}

    func activate(_ theme: AppColorTheme) {
        lock.lock()
        value = theme
        lock.unlock()
    }

    var activeTheme: AppColorTheme {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum AppThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum EditorTabLayoutMode: String, CaseIterable, Identifiable {
    case singleLine
    case multipleRows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleLine: "Single row"
        case .multipleRows: "Wrap into rows"
        }
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

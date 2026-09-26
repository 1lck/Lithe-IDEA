import Combine
import Foundation
import LitheCoreContracts
import LitheGitModule

enum JavaBuildFailurePolicy: String, Codable {
    case ask
    case alwaysContinue
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let colorTheme = "settings.colorTheme"
        static let themePreference = "settings.themePreference"
        static let language = "settings.language"
        static let editorFontSize = "settings.editorFontSize"
        static let editorSoftWrap = "settings.editorSoftWrap"
        static let editorMinimap = "settings.editorMinimap"
        static let projectTreeRowHeight = "settings.projectTreeRowHeight"
        static let tabWidth = "settings.tabWidth"
        static let editorTabLayoutMode = "settings.editorTabLayoutMode"
        static let showCodeVision = "settings.showCodeVision"
        static let autoSave = "settings.autoSave"
        static let autoSaveDelay = "settings.autoSaveDelay"
        static let terminalShell = "settings.terminalShell"
        static let terminalShellPathOverride = "settings.terminalShellPathOverride"
        static let hiddenDirectories = "settings.hiddenDirectories"
        static let hiddenFilePatterns = "settings.hiddenFilePatterns"
        static let gitExecutable = "settings.gitExecutable"
        static let gitUseCredentialHelper = "settings.gitUseCredentialHelper"
        static let gitFetchOptions = "settings.gitFetchOptions"
        static let gitSaveChangesPolicy = "settings.gitSaveChangesPolicy"
        static let projectOpenBehavior = "settings.projectOpenBehavior"
        static let commitMessageAI = "settings.commitMessageAI"
        static let agentCommand = "settings.agentCommand"
        static let agentArguments = "settings.agentArguments"
        static let agentConfigurations = "settings.agentConfigurations"
        static let keyboardShortcutOverrides = "settings.keyboardShortcutOverrides"
        static let customLogDirectory = "settings.customLogDirectory"
        static let workbenchBackground = "settings.workbenchBackground"
        static let javaBuildFailurePolicies = "settings.javaBuildFailurePolicies"
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
    /// 主编辑器软换行开关。默认关闭，与 IDEA 代码编辑器一致；
    /// 折行布局对超大文件有行数阈值兜底，见 `LitheTextViewportLayout`。
    @Published var editorSoftWrapEnabled: Bool {
        didSet { defaults.set(editorSoftWrapEnabled, forKey: Key.editorSoftWrap) }
    }
    @Published var editorMinimapEnabled: Bool {
        didSet { defaults.set(editorMinimapEnabled, forKey: Key.editorMinimap) }
    }
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
    @Published var terminalShellPathOverride: String { didSet { defaults.set(terminalShellPathOverride, forKey: Key.terminalShellPathOverride) } }
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
    let gitExecutionPreferences = GitExecutionPreferences()
    @Published var gitExecutable: String {
        didSet { defaults.set(gitExecutable, forKey: Key.gitExecutable); updateGitExecutionPreferences() }
    }
    @Published var gitUseCredentialHelper: Bool {
        didSet { defaults.set(gitUseCredentialHelper, forKey: Key.gitUseCredentialHelper); updateGitExecutionPreferences() }
    }
    private func updateGitExecutionPreferences() {
        var options = GitExecutionOptions()
        options.executable = gitExecutable.isEmpty ? nil : gitExecutable
        options.useCredentialHelper = gitUseCredentialHelper
        options.fetchDefaults = gitFetchOptions
        gitExecutionPreferences.update(options)
    }
    @Published var gitFetchOptions: GitFetchOptions {
        didSet {
            if let data = try? JSONEncoder().encode(gitFetchOptions) { defaults.set(data, forKey: Key.gitFetchOptions) }
            updateGitExecutionPreferences()
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
    @Published var agentCommand: String { didSet { defaults.set(agentCommand, forKey: Key.agentCommand) } }
    /// One command argument per line, so paths with spaces need no shell parser.
    @Published var agentArguments: String { didSet { defaults.set(agentArguments, forKey: Key.agentArguments) } }
    /// AI provider whose endpoint and API key the Agent uses; `nil` until chosen.
    /// Per-agent setup from Settings › Agents, keyed by ACP registry id or
    /// `AgentConfiguration.customAgentID`.
    @Published var agentConfigurations: [String: AgentConfiguration] {
        didSet {
            if let data = try? JSONEncoder().encode(agentConfigurations) {
                defaults.set(data, forKey: Key.agentConfigurations)
            }
        }
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
    private var javaBuildFailurePolicies: [String: JavaBuildFailurePolicy] = [:]

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
        editorSoftWrapEnabled = defaults.object(forKey: Key.editorSoftWrap) as? Bool ?? false
        editorMinimapEnabled = defaults.object(forKey: Key.editorMinimap) as? Bool ?? true
        projectTreeRowHeight = defaults.object(forKey: Key.projectTreeRowHeight) as? Double ?? 24
        tabWidth = defaults.object(forKey: Key.tabWidth) as? Int ?? 4
        editorTabLayoutMode = EditorTabLayoutMode(
            rawValue: defaults.string(forKey: Key.editorTabLayoutMode) ?? ""
        ) ?? .singleLine
        showCodeVision = defaults.object(forKey: Key.showCodeVision) as? Bool ?? true
        autoSave = defaults.object(forKey: Key.autoSave) as? Bool ?? true
        autoSaveDelay = defaults.object(forKey: Key.autoSaveDelay) as? Double ?? 1.5
        terminalShellPathOverride = defaults.string(forKey: Key.terminalShellPathOverride) ?? ""
        terminalShell = TerminalShell(rawValue: defaults.string(forKey: Key.terminalShell) ?? "") ?? .system
        hiddenDirectoryNames = defaults.stringArray(forKey: Key.hiddenDirectories)
            ?? FileVisibilityRules.default.hiddenDirectoryNames
        hiddenFilePatterns = defaults.stringArray(forKey: Key.hiddenFilePatterns)
            ?? FileVisibilityRules.default.hiddenFilePatterns
        gitExecutable = defaults.string(forKey: Key.gitExecutable) ?? ""
        gitUseCredentialHelper = defaults.object(forKey: Key.gitUseCredentialHelper) as? Bool ?? true
        var savedFetchOptions = defaults.data(forKey: Key.gitFetchOptions)
            .flatMap { try? JSONDecoder().decode(GitFetchOptions.self, from: $0) } ?? GitFetchOptions()
        savedFetchOptions.remote = nil
        gitFetchOptions = savedFetchOptions
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
        agentCommand = defaults.string(forKey: Key.agentCommand) ?? ""
        agentArguments = defaults.string(forKey: Key.agentArguments) ?? ""
        agentConfigurations = defaults.data(forKey: Key.agentConfigurations)
            .flatMap { try? JSONDecoder().decode([String: AgentConfiguration].self, from: $0) } ?? [:]
        if let data = defaults.data(forKey: Key.javaBuildFailurePolicies),
           let saved = try? JSONDecoder().decode([String: JavaBuildFailurePolicy].self, from: data) {
            javaBuildFailurePolicies = saved
        }
        AppThemeRuntime.shared.activate(colorTheme)
        updateGitExecutionPreferences()
    }

    var terminalShellPath: String? {
        terminalShellPathOverride.isEmpty ? terminalShell.path : terminalShellPathOverride
    }

    func javaBuildFailurePolicy(for workspaceURL: URL) -> JavaBuildFailurePolicy {
        javaBuildFailurePolicies[Self.javaWorkspacePreferenceKey(workspaceURL)] ?? .ask
    }

    func setJavaBuildFailurePolicy(_ policy: JavaBuildFailurePolicy, for workspaceURL: URL) {
        let key = Self.javaWorkspacePreferenceKey(workspaceURL)
        if policy == .ask {
            javaBuildFailurePolicies[key] = nil
        } else {
            javaBuildFailurePolicies[key] = policy
        }
        if let data = try? JSONEncoder().encode(javaBuildFailurePolicies) {
            defaults.set(data, forKey: Key.javaBuildFailurePolicies)
        }
    }

    private static func javaWorkspacePreferenceKey(_ workspaceURL: URL) -> String {
        workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func selectTerminalShell(path: String) {
        terminalShell = .system
        terminalShellPathOverride = path
    }

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
        editorSoftWrapEnabled = false
        editorMinimapEnabled = true
        projectTreeRowHeight = 24
        tabWidth = 4
        editorTabLayoutMode = .singleLine
        showCodeVision = true
        autoSave = true
        autoSaveDelay = 1.5
        terminalShell = .system
        terminalShellPathOverride = ""
        hiddenDirectoryNames = FileVisibilityRules.default.hiddenDirectoryNames
        hiddenFilePatterns = FileVisibilityRules.default.hiddenFilePatterns
        gitFetchOptions = GitFetchOptions()
        gitExecutable = ""
        gitUseCredentialHelper = true
        gitSaveChangesPolicy = .stash
        projectOpenBehavior = .ask
        commitMessageAI = .default
        agentCommand = ""
        agentArguments = ""
        agentConfigurations = [:]
        setCustomLogDirectory(nil)
        clearWorkbenchBackground()
        workbenchBackgroundOpacity = 0.22
        setKeyboardShortcutOverrides([:])
        javaBuildFailurePolicies = [:]
        defaults.set(nil, forKey: Key.javaBuildFailurePolicies)
    }

    func setKeyboardShortcutOverrides(_ value: [String: [KeyboardShortcutBinding]]) {
        keyboardShortcutOverrides = value
        saveKeyboardShortcutOverrides()
    }

    /// Providers an agent speaking `apiProtocol` can use.
    func agentProviderCandidates(for apiProtocol: CommitMessageAPIProtocol) -> [AIProviderProfile] {
        commitMessageAI.providers.filter { $0.apiProtocol == apiProtocol }
    }

    /// The provider assigned to `agentID`, if it still exists.
    func agentProvider(for agentID: String) -> AIProviderProfile? {
        guard let providerID = agentConfigurations[agentID]?.providerID else { return nil }
        return commitMessageAI.providers.first { $0.id == providerID }
    }

    func setAgentProvider(_ providerID: UUID?, for agentID: String, name: String) {
        agentConfigurations[agentID] = AgentConfiguration(name: name, providerID: providerID)
    }

    /// Refresh linked agents' default models without changing the commit provider
    /// selection, endpoints, credentials, or manually configured models.
    func refreshAgentModels(from configurations: [AIConfigurationModel]) {
        let linkedIDs = Set(agentConfigurations.values.compactMap(\.providerID))
        var value = commitMessageAI
        for index in value.providers.indices {
            let provider = value.providers[index]
            guard linkedIDs.contains(provider.id),
                  let source = provider.credentialSource.configurationSource,
                  let snapshot = configurations.first(where: { $0.source == source }) else { continue }
            value.providers[index].model = snapshot.model
        }
        if value != commitMessageAI { commitMessageAI = value }
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

    /// Edit any provider without changing which one commit messages use.
    func updateAIProvider(_ id: UUID, _ update: (inout AIProviderProfile) -> Void) {
        var value = commitMessageAI
        guard let index = value.providers.firstIndex(where: { $0.id == id }) else { return }
        update(&value.providers[index])
        commitMessageAI = value
    }

    /// Add a provider; commit messages switch to it only when none was selected.
    @discardableResult
    func addAIProvider() -> UUID {
        var value = commitMessageAI
        let previous = value.activeProviderID
        let provider = value.addProvider()
        if previous != nil { value.activeProviderID = previous }
        value.codexImportCompleted = true
        commitMessageAI = value
        return provider.id
    }

    /// Remove a provider and every reference to it.
    func removeAIProvider(_ id: UUID) {
        var value = commitMessageAI
        value.providers.removeAll { $0.id == id }
        if value.activeProviderID == id { value.activeProviderID = value.providers.first?.id }
        commitMessageAI = value
        for (agentID, configuration) in agentConfigurations where configuration.providerID == id {
            agentConfigurations[agentID]?.providerID = nil
        }
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

/// Agent setup chosen in Settings › Agents.
struct AgentConfiguration: Codable, Equatable {
    /// Identifier of the user-provided command agent configured by
    /// `agentCommand` and `agentArguments`.
    static let customAgentID = "custom"

    /// Display name recorded when the agent was set up, for the Agent panel.
    var name: String
    var providerID: UUID?
}

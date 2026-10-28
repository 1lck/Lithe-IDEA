import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// UI-facing projection for project runtime settings and discovery.
@MainActor
final class RuntimeSettingsFeatureModel: ObservableObject {
    private let service: ProjectRuntimeService
    private var observation: AnyCancellable?
    private var baseline = ProjectRuntimeSettings()
    private var draftSnapshot: ProjectRuntimeSettingsSnapshot?
    @Published private(set) var settingsError: String?
    @Published private(set) var isSaving = false
    var hasChanges: Bool { settings != baseline }

    @Published private(set) var javaRuntimes: [JavaRuntimeCandidate]
    @Published private(set) var mavenRuntimes: [MavenRuntimeCandidate]
    @Published private(set) var javaEnvironmentReport: JavaEnvironmentReport?
    @Published private(set) var isDiscovering: Bool
    @Published private(set) var settings: ProjectRuntimeSettings
    @Published private(set) var subprojects: [ProjectRuntimeSubproject] = []

    init(service: ProjectRuntimeService) {
        self.service = service
        _javaRuntimes = Published(initialValue: service.javaRuntimes)
        _mavenRuntimes = Published(initialValue: service.mavenRuntimes)
        _javaEnvironmentReport = Published(initialValue: service.javaEnvironmentReport)
        _isDiscovering = Published(initialValue: service.isDiscovering)
        _settings = Published(initialValue: service.settings)
        observation = service.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.javaRuntimes = self.service.javaRuntimes
            self.mavenRuntimes = self.service.mavenRuntimes
            self.javaEnvironmentReport = self.service.javaEnvironmentReport
            self.isDiscovering = self.service.isDiscovering
            self.settingsError = self.service.settingsError
        }
    }

    func openProject(at url: URL) {
        service.openProject(at: url)
        settings = service.settings
        baseline = settings
        draftSnapshot = nil
        isSaving = false
        settingsError = service.settingsError
    }
    func closeProject() {
        service.closeProject()
        subprojects = []
        settings = ProjectRuntimeSettings()
        baseline = settings
        draftSnapshot = nil
        isSaving = false
        settingsError = nil
    }
    func refreshAvailableRuntimes() async { await service.refreshAvailableRuntimes() }
    func ensureRuntimesDiscovered() async { await service.ensureRuntimesDiscovered() }
    func activeJavaRuntime() -> JavaRuntimeCandidate? { service.activeJavaRuntime() }
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate] {
        service.executableCandidates(command)
    }
    func toolGuidance(_ command: String) -> RuntimeToolGuidance {
        service.toolGuidance(command)
    }

    // Settings shows what a launch would use through the launch's own selection
    // chains. Detection uses the runtimes already discovered in the background;
    // `nil` means that discovery has not finished yet.

    func javaChoice(overridePath: String?) -> RuntimeChoice? {
        service.chooseJavaHome(overridePath: overridePath, detected: detectedJavaRuntimes)
    }

    func mavenJavaChoice(overridePath: String?) -> RuntimeChoice? {
        service.chooseMavenJavaHome(overridePath: overridePath, detected: detectedJavaRuntimes)
    }

    func mavenChoice(at rootURL: URL, overridePath: String?) -> RuntimeChoice {
        service.chooseMavenExecutable(at: rootURL, overridePath: overridePath)
    }

    func javaRuntimeName(at url: URL) -> String? {
        javaRuntimes.first { $0.homePath == url.path }?.displayName
    }

    func mavenRuntimeName(at url: URL) -> String? {
        mavenRuntimes.first { $0.executablePath == url.path }?.displayName
    }

    private func detectedJavaRuntimes() -> [JavaRuntimeCandidate]? {
        service.hasDiscoveredRuntimes ? service.javaRuntimes : nil
    }

    func prepare(
        workspaceName: String,
        workspaceURL: URL?,
        files: [URL],
        buildSources: [ProjectRuntimeInventory.BuildSource] = [],
        languageSupports: [LanguageSupportDeclaration] = [],
        mavenSettingsPath: String?,
        mavenLocalRepositoryPath: String?
    ) {
        guard !isSaving else { return }
        guard let workspaceURL else {
            subprojects = []
            return
        }
        service.reloadSettings()
        subprojects = ProjectRuntimeInventory.subprojects(
            workspaceName: workspaceName,
            workspaceURL: workspaceURL,
            files: files,
            buildSources: buildSources,
            languageSupports: languageSupports
        )
        settings = service.settings
        // Maven's legacy override owner is still separate during stage D.
        // Do not copy these values to runtime preferences when opening a page.
        settings.mavenSettingsPath = mavenSettingsPath ?? ""
        settings.mavenLocalRepositoryPath = mavenLocalRepositoryPath ?? ""
        baseline = settings
        draftSnapshot = service.settingsSnapshot
        settingsError = service.settingsError
    }

    @discardableResult
    func saveSettings() -> Bool {
        guard !isSaving else {
            settingsError = L10n.string("Project environment settings are being saved. Wait before saving again.")
            return false
        }
        isSaving = true
        guard let draftSnapshot, service.updateSettings(settings, expecting: draftSnapshot) else {
            settingsError = service.settingsError
            isSaving = false
            return false
        }
        var saved = service.settings
        saved.mavenSettingsPath = settings.mavenSettingsPath
        saved.mavenLocalRepositoryPath = settings.mavenLocalRepositoryPath
        settings = saved
        self.draftSnapshot = service.settingsSnapshot
        return true
    }

    func finishSaving(error: String? = nil) {
        isSaving = false
        settingsError = error
        if error == nil { baseline = settings }
    }

    func cancelChanges() {
        guard !isSaving else { return }
        guard service.reloadSettings() else {
            settingsError = service.settingsError
            return
        }
        var current = service.settings
        current.mavenSettingsPath = baseline.mavenSettingsPath
        current.mavenLocalRepositoryPath = baseline.mavenLocalRepositoryPath
        settings = current
        baseline = current
        draftSnapshot = service.settingsSnapshot
        settingsError = nil
    }

    func updateSettings(_ mutate: (inout ProjectRuntimeSettings) -> Void) {
        guard !isSaving else { return }
        var next = settings
        mutate(&next)
        settings = next
    }

    func javaRuntimeTitle(for path: String, automaticTitle: String) -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return automaticTitle }
        if let match = javaRuntimes.first(where: { $0.homePath == normalized }) {
            return "\(match.displayName) — \(match.homePath)"
        }
        return normalized
    }

    func mavenRuntimeTitle(for path: String, automaticTitle: String) -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return automaticTitle }
        if let match = mavenRuntimes.first(where: {
            $0.executablePath == normalized || $0.homePath == normalized
        }) {
            return "\(match.displayName) — \(match.homePath)"
        }
        return normalized
    }

    func effectiveJavaHome(for subproject: ProjectRuntimeSubproject) -> String {
        if !subproject.usesJava { return "" }
        if subproject.kind == .projectDefaults {
            return settings.javaHomePath
        }
        return settings.overlay(
            onto: RunOptions(),
            workspaceRelativePath: subproject.relativePath
        ).javaHomePath
    }
}

import Combine
import Foundation
import LitheCoreContracts

/// UI-facing projection for project runtime settings and discovery.
@MainActor
final class RuntimeSettingsFeatureModel: ObservableObject {
    private let service: ProjectRuntimeService
    private var observation: AnyCancellable?

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
            self.settings = self.service.settings
        }
    }

    func openProject(at url: URL) { service.openProject(at: url) }
    func closeProject() {
        service.closeProject()
        subprojects = []
    }
    func refreshAvailableRuntimes() async { await service.refreshAvailableRuntimes() }
    func activeJavaRuntime() -> JavaRuntimeCandidate? { service.activeJavaRuntime() }
    func activeMavenRuntime(for project: MavenProject) -> MavenRuntimeCandidate? {
        service.activeMavenRuntime(for: project)
    }
    func mavenExecutable(for project: MavenProject) -> URL? {
        service.mavenExecutable(for: project)
    }
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate] {
        service.executableCandidates(command)
    }
    func toolGuidance(_ command: String) -> RuntimeToolGuidance {
        service.toolGuidance(command)
    }

    func prepare(
        workspaceName: String,
        workspaceURL: URL?,
        files: [URL],
        mavenProject: MavenProject?,
        toolchain: ProjectToolchainSelection?,
        mavenSettingsPath: String?,
        mavenLocalRepositoryPath: String?,
        mavenExecutablePath: String?,
        mavenJavaHomePath: String?
    ) {
        guard let workspaceURL else {
            subprojects = []
            return
        }
        service.mergeImportedSettings(
            toolchain: toolchain,
            mavenSettingsPath: mavenSettingsPath,
            mavenLocalRepositoryPath: mavenLocalRepositoryPath,
            mavenExecutablePath: mavenExecutablePath,
            mavenJavaHomePath: mavenJavaHomePath
        )
        subprojects = ProjectRuntimeInventory.subprojects(
            workspaceName: workspaceName,
            workspaceURL: workspaceURL,
            files: files,
            mavenProject: mavenProject
        )
        settings = service.settings
    }

    func updateSettings(_ mutate: (inout ProjectRuntimeSettings) -> Void) {
        var next = settings
        mutate(&next)
        service.updateSettings(next)
        settings = service.settings
    }

    var projectToolchainSelection: ProjectToolchainSelection {
        settings.projectToolchainSelection()
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

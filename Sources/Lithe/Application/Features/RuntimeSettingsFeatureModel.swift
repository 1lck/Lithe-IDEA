import Combine
import Foundation

/// UI-facing projection for project runtime settings and discovery.
@MainActor
final class RuntimeSettingsFeatureModel: ObservableObject {
    private let service: ProjectRuntimeService
    private var observation: AnyCancellable?

    @Published private(set) var javaRuntimes: [JavaRuntimeCandidate]
    @Published private(set) var mavenRuntimes: [MavenRuntimeCandidate]
    @Published private(set) var javaEnvironmentReport: JavaEnvironmentReport?
    @Published private(set) var isDiscovering: Bool

    var javaLanguageServerRuntimes: [JavaRuntimeCandidate] {
        service.javaLanguageServerRuntimes
    }

    init(service: ProjectRuntimeService) {
        self.service = service
        _javaRuntimes = Published(initialValue: service.javaRuntimes)
        _mavenRuntimes = Published(initialValue: service.mavenRuntimes)
        _javaEnvironmentReport = Published(initialValue: service.javaEnvironmentReport)
        _isDiscovering = Published(initialValue: service.isDiscovering)
        observation = service.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.javaRuntimes = self.service.javaRuntimes
            self.mavenRuntimes = self.service.mavenRuntimes
            self.javaEnvironmentReport = self.service.javaEnvironmentReport
            self.isDiscovering = self.service.isDiscovering
        }
    }

    func openProject(at url: URL) { service.openProject(at: url) }
    func closeProject() { service.closeProject() }
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
}

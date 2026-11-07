import Foundation

/// UI-facing entry to the project's tool and environment lookup. It carries no
/// tool-specific state: which tools exist and how each is chosen comes from the
/// plugin-defined tool definitions on the generic Environment page.
@MainActor
final class RuntimeSettingsFeatureModel: ObservableObject {
    private let service: ProjectRuntimeService

    init(service: ProjectRuntimeService) {
        self.service = service
    }

    func openProject(at url: URL) { service.openProject(at: url) }
    func closeProject() { service.closeProject() }
    func refreshAvailableRuntimes() async { await service.refreshAvailableRuntimes() }
    func ensureRuntimesDiscovered() async { await service.ensureRuntimesDiscovered() }
}

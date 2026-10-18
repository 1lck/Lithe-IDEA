import Combine
import Foundation
import LitheCoreContracts

/// UI-facing projection of plugin build systems. Views use it instead of
/// `BuildSystemService`, so the service and its process adapters stay out
/// of the view layer.
@MainActor
package final class BuildSystemsFeatureModel: ObservableObject {
    private let service: BuildSystemService
    private var observation: AnyCancellable?

    package init(service: BuildSystemService) {
        self.service = service
        observation = service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    package var entries: [BuildSystemEntry] { service.entries }
    package var isDetecting: Bool { service.isDetecting }
    package var issues: [String] { service.issues }
    package var runState: BuildRunState { service.runState }
    package var runningTitle: String? { service.runningTitle }
    package var output: String { service.output }
    /// Directories of the commands that wrote the current output.
    package var outputRoots: [URL] { service.outputRoots }
    package var diagnostics: [BuildDiagnostic] { service.diagnostics }
    package var testResults: BuildTestResults? { service.testResults }
    package var isRunning: Bool { service.isRunning }
    package var hasActiveWork: Bool { service.hasActiveWork }
    package var hasBuildSystemPlugins: Bool { service.hasBuildSystemPlugins }
    package var workspaceURL: URL? { service.workspaceURL }
    package var languageImport: JavaLanguageImportConfiguration? { service.languageImport }
    package var hasPublishedMavenLanguageImport: Bool { service.hasPublishedMavenLanguageImport }
    package var onLanguageImportChanged: ((URL) -> Void)? {
        get { service.onLanguageImportChanged }
        set { service.onLanguageImportChanged = newValue }
    }

    package func entry(_ id: String) -> BuildSystemEntry? { service.entry(id) }
    package func reset(workspaceURL: URL?) { service.reset(workspaceURL: workspaceURL) }
    package func detect() { service.detect() }
    package func workspaceFilesChanged(_ urls: [URL]) { service.workspaceFilesChanged(urls) }
    package func loadModel(_ entryID: String) { service.loadModel(entryID) }
    package func runTask(_ entryID: String, request: BuildTaskRequest, title: String) {
        service.runTask(entryID, request: request, title: title)
    }
    package func runTests(_ entryID: String, request: BuildTestRequest, title: String) {
        service.runTests(entryID, request: request, title: title)
    }
    package func loadDependencies(_ entryID: String, project: BuildModel.Project?) {
        service.loadDependencies(entryID, project: project)
    }
    package func setOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) {
        service.setOption(entryID, optionID: optionID, value: value)
    }
    package func setInstanceOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) {
        service.setInstanceOption(entryID, optionID: optionID, value: value)
    }
    package func pluginsChanged() { service.pluginsChanged() }
    package func stopRun() { service.stopRun() }
    package func stop() { service.stop() }
    package func clearOutput() { service.clearOutput() }
}

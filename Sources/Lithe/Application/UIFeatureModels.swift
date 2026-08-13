import Combine
import Foundation

/// UI-facing projection for Maven state and commands.
/// The view layer does not depend on MavenService or its process adapter.
@MainActor
final class MavenFeatureModel: ObservableObject {
    private let service: MavenService
    private var observation: AnyCancellable?

    init(service: MavenService) {
        self.service = service
        observation = service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var project: MavenProject? { service.project }
    var isLoadingProject: Bool { service.isLoadingProject }
    var isRunning: Bool { service.isRunning }
    var runningTitle: String? { service.runningTitle }
    var output: String { service.output }
    var issues: [MavenBuildIssue] { service.issues }
    var lastExitCode: Int32? { service.lastExitCode }

    func loadProject(at workspaceURL: URL) async {
        await service.loadProject(at: workspaceURL)
    }

    func run(phase: MavenLifecyclePhase, module: MavenModule?, profiles: Set<String>) {
        service.run(phase: phase, module: module, profiles: profiles)
    }

    func reset() { service.reset() }

    func stop() {
        service.stop()
    }

    func clearOutput() {
        service.clearOutput()
    }

}

/// UI-facing projection for language-neutral run configurations and process sessions.
enum RunConfigurationGenerationIntent: Sendable {
    case identifyOnly
    case run
    case debug
}

@MainActor
final class RunFeatureModel: ObservableObject {
    private let service: RunService
    private var observation: AnyCancellable?
    @Published var isGenerationConfirmationPresented = false
    private(set) var generationIntent: RunConfigurationGenerationIntent = .identifyOnly

    init(service: RunService) {
        self.service = service
        observation = service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var selectedConfigurationID: String {
        get { service.selectedConfigurationID }
        set { service.selectedConfigurationID = newValue }
    }

    var configurations: [RunConfiguration] { service.configurations }
    var selectedConfiguration: RunConfiguration? { service.selectedConfiguration }
    var isLoadingProject: Bool { service.isLoadingProject }
    var isRunning: Bool { service.isRunning }
    var runningTitle: String? { service.runningTitle }
    var output: String { service.output }
    var lastExitCode: Int32? { service.lastExitCode }
    var mavenProfiles: [MavenProfile] { service.mavenProfiles }
    var moduleSessions: [RunSession] { service.moduleSessions }
    var portConflicts: [RunPortConflict] { service.portConflicts }
    var configurationStatus: ProjectRunConfigurationStatus { service.configurationStatus }
    var configurationDiagnostics: [RunConfigurationDiagnostic] { service.configurationDiagnostics }
    var generationState: RunConfigurationGenerationState { service.generationState }
    var recoveryAction: RunConfigurationRecoveryAction { service.recoveryAction }
    var recoveryPath: String? { service.recoveryPath }
    var configurationSaveError: String? { service.configurationSaveError }
    var blockingToolchainDiagnostic: RunConfigurationDiagnostic? {
        service.configurationDiagnostics.first {
            $0.code == "missingToolchain" || $0.code == "toolchainVersionMismatch"
        }
    }
    var sourceSearchRoots: [URL] { service.sourceSearchRoots }

    func options(for configuration: RunConfiguration) -> RunOptions {
        service.options(for: configuration)
    }

    func source(for configuration: RunConfiguration) -> RunConfigurationSource {
        service.source(for: configuration)
    }

    func serviceURL(for configuration: RunConfiguration) -> URL? {
        service.serviceURL(for: configuration)
    }

    @discardableResult
    func updateOptions(
        _ options: RunOptions,
        for configuration: RunConfiguration,
        scope: RunConfigurationSaveScope = .local
    ) -> Bool {
        service.updateOptions(options, for: configuration, scope: scope)
    }

    func resetOptions(for configuration: RunConfiguration) {
        service.resetOptions(for: configuration)
    }

    @discardableResult
    func createConfiguration(_ draft: RunConfigurationDraft) -> Bool {
        service.createConfiguration(draft)
    }

    func runAllServices() {
        service.runAllServices()
    }

    func stopAllServices() {
        service.stopAllServices()
    }

    func startConfiguration(_ configuration: RunConfiguration) {
        service.startConfiguration(configuration)
    }

    func stopModule(_ session: RunSession) {
        service.stopModule(session)
    }

    func restartModule(_ session: RunSession) {
        service.restartModule(session)
    }

    func clearModuleOutput(_ session: RunSession) {
        service.clearModuleOutput(session)
    }

    func clearOutput() {
        service.clearOutput()
    }

    func loadProject(
        at workspaceURL: URL,
        files: [URL],
        mavenProject: MavenProject?
    ) async {
        await service.loadProject(at: workspaceURL, files: files, mavenProject: mavenProject)
    }

    func generateRunConfigurations() async {
        isGenerationConfirmationPresented = false
        await service.generateRunConfigurations()
    }

    func requestRunConfigurationGeneration(intent: RunConfigurationGenerationIntent = .identifyOnly) {
        guard recoveryAction != .upgradeApplication else { return }
        generationIntent = intent
        isGenerationConfirmationPresented = true
    }

    func select(_ configuration: RunConfiguration) { service.select(configuration) }
    func runSelected(currentFileURL: URL?) { service.runSelected(currentFileURL: currentFileURL) }
    func restart() { service.restart() }
    func stop() { service.stop() }
    func reset() { service.reset() }
}

/// Coordinates project-scoped build and run loading without making AppModel
/// own build-system sequencing. Language-specific project loaders can later be
/// added here without changing the workspace/UI composition boundary.
@MainActor
final class ProjectDevelopmentFeatureModel {
    private let mavenFeature: MavenFeatureModel
    private let runFeature: RunFeatureModel

    init(mavenFeature: MavenFeatureModel, runFeature: RunFeatureModel) {
        self.mavenFeature = mavenFeature
        self.runFeature = runFeature
    }

    func loadProject(at workspaceURL: URL, files: [URL]) async {
        // Maven is one build-system Provider, not a workspace prerequisite.
        // Avoid scanning every project as Maven; non-Maven ecosystems should
        // reach the generic run pipeline without paying for Java discovery.
        let hasMavenDescriptor = files.contains { file in
            file.lastPathComponent.lowercased() == "pom.xml"
        }
        if hasMavenDescriptor {
            await mavenFeature.loadProject(at: workspaceURL)
        } else {
            mavenFeature.reset()
        }
        await runFeature.loadProject(
            at: workspaceURL,
            files: files,
            mavenProject: mavenFeature.project
        )
    }
}

typealias JavaRunFeatureModel = RunFeatureModel

/// UI-facing projection for Java debugger state and commands.
@MainActor
final class JavaDebugFeatureModel: ObservableObject {
    private let service: JavaDebugService
    private var observation: AnyCancellable?

    @Published var targetKind: JavaDebugTargetKind {
        didSet {
            guard targetKind != service.targetKind else { return }
            service.targetKind = targetKind
        }
    }

    @Published var remoteHost: String {
        didSet {
            guard remoteHost != service.remoteHost else { return }
            service.remoteHost = remoteHost
        }
    }

    @Published var remotePort: String {
        didSet {
            guard remotePort != service.remotePort else { return }
            service.remotePort = remotePort
        }
    }

    @Published var remoteJavaHomePath: String {
        didSet {
            guard remoteJavaHomePath != service.remoteJavaHomePath else { return }
            service.remoteJavaHomePath = remoteJavaHomePath
        }
    }

    init(service: JavaDebugService) {
        self.service = service
        _targetKind = Published(initialValue: service.targetKind)
        _remoteHost = Published(initialValue: service.remoteHost)
        _remotePort = Published(initialValue: service.remotePort)
        _remoteJavaHomePath = Published(initialValue: service.remoteJavaHomePath)
        observation = service.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            if self.targetKind != self.service.targetKind { self.targetKind = self.service.targetKind }
            if self.remoteHost != self.service.remoteHost { self.remoteHost = self.service.remoteHost }
            if self.remotePort != self.service.remotePort { self.remotePort = self.service.remotePort }
            if self.remoteJavaHomePath != self.service.remoteJavaHomePath {
                self.remoteJavaHomePath = self.service.remoteJavaHomePath
            }
            self.objectWillChange.send()
        }
    }

    var state: JavaDebugSessionState { service.state }
    var output: String { service.output }
    var inspectionTitle: String? { service.inspectionTitle }
    var inspectionOutput: String { service.inspectionOutput }
    var variables: [JavaDebugVariable] { service.variables }
    var threads: [JavaDebugThread] { service.threads }
    var callStack: [JavaDebugStackFrame] { service.callStack }
    var expandingVariableID: String? { service.expandingVariableID }
    var exceptionMessage: String? { service.exceptionMessage }
    var port: Int? { service.port }
    var breakpoints: [JavaDebugBreakpoint] { service.breakpoints }
    var runningTargetTitle: String? { service.runningTargetTitle }
    var isSessionActive: Bool { service.isSessionActive }
    var canControl: Bool { service.canControl }

    func pause() { service.pause() }
    func continueExecution() { service.continueExecution() }
    func stepInto() { service.stepInto() }
    func stepOver() { service.stepOver() }
    func stepOut() { service.stepOut() }
    func inspectThreads() { service.inspectThreads() }
    func inspectStack() { service.inspectStack() }
    func inspectVariables() { service.inspectVariables() }
    func evaluate(_ expression: String) { service.evaluate(expression) }
    func toggleVariable(_ variable: JavaDebugVariable) { service.toggleVariable(variable) }
    func clearOutput() { service.clearOutput() }

    func reset() { service.reset() }
    func start(
        fileURL: URL,
        sourceText: String,
        projectURL: URL?,
        options: RunOptions
    ) { service.start(fileURL: fileURL, sourceText: sourceText, projectURL: projectURL, options: options) }
    func startMaven(
        configuration: RunConfiguration,
        project: MavenProject,
        projectURL: URL,
        options: RunOptions
    ) { service.startMaven(configuration: configuration, project: project, projectURL: projectURL, options: options) }
    func attachRemote() { service.attachRemote() }
    func toggleBreakpoint(fileURL: URL, line: Int, className: String) {
        service.toggleBreakpoint(fileURL: fileURL, line: line, className: className)
    }
    func className(for fileURL: URL, sourceText: String) -> String {
        service.className(for: fileURL, sourceText: sourceText)
    }
    func stop() { service.stop() }
}

/// UI-facing projection for project runtime settings and discovery.
@MainActor
final class RuntimeSettingsFeatureModel: ObservableObject {
    private let service: ProjectRuntimeService
    private var observation: AnyCancellable?

    @Published private(set) var javaRuntimes: [JavaRuntimeCandidate]
    @Published private(set) var mavenRuntimes: [MavenRuntimeCandidate]
    @Published private(set) var javaEnvironmentReport: JavaEnvironmentReport?
    @Published private(set) var isDiscovering: Bool

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

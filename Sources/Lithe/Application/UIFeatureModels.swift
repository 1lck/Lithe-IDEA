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

/// UI-facing projection for Java run configurations and process sessions.
enum RunConfigurationGenerationIntent: Sendable {
    case identifyOnly
    case run
    case debug
}

@MainActor
final class JavaRunFeatureModel: ObservableObject {
    private let service: JavaRunService
    private var observation: AnyCancellable?
    @Published var isGenerationConfirmationPresented = false
    private(set) var generationIntent: RunConfigurationGenerationIntent = .identifyOnly

    init(service: JavaRunService) {
        self.service = service
        observation = service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var selectedConfigurationID: String {
        get { service.selectedConfigurationID }
        set { service.selectedConfigurationID = newValue }
    }

    var configurations: [JavaRunConfiguration] { service.configurations }
    var selectedConfiguration: JavaRunConfiguration? { service.selectedConfiguration }
    var isLoadingProject: Bool { service.isLoadingProject }
    var isRunning: Bool { service.isRunning }
    var runningTitle: String? { service.runningTitle }
    var output: String { service.output }
    var lastExitCode: Int32? { service.lastExitCode }
    var mavenProfiles: [MavenProfile] { service.mavenProfiles }
    var moduleSessions: [JavaRunSession] { service.moduleSessions }
    var portConflicts: [JavaRunPortConflict] { service.portConflicts }
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

    func options(for configuration: JavaRunConfiguration) -> JavaRunOptions {
        service.options(for: configuration)
    }

    func source(for configuration: JavaRunConfiguration) -> RunConfigurationSource {
        service.source(for: configuration)
    }

    @discardableResult
    func updateOptions(
        _ options: JavaRunOptions,
        for configuration: JavaRunConfiguration,
        scope: RunConfigurationSaveScope = .local
    ) -> Bool {
        service.updateOptions(options, for: configuration, scope: scope)
    }

    func resetOptions(for configuration: JavaRunConfiguration) {
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

    func startConfiguration(_ configuration: JavaRunConfiguration) {
        service.startConfiguration(configuration)
    }

    func stopModule(_ session: JavaRunSession) {
        service.stopModule(session)
    }

    func restartModule(_ session: JavaRunSession) {
        service.restartModule(session)
    }

    func clearModuleOutput(_ session: JavaRunSession) {
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

    func select(_ configuration: JavaRunConfiguration) { service.select(configuration) }
    func runSelected(currentFileURL: URL?) { service.runSelected(currentFileURL: currentFileURL) }
    func restart() { service.restart() }
    func stop() { service.stop() }
    func reset() { service.reset() }
}

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
        options: JavaRunOptions
    ) { service.start(fileURL: fileURL, sourceText: sourceText, projectURL: projectURL, options: options) }
    func startMaven(
        configuration: JavaRunConfiguration,
        project: MavenProject,
        projectURL: URL,
        options: JavaRunOptions
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

    @Published private(set) var settings: ProjectRuntimeSettings
    @Published private(set) var javaRuntimes: [JavaRuntimeCandidate]
    @Published private(set) var mavenRuntimes: [MavenRuntimeCandidate]
    @Published private(set) var isDiscovering: Bool

    init(service: ProjectRuntimeService) {
        self.service = service
        _settings = Published(initialValue: service.settings)
        _javaRuntimes = Published(initialValue: service.javaRuntimes)
        _mavenRuntimes = Published(initialValue: service.mavenRuntimes)
        _isDiscovering = Published(initialValue: service.isDiscovering)
        observation = service.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.settings = self.service.settings
            self.javaRuntimes = self.service.javaRuntimes
            self.mavenRuntimes = self.service.mavenRuntimes
            self.isDiscovering = self.service.isDiscovering
        }
    }

    func openProject(at url: URL) { service.openProject(at: url) }
    func closeProject() { service.closeProject() }
    func setOnRuntimeChanged(_ handler: @escaping () -> Void) { service.onRuntimeChanged = handler }

    func updateJavaHomePath(_ path: String) { service.updateJavaHomePath(path) }
    func updateMavenHomeSelection(_ selection: MavenHomeSelection) { service.updateMavenHomeSelection(selection) }
    func updateMavenHomePath(_ path: String) { service.updateMavenHomePath(path) }
    func updateMavenJavaHomePath(_ path: String) { service.updateMavenJavaHomePath(path) }
    func refreshAvailableRuntimes() async { await service.refreshAvailableRuntimes() }
    func activeJavaRuntime() -> JavaRuntimeCandidate? { service.activeJavaRuntime() }
    func activeMavenRuntime(for project: MavenProject) -> MavenRuntimeCandidate? {
        service.activeMavenRuntime(for: project)
    }
    func mavenExecutable(for project: MavenProject) -> URL? {
        service.mavenExecutable(for: project)
    }
}

import Combine
import Foundation
import LitheDebugModule

/// UI-facing projection for Java debugger state and commands.
@MainActor
final class JavaDebugFeatureModel: ObservableObject, JavaDebugFeatureTarget {
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
        options: RunOptions,
        mavenContext: MavenLaunchContext?
    ) {
        service.startMaven(
            configuration: configuration,
            project: project,
            projectURL: projectURL,
            options: options,
            mavenContext: mavenContext
        )
    }
    func attachRemote() { service.attachRemote() }
    func toggleBreakpoint(fileURL: URL, line: Int, className: String) {
        service.toggleBreakpoint(fileURL: fileURL, line: line, className: className)
    }
    func className(for fileURL: URL, sourceText: String) -> String {
        service.className(for: fileURL, sourceText: sourceText)
    }
    func stop() { service.stop() }
}

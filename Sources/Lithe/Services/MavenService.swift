import Foundation

@MainActor
final class MavenService: ObservableObject {
    @Published private(set) var project: MavenProject?
    @Published private(set) var isLoadingProject = false
    @Published private(set) var isRunning = false
    @Published private(set) var runningTitle: String?
    @Published private(set) var output = ""
    @Published private(set) var issues: [MavenBuildIssue] = []
    @Published private(set) var lastExitCode: Int32?

    private let process: any StreamingProcess
    private let javaMavenOperations: any JavaMavenOperations
    private var projectLoadID = UUID()
    private let maximumOutputCharacters = 500_000
    private let runtimeService: ProjectRuntimeService
    private var activeOperationID: String?

    init(
        runtimeService: ProjectRuntimeService,
        process: any StreamingProcess,
        javaMavenOperations: any JavaMavenOperations
    ) {
        self.runtimeService = runtimeService
        self.process = process
        self.javaMavenOperations = javaMavenOperations
        process.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.append(chunk)
            }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.finishProcess(exitCode: exitCode)
            }
        }
        process.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeLifecycle(event)
            }
        }
    }

    func loadProject(at workspaceURL: URL) async {
        let loadID = UUID()
        projectLoadID = loadID
        isLoadingProject = true
        let rootURL = workspaceURL.standardizedFileURL
        let javaMavenOperations = javaMavenOperations
        let scannedProject = await Task.detached(priority: .utility) {
            javaMavenOperations.scanMavenProject(at: rootURL)
        }.value
        guard !Task.isCancelled, projectLoadID == loadID else { return }
        project = scannedProject
        isLoadingProject = false
    }

    func run(
        phase: MavenLifecyclePhase,
        module: MavenModule?,
        profiles: Set<String>
    ) {
        guard project != nil else { return }
        stop()
        resetOutput()
        var arguments = baseArguments(profiles: profiles)
        if let module {
            arguments += ["-pl", module.relativePath, "-am"]
        }
        arguments.append(phase.rawValue)
        startProcess(arguments: arguments, title: taskTitle(phase: phase, module: module))
    }

    func stop() {
        process.stop()
        isRunning = false
        runningTitle = nil
        activeOperationID = nil
    }

    func reset() {
        stop()
        projectLoadID = UUID()
        project = nil
        isLoadingProject = false
        output = ""
        issues = []
        lastExitCode = nil
    }

    func clearOutput() {
        output = ""
        issues = []
        lastExitCode = nil
    }

    // MARK: - 进程执行

    private func baseArguments(profiles: Set<String>) -> [String] {
        var arguments = ["-B", "-ntp"]
        if !profiles.isEmpty {
            arguments += ["-P", profiles.sorted().joined(separator: ",")]
        }
        return arguments
    }

    private func resetOutput() {
        output = ""
        issues = []
        lastExitCode = nil
    }

    private func startProcess(arguments: [String], title: String) {
        guard let project else { return }
        guard let executable = runtimeService.mavenExecutable(for: project) else {
            output = "No Maven executable was found. Edit the Maven service configuration.\n"
            lastExitCode = 1
            return
        }
        isRunning = true
        runningTitle = title
        append("$ " + executable.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n")

        let operationID = UUID().uuidString
        activeOperationID = operationID
        do {
            try process.start(ProcessRequest(
                operationID: operationID,
                executablePath: executable.path,
                arguments: arguments,
                workingDirectory: project.rootURL.path,
                environment: runtimeService.environment(for: .maven)
            ))
        } catch {
            append("Unable to start Maven: " + error.localizedDescription + "\n")
            isRunning = false
            runningTitle = nil
            lastExitCode = 1
            issues = [MavenBuildIssue(
                id: "start-error",
                fileURL: nil,
                line: nil,
                column: nil,
                severity: .error,
                message: error.localizedDescription
            )]
        }
    }

    private func finishProcess(exitCode: Int32) {
        guard let project else { return }
        isRunning = false
        runningTitle = nil
        lastExitCode = exitCode
        issues = javaMavenOperations.mavenDiagnostics(output: output, projectRoot: project.rootURL)
        activeOperationID = nil
    }

    private func consumeLifecycle(_ event: ProcessLifecycleEvent) {
        guard event.operationID == activeOperationID else { return }
        switch event.state {
        case .starting, .running:
            isRunning = true
        case .stopping:
            isRunning = false
        case .failed:
            isRunning = false
            runningTitle = nil
            if let message = event.message, !message.isEmpty {
                append("Unable to run Maven: " + message + "\n")
            }
        case .finished:
            break
        }
    }

    private func append(_ value: String) {
        output.append(value.replacingOccurrences(of: "\r", with: ""))
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }

    private func taskTitle(phase: MavenLifecyclePhase, module: MavenModule?) -> String {
        let target = module?.displayName ?? project?.displayName ?? "Project"
        return phase.title + " · " + target
    }

}

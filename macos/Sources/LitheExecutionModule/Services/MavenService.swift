import Combine
import Foundation
import LitheCoreContracts

@MainActor
package final class MavenService: ObservableObject {
    @Published package private(set) var project: MavenProject?
    @Published package private(set) var projectState: MavenProjectLoadState = .idle
    @Published package private(set) var taskState: MavenTaskState = .idle
    @Published package private(set) var runningTitle: String?
    @Published package private(set) var output = ""
    @Published package private(set) var issues: [MavenBuildIssue] = []
    @Published package private(set) var lastExitCode: Int32?
    @Published package private(set) var selectedProfiles: Set<String> = []
    @Published package private(set) var customProfiles: [String] = []
    @Published package private(set) var skipTests = false
    @Published package private(set) var settingsPath: String?
    @Published package private(set) var mavenExecutablePath: String?
    @Published package private(set) var javaHomePath: String?
    @Published package private(set) var configurationSaveError: String?
    @Published package private(set) var isReloadRequired = false
    @Published package private(set) var dependencyStates: [String: MavenDependencyLoadState] = [:]

    package var isLoadingProject: Bool {
        if case .loading = projectState { return true }
        return false
    }

    package var isRunning: Bool {
        switch taskState {
        case .running, .stopping: true
        case .idle, .cancelled, .failed: false
        }
    }

    package var isResolvingDependencies: Bool {
        dependencyStates.values.contains { state in
            if case .loading = state { return true }
            return false
        }
    }

    package var availableProfiles: [MavenProfile] {
        var seen = Set<String>()
        let discovered = project?.profiles.filter { seen.insert($0.id).inserted } ?? []
        let custom = customProfiles.compactMap { id -> MavenProfile? in
            guard seen.insert(id).inserted else { return nil }
            return MavenProfile(id: id, isActiveByDefault: false)
        }
        return discovered + custom
    }

    package var launchContext: MavenLaunchContext? {
        guard let reactorPath else { return nil }
        return MavenLaunchContext(
            reactorPath: reactorPath,
            profiles: selectedProfiles.sorted(),
            settingsPath: settingsPath,
            skipTests: skipTests,
            mavenExecutablePath: mavenExecutablePath,
            javaHomePath: javaHomePath
        )
    }

    private let process: any StreamingProcess
    private let dependencyProcess: any StreamingProcess
    private let mavenOperations: any MavenProjectOperations
    private let runtimeService: any MavenRuntimePort
    private let configurationWriter: MavenConfigurationWriter
    private var workspaceURL: URL?
    private var reactorPath: String?
    private var projectLoadID = UUID()
    private var launchPlanID = UUID()
    private var activeOperationID: String?
    private var dependencyLoadID = UUID()
    private var activeDependencyOperationID: String?
    private var activeDependencyModulePath: String?
    private var dependencyOutput = ""
    private var dependencyTimedOut = false
    private var configurationRevision = 0
    private var configurationFingerprint: String?
    private var fingerprintRevision = 0
    private let maximumOutputCharacters = 500_000
    private let maximumDependencyOutputCharacters = 500_000
    private let dependencyTimeoutMilliseconds = 60_000

    package init(
        runtimeService: any MavenRuntimePort,
        process: any StreamingProcess,
        dependencyProcess: any StreamingProcess,
        mavenOperations: any MavenProjectOperations,
        configurationStore: (any MavenConfigurationStoring)? = nil
    ) {
        self.runtimeService = runtimeService
        self.process = process
        self.dependencyProcess = dependencyProcess
        self.mavenOperations = mavenOperations
        configurationWriter = MavenConfigurationWriter(store: configurationStore)
        process.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                guard self?.activeOperationID != nil else { return }
                self?.append(chunk)
            }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                guard self?.activeOperationID != nil else { return }
                self?.finishProcess(exitCode: exitCode)
            }
        }
        process.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeLifecycle(event)
            }
        }
        dependencyProcess.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                guard self?.activeDependencyOperationID != nil else { return }
                self?.appendDependencyOutput(chunk)
            }
        }
        dependencyProcess.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                guard self?.activeDependencyOperationID != nil else { return }
                self?.finishDependencyProcess(exitCode: exitCode)
            }
        }
        dependencyProcess.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeDependencyLifecycle(event)
            }
        }
    }

    package func loadProject(at workspaceURL: URL, files: [URL]) async {
        invalidateDependencies()
        let loadID = UUID()
        projectLoadID = loadID
        projectState = .loading
        let rootURL = workspaceURL.standardizedFileURL
        let mavenOperations = mavenOperations
        let configurationWriter = configurationWriter
        let result = await Task.detached(priority: .utility) {
            do {
                let project = try mavenOperations.scanMavenProject(at: rootURL, files: files)
                let reactorPath = project.map { Self.relativePath(from: rootURL, to: $0.rootURL) }
                let stored: MavenStoredConfiguration?
                if let reactorPath {
                    stored = try await configurationWriter.load(
                        workspaceURL: rootURL,
                        reactorPath: reactorPath
                    )
                } else {
                    stored = nil
                }
                return MavenProjectLoadResult(
                    project: project,
                    reactorPath: reactorPath,
                    stored: stored,
                    errorMessage: nil
                )
            } catch {
                return MavenProjectLoadResult(
                    project: nil,
                    reactorPath: nil,
                    stored: nil,
                    errorMessage: error.localizedDescription
                )
            }
        }.value
        guard !Task.isCancelled, projectLoadID == loadID else { return }

        guard let errorMessage = result.errorMessage else {
            self.workspaceURL = rootURL
            reactorPath = result.reactorPath
            project = result.project
            applyStoredConfiguration(result.stored, project: result.project)
            if let context = launchContext {
                let fingerprint = await Task.detached(priority: .utility) {
                    try? mavenOperations.mavenLaunchPlan(
                        at: rootURL,
                        context: context,
                        module: nil,
                        goals: [MavenLifecyclePhase.validate.rawValue]
                    ).configurationFingerprint
                }.value
                guard !Task.isCancelled, projectLoadID == loadID else { return }
                configurationFingerprint = fingerprint
            } else {
                configurationFingerprint = nil
            }
            projectState = .ready
            configurationSaveError = nil
            isReloadRequired = false
            return
        }
        project = nil
        self.workspaceURL = nil
        reactorPath = nil
        projectState = .failed(errorMessage)
    }

    package func run(phase: MavenLifecyclePhase, module: MavenModule?) {
        run(goals: [phase.rawValue], module: module, title: taskTitle(name: phase.title, module: module))
    }

    package func runCustomGoal(_ value: String, module: MavenModule?) {
        let goals = value.split(whereSeparator: \.isWhitespace).map(String.init)
        run(goals: goals, module: module, title: taskTitle(name: value, module: module))
    }

    package func setSelectedProfiles(_ profiles: Set<String>) {
        let knownProfiles = Set(availableProfiles.map(\.id))
        let normalized = Set(profiles.filter { knownProfiles.contains($0) })
        guard normalized != selectedProfiles else { return }
        selectedProfiles = normalized
        configurationDidChange()
    }

    @discardableResult
    package func addCustomProfile(_ value: String) -> Bool {
        let profile = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProfile(profile) else { return false }
        if !customProfiles.contains(profile), project?.profiles.contains(where: { $0.id == profile }) != true {
            customProfiles.append(profile)
            customProfiles.sort()
        }
        selectedProfiles.insert(profile)
        configurationDidChange()
        return true
    }

    package func restoreDefaultProfiles() {
        let defaults = Set(project?.profiles.filter(\.isActiveByDefault).map(\.id) ?? [])
        guard selectedProfiles != defaults else { return }
        selectedProfiles = defaults
        configurationDidChange()
    }

    package func setSkipTests(_ enabled: Bool) {
        guard skipTests != enabled else { return }
        skipTests = enabled
        configurationDidChange()
    }

    package func updateLocalConfiguration(
        settingsPath: String?,
        mavenExecutablePath: String?,
        javaHomePath: String?
    ) {
        let settings = normalizedLocalPath(settingsPath)
        let executable = normalizedLocalPath(mavenExecutablePath)
        let javaHome = normalizedLocalPath(javaHomePath)
        guard settings != self.settingsPath
                || executable != self.mavenExecutablePath
                || javaHome != self.javaHomePath else { return }
        self.settingsPath = settings
        self.mavenExecutablePath = executable
        self.javaHomePath = javaHome
        configurationDidChange()
    }

    package func acknowledgeReload() {
        isReloadRequired = false
        refreshConfigurationFingerprint(establishBaseline: true)
    }

    package func dependencyState(for modulePath: String) -> MavenDependencyLoadState {
        dependencyStates[modulePath] ?? .idle
    }

    package func loadDependencies(for modulePath: String) {
        if case .ready = dependencyState(for: modulePath) { return }
        if activeDependencyModulePath == modulePath,
           case .loading = dependencyState(for: modulePath) { return }
        guard let project, let workspaceURL, let context = launchContext else { return }

        cancelActiveDependency(markCancelled: true)
        let loadID = UUID()
        dependencyLoadID = loadID
        activeDependencyModulePath = modulePath
        activeDependencyOperationID = nil
        dependencyOutput = ""
        dependencyTimedOut = false
        dependencyStates[modulePath] = .loading
        let operations = mavenOperations
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return MavenPlanResult(
                        plan: try operations.mavenDependencyPlan(
                            at: workspaceURL,
                            context: context,
                            module: modulePath == "." ? nil : modulePath
                        ),
                        errorMessage: nil
                    )
                } catch {
                    return MavenPlanResult(plan: nil, errorMessage: error.localizedDescription)
                }
            }.value
            guard let self,
                  self.dependencyLoadID == loadID,
                  self.activeDependencyModulePath == modulePath else { return }
            guard let plan = result.plan else {
                self.failDependency(
                    modulePath: modulePath,
                    message: result.errorMessage ?? "Unable to create the Maven dependency plan."
                )
                return
            }
            self.startDependencyProcess(
                plan: plan,
                project: project,
                context: context,
                modulePath: modulePath
            )
        }
    }

    package func cancelDependencies(for modulePath: String) {
        guard case .loading = dependencyState(for: modulePath) else { return }
        guard activeDependencyModulePath == modulePath else {
            dependencyStates[modulePath] = .cancelled
            return
        }
        cancelActiveDependency(markCancelled: true)
    }

    package func cancelAllDependencies() {
        cancelActiveDependency(markCancelled: true)
    }

    package func stop() {
        launchPlanID = UUID()
        cancelActiveDependency(markCancelled: true)
        guard isRunning else { return }
        taskState = .stopping
        if activeOperationID != nil {
            process.stop()
        }
        activeOperationID = nil
        runningTitle = nil
        lastExitCode = nil
        taskState = .cancelled
        if !output.isEmpty, !output.hasSuffix("\n") {
            append("\n")
        }
        append("Maven task cancelled.\n")
    }

    package func reset() {
        stop()
        invalidateDependencies()
        projectLoadID = UUID()
        launchPlanID = UUID()
        project = nil
        workspaceURL = nil
        reactorPath = nil
        projectState = .idle
        taskState = .idle
        runningTitle = nil
        output = ""
        issues = []
        lastExitCode = nil
        selectedProfiles = []
        customProfiles = []
        skipTests = false
        settingsPath = nil
        mavenExecutablePath = nil
        javaHomePath = nil
        configurationFingerprint = nil
        fingerprintRevision += 1
        configurationSaveError = nil
        isReloadRequired = false
        dependencyStates = [:]
    }

    package func clearOutput() {
        output = ""
        issues = []
        lastExitCode = nil
        if taskState == .cancelled {
            taskState = .idle
        }
    }

    private func run(goals: [String], module: MavenModule?, title: String) {
        guard let project, let workspaceURL, let reactorPath else { return }
        stop()
        resetOutput()
        let planID = UUID()
        launchPlanID = planID
        runningTitle = title
        taskState = .running
        let context = MavenLaunchContext(
            reactorPath: reactorPath,
            profiles: selectedProfiles.sorted(),
            settingsPath: settingsPath,
            skipTests: skipTests,
            mavenExecutablePath: mavenExecutablePath,
            javaHomePath: javaHomePath
        )
        let operations = mavenOperations
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return MavenPlanResult(
                        plan: try operations.mavenLaunchPlan(
                            at: workspaceURL,
                            context: context,
                            module: module?.relativePath,
                            goals: goals
                        ),
                        errorMessage: nil
                    )
                } catch {
                    return MavenPlanResult(
                        plan: nil,
                        errorMessage: error.localizedDescription
                    )
                }
            }.value
            guard let self, self.launchPlanID == planID else { return }
            if let plan = result.plan {
                self.startProcess(plan: plan, project: project, context: context, title: title)
            } else {
                self.failTask(message: result.errorMessage ?? "Unable to create the Maven launch plan.")
            }
        }
    }

    private func startProcess(
        plan: MavenLaunchPlan,
        project: MavenProject,
        context: MavenLaunchContext,
        title: String
    ) {
        guard let workspaceURL else { return }
        guard let executable = runtimeService.mavenExecutable(
            for: project,
            overridePath: context.mavenExecutablePath
        ) else {
            failTask(message: "No Maven executable was found. Choose Maven Home or an executable in Maven Settings.")
            return
        }
        runningTitle = title
        taskState = .running
        recordConfigurationFingerprint(plan.configurationFingerprint)
        append(
            "$ " + executable.lastPathComponent + " "
                + redactedMavenArgumentsForDisplay(plan.arguments).joined(separator: " ") + "\n\n"
        )

        let operationID = UUID().uuidString
        activeOperationID = operationID
        let workingDirectory = plan.workingDirectory == "."
            ? workspaceURL
            : workspaceURL.appendingPathComponent(plan.workingDirectory, isDirectory: true)
        do {
            try process.start(ProcessRequest(
                operationID: operationID,
                executablePath: executable.path,
                arguments: plan.arguments,
                workingDirectory: workingDirectory.standardizedFileURL.path,
                environment: runtimeService.mavenProcessEnvironment(javaHomePath: context.javaHomePath)
            ))
        } catch {
            guard activeOperationID == operationID else { return }
            activeOperationID = nil
            failTask(message: "Unable to start Maven: " + error.localizedDescription)
        }
    }

    private func startDependencyProcess(
        plan: MavenLaunchPlan,
        project: MavenProject,
        context: MavenLaunchContext,
        modulePath: String
    ) {
        guard let workspaceURL else { return }
        guard let executable = runtimeService.mavenExecutable(
            for: project,
            overridePath: context.mavenExecutablePath
        ) else {
            failDependency(
                modulePath: modulePath,
                message: "No Maven executable was found. Choose Maven Home or an executable in Maven Settings."
            )
            return
        }
        let operationID = UUID().uuidString
        activeDependencyOperationID = operationID
        let workingDirectory = plan.workingDirectory == "."
            ? workspaceURL
            : workspaceURL.appendingPathComponent(plan.workingDirectory, isDirectory: true)
        do {
            try dependencyProcess.start(ProcessRequest(
                operationID: operationID,
                executablePath: executable.path,
                arguments: plan.arguments,
                workingDirectory: workingDirectory.standardizedFileURL.path,
                environment: runtimeService.mavenProcessEnvironment(javaHomePath: context.javaHomePath),
                timeoutMilliseconds: dependencyTimeoutMilliseconds
            ))
        } catch {
            guard activeDependencyOperationID == operationID else { return }
            failDependency(
                modulePath: modulePath,
                message: "Unable to start Maven dependency resolution: " + error.localizedDescription
            )
        }
    }

    private func finishDependencyProcess(exitCode: Int32) {
        guard let modulePath = activeDependencyModulePath else { return }
        let loadID = dependencyLoadID
        let output = dependencyOutput
        let timedOut = dependencyTimedOut
        activeDependencyOperationID = nil
        dependencyTimedOut = false
        if timedOut {
            failDependency(
                modulePath: modulePath,
                message: "Maven dependency resolution timed out after 60 seconds."
            )
            return
        }
        guard exitCode == 0 else {
            failDependency(
                modulePath: modulePath,
                message: "Maven dependency resolution exited with code \(exitCode)."
            )
            return
        }
        let operations = mavenOperations
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return MavenDependencyParseResult(
                        tree: try operations.mavenDependencies(modulePath: modulePath, output: output),
                        errorMessage: nil
                    )
                } catch {
                    return MavenDependencyParseResult(
                        tree: nil,
                        errorMessage: error.localizedDescription
                    )
                }
            }.value
            guard let self,
                  self.dependencyLoadID == loadID,
                  self.activeDependencyModulePath == modulePath,
                  case .loading = self.dependencyState(for: modulePath) else { return }
            self.activeDependencyModulePath = nil
            self.dependencyOutput = ""
            if let tree = result.tree {
                self.dependencyStates[modulePath] = .ready(tree.dependencies)
            } else {
                self.dependencyStates[modulePath] = .failed(
                    result.errorMessage ?? "Unable to parse Maven dependencies for this module."
                )
            }
        }
    }

    private func consumeDependencyLifecycle(_ event: ProcessLifecycleEvent) {
        guard event.operationID == activeDependencyOperationID else { return }
        switch event.state {
        case .starting, .running:
            break
        case .stopping:
            if event.message == "Process timed out" {
                dependencyTimedOut = true
            }
        case .failed:
            guard let modulePath = activeDependencyModulePath else { return }
            failDependency(
                modulePath: modulePath,
                message: event.message ?? "Unable to resolve Maven dependencies."
            )
        case .finished:
            if let exitCode = event.exitCode {
                finishDependencyProcess(exitCode: exitCode)
            }
        }
    }

    private func appendDependencyOutput(_ value: String) {
        guard let modulePath = activeDependencyModulePath else { return }
        dependencyOutput.append(value.replacingOccurrences(of: "\r", with: ""))
        guard dependencyOutput.count <= maximumDependencyOutputCharacters else {
            dependencyProcess.stop()
            failDependency(
                modulePath: modulePath,
                message: "Maven dependency output exceeded the supported limit."
            )
            return
        }
    }

    private func failDependency(modulePath: String, message: String) {
        dependencyStates[modulePath] = .failed(message)
        activeDependencyOperationID = nil
        activeDependencyModulePath = nil
        dependencyOutput = ""
        dependencyTimedOut = false
    }

    private func cancelActiveDependency(markCancelled: Bool) {
        dependencyLoadID = UUID()
        let modulePath = activeDependencyModulePath
        if activeDependencyOperationID != nil {
            dependencyProcess.stop()
        }
        activeDependencyOperationID = nil
        activeDependencyModulePath = nil
        dependencyOutput = ""
        dependencyTimedOut = false
        if markCancelled, let modulePath {
            dependencyStates[modulePath] = .cancelled
        }
    }

    private func invalidateDependencies() {
        cancelActiveDependency(markCancelled: false)
        dependencyStates = [:]
    }

    private func finishProcess(exitCode: Int32) {
        guard let project else { return }
        if taskState == .stopping {
            activeOperationID = nil
            runningTitle = nil
            lastExitCode = nil
            taskState = .cancelled
            append("Maven task cancelled.\n")
            return
        }
        taskState = exitCode == 0 ? .idle : .failed("Maven exited with code \(exitCode).")
        runningTitle = nil
        lastExitCode = exitCode
        issues = mavenOperations.mavenDiagnostics(output: output, projectRoot: project.rootURL)
        activeOperationID = nil
    }

    private func consumeLifecycle(_ event: ProcessLifecycleEvent) {
        guard event.operationID == activeOperationID else { return }
        switch event.state {
        case .starting, .running:
            taskState = .running
        case .stopping:
            taskState = .stopping
        case .failed:
            activeOperationID = nil
            failTask(message: event.message ?? "Unable to run Maven.")
        case .finished:
            if let exitCode = event.exitCode {
                finishProcess(exitCode: exitCode)
            }
        }
    }

    private func failTask(message: String) {
        append(message + (message.hasSuffix("\n") ? "" : "\n"))
        taskState = .failed(message)
        runningTitle = nil
        lastExitCode = 1
        issues = [MavenBuildIssue(
            id: "maven-error-" + UUID().uuidString,
            fileURL: nil,
            line: nil,
            column: nil,
            severity: .error,
            message: message
        )]
    }

    private func applyStoredConfiguration(
        _ stored: MavenStoredConfiguration?,
        project: MavenProject?
    ) {
        let defaults = project?.profiles.filter(\.isActiveByDefault).map(\.id) ?? []
        let portable = stored?.portable
        selectedProfiles = Set(portable?.selectedProfiles ?? defaults)
        customProfiles = normalizedProfiles(portable?.customProfiles ?? [])
        skipTests = portable?.skipTests ?? false
        settingsPath = normalizedLocalPath(stored?.local?.settingsPath)
        mavenExecutablePath = normalizedLocalPath(stored?.local?.mavenExecutablePath)
        javaHomePath = normalizedLocalPath(stored?.local?.javaHomePath)
    }

    private func configurationDidChange() {
        invalidateDependencies()
        isReloadRequired = configurationFingerprint != nil
        configurationSaveError = nil
        persistConfiguration()
        refreshConfigurationFingerprint()
    }

    private func refreshConfigurationFingerprint(establishBaseline: Bool = false) {
        guard let workspaceURL, let context = launchContext else { return }
        fingerprintRevision += 1
        let revision = fingerprintRevision
        let operations = mavenOperations
        Task { [weak self] in
            let fingerprint = await Task.detached(priority: .utility) {
                try? operations.mavenLaunchPlan(
                    at: workspaceURL,
                    context: context,
                    module: nil,
                    goals: [MavenLifecyclePhase.validate.rawValue]
                ).configurationFingerprint
            }.value
            guard let self, self.fingerprintRevision == revision, let fingerprint else { return }
            if establishBaseline || self.configurationFingerprint == nil {
                self.configurationFingerprint = fingerprint
                self.isReloadRequired = false
            } else {
                self.isReloadRequired = self.configurationFingerprint != fingerprint
            }
        }
    }

    private func recordConfigurationFingerprint(_ fingerprint: String) {
        if let configurationFingerprint {
            isReloadRequired = configurationFingerprint != fingerprint
        } else {
            configurationFingerprint = fingerprint
            isReloadRequired = false
        }
    }

    private func persistConfiguration() {
        guard let workspaceURL, let reactorPath else { return }
        configurationRevision += 1
        let revision = configurationRevision
        let stored = MavenStoredConfiguration(
            portable: MavenPortableConfiguration(
                selectedProfiles: selectedProfiles.sorted(),
                customProfiles: normalizedProfiles(customProfiles),
                skipTests: skipTests
            ),
            local: MavenLocalConfiguration(
                settingsPath: settingsPath,
                mavenExecutablePath: mavenExecutablePath,
                javaHomePath: javaHomePath
            )
        )
        let writer = configurationWriter
        Task { [weak self] in
            let errorMessage = await writer.save(
                revision: revision,
                configuration: stored,
                workspaceURL: workspaceURL,
                reactorPath: reactorPath
            )
            guard let self, self.configurationRevision == revision else { return }
            self.configurationSaveError = errorMessage
        }
    }

    private func resetOutput() {
        output = ""
        issues = []
        lastExitCode = nil
    }

    private func append(_ value: String) {
        output.append(value.replacingOccurrences(of: "\r", with: ""))
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }

    private func taskTitle(name: String, module: MavenModule?) -> String {
        let target = module?.displayName ?? project?.displayName ?? "Project"
        return name + " · " + target
    }

    private func isValidProfile(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains(",")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func normalizedProfiles(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isValidProfile)))
            .sorted()
    }

    private func normalizedLocalPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
    }

    nonisolated private static func relativePath(from rootURL: URL, to childURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let child = childURL.standardizedFileURL.path
        if root == child { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard child.hasPrefix(prefix) else { return "." }
        return String(child.dropFirst(prefix.count))
    }
}

private struct MavenProjectLoadResult: Sendable {
    let project: MavenProject?
    let reactorPath: String?
    let stored: MavenStoredConfiguration?
    let errorMessage: String?
}

private struct MavenPlanResult: Sendable {
    let plan: MavenLaunchPlan?
    let errorMessage: String?
}

private struct MavenDependencyParseResult: Sendable {
    let tree: MavenDependencyTree?
    let errorMessage: String?
}

private actor MavenConfigurationWriter {
    private let store: (any MavenConfigurationStoring)?
    private var latestRevision = 0

    init(store: (any MavenConfigurationStoring)?) {
        self.store = store
    }

    func load(
        workspaceURL: URL,
        reactorPath: String
    ) throws -> MavenStoredConfiguration {
        try store?.loadMavenConfiguration(
            workspaceURL: workspaceURL,
            reactorPath: reactorPath
        ) ?? MavenStoredConfiguration(portable: nil, local: nil)
    }

    func save(
        revision: Int,
        configuration: MavenStoredConfiguration,
        workspaceURL: URL,
        reactorPath: String
    ) -> String? {
        guard revision > latestRevision else { return nil }
        latestRevision = revision
        do {
            try store?.saveMavenConfiguration(
                configuration,
                workspaceURL: workspaceURL,
                reactorPath: reactorPath
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

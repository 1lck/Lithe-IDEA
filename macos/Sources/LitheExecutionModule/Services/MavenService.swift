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
    @Published package private(set) var localRepositoryPath: String?
    @Published package private(set) var mavenExecutablePath: String?
    @Published package private(set) var javaHomePath: String?
    @Published package private(set) var configurationSaveError: String?
    @Published package private(set) var isReloadRequired = false

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
            localRepositoryPath: localRepositoryPath,
            skipTests: skipTests,
            mavenExecutablePath: mavenExecutablePath,
            javaHomePath: javaHomePath
        )
    }

    private let process: any StreamingProcess
    private let mavenOperations: any MavenProjectOperations
    private let runtimeService: any MavenRuntimePort
    private let configurationWriter: MavenConfigurationWriter
    private var workspaceURL: URL?
    private var reactorPath: String?
    private var projectLoadID = UUID()
    private var launchPlanID = UUID()
    private var activeOperationID: String?
    private var configurationRevision = 0
    private var configurationFingerprint: String?
    private var fingerprintRevision = 0
    private let maximumOutputCharacters = 500_000

    package init(
        runtimeService: any MavenRuntimePort,
        process: any StreamingProcess,
        mavenOperations: any MavenProjectOperations,
        configurationStore: (any MavenConfigurationStoring)? = nil
    ) {
        self.runtimeService = runtimeService
        self.process = process
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
    }

    package func loadProject(at workspaceURL: URL, files: [URL]) async {
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
        localRepositoryPath: String?,
        mavenExecutablePath: String?,
        javaHomePath: String?
    ) {
        let settings = normalizedLocalPath(settingsPath)
        let localRepository = normalizedLocalPath(localRepositoryPath)
        let executable = normalizedLocalPath(mavenExecutablePath)
        let javaHome = normalizedLocalPath(javaHomePath)
        guard settings != self.settingsPath
                || localRepository != self.localRepositoryPath
                || executable != self.mavenExecutablePath
                || javaHome != self.javaHomePath else { return }
        self.settingsPath = settings
        self.localRepositoryPath = localRepository
        self.mavenExecutablePath = executable
        self.javaHomePath = javaHome
        configurationDidChange()
    }

    package func acknowledgeReload() {
        isReloadRequired = false
        refreshConfigurationFingerprint(establishBaseline: true)
    }

    package func stop() {
        launchPlanID = UUID()
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
        localRepositoryPath = nil
        mavenExecutablePath = nil
        javaHomePath = nil
        configurationFingerprint = nil
        fingerprintRevision += 1
        configurationSaveError = nil
        isReloadRequired = false
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
            localRepositoryPath: localRepositoryPath,
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
        localRepositoryPath = normalizedLocalPath(stored?.local?.localRepositoryPath)
        mavenExecutablePath = normalizedLocalPath(stored?.local?.mavenExecutablePath)
        javaHomePath = normalizedLocalPath(stored?.local?.javaHomePath)
    }

    private func configurationDidChange() {
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
                localRepositoryPath: localRepositoryPath,
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

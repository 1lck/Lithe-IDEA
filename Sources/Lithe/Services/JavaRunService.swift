import Foundation

@MainActor
final class RunService: ObservableObject {
    @Published private(set) var configurations: [RunConfiguration] = [.currentFile]
    @Published var selectedConfigurationID = RunConfiguration.currentFileID {
        didSet {
            guard let projectURL else { return }
            selectedConfigurationIDsByProject[projectURL.path] = selectedConfigurationID
            preferences.set(selectedConfigurationID, forKey: selectionPreferenceKey(for: projectURL))
        }
    }
    @Published private(set) var isLoadingProject = false
    @Published private(set) var isRunning = false
    @Published private(set) var runningTitle: String?
    @Published private(set) var output = ""
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var optionsByConfigurationID: [String: RunOptions] = [:]
    @Published private(set) var effectiveSourcesByConfigurationID: [String: RunConfigurationSource] = [:]
    @Published private(set) var mavenProfiles: [MavenProfile] = []
    @Published private(set) var moduleSessions: [RunSession] = []
    @Published private(set) var portConflicts: [RunPortConflict] = []
    @Published private(set) var configurationStatus: ProjectRunConfigurationStatus = .missing
    @Published private(set) var configurationDiagnostics: [RunConfigurationDiagnostic] = []
    @Published private(set) var generationState: RunConfigurationGenerationState = .idle
    @Published private(set) var recoveryAction: RunConfigurationRecoveryAction = .regenerate
    @Published private(set) var recoveryPath: String?
    @Published private(set) var configurationSaveError: String?

    private let process: any StreamingProcess
    private let processFactory: () -> any StreamingProcess
    private let fileStorage: any FileStorage
    private let preferences: any KeyValueStore
    private let javaMavenOperations: any JavaMavenOperations
    private let runConfigurationOperations: any RunConfigurationOperations
    private let languageProviderCatalog: LanguageProviderCatalog
    private let languageRunProviders: LanguageRunProviderRegistry
    private var projectURL: URL?
    private var projectFiles: [URL] = []
    private var mavenProject: MavenProject?
    private var projectLoadID = UUID()
    private var selectedConfigurationIDsByProject: [String: String] = [:]
    private var lastRunConfiguration: RunConfiguration?
    private var lastCurrentFileURL: URL?
    private var moduleProcesses: [String: any StreamingProcess] = [:]
    private var activeOperationID: String?
    private var moduleOperationIDs: [String: String] = [:]
    private let maximumOutputCharacters = 500_000
    private let runtimeService: ProjectRuntimeService
    private let executableResolver: any RunExecutableResolving

    init(
        runtimeService: ProjectRuntimeService,
        process: any StreamingProcess,
        processFactory: @escaping () -> any StreamingProcess,
        fileStorage: any FileStorage,
        preferences: any KeyValueStore,
        javaMavenOperations: any JavaMavenOperations,
        runConfigurationOperations: any RunConfigurationOperations,
        executableResolver: (any RunExecutableResolving)? = nil,
        languageProviderCatalog: LanguageProviderCatalog = .standard,
        languageRunProviders: LanguageRunProviderRegistry? = nil,
        languagePackRegistry: LanguagePackRegistry? = nil
    ) {
        self.runtimeService = runtimeService
        self.process = process
        self.processFactory = processFactory
        self.fileStorage = fileStorage
        self.preferences = preferences
        self.javaMavenOperations = javaMavenOperations
        self.runConfigurationOperations = runConfigurationOperations
        self.languageProviderCatalog = languagePackRegistry?.catalog ?? languageProviderCatalog
        self.languageRunProviders = languagePackRegistry?.runProviders
            ?? languageRunProviders
            ?? .standard(catalog: languageProviderCatalog)
        self.executableResolver = executableResolver ?? RunExecutableResolver(runtimeService: runtimeService)
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

    var selectedConfiguration: RunConfiguration? {
        configurations.first { $0.id == selectedConfigurationID }
    }

    /// 供输出文本定位源码使用:项目根 + 各 Maven 模块根。
    var sourceSearchRoots: [URL] {
        var roots = projectURL.map { [$0] } ?? []
        if let mavenProject {
            roots.append(contentsOf: mavenProject.allModules.map(\.url))
        }
        return roots
    }

    func loadProject(
        at projectURL: URL,
        files: [URL],
        mavenProject: MavenProject?
    ) async {
        let loadID = UUID()
        projectLoadID = loadID
        isLoadingProject = true
        let operations = runConfigurationOperations
        let inspection = await Task.detached(priority: .utility) {
            operations.inspect(at: projectURL)
        }.value
        guard !Task.isCancelled, projectLoadID == loadID else { return }
        if let currentProject = self.projectURL {
            selectedConfigurationIDsByProject[currentProject.path] = selectedConfigurationID
        }
        self.projectURL = projectURL.standardizedFileURL
        self.mavenProject = mavenProject
        mavenProfiles = mavenProject?.profiles ?? []
        self.projectFiles = files
        configurationStatus = inspection.status
        configurationDiagnostics = inspection.diagnostics
        recoveryAction = inspection.recoveryAction
        recoveryPath = inspection.recoveryPath
        generationState = .idle
        if inspection.status == .ready {
            do {
                await executableResolver.refreshCandidates(projectURL: projectURL)
                guard !Task.isCancelled, projectLoadID == loadID else { return }
                let candidates = toolchainCandidates(projectURL: projectURL, mavenProject: mavenProject)
                let resolution = try operations.resolve(at: projectURL, toolchainCandidates: candidates)
                configurationDiagnostics += resolution.diagnostics
                apply(
                    resolution.configurations,
                    preferredConfigurationID: selectedConfigurationIDsByProject[projectURL.standardizedFileURL.path]
                        ?? preferences.string(forKey: selectionPreferenceKey(for: projectURL.standardizedFileURL))
                        ?? resolution.defaultConfigurationID
                )
            } catch {
                configurationStatus = .invalid(error.localizedDescription)
                recoveryAction = .editConfiguration
                configurations = []
                optionsByConfigurationID = [:]
                effectiveSourcesByConfigurationID = [:]
            }
        } else {
            configurations = []
            optionsByConfigurationID = [:]
            effectiveSourcesByConfigurationID = [:]
            reconcileModuleSessions(validConfigurationIDs: [])
            refreshPortConflicts()
        }
        isLoadingProject = false
    }

    func generateRunConfigurations() async {
        guard let projectURL else { return }
        let loadID = projectLoadID
        isLoadingProject = true
        let operations = runConfigurationOperations
        let files = projectFiles
        let modulePaths = mavenProject?.allModules.map(\.relativePath) ?? []
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try operations.generate(
                    at: projectURL,
                    files: files,
                    modulePaths: modulePaths
                )
            }
        }.value
        guard !Task.isCancelled, projectLoadID == loadID else { return }
        switch result {
        case .success(let result):
            do {
                await executableResolver.refreshCandidates(projectURL: projectURL)
                guard !Task.isCancelled, projectLoadID == loadID else { return }
                let candidates = toolchainCandidates(projectURL: projectURL, mavenProject: mavenProject)
                var resolution = try operations.resolve(at: projectURL, toolchainCandidates: candidates)
                try operations.migrateLegacySettings(
                    at: projectURL,
                    configurationIDs: resolution.configurations.map { $0.configuration.id }
                )
                resolution = try operations.resolve(at: projectURL, toolchainCandidates: candidates)
                configurationStatus = .ready
                recoveryAction = .none
                recoveryPath = nil
                configurationDiagnostics = operations.inspect(at: projectURL).diagnostics + resolution.diagnostics
                generationState = result.entryCount == 0 ? .noEntries : .succeeded(entryCount: result.entryCount)
                apply(
                    resolution.configurations,
                    preferredConfigurationID: selectedConfigurationIDsByProject[projectURL.standardizedFileURL.path]
                        ?? resolution.defaultConfigurationID
                )
            } catch {
                configurationStatus = .invalid(error.localizedDescription)
                recoveryAction = .editConfiguration
                configurationDiagnostics = []
                generationState = .failed(error.localizedDescription)
                fail(error.localizedDescription)
            }
        case .failure(let error):
            configurationStatus = .invalid(error.localizedDescription)
            recoveryAction = .fixPermissions
            configurationDiagnostics = []
            generationState = .failed(error.localizedDescription)
            fail(error.localizedDescription)
        }
        isLoadingProject = false
    }

    func select(_ configuration: RunConfiguration) {
        selectedConfigurationID = configuration.id
    }

    private func selectionPreferenceKey(for projectURL: URL) -> String {
        "lithe.selected-run-configuration."
            + projectURL.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
    }

    func options(for configuration: RunConfiguration) -> RunOptions {
        optionsByConfigurationID[configuration.id] ?? RunOptions()
    }

    func source(for configuration: RunConfiguration) -> RunConfigurationSource {
        effectiveSourcesByConfigurationID[configuration.id] ?? .generated
    }

    @discardableResult
    func updateOptions(
        _ options: RunOptions,
        for configuration: RunConfiguration,
        scope: RunConfigurationSaveScope = .local
    ) -> Bool {
        configurationSaveError = nil
        if configurationStatus == .ready, let projectURL {
            do {
                try runConfigurationOperations.saveOptions(
                    options,
                    configurationID: configuration.id,
                    scope: scope,
                    at: projectURL
                )
            } catch {
                configurationSaveError = error.localizedDescription
                return false
            }
        }
        optionsByConfigurationID[configuration.id] = options
        effectiveSourcesByConfigurationID[configuration.id] = scope == .local ? .local : .project
        persist(options, for: configuration.id)
        refreshPortConflicts()
        return true
    }

    func resetOptions(for configuration: RunConfiguration) {
        let options = RunOptions()
        updateOptions(options, for: configuration)
    }

    @discardableResult
    func createConfiguration(_ draft: RunConfigurationDraft) -> Bool {
        configurationSaveError = nil
        guard configurationStatus == .ready, let projectURL else {
            configurationSaveError = "Identify the project before creating a run configuration."
            return false
        }
        do {
            let id = try runConfigurationOperations.createConfiguration(draft, at: projectURL)
            let candidates = toolchainCandidates(projectURL: projectURL, mavenProject: mavenProject)
            let resolution = try runConfigurationOperations.resolve(
                at: projectURL,
                toolchainCandidates: candidates
            )
            guard resolution.configurations.contains(where: { $0.configuration.id == id }) else {
                throw RunConfigurationOperationFailure(
                    message: "The new configuration did not pass project validation. Check its module and main class."
                )
            }
            configurationDiagnostics = runConfigurationOperations.inspect(at: projectURL).diagnostics
                + resolution.diagnostics
            apply(resolution.configurations, preferredConfigurationID: id)
            selectedConfigurationIDsByProject[projectURL.path] = id
            return true
        } catch {
            configurationSaveError = error.localizedDescription
            return false
        }
    }

    func runSelected(currentFileURL: URL?) {
        guard let configuration = selectedConfiguration else { return }
        run(configuration: configuration, currentFileURL: currentFileURL)
    }

    func restart() {
        guard let lastRunConfiguration else { return }
        run(configuration: lastRunConfiguration, currentFileURL: lastCurrentFileURL)
    }

    func run(configuration: RunConfiguration, currentFileURL: URL?) {
        stop()
        output = ""
        lastExitCode = nil
        lastRunConfiguration = configuration
        lastCurrentFileURL = currentFileURL
        let options = self.options(for: configuration)
        let usesGenericCurrentFile = configuration.kind == .currentFile
            && isGenericCurrentFile(currentFileURL)
        if !usesGenericCurrentFile {
            let configuredJavaHome = options.javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !configuredJavaHome.isEmpty && runtimeService.javaHomeURL(overridePath: configuredJavaHome) == nil {
                fail("JDK Home does not point to a directory: " + configuredJavaHome)
                return
            }
        }

        guard configurationStatus == .ready, let projectURL else {
            fail("Project run configuration is missing. Identify the project before running.")
            return
        }
        if let diagnostic = configurationDiagnostics.first(where: { Self.isBlockingToolchainDiagnostic($0) }) {
            fail(diagnostic.message)
            return
        }
        if configuration.kind == .currentFile, currentFileURL == nil {
            fail(String(localized: "Open a source file before running Current File."))
            return
        }
        let currentFile = currentFileURL.flatMap { relativePath(for: $0, root: projectURL) }
        let planClassPath = currentFileURL.flatMap(classPath(for:))
        let plan: SharedLaunchPlan
        do {
            if usesGenericCurrentFile, let currentFileURL {
                plan = try languageRunProviders.launchPlan(
                    for: currentFileURL,
                    workspaceURL: projectURL,
                    options: options
                )
            } else {
                plan = try runConfigurationOperations.launchPlan(
                    at: projectURL,
                    configurationID: configuration.id,
                    currentFile: currentFile,
                    classPath: planClassPath,
                    debugPort: nil
                )
            }
        } catch {
            fail(error.localizedDescription)
            return
        }
        let resolved: ResolvedRunExecutable
        do {
            resolved = try executableResolver.resolve(plan, projectURL: projectURL, options: options)
        } catch {
            fail(error.localizedDescription)
            return
        }
        let arguments = plan.arguments
        let workingDirectory = resolvedWorkingDirectory(plan.workingDirectory, fallback: projectURL)

        runningTitle = configuration.name
        isRunning = true
        append("$ " + resolved.executableURL.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n")

        let operationID = UUID().uuidString
        activeOperationID = operationID
        do {
            try process.start(ProcessRequest(
                operationID: operationID,
                executablePath: resolved.executableURL.path,
                arguments: arguments,
                workingDirectory: workingDirectory.path,
                environment: resolved.environment
            ))
        } catch {
            fail("Unable to start " + configuration.name + ": " + error.localizedDescription)
        }
    }

    func runAllServices() {
        let serviceConfigurations = configurations.filter { $0.execution == .service }
        guard !serviceConfigurations.isEmpty else {
            fail(String(localized: "No runnable services were detected in this project."))
            return
        }
        stopAllServices()
        moduleSessions = []
        for configuration in serviceConfigurations {
            startModuleSession(configuration)
        }
    }

    func startConfiguration(_ configuration: RunConfiguration) {
        guard configuration.kind != .currentFile else { return }
        stopModule(sessionID: configuration.id)
        startModuleSession(configuration)
    }

    func stopModule(_ session: RunSession) {
        stopModule(sessionID: session.id)
    }

    func restartModule(_ session: RunSession) {
        guard let configuration = configurations.first(where: { $0.id == session.configurationID }) else { return }
        stopModule(sessionID: session.id)
        moduleSessions.removeAll { $0.id == session.id }
        startModuleSession(configuration)
    }

    func stopAllServices() {
        for sessionID in Array(moduleProcesses.keys) {
            stopModule(sessionID: sessionID)
        }
    }

    func clearModuleOutput() {
        for index in moduleSessions.indices {
            moduleSessions[index].output = ""
        }
    }

    func clearModuleOutput(_ session: RunSession) {
        guard let index = moduleSessions.firstIndex(where: { $0.id == session.id }) else { return }
        moduleSessions[index].output = ""
    }

    func stop() {
        process.stop()
        isRunning = false
        runningTitle = nil
        activeOperationID = nil
    }

    func reset() {
        stop()
        stopAllServices()
        projectLoadID = UUID()
        projectURL = nil
        selectedConfigurationIDsByProject = [:]
        projectFiles = []
        mavenProject = nil
        configurations = [.currentFile]
        selectedConfigurationID = RunConfiguration.currentFileID
        optionsByConfigurationID = [:]
        effectiveSourcesByConfigurationID = [:]
        mavenProfiles = []
        moduleSessions = []
        portConflicts = []
        configurationStatus = .missing
        configurationDiagnostics = []
        generationState = .idle
        recoveryAction = .regenerate
        recoveryPath = nil
        configurationSaveError = nil
        isLoadingProject = false
        output = ""
        lastExitCode = nil
        lastRunConfiguration = nil
        lastCurrentFileURL = nil
    }

    func clearOutput() {
        output = ""
        lastExitCode = nil
    }

    private func fail(_ message: String) {
        output = message + "\n"
        lastExitCode = 1
        isRunning = false
        runningTitle = nil
    }

    private func isGenericCurrentFile(_ fileURL: URL?) -> Bool {
        guard let fileURL else { return false }
        guard let descriptor = languageProviderCatalog.provider(for: fileURL) else {
            return true
        }
        return descriptor.id != "java"
    }

    private static func isBlockingToolchainDiagnostic(_ diagnostic: RunConfigurationDiagnostic) -> Bool {
        diagnostic.code == "missingToolchain" || diagnostic.code == "toolchainVersionMismatch"
    }

    private func toolchainCandidates(
        projectURL: URL,
        mavenProject: MavenProject?
    ) -> [ProjectToolchainCandidate] {
        let runtimeCandidates = runtimeService.runConfigurationToolchainCandidates(
            for: mavenProject,
            projectRoot: projectURL
        )
        var candidatesByID = Dictionary(uniqueKeysWithValues: runtimeCandidates.map { ($0.id, $0) })
        for candidate in executableResolver.candidates(projectURL: projectURL)
            where candidatesByID[candidate.id] == nil {
            candidatesByID[candidate.id] = candidate
        }
        return candidatesByID.values.sorted { $0.id < $1.id }
    }

    private func apply(
        _ effective: [EffectiveRunConfiguration],
        preferredConfigurationID: String? = nil
    ) {
        // Keep the language-neutral Current File entry available even when a
        // project has no declared service. Its launch plan is selected by the
        // active language Provider at run time; Java projects still fall back
        // to the legacy core path.
        var resolved = effective
        if !resolved.contains(where: { $0.configuration.id == RunConfiguration.currentFileID }) {
            resolved.insert(
                EffectiveRunConfiguration(
                    configuration: .currentFile,
                    options: RunOptions(),
                    source: .generated
                ),
                at: 0
            )
        }
        configurations = resolved.map(\.configuration)
        optionsByConfigurationID = Dictionary(uniqueKeysWithValues: resolved.map {
            ($0.configuration.id, $0.options)
        })
        effectiveSourcesByConfigurationID = Dictionary(uniqueKeysWithValues: resolved.map {
            ($0.configuration.id, $0.source)
        })
        reconcileModuleSessions(validConfigurationIDs: Set(configurations.map(\.id)))
        refreshPortConflicts()
        if let preferredConfigurationID,
           configurations.contains(where: { $0.id == preferredConfigurationID }) {
            selectedConfigurationID = preferredConfigurationID
        } else if !configurations.contains(where: { $0.id == selectedConfigurationID }) {
            selectedConfigurationID = configurations.first(where: { $0.kind == .springBoot })?.id
                ?? configurations.first?.id
                ?? RunConfiguration.currentFileID
        }
    }

    private func relativePath(for fileURL: URL, root: URL) -> String? {
        let file = fileURL.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        guard file.hasPrefix(prefix) else { return nil }
        return String(file.dropFirst(prefix.count))
    }

    private func finishProcess(exitCode: Int32) {
        isRunning = false
        runningTitle = nil
        lastExitCode = exitCode
        activeOperationID = nil
    }

    private func consumeLifecycle(_ event: ProcessLifecycleEvent) {
        guard event.operationID == activeOperationID else { return }
        switch event.state {
        case .starting, .running:
            isRunning = true
        case .stopping, .finished:
            isRunning = false
        case .failed:
            isRunning = false
            runningTitle = nil
            lastExitCode = event.exitCode ?? 1
            if let message = event.message, !message.isEmpty {
                append("Unable to run: " + message + "\n")
            }
        }
    }

    private func append(_ value: String) {
        let continuing = !(output.isEmpty || output.hasSuffix("\n"))
        output.append(
            OutputTimestamper.stamped(
                value.replacingOccurrences(of: "\r", with: ""),
                continuingLine: continuing
            )
        )
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }

    private func classPath(for fileURL: URL) -> String? {
        var candidateRoots: [URL] = []
        if let mavenProject {
            candidateRoots += mavenProject.allModules
                .filter { Self.isInside(fileURL, directory: $0.url) }
                .sorted { $0.url.path.count > $1.url.path.count }
                .map(\.url)
            candidateRoots.append(mavenProject.rootURL)
        }
        if let projectURL {
            candidateRoots.append(projectURL)
        }

        var seenPaths = Set<String>()
        for root in candidateRoots {
            let classesURL = root.appendingPathComponent("target/classes", isDirectory: true)
            guard seenPaths.insert(classesURL.standardizedFileURL.path).inserted else { continue }
            guard fileStorage.metadata(for: classesURL)?.isDirectory == true else { continue }
            return classesURL.standardizedFileURL.path
        }
        return nil
    }

    private func startModuleSession(_ configuration: RunConfiguration) {
        guard configurationStatus == .ready,
              let projectURL else { return }
        moduleSessions.removeAll { $0.id == configuration.id }
        let options = self.options(for: configuration)
        let configuredJavaHome = options.javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredJavaHome.isEmpty && runtimeService.mavenJavaHomeURL(overridePath: configuredJavaHome) == nil {
            moduleSessions.append(RunSession(
                id: configuration.id,
                configurationID: configuration.id,
                title: configuration.name,
                output: "JDK Home does not point to a directory: " + configuredJavaHome + "\n",
                isRunning: false,
                exitCode: 1
            ))
            return
        }

        let plan: SharedLaunchPlan
        do {
            plan = try runConfigurationOperations.launchPlan(
                at: projectURL,
                configurationID: configuration.id,
                currentFile: nil,
                classPath: nil,
                debugPort: nil
            )
        } catch {
            moduleSessions.append(RunSession(
                id: configuration.id,
                configurationID: configuration.id,
                title: configuration.name,
                output: error.localizedDescription + "\n",
                isRunning: false,
                exitCode: 1
            ))
            return
        }

        let resolved: ResolvedRunExecutable
        do {
            resolved = try executableResolver.resolve(plan, projectURL: projectURL, options: options)
        } catch {
            // A service that cannot start still becomes a session so the panel
            // shows which one failed and why, rather than silently omitting it.
            moduleSessions.append(RunSession(
                id: configuration.id,
                configurationID: configuration.id,
                title: configuration.name,
                output: error.localizedDescription + "\n",
                isRunning: false,
                exitCode: 1
            ))
            return
        }
        let arguments = plan.arguments
        let workingDirectory = resolvedWorkingDirectory(plan.workingDirectory, fallback: projectURL)

        let session = RunSession(
            id: configuration.id,
            configurationID: configuration.id,
            title: configuration.name,
            output: "$ " + resolved.executableURL.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n",
            isRunning: true,
            exitCode: nil
        )
        moduleSessions.append(session)

        let process = processFactory()
        process.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendModuleOutput(chunk, sessionID: configuration.id)
            }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.finishModule(sessionID: configuration.id, exitCode: exitCode)
            }
        }
        let operationID = UUID().uuidString
        process.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeModuleLifecycle(event, sessionID: configuration.id)
            }
        }

        moduleProcesses[configuration.id] = process
        moduleOperationIDs[configuration.id] = operationID
        do {
            try process.start(ProcessRequest(
                operationID: operationID,
                executablePath: resolved.executableURL.path,
                arguments: arguments,
                workingDirectory: workingDirectory.path,
                environment: resolved.environment
            ))
        } catch {
            moduleProcesses[configuration.id] = nil
            moduleOperationIDs[configuration.id] = nil
            if let index = moduleSessions.firstIndex(where: { $0.id == configuration.id }) {
                moduleSessions[index].isRunning = false
                moduleSessions[index].exitCode = 1
                appendModuleOutput(
                    "Unable to start " + configuration.name + ": " + error.localizedDescription + "\n",
                    sessionID: configuration.id
                )
            }
        }
    }

    private func stopModule(sessionID: String) {
        moduleProcesses[sessionID]?.stop()
        moduleProcesses[sessionID] = nil
        moduleOperationIDs[sessionID] = nil
        if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
            moduleSessions[index].isRunning = false
        }
    }

    private func finishModule(sessionID: String, exitCode: Int32) {
        guard moduleProcesses[sessionID] != nil else { return }
        if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
            moduleSessions[index].isRunning = false
            moduleSessions[index].exitCode = exitCode
        }
        moduleProcesses[sessionID] = nil
        moduleOperationIDs[sessionID] = nil
    }

    private func consumeModuleLifecycle(_ event: ProcessLifecycleEvent, sessionID: String) {
        guard event.operationID == moduleOperationIDs[sessionID] else { return }
        switch event.state {
        case .starting, .running:
            if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
                moduleSessions[index].isRunning = true
            }
        case .stopping, .finished:
            if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
                moduleSessions[index].isRunning = false
            }
        case .failed:
            if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
                moduleSessions[index].isRunning = false
                moduleSessions[index].exitCode = event.exitCode ?? 1
                if let message = event.message, !message.isEmpty {
                    appendModuleOutput(message + "\n", sessionID: sessionID)
                }
            }
        }
    }

    private func reconcileModuleSessions(validConfigurationIDs: Set<String>) {
        let staleSessionIDs = moduleProcesses.keys.filter { !validConfigurationIDs.contains($0) }
        for sessionID in staleSessionIDs {
            stopModule(sessionID: sessionID)
        }
        moduleSessions.removeAll { !validConfigurationIDs.contains($0.configurationID) }
    }

    private func appendModuleOutput(_ value: String, sessionID: String) {
        guard let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let existing = moduleSessions[index].output
        let continuing = !(existing.isEmpty || existing.hasSuffix("\n"))
        moduleSessions[index].output.append(
            OutputTimestamper.stamped(
                value.replacingOccurrences(of: "\r", with: ""),
                continuingLine: continuing
            )
        )
        if moduleSessions[index].output.count > maximumOutputCharacters {
            moduleSessions[index].output.removeFirst(
                moduleSessions[index].output.count - maximumOutputCharacters
            )
        }
    }

    private func refreshPortConflicts() {
        let moduleConfigurations = configurations.filter { $0.kind == .mavenModule }
        var configurationsByPort: [Int: [String]] = [:]
        for configuration in moduleConfigurations {
            let port = configuredPort(for: configuration) ?? 8080
            guard (1...65_535).contains(port) else { continue }
            configurationsByPort[port, default: []].append(configuration.name)
        }
        portConflicts = configurationsByPort
            .filter { $0.value.count > 1 }
            .map { port, names in
                RunPortConflict(
                    port: port,
                    configurationNames: names.sorted {
                        $0.localizedStandardCompare($1) == .orderedAscending
                    }
                )
            }
            .sorted { $0.port < $1.port }
    }

    private func configuredPort(for configuration: RunConfiguration) -> Int? {
        let options = self.options(for: configuration)
        if let port = Self.port(in: options.programArguments) ?? Self.port(in: options.vmArguments) {
            return port
        }

        let moduleRoot = configuration.modulePath.flatMap { modulePath in
            mavenProject?.modules.first(where: { $0.relativePath == modulePath })?.url
        } ?? projectURL
        guard let moduleRoot else { return nil }
        let resourceFiles = projectFiles.filter { fileURL in
            let name = fileURL.lastPathComponent.lowercased()
            return Self.isInside(fileURL, directory: moduleRoot) &&
                (name == "application.properties" || name == "application.yml" || name == "application.yaml" ||
                 (name.hasPrefix("application-") &&
                  (name.hasSuffix(".properties") || name.hasSuffix(".yml") || name.hasSuffix(".yaml"))))
        }
        for fileURL in resourceFiles {
            guard let data = try? fileStorage.readData(from: fileURL, options: []),
                  let contents = String(data: data, encoding: .utf8),
                  let port = javaMavenOperations.serverPort(
                      content: contents,
                      fileExtension: fileURL.pathExtension.lowercased()
                  ) else {
                continue
            }
            return port
        }
        return nil
    }

    private static func port(in input: String) -> Int? {
        let tokens = RunArgumentParser.parse(input)
        for (index, token) in tokens.enumerated() {
            let keys = ["--server.port=", "-Dserver.port=", "--server.port", "-Dserver.port"]
            for key in keys where token.hasPrefix(key) {
                let value: String
                if token == key {
                    guard tokens.indices.contains(index + 1) else { continue }
                    value = tokens[index + 1]
                } else {
                    value = String(token.dropFirst(key.count))
                }
                if let port = Int(value), port > 0 { return port }
            }
        }
        return nil
    }

    private static func isInside(_ fileURL: URL, directory: URL) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return filePath.hasPrefix(directoryPath + "/")
    }

    private func resolvedWorkingDirectory(_ path: String, fallback: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let url = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : URL(fileURLWithPath: trimmed, relativeTo: projectURL ?? fallback)
        let standardized = url.standardizedFileURL
        guard fileStorage.metadata(for: standardized)?.isDirectory == true else { return fallback }
        return standardized
    }

    private func optionsKey(for configurationID: String) -> String? {
        guard let projectURL else { return nil }
        let projectKey = projectURL.path.replacingOccurrences(of: "/", with: "_")
        return "lithe.java-run-options.\(projectKey).\(configurationID)"
    }

    private func loadOptions(for configurationID: String) -> RunOptions {
        guard let key = optionsKey(for: configurationID),
              let data = preferences.data(forKey: key),
              let options = try? JSONDecoder().decode(RunOptions.self, from: data) else {
            return RunOptions()
        }
        return options
    }

    private func persist(_ options: RunOptions, for configurationID: String) {
        guard let key = optionsKey(for: configurationID),
              let data = try? JSONEncoder().encode(options) else { return }
        preferences.set(data, forKey: key)
    }
}

/// Compatibility name retained while Java debug remains a provider-specific
/// consumer of the generic run service.
typealias JavaRunService = RunService

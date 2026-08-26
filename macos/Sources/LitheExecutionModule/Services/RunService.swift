import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
package final class RunService: ObservableObject {
    @Published package private(set) var configurations: [RunConfiguration] = [.currentFile]
    @Published package var selectedConfigurationID = RunConfiguration.currentFileID {
        didSet {
            guard let projectURL else { return }
            selectedConfigurationIDsByProject[projectURL.path] = selectedConfigurationID
            preferences.setString(selectedConfigurationID, forKey: selectionPreferenceKey(for: projectURL))
        }
    }
    @Published package private(set) var isLoadingProject = false
    @Published package private(set) var isRunning = false
    @Published package private(set) var runningTitle: String?
    @Published package private(set) var output = ""
    @Published package private(set) var lastExitCode: Int32?
    @Published package private(set) var optionsByConfigurationID: [String: RunOptions] = [:]
    @Published package private(set) var projectToolchain = ProjectToolchainSelection()
    @Published package private(set) var effectiveSourcesByConfigurationID: [String: RunConfigurationSource] = [:]
    @Published package private(set) var mavenProfiles: [MavenProfile] = []
    @Published package private(set) var moduleSessions: [RunSession] = []
    @Published package private(set) var portConflicts: [RunPortConflict] = []
    @Published package private(set) var configurationStatus: ProjectRunConfigurationStatus = .missing
    @Published package private(set) var configurationDiagnostics: [RunConfigurationDiagnostic] = []
    @Published package private(set) var generationState: RunConfigurationGenerationState = .idle
    @Published package private(set) var recoveryAction: RunConfigurationRecoveryAction = .regenerate
    @Published package private(set) var recoveryPath: String?
    @Published package private(set) var configurationSaveError: String?

    private let process: any StreamingProcess
    private let processFactory: () -> any StreamingProcess
    private let fileAccess: any RunFileAccess
    private let preferences: any RunPreferenceStore
    private let serverPortParser: any RunServerPortParsing
    private let runConfigurationOperations: any RunConfigurationOperations
    private let languageProviderCatalog: LanguageProviderCatalog
    private let languageRunProviders: LanguageRunProviderRegistry
    private let extensionRequiredLanguageIDs: Set<String>
    private var languageRunExtensions: [String: RegisteredLanguageRunExtension] = [:]
    private var activeLanguageExecutionSession: (any LanguageExecutionSession)?
    private var projectURL: URL?
    private var projectFiles: [URL] = []
    private var mavenProject: MavenProject?
    private var projectLoadID = UUID()
    private var selectedConfigurationIDsByProject: [String: String] = [:]
    private var lastRunConfiguration: RunConfiguration?
    private var lastCurrentFileURL: URL?
    private var moduleProcesses: [String: any StreamingProcess] = [:]
    private var moduleLanguageExecutionSessions: [String: any LanguageExecutionSession] = [:]
    private var activeOperationID: String?
    private var moduleOperationIDs: [String: String] = [:]
    private let maximumOutputCharacters = 500_000
    private let runtime: any RunRuntimePort
    private let executableResolver: any RunExecutableResolving

    package init(
        runtime: any RunRuntimePort,
        process: any StreamingProcess,
        processFactory: @escaping () -> any StreamingProcess,
        fileAccess: any RunFileAccess,
        preferences: any RunPreferenceStore,
        serverPortParser: any RunServerPortParsing,
        runConfigurationOperations: any RunConfigurationOperations,
        executableResolver: any RunExecutableResolving,
        languageProviderCatalog: LanguageProviderCatalog,
        languageRunProviders: LanguageRunProviderRegistry,
        extensionRequiredLanguageIDs: Set<String> = []
    ) {
        self.runtime = runtime
        self.process = process
        self.processFactory = processFactory
        self.fileAccess = fileAccess
        self.preferences = preferences
        self.serverPortParser = serverPortParser
        self.runConfigurationOperations = runConfigurationOperations
        self.languageProviderCatalog = languageProviderCatalog
        self.languageRunProviders = languageRunProviders
        self.extensionRequiredLanguageIDs = extensionRequiredLanguageIDs
        self.executableResolver = executableResolver
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

    package var selectedConfiguration: RunConfiguration? {
        configurations.first { $0.id == selectedConfigurationID }
    }

    package var lastRunFileURL: URL? { lastCurrentFileURL }
    package var lastConfiguration: RunConfiguration? { lastRunConfiguration }

    @discardableResult
    package func registerLanguageRunExtension(
        _ provider: any LanguageRunExtensionProviding,
        support: LanguageSupportDeclaration
    ) -> Bool {
        guard provider.languageID == support.id,
              support.executionModuleID != nil else { return false }
        languageRunExtensions[support.id] = RegisteredLanguageRunExtension(
            support: support,
            provider: provider
        )
        return true
    }

    package func unregisterLanguageRunExtension(languageID: String) {
        languageRunExtensions[languageID] = nil
    }

    /// 供输出文本定位源码使用:项目根 + 各 Maven 模块根。
    package var sourceSearchRoots: [URL] {
        var roots = projectURL.map { [$0] } ?? []
        if let mavenProject {
            roots.append(contentsOf: mavenProject.allModules.map(\.url))
        }
        return roots
    }

    package func loadProject(
        at projectURL: URL,
        files: [URL],
        mavenProject: MavenProject?
    ) async {
        let loadID = UUID()
        projectLoadID = loadID
        isLoadingProject = true
        defer {
            if projectLoadID == loadID {
                isLoadingProject = false
            }
        }
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
                let preferredID = selectedConfigurationIDsByProject[projectURL.standardizedFileURL.path]
                    ?? preferences.string(forKey: selectionPreferenceKey(for: projectURL.standardizedFileURL))
                let resolution = try resolveWithServiceToolchains(
                    operations: operations,
                    projectURL: projectURL,
                    mavenProject: mavenProject,
                    preferredConfigurationID: preferredID
                )
                configurationDiagnostics += resolution.diagnostics
                apply(
                    resolution.configurations,
                    projectToolchain: resolution.projectToolchain,
                    preferredConfigurationID: preferredID ?? resolution.defaultConfigurationID
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
    }

    package func generateRunConfigurations() async {
        guard let projectURL else { return }
        let loadID = projectLoadID
        isLoadingProject = true
        defer {
            if projectLoadID == loadID {
                isLoadingProject = false
            }
        }
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
                var resolution = try resolveWithServiceToolchains(
                    operations: operations,
                    projectURL: projectURL,
                    mavenProject: mavenProject,
                    preferredConfigurationID: nil
                )
                try operations.migrateLegacySettings(
                    at: projectURL,
                    configurationIDs: resolution.configurations.map { $0.configuration.id }
                )
                resolution = try resolveWithServiceToolchains(
                    operations: operations,
                    projectURL: projectURL,
                    mavenProject: mavenProject,
                    preferredConfigurationID: selectedConfigurationIDsByProject[projectURL.standardizedFileURL.path]
                        ?? resolution.defaultConfigurationID
                )
                configurationStatus = .ready
                recoveryAction = .none
                recoveryPath = nil
                configurationDiagnostics = operations.inspect(at: projectURL).diagnostics + resolution.diagnostics
                generationState = result.entryCount == 0 ? .noEntries : .succeeded(entryCount: result.entryCount)
                apply(
                    resolution.configurations,
                    projectToolchain: resolution.projectToolchain,
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
    }

    package func select(_ configuration: RunConfiguration) {
        selectedConfigurationID = configuration.id
        if configuration.kind.capabilities.contains(.javaRuntime) {
            runtime.setActiveServiceJavaHomePath(options(for: configuration).javaHomePath)
        }
    }

    private func selectionPreferenceKey(for projectURL: URL) -> String {
        "lithe.selected-run-configuration."
            + projectURL.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
    }

    package func options(for configuration: RunConfiguration) -> RunOptions {
        optionsByConfigurationID[configuration.id] ?? RunOptions()
    }

    package func source(for configuration: RunConfiguration) -> RunConfigurationSource {
        effectiveSourcesByConfigurationID[configuration.id] ?? .generated
    }

    package func serviceURL(for configuration: RunConfiguration) -> URL? {
        guard configuration.execution == .service,
              let port = configuredPort(for: configuration),
              (1...65_535).contains(port) else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    @discardableResult
    package func saveEditorChanges(
        _ options: RunOptions,
        toolchain: ProjectToolchainSelection,
        for configuration: RunConfiguration,
        scope: RunConfigurationSaveScope
    ) -> Bool {
        configurationSaveError = nil
        guard configurationStatus == .ready, let projectURL else {
            configurationSaveError = "Identify the project before editing its run configuration."
            return false
        }
        do {
            try runConfigurationOperations.saveEditorChanges(
                options,
                toolchain: toolchain,
                configurationID: configuration.id,
                scope: scope,
                at: projectURL
            )
        } catch {
            configurationSaveError = editorSaveFailureMessage(error, fallbackStage: .write)
            return false
        }
        do {
            let resolution = try resolveWithServiceToolchains(
                operations: runConfigurationOperations,
                projectURL: projectURL,
                mavenProject: mavenProject,
                preferredConfigurationID: configuration.id
            )
            configurationDiagnostics = runConfigurationOperations.inspect(at: projectURL).diagnostics
                + resolution.diagnostics
            apply(
                resolution.configurations,
                projectToolchain: resolution.projectToolchain,
                preferredConfigurationID: configuration.id
            )
        } catch {
            configurationSaveError = editorSaveFailureMessage(error, fallbackStage: .reload)
            return false
        }
        persist(options, for: configuration.id)
        return true
    }

    package func resetOptions(for configuration: RunConfiguration) {
        saveEditorChanges(
            RunOptions(),
            toolchain: projectToolchain,
            for: configuration,
            scope: .local
        )
    }

    @discardableResult
    package func createConfiguration(_ draft: RunConfigurationDraft) -> Bool {
        configurationSaveError = nil
        guard configurationStatus == .ready, let projectURL else {
            configurationSaveError = "Identify the project before creating a run configuration."
            return false
        }
        do {
            let id = try runConfigurationOperations.createConfiguration(draft, at: projectURL)
            let resolution = try resolveWithServiceToolchains(
                operations: runConfigurationOperations,
                projectURL: projectURL,
                mavenProject: mavenProject,
                preferredConfigurationID: id
            )
            guard resolution.configurations.contains(where: { $0.configuration.id == id }) else {
                throw RunConfigurationOperationFailure(
                    message: "The new configuration did not pass project validation. Check its module and main class."
                )
            }
            configurationDiagnostics = runConfigurationOperations.inspect(at: projectURL).diagnostics
                + resolution.diagnostics
            apply(
                resolution.configurations,
                projectToolchain: resolution.projectToolchain,
                preferredConfigurationID: id
            )
            selectedConfigurationIDsByProject[projectURL.path] = id
            return true
        } catch {
            configurationSaveError = error.localizedDescription
            return false
        }
    }

    package func runSelected(currentFileURL: URL?) {
        guard let configuration = selectedConfiguration else { return }
        run(configuration: configuration, currentFileURL: currentFileURL)
    }

    package func restart() {
        guard let lastRunConfiguration else { return }
        run(configuration: lastRunConfiguration, currentFileURL: lastCurrentFileURL)
    }

    package func run(configuration: RunConfiguration, currentFileURL: URL?) {
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
            if !configuredJavaHome.isEmpty && runtime.javaHomeURL(overridePath: configuredJavaHome) == nil {
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
        let requiredExtensionLanguageID = configuration.kind == .currentFile
            ? currentFileURL.flatMap { languageProviderCatalog.provider(for: $0)?.id }
            : configuration.kind.providerID
        if let requiredExtensionLanguageID,
           extensionRequiredLanguageIDs.contains(requiredExtensionLanguageID),
           languageRunExtension(providerID: requiredExtensionLanguageID) == nil {
            fail("\(requiredExtensionLanguageID) execution extension is not active.")
            return
        }
        let plan: SharedLaunchPlan
        var extensionSession: (any LanguageExecutionSession)?
        do {
            if usesGenericCurrentFile, let currentFileURL {
                if let provider = languageRunExtension(for: currentFileURL) {
                    guard let relativeFilePath = relativePath(for: currentFileURL, root: projectURL) else {
                        throw LanguageRunPlanError.fileOutsideWorkspace(currentFileURL)
                    }
                    plan = Self.sharedLaunchPlan(from: try provider.launchPlan(
                        for: LanguageRunExtensionRequest(
                            relativeFilePath: relativeFilePath,
                            arguments: RunArgumentParser.parse(options.arguments),
                            environment: options.environment
                        )
                    ))
                    extensionSession = provider.makeExecutionSession()
                } else {
                    plan = try languageRunProviders.launchPlan(
                        for: currentFileURL,
                        workspaceURL: projectURL,
                        options: options
                    )
                }
            } else {
                plan = try runConfigurationOperations.launchPlan(
                    at: projectURL,
                    configurationID: configuration.id,
                    currentFile: currentFile,
                    classPath: planClassPath,
                    debugPort: nil
                )
                extensionSession = languageRunExtension(
                    providerID: configuration.kind.providerID
                )?.makeExecutionSession()
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
            if let extensionSession {
                activeLanguageExecutionSession = extensionSession
                configureLanguageExecutionSession(extensionSession)
                try extensionSession.start(LanguageExecutionProcessRequest(
                    operationID: operationID,
                    executablePath: resolved.executableURL.path,
                    arguments: arguments,
                    workingDirectory: workingDirectory.path,
                    environment: resolved.environment
                ))
            } else {
                try process.start(ProcessRequest(
                    operationID: operationID,
                    executablePath: resolved.executableURL.path,
                    arguments: arguments,
                    workingDirectory: workingDirectory.path,
                    environment: resolved.environment
                ))
            }
        } catch {
            activeLanguageExecutionSession = nil
            fail("Unable to start " + configuration.name + ": " + error.localizedDescription)
        }
    }

    package func runAllServices() {
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

    package func startConfiguration(_ configuration: RunConfiguration) {
        guard configuration.kind != .currentFile else { return }
        stopModule(sessionID: configuration.id)
        startModuleSession(configuration)
    }

    package func stopModule(_ session: RunSession) {
        stopModule(sessionID: session.id)
    }

    package func restartModule(_ session: RunSession) {
        guard let configuration = configurations.first(where: { $0.id == session.configurationID }) else { return }
        stopModule(sessionID: session.id)
        moduleSessions.removeAll { $0.id == session.id }
        startModuleSession(configuration)
    }

    package func stopAllServices() {
        let sessionIDs = Set(moduleProcesses.keys).union(moduleLanguageExecutionSessions.keys)
        for sessionID in sessionIDs {
            stopModule(sessionID: sessionID)
        }
    }

    package func clearModuleOutput() {
        for index in moduleSessions.indices {
            moduleSessions[index].output = ""
        }
    }

    package func clearModuleOutput(_ session: RunSession) {
        guard let index = moduleSessions.firstIndex(where: { $0.id == session.id }) else { return }
        moduleSessions[index].output = ""
    }

    package func stop() {
        activeLanguageExecutionSession?.stop()
        activeLanguageExecutionSession = nil
        process.stop()
        isRunning = false
        runningTitle = nil
        activeOperationID = nil
    }

    package func reset() {
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
        projectToolchain = ProjectToolchainSelection()
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

    package func clearOutput() {
        output = ""
        lastExitCode = nil
    }

    private func fail(_ message: String) {
        output = message + "\n"
        lastExitCode = 1
        isRunning = false
        runningTitle = nil
    }

    private func editorSaveFailureMessage(
        _ error: any Error,
        fallbackStage: RunConfigurationEditorSaveStage
    ) -> String {
        if let failure = error as? RunConfigurationEditorSaveFailure {
            return failure.localizedDescription
        }
        return RunConfigurationEditorSaveFailure(
            stage: fallbackStage,
            message: error.localizedDescription
        ).localizedDescription
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
        mavenProject: MavenProject?,
        options: RunOptions? = nil
    ) -> [ProjectToolchainCandidate] {
        let runtimeCandidates = runtime.runConfigurationToolchainCandidates(
            for: mavenProject,
            projectRoot: projectURL,
            javaHomeOverride: options?.javaHomePath,
            mavenExecutableOverride: options?.mavenExecutablePath
        )
        var candidatesByID = Dictionary(uniqueKeysWithValues: runtimeCandidates.map { ($0.id, $0) })
        for candidate in executableResolver.candidates(projectURL: projectURL)
            where candidatesByID[candidate.id] == nil {
            candidatesByID[candidate.id] = candidate
        }
        return candidatesByID.values.sorted { $0.id < $1.id }
    }

    private func resolveWithServiceToolchains(
        operations: any RunConfigurationOperations,
        projectURL: URL,
        mavenProject: MavenProject?,
        preferredConfigurationID: String?
    ) throws -> RunConfigurationResolution {
        let initial = try operations.resolve(
            at: projectURL,
            toolchainCandidates: toolchainCandidates(projectURL: projectURL, mavenProject: mavenProject)
        )
        let preferred = initial.configurations.first { $0.configuration.id == preferredConfigurationID }
        let javaService = preferred ?? initial.configurations.first {
            $0.configuration.kind.capabilities.contains(.javaRuntime)
                && !$0.options.javaHomePath.isEmpty
        }
        guard let javaService else { return initial }
        let candidates = toolchainCandidates(
            projectURL: projectURL,
            mavenProject: mavenProject,
            options: javaService.options
        )
        return try operations.resolve(at: projectURL, toolchainCandidates: candidates)
    }

    private func apply(
        _ effective: [EffectiveRunConfiguration],
        projectToolchain: ProjectToolchainSelection = ProjectToolchainSelection(),
        preferredConfigurationID: String? = nil
    ) {
        // Keep the language-neutral Current File entry available even when a
        // project has no declared service. Its launch plan is selected by the
        // active language Provider at run time; Java projects still fall back
        // to the legacy core path.
        var seenConfigurationIDs = Set<String>()
        var resolved = effective.filter {
            seenConfigurationIDs.insert($0.configuration.id).inserted
        }
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
        self.projectToolchain = projectToolchain
        let preferredJava = resolved.first { item in
            item.configuration.id == preferredConfigurationID
                && item.configuration.kind.capabilities.contains(.javaRuntime)
        } ?? resolved.first { $0.configuration.kind.capabilities.contains(.javaRuntime) }
        runtime.setActiveServiceJavaHomePath(preferredJava?.options.javaHomePath ?? "")
        effectiveSourcesByConfigurationID = Dictionary(uniqueKeysWithValues: resolved.map {
            ($0.configuration.id, $0.source)
        })
        reconcileModuleSessions(validConfigurationIDs: Set(configurations.map(\.id)))
        refreshPortConflicts()
        if let preferredConfigurationID,
           configurations.contains(where: { $0.id == preferredConfigurationID }) {
            selectedConfigurationID = preferredConfigurationID
        } else if !configurations.contains(where: { $0.id == selectedConfigurationID }) {
            selectedConfigurationID = configurations.first(where: { $0.kind.mavenFramework != nil })?.id
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
        activeLanguageExecutionSession = nil
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

    private func languageRunExtension(
        for fileURL: URL
    ) -> (any LanguageRunExtensionProviding)? {
        languageRunExtensions.values
            .filter { $0.support.handles(fileURL: fileURL) }
            .sorted { $0.support.id < $1.support.id }
            .compactMap(\.provider)
            .first
    }

    private func languageRunExtension(
        providerID: String
    ) -> (any LanguageRunExtensionProviding)? {
        languageRunExtensions[providerID]?.provider
    }

    private func configureLanguageExecutionSession(_ session: any LanguageExecutionSession) {
        session.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in self?.append(chunk) }
        }
        session.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in self?.finishProcess(exitCode: exitCode) }
        }
        session.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeLifecycle(ProcessLifecycleEvent(
                    operationID: event.operationID,
                    state: Self.processState(event.state),
                    exitCode: event.exitCode,
                    message: event.message
                ))
            }
        }
    }

    private static func sharedLaunchPlan(
        from plan: LanguageRunExtensionPlan
    ) -> SharedLaunchPlan {
        let executable: SharedLaunchPlan.Executable
        switch plan.executable {
        case .toolchain(let id): executable = .toolchain(id)
        case .command(let command): executable = .command(command)
        }
        return SharedLaunchPlan(
            executable: executable,
            arguments: plan.arguments,
            workingDirectory: plan.workingDirectory,
            environment: plan.environment
        )
    }

    private static func processState(
        _ state: LanguageExecutionLifecycleState
    ) -> ProcessLifecycleState {
        switch state {
        case .starting: .starting
        case .running: .running
        case .stopping: .stopping
        case .finished: .finished
        case .failed: .failed
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
            guard fileAccess.isDirectory(at: classesURL) else { continue }
            return classesURL.standardizedFileURL.path
        }
        return nil
    }

    private func startModuleSession(_ configuration: RunConfiguration) {
        guard configurationStatus == .ready,
              let projectURL else { return }
        moduleSessions.removeAll { $0.id == configuration.id }
        if extensionRequiredLanguageIDs.contains(configuration.kind.providerID),
           languageRunExtension(providerID: configuration.kind.providerID) == nil {
            moduleSessions.append(RunSession(
                id: configuration.id,
                configurationID: configuration.id,
                title: configuration.name,
                output: "\(configuration.kind.providerID) execution extension is not active.\n",
                isRunning: false,
                exitCode: 1
            ))
            return
        }
        let options = self.options(for: configuration)
        let configuredJavaHome = (options.mavenJavaHomePath.isEmpty
            ? options.javaHomePath
            : options.mavenJavaHomePath).trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredJavaHome.isEmpty && runtime.mavenJavaHomeURL(overridePath: configuredJavaHome) == nil {
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

        let operationID = UUID().uuidString
        moduleOperationIDs[configuration.id] = operationID
        do {
            if let provider = languageRunExtension(providerID: configuration.kind.providerID) {
                let extensionSession = provider.makeExecutionSession()
                configureModuleLanguageExecutionSession(
                    extensionSession,
                    sessionID: configuration.id
                )
                moduleLanguageExecutionSessions[configuration.id] = extensionSession
                try extensionSession.start(LanguageExecutionProcessRequest(
                    operationID: operationID,
                    executablePath: resolved.executableURL.path,
                    arguments: arguments,
                    workingDirectory: workingDirectory.path,
                    environment: resolved.environment
                ))
            } else {
                let process = processFactory()
                configureModuleProcess(process, sessionID: configuration.id)
                moduleProcesses[configuration.id] = process
                try process.start(ProcessRequest(
                    operationID: operationID,
                    executablePath: resolved.executableURL.path,
                    arguments: arguments,
                    workingDirectory: workingDirectory.path,
                    environment: resolved.environment
                ))
            }
        } catch {
            moduleProcesses[configuration.id] = nil
            moduleLanguageExecutionSessions[configuration.id] = nil
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
        moduleLanguageExecutionSessions[sessionID]?.stop()
        moduleLanguageExecutionSessions[sessionID] = nil
        moduleOperationIDs[sessionID] = nil
        if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
            moduleSessions[index].isRunning = false
        }
    }

    private func finishModule(sessionID: String, exitCode: Int32) {
        guard moduleProcesses[sessionID] != nil
                || moduleLanguageExecutionSessions[sessionID] != nil else { return }
        if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
            moduleSessions[index].isRunning = false
            moduleSessions[index].exitCode = exitCode
        }
        moduleProcesses[sessionID] = nil
        moduleLanguageExecutionSessions[sessionID] = nil
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
        let activeSessionIDs = Set(moduleProcesses.keys).union(moduleLanguageExecutionSessions.keys)
        let staleSessionIDs = activeSessionIDs.filter { !validConfigurationIDs.contains($0) }
        for sessionID in staleSessionIDs {
            stopModule(sessionID: sessionID)
        }
        moduleSessions.removeAll { !validConfigurationIDs.contains($0.configurationID) }
    }

    private func configureModuleProcess(
        _ process: any StreamingProcess,
        sessionID: String
    ) {
        process.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendModuleOutput(chunk, sessionID: sessionID)
            }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.finishModule(sessionID: sessionID, exitCode: exitCode)
            }
        }
        process.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeModuleLifecycle(event, sessionID: sessionID)
            }
        }
    }

    private func configureModuleLanguageExecutionSession(
        _ session: any LanguageExecutionSession,
        sessionID: String
    ) {
        session.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendModuleOutput(chunk, sessionID: sessionID)
            }
        }
        session.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.finishModule(sessionID: sessionID, exitCode: exitCode)
            }
        }
        session.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeModuleLifecycle(
                    ProcessLifecycleEvent(
                        operationID: event.operationID,
                        state: Self.processState(event.state),
                        exitCode: event.exitCode,
                        message: event.message
                    ),
                    sessionID: sessionID
                )
            }
        }
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
        for key in ["PORT", "SERVER_PORT", "QUARKUS_HTTP_PORT", "MICRONAUT_SERVER_PORT"] {
            if let value = options.environment[key], let port = Int(value), port > 0 {
                return port
            }
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
            guard let data = try? fileAccess.readData(from: fileURL),
                  let contents = String(data: data, encoding: .utf8),
                  let port = serverPortParser.serverPort(
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
            let keys = [
                "--server.port=", "-Dserver.port=", "--server.port", "-Dserver.port",
                "--port=", "--port", "-p=", "-p"
            ]
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
        guard fileAccess.isDirectory(at: standardized) else { return fallback }
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
        preferences.setData(data, forKey: key)
    }
}

@MainActor
private final class RegisteredLanguageRunExtension {
    let support: LanguageSupportDeclaration
    weak var provider: (any LanguageRunExtensionProviding)?

    init(
        support: LanguageSupportDeclaration,
        provider: any LanguageRunExtensionProviding
    ) {
        self.support = support
        self.provider = provider
    }
}

/// Compatibility name retained while Java debug remains a provider-specific
/// consumer of the generic run service.
package typealias JavaRunService = RunService

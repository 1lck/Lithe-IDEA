import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

/// Run configuration entry points and workspace readiness gates.
@MainActor
extension AppModel {
    func toggleSpringEndpoints() {
        guard toggleToolWindow(.spring) else { return }
    }

    func openSpringEndpoint(_ endpoint: SpringEndpoint) {
        navigateToEditorLocation(
            url: endpoint.url,
            line: max(0, endpoint.line - 1),
            utf16Column: max(0, endpoint.column - 1)
        )
    }

    func toggleRun() {
        guard toggleToolWindow(.run) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await activateExecutionModule() != nil else { return }
            if let workspaceURL {
                await loadProjectServicesForAppliedSnapshot(at: workspaceURL)
            }
        }
    }

    func toggleMaven() {
        guard hasMavenProject else {
            showNotification("No Maven project was detected in this workspace")
            workbenchFeature.setVisibility(.maven, isVisible: false)
            return
        }
        guard toggleToolWindow(.maven) else { return }
        Task { [weak self] in
            guard let self, await activateExecutionModule() != nil,
                  let workspaceURL else { return }
            await loadProjectServicesForAppliedSnapshot(at: workspaceURL)
        }
        guard let workspaceURL else { return }
        Task { [weak self] in
            guard let self else { return }
            let capability = await self.activateExecutionModule()
            if capability?.mavenFeature.project == nil {
                await self.loadProjectServicesForAppliedSnapshot(at: workspaceURL)
            }
        }
    }

    func runMaven(
        phase: MavenLifecyclePhase,
        module: MavenModule?
    ) {
        showToolWindow(.mavenOutput)
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.run(phase: phase, module: module)
        }
    }

    func runMavenGoal(_ goal: String, module: MavenModule?) {
        showToolWindow(.mavenOutput)
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.runCustomGoal(goal, module: module)
        }
    }

    func stopMaven() {
        runWorkflowCoordinator.cancelModuleOperation()
        executionModuleCoordinator.stopFeatures(
            maven: mavenFeatureIfActive,
            run: nil
        )
    }

    func openMavenIssue(_ issue: MavenBuildIssue) {
        guard let fileURL = issue.fileURL,
              workspaceFeature.fileExists(at: fileURL) else { return }
        navigateToEditorLocation(
            url: fileURL.standardizedFileURL,
            line: max(0, (issue.line ?? 1) - 1),
            utf16Column: max(0, (issue.column ?? 1) - 1)
        )
    }

    func openSourceLocation(url: URL, line: Int, column: Int?) {
        guard workspaceFeature.fileExists(at: url) else { return }
        navigateToEditorLocation(
            url: url.standardizedFileURL,
            line: max(0, line - 1),
            utf16Column: max(0, (column ?? 1) - 1)
        )
    }

    func toggleProblems() {
        guard toggleToolWindow(.problems) else { return }
    }

    func openDiagnostic(_ diagnostic: EditorDiagnostic) {
        guard workspaceFeature.fileExists(at: diagnostic.fileURL) else { return }
        navigateToEditorLocation(
            url: diagnostic.fileURL.standardizedFileURL,
            line: diagnostic.line,
            utf16Column: diagnostic.utf16Column
        )
    }

    func selectRunConfiguration(_ configuration: RunConfiguration) {
        runFeatureIfActive?.select(configuration)
    }

    /// Generate configurations only after the current workspace snapshot is ready.
    func generateRunConfigurations() async {
        guard let identity = currentWorkspaceIdentity else { return }
        guard let runFeature = await activateExecutionModule()?.runFeature else { return }
        guard isCurrentWorkspace(identity) else { return }
        guard runFeature.recoveryAction != .upgradeApplication else { return }
        switch await ensureRunProjectReady(runFeature, for: identity) {
        case .ready:
            await generateFromJavaEntrypoints(runFeature, for: identity)
        case .waitingForSnapshot:
            runFeature.reportGenerationProjectNotReady()
        case .stale:
            return
        }
    }

    func openRunConfiguration(relativePath: String?) {
        guard let workspaceURL else { return }
        let url = workspaceURL.appendingPathComponent(relativePath ?? ".lithe/run/generated.json")
        guard workspaceFeature.fileExists(at: url) else { return }
        openFile(url)
    }

    func runSelectedConfiguration() {
        Task { [weak self] in await self?.runSelectedConfigurationAfterActivation() }
    }

    /// Loads services for the workspace snapshot currently applied by the model.
    func loadProjectServicesForAppliedSnapshot(at workspaceURL: URL) async {
        let applied = workspaceFeature.appliedSnapshot
        await loadProjectServices(
            at: workspaceURL,
            files: applied?.files ?? [],
            snapshotID: applied?.id
        )
    }

    /// Loads build-system and run state for one scan; `files` and `snapshotID` must match.
    func loadProjectServices(
        at workspaceURL: URL,
        files: [URL],
        snapshotID: UUID?,
        resumesDeferredRunAction: Bool = false
    ) async {
        let target = workspaceURL.standardizedFileURL
        guard let identity = currentWorkspaceIdentity, identity.url == target else { return }
        prepareJavaLanguageServerForWorkspaceIfNeeded(
            at: target,
            files: files
        )
        springFeature.scheduleLoad(
            workspaceURL: target,
            files: files,
            textOverrides: Dictionary(uniqueKeysWithValues: openDocuments.map {
                ($0.url.standardizedFileURL, $0.text)
            })
        )
        mybatisFeature.scheduleLoad(
            workspaceURL: target,
            files: files,
            textOverrides: Dictionary(uniqueKeysWithValues: openDocuments.map {
                ($0.url.standardizedFileURL, $0.text)
            })
        )
        guard let execution = await activateExecutionModule() else { return }
        guard isCurrentWorkspace(identity) else { return }
        execution.tests.discover(workspaceURL: target, files: files)
        await execution.projectDevelopment.loadProject(
            at: target,
            files: files,
            snapshotID: snapshotID
        )
        guard isCurrentWorkspace(identity) else { return }
        adoptSavedProjectToolchain(from: execution.runFeature, workspace: target)
        checkJavaEntrypointFreshness(execution.runFeature, for: identity, files: files)
        guard resumesDeferredRunAction else { return }
        runWorkflowCoordinator.resumeDeferredAction(
            runFeature: execution.runFeature,
            identity: identity,
            snapshotID: snapshotID
        )
    }

    var currentWorkspaceIdentity: WorkspaceIdentity? {
        guard let url = workspaceURL?.standardizedFileURL else { return nil }
        return WorkspaceIdentity(url: url, generation: workspaceFeature.workspaceGeneration)
    }

    func isCurrentWorkspace(_ identity: WorkspaceIdentity) -> Bool {
        currentWorkspaceIdentity == identity
    }

    /// Applies the captured workspace snapshot before a run action proceeds.
    func ensureRunProjectReady(
        _ runFeature: RunFeatureModel,
        for identity: WorkspaceIdentity
    ) async -> RunProjectReadiness {
        let applied = workspaceFeature.appliedSnapshot
        return await runWorkflowCoordinator.ensureProjectReady(
            runFeature,
            identity: identity,
            appliedSnapshotID: applied?.id,
            appliedFiles: applied?.files ?? [],
            isCurrent: { [weak self] identity in
                self?.isCurrentWorkspace(identity) == true
            }
        )
    }

    func clearPendingRunAction(for identity: WorkspaceIdentity) {
        runWorkflowCoordinator.clearPendingAction(for: identity)
    }

    func deferRunAction(_ kind: PendingRunAction.Kind, for identity: WorkspaceIdentity) {
        guard isCurrentWorkspace(identity) else { return }
        runWorkflowCoordinator.deferAction(kind, for: identity)
    }

    private func runSelectedConfigurationAfterActivation() async {
        guard let identity = currentWorkspaceIdentity else { return }
        guard let runFeature = await activateExecutionModule()?.runFeature else { return }
        guard isCurrentWorkspace(identity) else { return }
        switch await ensureRunProjectReady(runFeature, for: identity) {
        case .ready:
            clearPendingRunAction(for: identity)
        case .waitingForSnapshot(let waitingIdentity):
            deferRunAction(.run, for: waitingIdentity)
            return
        case .stale:
            return
        }
        let configurationReadiness = runWorkflowCoordinator.configurationReadiness(
            status: runFeature.configurationStatus,
            selected: runFeature.selectedConfiguration
        )
        switch configurationReadiness {
        case .needsGeneration:
            runFeature.requestRunConfigurationGeneration(intent: .run)
            return
        case .unavailable:
            return
        case .ready:
            break
        }
        guard case .ready(let configuration) = configurationReadiness else { return }
        if !(await activateLanguageRunExtensionIfNeeded(
            for: configuration,
            currentFileURL: activeDocument?.url,
            runFeature: runFeature
        )) {
            return
        }
        guard isCurrentWorkspace(identity) else { return }
        guard await runWorkflowCoordinator.saveDirtyCurrentFileIfNeeded(
            configuration: configuration,
            document: activeDocument,
            saving: self
        ) else {
            return
        }
        guard isCurrentWorkspace(identity) else { return }
        let javaLaunch: JavaDebugLaunchTarget?
        do {
            javaLaunch = try await prepareJavaRunLaunch(
                for: configuration,
                identity: identity
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentWorkspace(identity) else { return }
            showNotification(error.localizedDescription)
            return
        }
        guard isCurrentWorkspace(identity) else { return }
        if configuration.kind != .currentFile {
            runFeature.startConfiguration(configuration, javaLaunch: javaLaunch)
        } else {
            runFeature.runSelected(currentFileURL: activeDocument?.url, javaLaunch: javaLaunch)
        }
        showToolWindow(.run)
    }

    func restartSelectedRun() {
        if let configuration = runFeatureIfActive?.selectedConfiguration,
           configuration.kind != .currentFile {
            startRunConfiguration(configuration)
            return
        }
        showToolWindow(.run)
        Task { [weak self] in
            guard let self else { return }
            guard let identity = currentWorkspaceIdentity else { return }
            guard let runFeature = await activateExecutionModule()?.runFeature else { return }
            guard isCurrentWorkspace(identity) else { return }
            guard runFeature.lastConfiguration != nil else { return }
            switch await ensureRunProjectReady(runFeature, for: identity) {
            case .ready:
                clearPendingRunAction(for: identity)
            case .waitingForSnapshot(let waitingIdentity):
                deferRunAction(.restart, for: waitingIdentity)
                return
            case .stale:
                return
            }
            guard let configuration = runFeature.lastConfiguration else { return }
            if !(await activateLanguageRunExtensionIfNeeded(
                for: configuration,
                currentFileURL: runFeature.lastRunFileURL,
                runFeature: runFeature
            )) {
                return
            }
            guard isCurrentWorkspace(identity) else { return }
            let javaLaunch: JavaDebugLaunchTarget?
            do {
                javaLaunch = try await prepareJavaRunLaunch(
                    for: configuration,
                    identity: identity
                )
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentWorkspace(identity) else { return }
                showNotification(error.localizedDescription)
                return
            }
            guard isCurrentWorkspace(identity) else { return }
            runFeature.restart(javaLaunch: javaLaunch)
        }
    }

    func startRunConfiguration(_ configuration: RunConfiguration) {
        Task { [weak self] in
            await self?.performStartRunConfiguration(configuration)
        }
    }

    func startSelectedServiceConfigurations(_ configurations: [RunConfiguration]) {
        guard !configurations.isEmpty else { return }
        Task { [weak self] in
            guard let self, let identity = currentWorkspaceIdentity else { return }
            guard let runFeature = await activateExecutionModule()?.runFeature else { return }
            guard isCurrentWorkspace(identity) else { return }
            switch await ensureRunProjectReady(runFeature, for: identity) {
            case .ready:
                clearPendingRunAction(for: identity)
            case .waitingForSnapshot(let waitingIdentity):
                deferRunAction(.startSelectedServices(configurations), for: waitingIdentity)
                return
            case .stale:
                return
            }
            for configuration in configurations {
                guard configuration.execution == .service,
                      await activateLanguageRunExtensionIfNeeded(
                        for: configuration, currentFileURL: nil, runFeature: runFeature
                      ),
                      isCurrentWorkspace(identity) else { return }
            }
            var preparedConfigurations: [(RunConfiguration, JavaDebugLaunchTarget?)] = []
            do {
                for configuration in configurations {
                    guard isCurrentWorkspace(identity) else { return }
                    let target = try await prepareJavaRunLaunch(
                        for: configuration,
                        identity: identity
                    )
                    preparedConfigurations.append((configuration, target))
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentWorkspace(identity) else { return }
                showNotification(error.localizedDescription)
                return
            }
            for (configuration, javaLaunch) in preparedConfigurations {
                guard isCurrentWorkspace(identity) else { return }
                runFeature.startConfiguration(configuration, javaLaunch: javaLaunch)
            }
            showToolWindow(.run)
        }
    }

    /// Completes a run action for the current workspace opening.
    func performStartRunConfiguration(_ configuration: RunConfiguration) async {
        guard let identity = currentWorkspaceIdentity else { return }
        guard let runFeature = await activateExecutionModule()?.runFeature else { return }
        guard isCurrentWorkspace(identity) else { return }
        switch await ensureRunProjectReady(runFeature, for: identity) {
        case .ready:
            clearPendingRunAction(for: identity)
        case .waitingForSnapshot(let waitingIdentity):
            deferRunAction(.startConfiguration(configuration), for: waitingIdentity)
            return
        case .stale:
            return
        }
        guard await activateLanguageRunExtensionIfNeeded(
            for: configuration,
            currentFileURL: activeDocument?.url,
            runFeature: runFeature
        ) else { return }
        guard isCurrentWorkspace(identity) else { return }
        let javaLaunch: JavaDebugLaunchTarget?
        do {
            javaLaunch = try await prepareJavaRunLaunch(for: configuration, identity: identity)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentWorkspace(identity) else { return }
            showNotification(error.localizedDescription)
            return
        }
        guard isCurrentWorkspace(identity) else { return }
        runFeature.startConfiguration(configuration, javaLaunch: javaLaunch)
        showToolWindow(.run)
    }

    private func prepareJavaRunLaunch(
        for configuration: RunConfiguration,
        identity: WorkspaceIdentity
    ) async throws -> JavaDebugLaunchTarget? {
        guard configuration.usesJavaProjectPreparation else { return nil }
        guard let workspaceURL,
              let sourceURL = runWorkflowCoordinator.sourceURLForDebug(
                configuration: configuration,
                activeDocument: activeDocument,
                projectFiles: projectFiles,
                workspaceURL: workspaceURL
              ) else {
            throw RunConfigurationOperationFailure(
                message: "The Java source for \(configuration.name) could not be resolved."
            )
        }
        let sessions = try await languageSessionsForWorkspaceMaintenance()
        guard isCurrentWorkspace(identity), !Task.isCancelled else {
            throw CancellationError()
        }
        let preparation = try await sessions.prepareJavaRunLaunchTarget(
            fileURL: sourceURL,
            rootURL: workspaceURL
        )
        return try await resolveJavaLaunchPreparation(preparation, identity: identity)
    }

    func startRunConfigurations(_ configurationIDs: [String]) {
        Task { [weak self] in
            await self?.performStartRunConfigurations(configurationIDs)
        }
    }

    func performStartRunConfigurations(_ configurationIDs: [String]) async {
        let ids = Set(configurationIDs).sorted()
        guard !ids.isEmpty, let identity = currentWorkspaceIdentity else { return }
        guard let runFeature = await activateExecutionModule()?.runFeature else { return }
        guard isCurrentWorkspace(identity) else { return }
        switch await ensureRunProjectReady(runFeature, for: identity) {
        case .ready:
            clearPendingRunAction(for: identity)
        case .waitingForSnapshot(let waitingIdentity):
            deferRunAction(.startConfigurations(ids), for: waitingIdentity)
            return
        case .stale:
            return
        }
        for id in ids {
            guard isCurrentWorkspace(identity) else { return }
            guard let configuration = runFeature.configurations.first(where: { $0.id == id }),
                  !configuration.usesCurrentEditorFile,
                  !runFeature.moduleSessions.contains(where: { $0.id == id && $0.isRunning })
            else { continue }
            let activated = await activateLanguageRunExtensionIfNeeded(
                for: configuration,
                currentFileURL: nil,
                runFeature: runFeature
            )
            guard isCurrentWorkspace(identity) else { return }
            guard activated,
                  let current = runFeature.configurations.first(where: { $0.id == id }),
                  !runFeature.moduleSessions.contains(where: { $0.id == id && $0.isRunning })
            else { continue }
            do {
                let javaLaunch = try await prepareJavaRunLaunch(
                    for: current,
                    identity: identity
                )
                guard isCurrentWorkspace(identity) else { return }
                runFeature.startConfiguration(current, javaLaunch: javaLaunch)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentWorkspace(identity) else { return }
                showNotification(error.localizedDescription)
            }
        }
        showToolWindow(.run)
    }

    func runAllServiceConfigurations() {
        Task { [weak self] in
            guard let self else { return }
            guard let identity = currentWorkspaceIdentity else { return }
            guard let runFeature = await activateExecutionModule()?.runFeature else { return }
            guard isCurrentWorkspace(identity) else { return }
            switch await ensureRunProjectReady(runFeature, for: identity) {
            case .ready:
                clearPendingRunAction(for: identity)
            case .waitingForSnapshot(let waitingIdentity):
                deferRunAction(.runAllServices, for: waitingIdentity)
                return
            case .stale:
                return
            }
            let serviceConfigurations = runFeature.configurations.filter { $0.execution == .service }
            for configuration in serviceConfigurations {
                guard await activateLanguageRunExtensionIfNeeded(
                    for: configuration,
                    currentFileURL: nil,
                    runFeature: runFeature
                ) else { return }
                guard isCurrentWorkspace(identity) else { return }
            }
            var javaLaunches: [String: JavaDebugLaunchTarget] = [:]
            do {
                for configuration in serviceConfigurations {
                    if let target = try await prepareJavaRunLaunch(
                        for: configuration,
                        identity: identity
                    ) {
                        javaLaunches[configuration.id] = target
                    }
                    guard isCurrentWorkspace(identity) else { return }
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentWorkspace(identity) else { return }
                showNotification(error.localizedDescription)
                return
            }
            runFeature.runAllServices(javaLaunches: javaLaunches)
        }
    }

    func stopSelectedRun() {
        if let feature = runFeatureIfActive,
           let configuration = feature.selectedConfiguration,
           configuration.kind != .currentFile {
            if let session = feature.moduleSessions.first(where: { $0.configurationID == configuration.id }) {
                feature.stopModule(session)
            }
            return
        }
        executionModuleCoordinator.stopFeatures(
            maven: nil,
            run: runFeatureIfActive
        )
    }

    func activateLanguageRunExtensionIfNeeded(
        for configuration: RunConfiguration,
        currentFileURL: URL?,
        runFeature: RunFeatureModel
    ) async -> Bool {
        await runWorkflowCoordinator.activateLanguageRunExtensionIfNeeded(
            for: configuration,
            currentFileURL: currentFileURL,
            runFeature: runFeature
        )
    }
}

/// Actions resumed by the run workflow coordinator.
extension AppModel: RunWorkflowActions {
    func loadProject(at workspaceURL: URL, files: [URL], snapshotID: UUID?) async {
        await loadProjectServices(at: workspaceURL, files: files, snapshotID: snapshotID)
    }

    func save(_ document: EditorDocument) async throws {
        try await saveDocument(document)
    }
}

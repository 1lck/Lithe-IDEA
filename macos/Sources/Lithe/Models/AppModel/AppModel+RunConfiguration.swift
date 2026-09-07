import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

/// Run, Maven, and Spring tool window entry points.
///
/// The workspace readiness gate lives here because Run, Debug, and Test all
/// enter through it: an action that arrives before the workspace snapshot has
/// been applied is deferred and resumed by the snapshot callback rather than
/// launched against a provisional inventory.
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
        showToolWindow(.maven)
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.run(phase: phase, module: module)
        }
    }

    func runMavenGoal(_ goal: String, module: MavenModule?) {
        showToolWindow(.maven)
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.runCustomGoal(goal, module: module)
        }
    }

    func stopMaven() {
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

    /// 打开源码文件并定位到指定行/列(供构建输出、运行堆栈等可点击文本跳转)。
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

    /// The single entry point for identification.
    ///
    /// Routing it through here is what keeps the run service from scanning a
    /// superseded snapshot: the service can only compare its own state, so the
    /// caller has to bring it up to the current snapshot first. When that fails,
    /// generation must stop — the service may still hold an older `.ready`
    /// inventory, and scanning it would overwrite `generated.json` with stale
    /// entry points.
    func generateRunConfigurations() async {
        guard let identity = currentWorkspaceIdentity else { return }
        guard let runFeature = await activateExecutionModule()?.runFeature else { return }
        guard isCurrentWorkspace(identity) else { return }
        switch await ensureRunProjectReady(runFeature, for: identity) {
        case .ready:
            await runFeature.generateRunConfigurations()
        case .waitingForSnapshot:
            // Report the pending workspace through the generation state when the
            // snapshot has not arrived, which the run panel surfaces as a notice.
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

    /// Loads project services for the scan currently applied to the workspace.
    ///
    /// Callers that only want "whatever the workspace has now" use this so the
    /// file list and its identity are captured in a single read.
    func loadProjectServicesForAppliedSnapshot(at workspaceURL: URL) async {
        let applied = workspaceFeature.appliedSnapshot
        await loadProjectServices(
            at: workspaceURL,
            files: applied?.files ?? [],
            snapshotID: applied?.id
        )
    }

    /// Loads build-system and run state at the workspace boundary. The generic
    /// run lifecycle is intentionally not owned by JavaFeatureModel.
    ///
    /// Spring indexing is scheduled rather than awaited. It scales with the
    /// number of Java sources, and run configurations, test discovery, and the
    /// Git refresh that follows this call must not wait for it.
    ///
    /// `files` and `snapshotID` must describe the same scan; the caller captures
    /// them together. `resumesDeferredRunAction` is set only by the workspace
    /// snapshot callback, because a deferred Run waits for a snapshot and
    /// resuming from any other load would either re-enter through
    /// `ensureRunProjectReady` or fire the action from an unrelated reload.
    func loadProjectServices(
        at workspaceURL: URL,
        files: [URL],
        snapshotID: UUID?,
        resumesDeferredRunAction: Bool = false
    ) async {
        let target = workspaceURL.standardizedFileURL
        // The caller established that this load belongs to the current opening,
        // so the identity is captured here and re-checked after every await.
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
        guard let execution = await activateExecutionModule() else { return }
        // Module activation suspends; a project switch or a reopen must not let
        // this load write the captured inventory into the new opening's run
        // service.
        guard isCurrentWorkspace(identity) else { return }
        execution.tests.discover(workspaceURL: target, files: files)
        // `files` and `snapshotID` are captured together by the caller. Reading
        // the applied snapshot here instead would pair this file list with a
        // newer scan's identity, which the readiness comparison cannot detect.
        await execution.projectDevelopment.loadProject(
            at: target,
            files: files,
            snapshotID: snapshotID
        )
        guard isCurrentWorkspace(identity) else { return }
        guard resumesDeferredRunAction else { return }
        runWorkflowCoordinator.resumeDeferredAction(
            runFeature: execution.runFeature,
            identity: identity,
            snapshotID: snapshotID
        )
    }

    /// The opening an entry task captures before its first await.
    var currentWorkspaceIdentity: WorkspaceIdentity? {
        guard let url = workspaceURL?.standardizedFileURL else { return nil }
        return WorkspaceIdentity(url: url, generation: workspaceFeature.workspaceGeneration)
    }

    func isCurrentWorkspace(_ identity: WorkspaceIdentity) -> Bool {
        currentWorkspaceIdentity == identity
    }

    /// Brings the run feature up to the snapshot for a captured opening.
    ///
    /// Entry tasks capture the opening before any await so a project switch — or
    /// a close and reopen of the same path — can be reported as `.stale` instead
    /// of being re-deferred against whatever is current when the load finishes.
    ///
    /// When a newer snapshot is published but the run service still holds an
    /// older `.ready` inventory for this workspace, the snapshot callback owns
    /// the transition. Loading from the entry path would race that callback and
    /// let Restart proceed from a half-applied refresh.
    ///
    /// When the run service is not already ready for this workspace, the entry
    /// path applies the published scan itself (open-before-run, prune, tool
    /// window) so readiness does not wait on a callback that may never arrive.
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
            // Launching from a provisional inventory resolves toolchains without
            // the Maven project, so wait for the snapshot instead of running.
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
        guard runWorkflowCoordinator.saveDirtyCurrentFileIfNeeded(
            configuration: configuration,
            document: activeDocument,
            saving: self
        ) else {
            return
        }
        guard isCurrentWorkspace(identity) else { return }
        runFeature.runSelected(currentFileURL: activeDocument?.url)
        showToolWindow(.run)
    }

    func restartSelectedRun() {
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
            runFeature.restart()
        }
    }

    func startRunConfiguration(_ configuration: RunConfiguration) {
        Task { [weak self] in
            guard let self else { return }
            guard let identity = currentWorkspaceIdentity else { return }
            guard let runFeature = await activateExecutionModule()?.runFeature else { return }
            guard isCurrentWorkspace(identity) else { return }
            switch await ensureRunProjectReady(runFeature, for: identity) {
            case .ready:
                clearPendingRunAction(for: identity)
            case .waitingForSnapshot(let waitingIdentity):
                // Direct play buttons reach here without going through
                // `runSelectedConfiguration`, so they need the same readiness
                // gate and must remember which configuration to resume — bound
                // to the opening this task started for, not whatever is current
                // after an await.
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
            runFeature.startConfiguration(configuration)
        }
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
            for configuration in runFeature.configurations where configuration.execution == .service {
                guard await activateLanguageRunExtensionIfNeeded(
                    for: configuration,
                    currentFileURL: nil,
                    runFeature: runFeature
                ) else { return }
                guard isCurrentWorkspace(identity) else { return }
            }
            runFeature.runAllServices()
        }
    }

    func stopSelectedRun() {
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

/// Run entry points the workflow coordinator resumes a deferred action into.
///
/// Conforming here rather than passing closures keeps the resume path a single
/// call on a connected object; the coordinator holds it weakly.
extension AppModel: RunWorkflowActions {
    func loadProject(at workspaceURL: URL, files: [URL], snapshotID: UUID?) async {
        await loadProjectServices(at: workspaceURL, files: files, snapshotID: snapshotID)
    }

    func save(_ document: EditorDocument) throws {
        try saveDocument(document)
    }
}

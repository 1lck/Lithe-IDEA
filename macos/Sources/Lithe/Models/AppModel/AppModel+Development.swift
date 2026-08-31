import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheExecutionModule
import LitheModuleAPI

/// One opening of one workspace.
///
/// The path alone repeats when the same project is closed and reopened, so a
/// task that started before the reopen would still compare equal to the current
/// workspace. Pairing the path with the opening's generation is what lets such a
/// task be recognized as belonging to a session that is over.
struct WorkspaceIdentity: Equatable {
    let url: URL
    let generation: Int
}

/// An action deferred until the run feature holds the current workspace snapshot.
///
/// The opening it was deferred for is part of the value so a snapshot applied for
/// a different workspace — or for a later opening of the same one — cannot resume
/// it. Direct launch entry points also keep the concrete configuration (or the
/// all-services intent) so resume can re-issue the same action the UI asked for.
struct PendingRunAction: Equatable {
    enum Kind: Equatable {
        case run
        case debug
        case startConfiguration(RunConfiguration)
        case runAllServices
        case restart
    }

    let kind: Kind
    let identity: WorkspaceIdentity
}

/// Result of bringing the run feature up to a specific opening's snapshot.
///
/// Distinguishing "still waiting on this opening" from "this entry task is
/// stale" is what stops an await that outlived a project switch or a reopen from
/// re-recording the old action against the current pending slot.
private enum RunProjectReadiness: Equatable {
    case ready
    case waitingForSnapshot(identity: WorkspaceIdentity)
    case stale
}

@MainActor
final class JavaTestWorkflowState {
    var resultServer: (any JavaTestResultServing)?
    var debugLaunchTask: Task<Void, Never>?
    var debugLaunchOperationID: UUID?
    var discoveryTask: Task<Void, Never>?
    var discoveryOperationID: UUID?
}

@MainActor
extension AppModel {
    func toggleSpringEndpoints() {
        isSpringVisible.toggle()
        guard isSpringVisible else { return }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
    }

    func openSpringEndpoint(_ endpoint: SpringEndpoint) {
        navigateToEditorLocation(
            url: endpoint.url,
            line: max(0, endpoint.line - 1),
            utf16Column: max(0, endpoint.column - 1)
        )
    }

    func toggleRun() {
        isRunVisible.toggle()
        guard isRunVisible else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await activateExecutionModule() != nil else { return }
            if let workspaceURL {
                await loadProjectServicesForAppliedSnapshot(at: workspaceURL)
            }
        }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isDebugVisible = false
    }

    func toggleMaven() {
        guard hasMavenProject else {
            showNotification("No Maven project was detected in this workspace")
            isMavenVisible = false
            return
        }
        isMavenVisible.toggle()
        guard isMavenVisible else { return }
        Task { [weak self] in
            guard let self, await activateExecutionModule() != nil,
                  let workspaceURL else { return }
            await loadProjectServicesForAppliedSnapshot(at: workspaceURL)
        }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isRunVisible = false
        isDebugVisible = false
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
        isMavenVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isRunVisible = false
        isDebugVisible = false
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.run(phase: phase, module: module)
        }
    }

    func runMavenGoal(_ goal: String, module: MavenModule?) {
        isMavenVisible = true
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.runCustomGoal(goal, module: module)
        }
    }

    func stopMaven() {
        mavenFeatureIfActive?.stop()
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

    /// Reveals a stopped debugger frame without adding every step to the
    /// user's editor back/forward history. Debug stepping is transient
    /// inspection, unlike an explicit navigation from build output or a link.
    func revealDebugLocation(url: URL, line: Int, column: Int?) {
        let normalizedURL = url.standardizedFileURL
        guard workspaceFeature.fileExists(at: normalizedURL) else {
            showNotification("The stopped source file is no longer available: \(url.lastPathComponent)")
            return
        }
        navigate(
            to: EditorNavigationLocation(
                url: normalizedURL,
                line: max(0, line - 1),
                utf16Column: max(0, (column ?? 1) - 1),
                isReadOnly: false,
                displayPath: nil,
                virtualProviderID: nil
            ),
            recordsHistory: false
        )
    }

    func toggleProblems() {
        isProblemsVisible.toggle()
        guard isProblemsVisible else { return }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
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
        resumeDeferredRunAction(
            execution.runFeature,
            identity: identity,
            snapshotID: snapshotID
        )
    }

    /// The opening an entry task captures before its first await.
    var currentWorkspaceIdentity: WorkspaceIdentity? {
        guard let url = workspaceURL?.standardizedFileURL else { return nil }
        return WorkspaceIdentity(url: url, generation: workspaceFeature.workspaceGeneration)
    }

    private func isCurrentWorkspace(_ identity: WorkspaceIdentity) -> Bool {
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
    private func ensureRunProjectReady(
        _ runFeature: RunFeatureModel,
        for identity: WorkspaceIdentity
    ) async -> RunProjectReadiness {
        guard isCurrentWorkspace(identity) else { return .stale }
        let target = identity.url
        // One read, so the file list and the identity describe the same scan.
        let applied = workspaceFeature.appliedSnapshot
        if runFeature.isProjectReady(for: target, snapshotID: applied?.id) { return .ready }
        if applied != nil, runFeature.hasReadyInventory(for: target) {
            return .waitingForSnapshot(identity: identity)
        }
        // No matching ready inventory: bind provisionally, or apply the
        // published scan when one already exists.
        await loadProjectServices(
            at: target,
            files: applied?.files ?? [],
            snapshotID: applied?.id
        )
        // A snapshot may land and be fully consumed while this load is in
        // flight, including its deferred-run resume with nothing pending yet.
        // Comparing against the pre-await capture would then treat a ready
        // project as not ready, defer the action, and leave it stranded.
        guard isCurrentWorkspace(identity) else { return .stale }
        let current = workspaceFeature.appliedSnapshot
        if runFeature.isProjectReady(for: target, snapshotID: current?.id) {
            return .ready
        }
        return .waitingForSnapshot(identity: identity)
    }

    /// Continues an action that arrived before the snapshot did. The workspace
    /// rebuild always finishes by applying a snapshot, so recording the intent is
    /// enough to resume without polling or waiting.
    ///
    /// A load for one opening must not clear a pending action that belongs to
    /// another: openProject already cleared the old pending on the switch, and a
    /// stale callback arriving later would otherwise wipe the newly recorded
    /// intent.
    /// `snapshotID` is the scan this load just applied, not whatever the
    /// workspace holds now. Reading the current identity here would compare the
    /// run feature against a scan it has not consumed.
    private func resumeDeferredRunAction(
        _ runFeature: RunFeatureModel,
        identity: WorkspaceIdentity,
        snapshotID: UUID?
    ) {
        guard let action = pendingRunAction else { return }
        guard action.identity == identity else { return }
        guard runFeature.isProjectReady(for: identity.url, snapshotID: snapshotID) else {
            return
        }
        setPendingRunAction(nil)
        switch action.kind {
        case .run: runSelectedConfiguration()
        case .debug: startDebugging()
        case .startConfiguration(let configuration): startRunConfiguration(configuration)
        case .runAllServices: runAllServiceConfigurations()
        case .restart: restartSelectedRun()
        }
    }

    /// Records an action for the opening the entry task captured, not whatever
    /// workspace happens to be current after an await.
    private func clearPendingRunAction(for identity: WorkspaceIdentity) {
        guard pendingRunAction?.identity == identity else { return }
        setPendingRunAction(nil)
    }

    private func setPendingRunAction(_ action: PendingRunAction?) {
        pendingRunAction = action
        // pendingRunAction is not @Published; relay so tests and any UI that
        // observes AppModel learn about defer/resume without a feature load.
        scheduleObjectWillChangeRelay()
    }

    private func deferRunAction(_ kind: PendingRunAction.Kind, for identity: WorkspaceIdentity) {
        guard isCurrentWorkspace(identity) else { return }
        setPendingRunAction(PendingRunAction(kind: kind, identity: identity))
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
        guard runFeature.configurationStatus == .ready else {
            runFeature.requestRunConfigurationGeneration(intent: .run)
            return
        }
        guard let configuration = runFeature.selectedConfiguration else { return }
        if !(await activateLanguageRunExtensionIfNeeded(
            for: configuration,
            currentFileURL: activeDocument?.url,
            runFeature: runFeature
        )) {
            return
        }
        guard isCurrentWorkspace(identity) else { return }
        if configuration.usesCurrentEditorFile,
           let activeDocument,
           activeDocument.isDirty {
            do {
                let previousText = activeDocument.savedText
                try saveDocument(activeDocument)
                recordSave(activeDocument, previousText: previousText)
            } catch {
                showNotification("Could not save \(activeDocument.url.lastPathComponent)")
                return
            }
        }
        guard isCurrentWorkspace(identity) else { return }
        runFeature.runSelected(currentFileURL: activeDocument?.url)
        isRunVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isMavenVisible = false
        isDebugVisible = false
    }

    func restartSelectedRun() {
        isRunVisible = true
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
        runFeatureIfActive?.stop()
    }

    private func activateLanguageRunExtensionIfNeeded(
        for fileURL: URL,
        runFeature: RunFeatureModel
    ) async -> Bool {
        guard let ownership = services.pluginCatalog.languageSupport(for: fileURL) else {
            return true
        }
        return await activateLanguageRunExtension(
            ownership.declaration,
            runFeature: runFeature
        )
    }

    private func activateLanguageRunExtensionIfNeeded(
        for configuration: RunConfiguration,
        currentFileURL: URL?,
        runFeature: RunFeatureModel
    ) async -> Bool {
        if configuration.usesCurrentEditorFile {
            guard let currentFileURL else { return true }
            return await activateLanguageRunExtensionIfNeeded(
                for: currentFileURL,
                runFeature: runFeature
            )
        }
        guard let ownership = services.pluginCatalog.languageSupports[
            configuration.kind.providerID
        ] else {
            return true
        }
        return await activateLanguageRunExtension(
            ownership.declaration,
            runFeature: runFeature
        )
    }

    private func activateLanguageRunExtension(
        _ support: LanguageSupportDeclaration,
        runFeature: RunFeatureModel
    ) async -> Bool {
        guard support.executionModuleID != nil else {
            showNotification("\(support.displayName) does not provide project execution")
            return false
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(
                .languageExecutionExtension(support.id)
            )
            guard let provider = value as? any LanguageRunExtensionProviding,
                  runFeature.registerLanguageRunExtension(provider, support: support) else {
                showNotification("\(support.displayName) returned an invalid execution provider")
                return false
            }
            return true
        } catch {
            showNotification(error.localizedDescription)
            return false
        }
    }

    func toggleDebug() {
        isDebugVisible.toggle()
        guard isDebugVisible else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await activateExecutionModule() != nil else { return }
            if let workspaceURL {
                await loadProjectServicesForAppliedSnapshot(at: workspaceURL)
            }
            _ = await activateDebugModule()
        }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
    }

    func showDebugBreakpointManager() {
        guard let requestedWorkspaceURL = workspaceURL else { return }
        Task { [weak self] in
            guard let self,
                  await activateDebugModule() != nil,
                  workspaceURL == requestedWorkspaceURL else { return }
            debugBreakpointPresentation.isManagerPresented = true
        }
    }

    func startDebugging() {
        Task { [weak self] in await self?.startDebuggingAfterActivation() }
    }

    func startOrRestartDebugging() {
        guard let feature = genericDebugFeatureIfActive,
              feature.isSessionActive else {
            startDebugging()
            return
        }
        showDebugToolWindow()
        if feature.canRestart {
            feature.execute(.restart)
        }
    }

    func attachJavaDebugger(host: String, port: Int) {
        Task { [weak self] in
            await self?.attachJavaDebuggerAfterActivation(host: host, port: port)
        }
    }

    private func attachJavaDebuggerAfterActivation(host: String, port: Int) async {
        guard let workspaceURL,
              await activateDebugModule() != nil else { return }
        let sourceURL = ([activeDocument?.url].compactMap { $0 } + projectFiles)
            .map(\.standardizedFileURL)
            .first {
                languageProviderCatalog.provider(for: $0)?.id == "java"
            }
        guard let sourceURL else {
            showNotification("Open a Java project before connecting the debugger")
            return
        }
        let configuration: DebugLaunchConfiguration
        do {
            configuration = try debugLaunchConfigurationResolver.resolveJavaAttach(
                host: host,
                port: port
            )
        } catch {
            showNotification(error.localizedDescription)
            return
        }
        guard let genericDebugFeature = genericDebugFeatureIfActive,
              genericDebugFeature.start(
                  fileURL: sourceURL,
                  rootURL: workspaceURL,
                  configuration: configuration
              ) else {
            showNotification(
                genericDebugFeatureIfActive?.errorMessage ?? "Could not connect to the JVM"
            )
            isDebugVisible = true
            return
        }
        showDebugToolWindow()
    }

    private func startDebuggingAfterActivation() async {
        guard let identity = currentWorkspaceIdentity else { return }
        guard let execution = await activateExecutionModule(),
              isCurrentWorkspace(identity) else { return }
        let runFeature = execution.runFeature
        switch await ensureRunProjectReady(runFeature, for: identity) {
        case .ready:
            clearPendingRunAction(for: identity)
        case .waitingForSnapshot(let waitingIdentity):
            deferRunAction(.debug, for: waitingIdentity)
            return
        case .stale:
            return
        }
        let workspaceURL = identity.url
        guard isCurrentWorkspace(identity) else { return }
        guard await activateDebugModule() != nil,
              isCurrentWorkspace(identity) else { return }
        guard runFeature.configurationStatus == .ready else {
            runFeature.requestRunConfigurationGeneration(intent: .debug)
            return
        }
        guard let selectedConfiguration = runFeature.selectedConfiguration else {
            showNotification("Choose a Run configuration before starting Debug")
            return
        }
        let configuration = DebugLaunchSourceResolver().configurationForDebug(
            selected: selectedConfiguration,
            activeDocumentText: activeDocument?.text,
            configurations: runFeature.configurations
        )
        runFeature.select(configuration)

        let sourceURL: URL
        if configuration.usesCurrentEditorFile {
            guard let document = activeDocument else {
                showNotification("Open a source file or choose a project Run configuration")
                return
            }
            sourceURL = document.url
        } else if configuration.kind.capabilities.contains(.jdwpDebug) {
            guard let resolved = DebugLaunchSourceResolver().resolve(
                configuration: configuration,
                activeDocumentURL: activeDocument?.url,
                projectFiles: projectFiles,
                workspaceURL: workspaceURL
            ) else {
                showNotification("Could not find the Java source for \(configuration.name)")
                return
            }
            sourceURL = resolved
        } else {
            showNotification("\(configuration.name) does not support Debug yet")
            return
        }

        guard languageProviderCatalog.provider(for: sourceURL)?
            .capabilities.contains(.debugAdapter) == true else {
            showNotification("Debug support is not available for \(sourceURL.lastPathComponent)")
            isDebugVisible = true
            return
        }
        let document = openDocuments.first {
            $0.url.standardizedFileURL == sourceURL.standardizedFileURL
        }
        await startGenericDebuggingAfterActivation(fileURL: sourceURL, document: document)
    }

    func toggleTests() {
        isTestsVisible.toggle()
        guard isTestsVisible else {
            cancelLanguageTestDiscovery()
            return
        }
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        guard let workspaceURL else { return }
        startLanguageTestDiscovery(workspaceURL: workspaceURL)
    }

    func refreshTests() {
        guard let workspaceURL else { return }
        startLanguageTestDiscovery(workspaceURL: workspaceURL)
    }

    private func startLanguageTestDiscovery(workspaceURL: URL) {
        cancelLanguageTestDiscovery()
        let operationID = UUID()
        javaTestWorkflowState.discoveryOperationID = operationID
        javaTestWorkflowState.discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { finishLanguageTestDiscovery(operationID) }
            guard let execution = await activateExecutionModule(),
                  await activateLanguageTestExtensionsIfNeeded(
                      for: projectFiles,
                      testService: execution.tests
                  ),
                  isCurrentLanguageTestDiscovery(operationID) else { return }
            execution.tests.discover(workspaceURL: workspaceURL, files: projectFiles)

            let baseItems = execution.tests.itemsByProviderID["java"] ?? []
            let javaFiles = baseItems.filter { $0.kind == .file && $0.fileURL != nil }
            guard !javaFiles.isEmpty else { return }
            do {
                let sessions = try await languageSessionsForWorkspaceMaintenance()
                var projected = baseItems.filter { $0.kind == .workspace }
                var completedFileCount = 0
                for fileItem in javaFiles {
                    try Task.checkCancellation()
                    guard isCurrentLanguageTestDiscovery(operationID),
                          let fileURL = fileItem.fileURL else { return }
                    do {
                        let details = try await sessions.discoverJavaTestItems(
                            fileURL: fileURL,
                            rootURL: workspaceURL
                        )
                        completedFileCount += 1
                        if !details.isEmpty {
                            projected.append(fileItem)
                            projected.append(contentsOf: details)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Preserve the cheap file-level fallback when semantic
                        // discovery fails for only one source file.
                        projected.append(fileItem)
                    }
                }
                guard isCurrentLanguageTestDiscovery(operationID) else { return }
                if projected.allSatisfy({ $0.kind == .workspace }), completedFileCount > 0 {
                    projected = []
                }
                execution.tests.replaceDiscoveredItems(projected, providerID: "java")
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentLanguageTestDiscovery(operationID) else { return }
                showNotification(error.localizedDescription)
            }
        }
    }

    func cancelLanguageTestDiscovery() {
        javaTestWorkflowState.discoveryOperationID = nil
        javaTestWorkflowState.discoveryTask?.cancel()
        javaTestWorkflowState.discoveryTask = nil
    }

    private func isCurrentLanguageTestDiscovery(_ operationID: UUID) -> Bool {
        javaTestWorkflowState.discoveryOperationID == operationID && !Task.isCancelled
    }

    private func finishLanguageTestDiscovery(_ operationID: UUID) {
        guard javaTestWorkflowState.discoveryOperationID == operationID else { return }
        javaTestWorkflowState.discoveryOperationID = nil
        javaTestWorkflowState.discoveryTask = nil
    }

    func runTest(providerID: String, scope: LanguageTestScope) {
        guard let workspaceURL else { return }
        isTestsVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        Task { [weak self] in
            guard let self, let execution = await activateExecutionModule() else { return }
            if let ownership = services.pluginCatalog.languageSupports[providerID],
               !(await activateLanguageTestExtension(
                   ownership.declaration,
                   testService: execution.tests
               )) {
                return
            }
            _ = execution.tests.run(
                providerID: providerID,
                scope: scope,
                workspaceURL: workspaceURL,
                projectFiles: projectFiles
            )
        }
    }

    func debugTest(providerID: String, scope: LanguageTestScope) {
        guard providerID == "java", let workspaceURL else {
            showNotification("Java test debugging is currently available for Java projects only")
            return
        }
        let fileURL: URL
        let testIdentifier: String?
        switch scope {
        case .workspace:
            showNotification("Select a Java test file or test case to debug")
            return
        case .file(let url):
            fileURL = url.standardizedFileURL
            testIdentifier = nil
        case .testCase(let identifier, let url):
            guard let url else {
                showNotification("The selected Java test has no source file")
                return
            }
            fileURL = url.standardizedFileURL
            testIdentifier = identifier
        }
        cancelJavaTestDebugLaunch()
        let operationID = UUID()
        javaTestWorkflowState.debugLaunchOperationID = operationID
        javaTestWorkflowState.debugLaunchTask = Task { [weak self] in
            guard let self else { return }
            defer { finishJavaTestDebugLaunch(operationID) }
            guard let runFeature = await activateExecutionModule()?.runFeature,
                  let genericDebugFeature = await activateDebugModule()?.genericFeature,
                  isCurrentJavaTestDebugLaunch(operationID) else { return }
            if let selectedConfiguration = runFeature.selectedConfiguration {
                runFeature.select(selectedConfiguration)
            }
            if let document = openDocuments.first(where: {
                $0.url.standardizedFileURL == fileURL
            }),
               document.isDirty {
                do {
                    let previousText = document.savedText
                    try saveDocument(document)
                    recordSave(document, previousText: previousText)
                } catch {
                    showNotification("Could not save \(document.url.lastPathComponent)")
                    return
                }
            }
            do {
                let sessions = try await languageSessionsForWorkspaceMaintenance()
                let prepared = try await services.javaTestDebugLaunchService.prepare(
                    fileURL: fileURL,
                    testIdentifier: testIdentifier,
                    rootURL: workspaceURL,
                    targetResolver: sessions
                )
                guard isCurrentJavaTestDebugLaunch(operationID) else {
                    prepared.stop()
                    return
                }
                stopJavaTestResultServer()
                javaTestWorkflowState.resultServer = prepared.resultServer
                guard genericDebugFeature.start(
                    fileURL: prepared.target.fileURL,
                    rootURL: workspaceURL,
                    configuration: prepared.configuration
                ) else {
                    let message = genericDebugFeature.errorMessage
                        ?? "Could not debug the Java test"
                    stopJavaTestResultServer()
                    showNotification(message)
                    return
                }
                showDebugToolWindow()
            } catch is CancellationError {
                finishJavaTestDebugLaunch(operationID, stopResultServer: true)
            } catch {
                guard isCurrentJavaTestDebugLaunch(operationID) else { return }
                finishJavaTestDebugLaunch(operationID, stopResultServer: true)
                showNotification(error.localizedDescription)
            }
        }
    }

    private func activateLanguageTestExtensionsIfNeeded(
        for files: [URL],
        testService: LanguageTestService
    ) async -> Bool {
        let supports = services.pluginCatalog.languageSupports(
            recognizingProjectFileNames: files.map(\.lastPathComponent)
        )
        for ownership in supports where ownership.declaration.testingModuleID != nil {
            guard await activateLanguageTestExtension(
                ownership.declaration,
                testService: testService
            ) else { return false }
        }
        return true
    }

    private func activateLanguageTestExtension(
        _ support: LanguageSupportDeclaration,
        testService: LanguageTestService
    ) async -> Bool {
        guard support.testingModuleID != nil else {
            showNotification("\(support.displayName) does not provide test execution")
            return false
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(
                .languageTestingExtension(support.id)
            )
            guard let provider = value as? any LanguageTestExtensionProviding,
                  testService.registerLanguageTestExtension(provider, support: support) else {
                showNotification("\(support.displayName) returned an invalid test provider")
                return false
            }
            return true
        } catch {
            showNotification(error.localizedDescription)
            return false
        }
    }

    func stopTests() {
        languageTestServiceIfActive?.stop()
    }

    func stopDebugging() {
        cancelJavaTestDebugLaunch()
        guard let feature = genericDebugFeatureIfActive else {
            stopDebugTerminalProcesses()
            return
        }
        let activeSessionID = feature.activeSessionID
        feature.stop()
        if let activeSessionID {
            stopDebugTerminalProcesses(for: activeSessionID)
        } else {
            stopDebugTerminalProcesses()
        }
    }

    func cancelJavaTestDebugLaunch() {
        javaTestWorkflowState.debugLaunchOperationID = nil
        javaTestWorkflowState.debugLaunchTask?.cancel()
        javaTestWorkflowState.debugLaunchTask = nil
        stopJavaTestResultServer()
    }

    func stopJavaTestResultServer() {
        javaTestWorkflowState.resultServer?.stop()
        javaTestWorkflowState.resultServer = nil
    }

    func cancelJavaTestWorkflows() {
        cancelLanguageTestDiscovery()
        cancelJavaTestDebugLaunch()
    }

    func cancelJavaWorkspaceWorkflows() {
        cancelJavaLanguageServerPreparation()
        cancelJavaTestWorkflows()
    }

    func handleDebugSessionStateChange(_ state: DebugAdapterState) {
        // A Java launch may request an integrated terminal before the adapter
        // reaches `running`. Once the debug session is live, the debugger is
        // the primary tool window, matching IDEA's launch behavior; the
        // terminal session remains available as a separate session tab.
        if state == .launching || state == .running {
            showDebugToolWindow()
            return
        }
        if state == .paused {
            showDebugToolWindow()
            platformUI.activateApplication()
            return
        }
        guard state == .terminated || state == .failed else { return }
        stopJavaTestResultServer()
        if let activeSessionID = genericDebugFeatureIfActive?.activeSessionID {
            stopDebugTerminalProcesses(for: activeSessionID)
        } else {
            stopDebugTerminalProcesses()
        }
    }

    private func isCurrentJavaTestDebugLaunch(_ operationID: UUID) -> Bool {
        javaTestWorkflowState.debugLaunchOperationID == operationID && !Task.isCancelled
    }

    private func finishJavaTestDebugLaunch(
        _ operationID: UUID,
        stopResultServer: Bool = false
    ) {
        guard javaTestWorkflowState.debugLaunchOperationID == operationID else { return }
        javaTestWorkflowState.debugLaunchOperationID = nil
        javaTestWorkflowState.debugLaunchTask = nil
        if stopResultServer {
            stopJavaTestResultServer()
        }
    }

    func resumeDebugging() {
        guard let feature = genericDebugFeatureIfActive, feature.state == .paused else { return }
        feature.execute(.continueExecution)
    }

    func stepOverDebugging() {
        guard let feature = genericDebugFeatureIfActive, feature.state == .paused else { return }
        feature.execute(.next)
    }

    func stepIntoDebugging() {
        guard let feature = genericDebugFeatureIfActive, feature.state == .paused else { return }
        feature.execute(.stepIn)
    }

    func stepOutDebugging() {
        guard let feature = genericDebugFeatureIfActive, feature.state == .paused else { return }
        feature.execute(.stepOut)
    }

    func toggleDebugBreakpointAtCaret() {
        guard let document = activeDocument,
              let caret = editorCaret,
              caret.url.standardizedFileURL == document.url.standardizedFileURL else {
            showNotification("Place the caret in a source file to set a breakpoint")
            return
        }
        toggleDebugBreakpoint(fileURL: document.url, line: caret.line + 1)
    }

    func toggleDebugBreakpoint(fileURL: URL, line: Int) {
        if languageProviderCatalog.provider(for: fileURL)?.id == "java",
           let document = openDocuments.first(where: {
               $0.url.standardizedFileURL == fileURL.standardizedFileURL
           }),
           !DebugBreakpointLocationValidator.isExecutableJavaLine(
               source: document.text,
               line: line
           ) {
            showNotification("This line cannot hold a Java breakpoint")
            return
        }
        if languageProviderCatalog.provider(for: fileURL)?
            .capabilities.contains(.debugAdapter) == true {
            Task { [weak self] in
                guard let feature = await self?.activateDebugModule()?.genericFeature else { return }
                feature.toggleBreakpoint(fileURL: fileURL, line: line)
            }
        } else {
            showNotification("Debugging is not supported for this file type")
        }
    }

    func applyDebugSourceEdit(
        fileURL: URL,
        previousSource: String,
        replacedRange: NSRange,
        replacement: String
    ) {
        guard replacedRange.location != NSNotFound,
              replacedRange.location >= 0,
              replacedRange.length >= 0,
              NSMaxRange(replacedRange) <= previousSource.utf16.count else { return }
        genericDebugFeatureIfActive?.applySourceEdit(
            fileURL: fileURL,
            source: previousSource,
            edit: DebugSourceEdit(
                startUTF16Offset: replacedRange.location,
                endUTF16Offset: NSMaxRange(replacedRange),
                replacement: replacement
            )
        )
    }

    func editDebugBreakpoint(fileURL: URL, line: Int) {
        let normalizedURL = fileURL.standardizedFileURL
        debugBreakpointPresentation.pendingEditor = genericDebugFeatureIfActive?.breakpoints
            .filter {
                $0.fileURL.standardizedFileURL == normalizedURL && $0.line == line
            }
            .min { ($0.column ?? 0) < ($1.column ?? 0) }
    }

    func updateDebugBreakpoint(
        _ breakpoint: GenericDebugBreakpoint,
        enabled: Bool,
        condition: String?,
        hitCondition: String?,
        logMessage: String?
    ) {
        debugBreakpointPresentation.pendingEditor = nil
        guard let expectedWorkspaceURL = workspaceURL,
              workspaceRelativePath(
                  for: breakpoint.fileURL,
                  root: expectedWorkspaceURL
              ) != nil else { return }
        Task { [weak self] in
            guard let self,
                  self.workspaceURL == expectedWorkspaceURL,
                  let feature = await activateDebugModule()?.genericFeature,
                  self.workspaceURL == expectedWorkspaceURL else { return }
            feature.updateBreakpoint(
                fileURL: breakpoint.fileURL,
                line: breakpoint.line,
                enabled: enabled,
                condition: condition,
                hitCondition: hitCondition,
                logMessage: logMessage
            )
        }
    }

    func runToCursor(fileURL: URL, line: Int, column: Int) {
        guard let feature = genericDebugFeatureIfActive,
              feature.state == .paused,
              feature.capabilities.supportsGotoTargetsRequest else {
            showNotification("Run to Cursor is unavailable for the active debug session")
            return
        }
        feature.requestRunToCursor(
            fileURL: fileURL,
            line: line,
            column: column
        ) { [weak self, weak feature] result in
            switch result {
            case .success(let targets):
                guard let target = targets.min(by: {
                    abs(($0.column ?? column) - column) < abs(($1.column ?? column) - column)
                }) else {
                    self?.showNotification("No executable location was found at the cursor")
                    return
                }
                feature?.runToCursor(target)
            case .failure(let error):
                self?.showNotification(error.localizedDescription)
            }
        }
    }

    func requestDebugHover(
        expression: String,
        completion: @escaping (String?) -> Void
    ) {
        guard let feature = genericDebugFeatureIfActive,
              feature.state == .paused else {
            completion(nil)
            return
        }
        feature.evaluateForHover(expression) { variable in
            guard let variable else {
                completion(nil)
                return
            }
            let type = variable.type.map { " : \($0)" } ?? ""
            completion("\(expression)\(type) = \(variable.value)")
        }
    }

    private func startGenericDebuggingAfterActivation(
        fileURL: URL,
        document: EditorDocument?
    ) async {
        guard let workspaceURL,
              let provider = languageProviderCatalog.provider(for: fileURL),
              let runFeature = await activateExecutionModule()?.runFeature,
              let genericDebugFeature = await activateDebugModule()?.genericFeature else {
            showNotification("No language provider is available for this file")
            return
        }
        // Debug is the second execution mode for the Run selection. Re-apply
        // the selection here so its project-scoped Java runtime override is
        // active even when the Run panel was never opened in this session.
        if let selectedConfiguration = runFeature.selectedConfiguration {
            runFeature.select(selectedConfiguration)
        }
        if let document, document.isDirty {
            do {
                let previousText = document.savedText
                try saveDocument(document)
                recordSave(document, previousText: previousText)
            } catch {
                showNotification("Could not save \(document.url.lastPathComponent)")
                return
            }
        }
        // Reject an occupied service port before asking JDT LS to resolve the
        // launch target. A failed preflight therefore creates no language
        // service, Debug Adapter, terminal, or Java child process.
        if provider.id == "java",
           let selectedConfiguration = runFeature.selectedConfiguration,
           let port = runFeature.configuredServerPort(for: selectedConfiguration),
           !debugPortAvailabilityChecker.isPortAvailable(port) {
            showNotification(
                "Port \(port) is already in use. Stop the process using it or change server.port in the Run configuration."
            )
            isDebugVisible = true
            return
        }
        let configuration: DebugLaunchConfiguration
        do {
            let javaTarget: JavaDebugLaunchTarget?
            if provider.id == "java" {
                let sessions = try await languageSessionsForWorkspaceMaintenance()
                javaTarget = try await sessions.resolveJavaDebugLaunchTarget(
                    fileURL: fileURL,
                    rootURL: workspaceURL
                )
            } else {
                javaTarget = nil
            }
            configuration = try debugLaunchConfigurationResolver.resolve(
                provider: provider,
                documentURL: fileURL,
                workspaceURL: workspaceURL,
                configurations: runFeature.configurations,
                selectedConfiguration: runFeature.selectedConfiguration,
                javaTarget: javaTarget,
                options: { [runFeature] in runFeature.options(for: $0) }
            )
        } catch {
            showNotification(error.localizedDescription)
            return
        }
        guard genericDebugFeature.start(
            fileURL: fileURL,
            rootURL: workspaceURL,
            configuration: configuration
        ) else {
            showNotification(genericDebugFeature.errorMessage ?? "Could not start debugging")
            isDebugVisible = true
            return
        }
        showDebugToolWindow()
    }

    private func showDebugToolWindow() {
        isDebugVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
    }

    func goToDefinition() {
        if let document = activeDocument, let caret = editorCaret {
            let springLocations = springFeature.navigationLocations(
                for: document.url,
                line: caret.line
            )
            if !springLocations.isEmpty {
                presentGenericNavigationValues(
                    springLocations,
                    kind: .definitions,
                    navigateToSingleResult: true,
                    providerID: nil
                )
                return
            }
        }
        guard languageServerFeatureIsReady(
            .definition,
            unsupportedMessage: "Definition navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(method: "textDocument/definition", kind: .definitions)
    }

    func goToUsages() {
        guard languageServerFeatureIsReady(
            .references,
            unsupportedMessage: "Reference navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(
            method: "textDocument/references",
            kind: .references,
            navigateToSingleResult: true
        )
    }

    func goToImplementation() {
        guard languageServerFeatureIsReady(
            .implementation,
            unsupportedMessage: "Implementation navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(method: "textDocument/implementation", kind: .implementations)
    }

    func navigateToSymbol(line: Int, utf16Column: Int, in fileURL: URL) {
        let normalizedURL = fileURL.standardizedFileURL
        guard languageProviderCatalog.provider(for: normalizedURL)?.capabilities.contains(.languageServer) == true
        else { return }
        editorCaret = EditorCaret(
            url: normalizedURL,
            line: max(0, line),
            utf16Column: max(0, utf16Column)
        )
        if (languageToolingSessionsIfActive?.features(for: normalizedURL).contains(.definition) == true) {
            performGenericNavigation(
                method: "textDocument/definition",
                kind: .definitions,
                fallbackToImplementationsIfSelf: true
            )
        }
    }

    func findReferences() {
        guard languageServerFeatureIsReady(
            .references,
            unsupportedMessage: "Reference navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(
            method: "textDocument/references",
            kind: .references,
            navigateToSingleResult: false
        )
    }

    func findJavaImplementations(line: Int, utf16Column: Int, in fileURL: URL) {
        editorCaret = EditorCaret(
            url: fileURL.standardizedFileURL,
            line: line,
            utf16Column: utf16Column
        )
        guard languageServerFeatureIsReady(
            .implementation,
            unsupportedMessage: "Implementation navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(
            method: "textDocument/implementation",
            kind: .implementations,
            navigateToSingleResult: false
        )
    }

    func resolveJavaNavigation(_ marker: JavaImplementationMarker, in fileURL: URL) {
        guard !languageNavigationState.isLoading,
              let sessions = languageToolingSessionsIfActive,
              let provider = languageProviderCatalog.provider(for: fileURL) else { return }
        guard !isJavaLanguageServerPreparing(for: fileURL) else {
            showJavaLanguageServerPreparingNotification()
            return
        }
        let kind: LanguageNavigationResultKind = marker.direction == .down
            ? .implementations
            : .definitions
        let operationID = beginLanguageNavigation(providerID: provider.id, kind: kind)
        do {
            try sessions.resolveJavaNavigation(
                fileURL: fileURL,
                marker: marker.sharedMarker
            ) { [weak self] result in
                guard let self,
                      self.languageNavigationState.owns(operationID: operationID) else { return }
                switch result {
                case .success(let locations):
                    self.presentGenericNavigationValues(
                        locations,
                        kind: kind,
                        navigateToSingleResult: true,
                        providerID: provider.id
                    )
                case .failure(let error):
                    self.languageNavigationState = .idle
                    self.showNotification(error.localizedDescription)
                }
            }
        } catch {
            if languageNavigationState.owns(operationID: operationID) {
                languageNavigationState = .idle
            }
            showNotification(error.localizedDescription)
        }
    }

    func navigate(to location: LanguageNavigationLocation) {
        isImplementationChooserVisible = false
        navigate(
            to: EditorNavigationLocation(
                url: location.url,
                line: location.line,
                utf16Column: location.utf16Column,
                isReadOnly: location.isReadOnly,
                displayPath: location.displayPath,
                virtualProviderID: location.url.isFileURL ? nil : languageNavigationState.providerID
            ),
            recordsHistory: true
        )
    }

    var canNavigateBack: Bool { navigationHistoryFeature.canNavigateBack }
    var canNavigateForward: Bool { navigationHistoryFeature.canNavigateForward }

    func navigateBack() {
        let historySnapshot = navigationHistoryFeature.snapshot()
        guard let location = navigationHistoryFeature.navigateBack(
            from: currentEditorNavigationLocation()
        ) else { return }
        navigate(to: location, recordsHistory: false) { [weak self] in
            self?.navigationHistoryFeature.restore(historySnapshot)
        }
    }

    func navigateForward() {
        let historySnapshot = navigationHistoryFeature.snapshot()
        guard let location = navigationHistoryFeature.navigateForward(
            from: currentEditorNavigationLocation()
        ) else { return }
        navigate(to: location, recordsHistory: false) { [weak self] in
            self?.navigationHistoryFeature.restore(historySnapshot)
        }
    }

    func navigateToEditorLocation(
        url: URL,
        line: Int,
        utf16Column: Int,
        isReadOnly: Bool = false,
        displayPath: String? = nil,
        selectsWholeLine: Bool = false
    ) {
        navigate(
            to: EditorNavigationLocation(
                url: url,
                line: line,
                utf16Column: utf16Column,
                isReadOnly: isReadOnly,
                displayPath: displayPath,
                virtualProviderID: nil,
                selectsWholeLine: selectsWholeLine
            ),
            recordsHistory: true
        )
    }

    private func navigate(
        to location: EditorNavigationLocation,
        recordsHistory: Bool,
        onFailure: (() -> Void)? = nil
    ) {
        let departure = recordsHistory ? currentEditorNavigationLocation() : nil
        guard location.url.isFileURL else {
            if let existing = openDocuments.first(where: { $0.url == location.url }) {
                activeDocumentID = existing.id
                if recordsHistory {
                    navigationHistoryFeature.recordJump(from: departure, to: location)
                }
                editorNavigationTarget = EditorNavigationTarget(
                    url: location.url,
                    line: location.line,
                    utf16Column: location.utf16Column,
                    selectsWholeLine: location.selectsWholeLine
                )
                return
            }
            guard let providerID = location.virtualProviderID
                ?? virtualDocumentProviderIDs[location.url]
                ?? languageNavigationState.providerID else {
                showNotification("The virtual source provider is no longer available")
                onFailure?()
                return
            }
            guard let languageToolingSessions = languageToolingSessionsIfActive else {
                showNotification("The language source provider is not running")
                onFailure?()
                return
            }
            let operationID = beginLanguageNavigation(
                providerID: providerID,
                kind: languageNavigationState.kind
            )
            do {
                try languageToolingSessions.resolveVirtualDocument(
                    providerID: providerID,
                    uri: location.url
                ) { [weak self] result in
                    guard let self,
                          self.languageNavigationState.owns(operationID: operationID) else { return }
                    self.languageNavigationState = .idle
                    switch result {
                    case .success(let text):
                        self.virtualDocumentProviderIDs[location.url] = providerID
                        if recordsHistory {
                            self.navigationHistoryFeature.recordJump(from: departure, to: location)
                        }
                        self.documentFeature.openVirtualDocument(
                            location.url,
                            text: text,
                            displayPath: location.displayPath
                        )
                        self.editorNavigationTarget = EditorNavigationTarget(
                            url: location.url,
                            line: location.line,
                            utf16Column: location.utf16Column,
                            selectsWholeLine: location.selectsWholeLine
                        )
                    case .failure(let error):
                        onFailure?()
                        self.showNotification(error.localizedDescription)
                    }
                }
            } catch {
                if languageNavigationState.owns(operationID: operationID) {
                    languageNavigationState = .idle
                }
                onFailure?()
                showNotification(error.localizedDescription)
            }
            return
        }
        if recordsHistory {
            navigationHistoryFeature.recordJump(from: departure, to: location)
        }
        openFile(
            location.url,
            isReadOnly: location.isReadOnly,
            displayPath: location.displayPath
        )
        editorNavigationTarget = EditorNavigationTarget(
            url: location.url.standardizedFileURL,
            line: location.line,
            utf16Column: location.utf16Column,
            selectsWholeLine: location.selectsWholeLine
        )
    }

    private func currentEditorNavigationLocation() -> EditorNavigationLocation? {
        guard let document = activeDocument else { return nil }
        let documentURL = document.url.isFileURL ? document.url.standardizedFileURL : document.url
        let caret = editorCaret.flatMap { caret -> EditorCaret? in
            let caretURL = caret.url.isFileURL ? caret.url.standardizedFileURL : caret.url
            return caretURL == documentURL ? caret : nil
        }
        return EditorNavigationLocation(
            url: documentURL,
            line: caret?.line ?? 0,
            utf16Column: caret?.utf16Column ?? 0,
            isReadOnly: document.isReadOnly,
            displayPath: document.displayPath,
            virtualProviderID: virtualDocumentProviderIDs[documentURL]
        )
    }

    func closeLanguageNavigationResults() {
        isReferencesVisible = false
        isImplementationChooserVisible = false
        clearLanguageNavigationProjection()
    }

    func clearLanguageNavigationProjection() {
        languageNavigationState = .idle
    }

    private func beginLanguageNavigation(
        providerID: String,
        kind: LanguageNavigationResultKind
    ) -> UUID {
        let operationID = UUID()
        languageNavigationState = .loading(
            operationID: operationID,
            providerID: providerID,
            kind: kind
        )
        return operationID
    }

    func requestLanguageHover(
        line: Int,
        utf16Column: Int,
        completion: @escaping (LanguageServerHover?) -> Void
    ) {
        if let document = activeDocument,
           let hover = springFeature.hover(for: document.url, line: line) {
            completion(hover)
            return
        }
        guard let document = activeDocument,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.hover) == true),
              let workspaceURL else {
            completion(nil)
            return
        }
        do {
            try languageToolingSessionsIfActive?.hover(
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, line),
                    utf16Column: max(0, utf16Column)
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let hover): completion(hover)
                case .failure(let error):
                    self?.showNotification(error.localizedDescription)
                    completion(nil)
                }
            }
        } catch {
            showNotification(error.localizedDescription)
            completion(nil)
        }
    }

    func requestLanguageCompletions(
        line: Int,
        utf16Column: Int,
        completion: @escaping ([LanguageServerCompletionItem]) -> Void
    ) {
        guard let document = activeDocument else {
            completion([])
            return
        }
        let springCompletions = springFeature.completions(
            document: document,
            line: line,
            utf16Column: utf16Column
        )
        guard
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.completion) == true),
              let workspaceURL else {
            completion(springCompletions)
            return
        }
        do {
            try languageToolingSessionsIfActive?.completions(
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, line),
                    utf16Column: max(0, utf16Column)
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let values):
                    var seen = Set<String>()
                    completion((springCompletions + values).filter { seen.insert($0.label).inserted })
                case .failure(let error):
                    self?.showNotification(error.localizedDescription)
                    completion(springCompletions)
                }
            }
        } catch {
            showNotification(error.localizedDescription)
            completion(springCompletions)
        }
    }

    func requestLanguageRename(
        line: Int,
        utf16Column: Int,
        newName: String
    ) {
        guard let document = activeDocument,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.rename) == true),
              let workspaceURL else { return }
        do {
            try languageToolingSessionsIfActive?.rename(
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(line: max(0, line), utf16Column: max(0, utf16Column)),
                newName: newName,
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let edit): self?.applyLanguageWorkspaceEdit(edit)
                case .failure(let error): self?.showNotification(error.localizedDescription)
                }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func requestLanguageFormatting() {
        guard let document = activeDocument,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.formatting) == true),
              let workspaceURL else { return }
        do {
            try languageToolingSessionsIfActive?.format(
                fileURL: document.url,
                text: document.text,
                rootURL: workspaceURL
            ) { [weak self, weak document] result in
                guard let self, let document else { return }
                switch result {
                case .success(let edits):
                    self.applyLanguageWorkspaceEdit(
                        LanguageServerWorkspaceEdit(changes: [document.url.standardizedFileURL: edits])
                    )
                case .failure(let error): self.showNotification(error.localizedDescription)
                }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func requestLanguageCodeActions(
        line: Int,
        utf16Column: Int,
        completion: @escaping ([LanguageServerCodeAction]) -> Void
    ) {
        guard let document = activeDocument,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.codeActions) == true),
              let workspaceURL else { completion([]); return }
        let position = LanguageServerPosition(line: max(0, line), utf16Column: max(0, utf16Column))
        let range = LanguageServerRange(start: position, end: position)
        do {
            try languageToolingSessionsIfActive?.codeActions(
                fileURL: document.url,
                text: document.text,
                range: range,
                diagnostics: languageDiagnostics[document.url.standardizedFileURL] ?? [],
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let actions): completion(actions)
                case .failure(let error): self?.showNotification(error.localizedDescription); completion([])
                }
            }
        } catch { showNotification(error.localizedDescription); completion([]) }
    }

    func applyLanguageCodeAction(_ action: LanguageServerCodeAction) {
        guard let document = activeDocument, let workspaceURL else { return }
        guard action.data != nil,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.codeActionResolve) == true) else {
            performLanguageCodeAction(action, documentURL: document.url, rootURL: workspaceURL)
            return
        }
        do {
            try languageToolingSessionsIfActive?.resolveCodeAction(
                action,
                fileURL: document.url,
                text: document.text,
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let resolved):
                    self?.performLanguageCodeAction(resolved, documentURL: document.url, rootURL: workspaceURL)
                case .failure(let error): self?.showNotification(error.localizedDescription)
                }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    private func performLanguageCodeAction(
        _ action: LanguageServerCodeAction,
        documentURL: URL,
        rootURL: URL
    ) {
        if let edit = action.edit, !applyLanguageWorkspaceEdit(edit) { return }
        guard let command = action.command else {
            if action.edit == nil { showNotification("This language action has no executable change.") }
            return
        }
        guard let document = openDocuments.first(where: {
            $0.url.standardizedFileURL == documentURL.standardizedFileURL
        }) else { return }
        do {
            try languageToolingSessionsIfActive?.execute(
                command,
                fileURL: document.url,
                text: document.text,
                rootURL: rootURL
            ) { [weak self] result in
                if case .failure(let error) = result { self?.showNotification(error.localizedDescription) }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func applyLanguageCompletion(
        _ item: LanguageServerCompletionItem,
        fallbackRange: LanguageServerRange
    ) {
        guard let document = activeDocument, let workspaceURL else { return }
        guard item.data != nil,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.completionResolve) == true) else {
            performLanguageCompletion(item, fallbackRange: fallbackRange, documentURL: document.url)
            return
        }
        do {
            try languageToolingSessionsIfActive?.resolveCompletion(
                item,
                fileURL: document.url,
                text: document.text,
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let resolved):
                    self?.performLanguageCompletion(
                        resolved,
                        fallbackRange: fallbackRange,
                        documentURL: document.url
                    )
                case .failure(let error):
                    self?.showNotification(error.localizedDescription)
                    self?.performLanguageCompletion(
                        item,
                        fallbackRange: fallbackRange,
                        documentURL: document.url
                    )
                }
            }
        } catch {
            showNotification(error.localizedDescription)
            performLanguageCompletion(item, fallbackRange: fallbackRange, documentURL: document.url)
        }
    }

    private func performLanguageCompletion(
        _ item: LanguageServerCompletionItem,
        fallbackRange: LanguageServerRange,
        documentURL: URL
    ) {
        let sourceEdit = item.textEdit ?? LanguageServerTextEdit(
            range: fallbackRange,
            newText: item.insertText
        )
        let primaryEdit = LanguageServerTextEdit(
            range: sourceEdit.range,
            newText: LanguageServerSnippet.plainText(sourceEdit.newText)
        )
        let edits = [primaryEdit] + item.additionalTextEdits
        applyLanguageWorkspaceEdit(LanguageServerWorkspaceEdit(
            changes: [documentURL.standardizedFileURL: edits]
        ))
    }

    @discardableResult
    private func applyLanguageWorkspaceEdit(_ edit: LanguageServerWorkspaceEdit) -> Bool {
        guard let workspaceURL else { return false }
        let root = workspaceURL.standardizedFileURL.path
        var sources: [URL: String] = [:]
        var documents: [URL: EditorDocument] = [:]
        do {
            for rawURL in edit.changes.keys {
                let url = rawURL.standardizedFileURL
                guard url.path == root || url.path.hasPrefix(root + "/") else {
                    throw NSError(domain: "LanguageEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Language edit targets a file outside the workspace."])
                }
                if let document = openDocuments.first(where: { $0.url.standardizedFileURL == url }) {
                    guard !document.isReadOnly else { throw EditorDocument.DocumentError.readOnly }
                    documents[url] = document
                    sources[url] = document.text
                } else {
                    guard WorkspaceTextFilePolicy.isReadableTextFile(url) else { throw NSError(domain: "LanguageEdit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Language edit targets an unreadable file."]) }
                    sources[url] = try workspaceFileOperations.readText(from: url)
                }
            }
            var replacements: [URL: String] = [:]
            for (url, edits) in edit.changes {
                let normalized = url.standardizedFileURL
                guard let source = sources[normalized] else { continue }
                replacements[normalized] = try LanguageServerTextEditApplicator.apply(edits, to: source)
            }
            var originals: [URL: String] = [:]
            do {
                // Open documents are editor buffers: mutate them only after
                // every unopened file was written successfully, and leave
                // them dirty instead of silently saving user work.
                for (url, replacement) in replacements where documents[url] == nil {
                    originals[url] = sources[url]
                    try workspaceFileOperations.writeText(replacement, to: url)
                }
            } catch {
                for (url, original) in originals { try? workspaceFileOperations.writeText(original, to: url) }
                throw error
            }
            for (url, replacement) in replacements {
                if let document = documents[url] {
                    document.text = replacement
                    documentDidChange(document)
                }
            }
            return true
        } catch {
            showNotification("Could not apply language edit: \(error.localizedDescription)")
            return false
        }
    }

    func supportsLanguageServerFeature(_ feature: LanguageServerFeatureSet) -> Bool {
        guard let document = activeDocument else { return false }
        return (languageToolingSessionsIfActive?.features(for: document.url).contains(feature) == true)
    }

    private func languageServerFeatureIsReady(
        _ feature: LanguageServerFeatureSet,
        unsupportedMessage: String
    ) -> Bool {
        guard let document = activeDocument else { return false }
        if isJavaLanguageServerPreparing(for: document.url) {
            showJavaLanguageServerPreparingNotification()
            return false
        }
        guard supportsLanguageServerFeature(feature) else {
            showNotification(unsupportedMessage)
            return false
        }
        return true
    }

    private func performGenericNavigation(
        method: String,
        kind: LanguageNavigationResultKind,
        navigateToSingleResult: Bool = true,
        fallbackToImplementationsIfSelf: Bool = false
    ) {
        guard !languageNavigationState.isLoading,
              let document = activeDocument,
              let caret = editorCaret,
              caret.url.standardizedFileURL == document.url.standardizedFileURL,
              let workspaceURL,
              let provider = languageProviderCatalog.provider(for: document.url) else {
            showNotification("Place the caret on a language symbol first")
            return
        }
        let operationID = beginLanguageNavigation(providerID: provider.id, kind: kind)
        do {
            try languageToolingSessionsIfActive?.navigate(
                method: method,
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, caret.line),
                    utf16Column: max(0, caret.utf16Column)
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                guard let self,
                      self.languageNavigationState.owns(operationID: operationID) else { return }
                switch result {
                case .failure(let error):
                    self.languageNavigationState = .idle
                    self.showNotification(error.localizedDescription)
                case .success(let values):
                    if fallbackToImplementationsIfSelf,
                       kind == .definitions,
                       values.count == 1,
                       values[0].url.standardizedFileURL == document.url.standardizedFileURL,
                       self.languageToolingSessionsIfActive?.features(for: document.url).contains(.implementation) == true {
                        self.requestGenericImplementationFallback(
                            document: document,
                            caret: caret,
                            workspaceURL: workspaceURL,
                            originalValues: values,
                            navigateToSingleResult: navigateToSingleResult,
                            providerID: provider.id
                        )
                        return
                    }
                    self.presentGenericNavigationValues(
                        values,
                        kind: kind,
                        navigateToSingleResult: navigateToSingleResult,
                        providerID: provider.id
                    )
                }
            }
        } catch {
            if languageNavigationState.owns(operationID: operationID) {
                languageNavigationState = .idle
            }
            showNotification(error.localizedDescription)
        }
    }

    private func requestGenericImplementationFallback(
        document: EditorDocument,
        caret: EditorCaret,
        workspaceURL: URL,
        originalValues: [LanguageServerLocation],
        navigateToSingleResult: Bool,
        providerID: String
    ) {
        let operationID = beginLanguageNavigation(
            providerID: providerID,
            kind: .implementations
        )
        do {
            try languageToolingSessionsIfActive?.navigate(
                method: "textDocument/implementation",
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, caret.line),
                    utf16Column: max(0, caret.utf16Column)
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                guard let self,
                      self.languageNavigationState.owns(operationID: operationID) else { return }
                if case .success(let implementations) = result, !implementations.isEmpty {
                    self.presentGenericNavigationValues(
                        implementations,
                        kind: .implementations,
                        navigateToSingleResult: navigateToSingleResult,
                        providerID: providerID
                    )
                } else {
                    self.presentGenericNavigationValues(
                        originalValues,
                        kind: .definitions,
                        navigateToSingleResult: navigateToSingleResult,
                        providerID: providerID
                    )
                }
            }
        } catch {
            guard languageNavigationState.owns(operationID: operationID) else { return }
            presentGenericNavigationValues(
                originalValues,
                kind: .definitions,
                navigateToSingleResult: navigateToSingleResult,
                providerID: providerID
            )
        }
    }

    private func presentGenericNavigationValues(
        _ values: [LanguageServerLocation],
        kind: LanguageNavigationResultKind,
        navigateToSingleResult: Bool,
        providerID: String?
    ) {
        let locations = values.map {
            LanguageNavigationLocation(
                url: $0.url,
                line: $0.range.start.line,
                utf16Column: $0.range.start.utf16Column,
                isReadOnly: $0.isReadOnly,
                displayPath: $0.displayPath
            )
        }
        guard !locations.isEmpty else {
            languageNavigationState = .idle
            switch kind {
            case .definitions: showNotification("Definition not found")
            case .references: showNotification("No usages found")
            case .implementations: showNotification("No implementations found")
            }
            return
        }
        languageNavigationState = .results(
            providerID: providerID,
            kind: kind,
            locations: locations
        )
        if navigateToSingleResult, locations.count == 1, let location = locations.first {
            navigate(to: location)
        } else {
            presentLanguageNavigationResults(kind)
        }
    }

    func presentLanguageNavigationResults(_ kind: LanguageNavigationResultKind) {
        isGitLogVisible = false
        isTerminalVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isReferencesVisible = kind != .implementations
        isImplementationChooserVisible = kind == .implementations
    }

}

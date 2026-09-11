import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheExecutionModule
import LitheModuleAPI

/// Debug tool window entry points: session lifecycle, stepping, breakpoints,
/// and the launch path that resolves a Run selection into a debug adapter
/// configuration.
///
/// Debug enters through the same workspace readiness gate as Run
/// (`AppModel+RunConfiguration`) because a debug launch resolves toolchains
/// from the run inventory.
@MainActor
extension AppModel {
    func toggleDebug() {
        guard toggleToolWindow(.debug) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await activateExecutionModule() != nil else { return }
            if let workspaceURL {
                await loadProjectServicesForAppliedSnapshot(at: workspaceURL)
            }
            _ = await activateDebugModule()
        }
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
            showToolWindow(.debug)
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
        let configurationReadiness = runWorkflowCoordinator.configurationReadiness(
            status: runFeature.configurationStatus,
            selected: runFeature.selectedConfiguration
        )
        guard case .ready(let selectedConfiguration) = configurationReadiness else {
            if case .needsGeneration = configurationReadiness {
                runFeature.requestRunConfigurationGeneration(intent: .debug)
            } else {
                showNotification("Choose a Run configuration before starting Debug")
            }
            return
        }
        let configuration = runWorkflowCoordinator.debugConfiguration(
            selected: selectedConfiguration,
            activeDocumentText: activeDocument?.text,
            configurations: runFeature.configurations
        )
        runFeature.select(configuration)

        let sourceResolution = runWorkflowCoordinator.resolveDebugSource(
            configuration: configuration,
            activeDocument: activeDocument,
            projectFiles: projectFiles,
            workspaceURL: workspaceURL
        )
        let sourceURL: URL
        switch sourceResolution {
        case .resolved(let resolved):
            sourceURL = resolved
        case .currentFileUnavailable:
                showNotification("Open a source file or choose a project Run configuration")
            return
        case .javaSourceUnavailable(let name):
            showNotification("Could not find the Java source for \(name)")
            return
        case .unsupported(let name):
            showNotification("\(name) does not support Debug yet")
            return
        }

        let providerReadiness = runWorkflowCoordinator.debugProviderReadiness(
            sourceURL: sourceURL,
            supportsDebugAdapter: languageProviderCatalog.provider(for: sourceURL)?
                .capabilities.contains(.debugAdapter) == true
        )
        guard case .ready = providerReadiness else {
            if case .unsupported(let fileName) = providerReadiness {
                showNotification("Debug support is not available for \(fileName)")
            }
            showToolWindow(.debug)
            return
        }
        let document = openDocuments.first {
            $0.url.standardizedFileURL == sourceURL.standardizedFileURL
        }
        await startGenericDebuggingAfterActivation(fileURL: sourceURL, document: document)
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

    func handleDebugSessionStateChange(_ state: DebugAdapterState) {
        featureGraph.debugSessionCleanup.handle(
            state,
            activeSessionID: genericDebugFeatureIfActive?.activeSessionID
        )
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
        runWorkflowCoordinator.reapplySelectedConfiguration(runFeature)
        guard featureGraph.debugLaunchPreparation.saveDirtyDocumentIfNeeded(document) else {
            return
        }
        let configuration: DebugLaunchConfiguration
        do {
            configuration = try await featureGraph.debugLaunchPreparation.prepare(
                provider: provider,
                fileURL: fileURL,
                workspaceURL: workspaceURL,
                runFeature: runFeature,
                resolver: debugLaunchConfigurationResolver,
                portChecker: debugPortAvailabilityChecker,
                resolveJavaTarget: { [weak self] in
                    guard let self else { return nil }
                    let sessions = try await self.languageSessionsForWorkspaceMaintenance()
                    return try await sessions.resolveJavaDebugLaunchTarget(
                        fileURL: fileURL,
                        rootURL: workspaceURL
                    )
                }
            )
        } catch {
            showNotification(error.localizedDescription)
            return
        }
        guard featureGraph.debugLaunchPreparation.start(
            configuration: configuration,
            launch: {
                genericDebugFeature.start(
                    fileURL: fileURL,
                    rootURL: workspaceURL,
                    configuration: configuration
                )
            },
            errorMessage: genericDebugFeature.errorMessage
        ) else {
            return
        }
        showDebugToolWindow()
    }

    func showDebugToolWindow() {
        showToolWindow(.debug)
    }
}

/// Debug presentation and teardown the debug coordinators drive.
///
/// Terminal teardown collapses the optional session into the two existing
/// entry points: a known session stops only its own processes, while a
/// terminated session with no ID falls back to stopping all of them.
extension AppModel: DebugSessionCleanupActions {
    func activateApplication() {
        platformUI.activateApplication()
    }

    func stopDebugTerminalProcesses(for debugSessionID: DebugSessionID?) {
        if let debugSessionID {
            stopDebugTerminalProcesses(for: debugSessionID)
        } else {
            stopDebugTerminalProcesses()
        }
    }
}

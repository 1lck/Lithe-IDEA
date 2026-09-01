import Combine
import Foundation
import LitheDebugModule
import LitheExecutionModule

@MainActor
extension AppModel {
    struct DebugFeatureAccess {
        let genericFeature: GenericDebugFeatureModel
    }
    struct ExecutionFeatureAccess {
        let mavenFeature: MavenFeatureModel
        let runFeature: RunFeatureModel
        let tests: LanguageTestService
        let projectDevelopment: ProjectDevelopmentFeatureModel
    }

    var mavenFeatureIfActive: MavenFeatureModel? { executionCapability?.mavenFeature }
    var runFeatureIfActive: RunFeatureModel? { executionCapability?.runFeature }
    var genericDebugFeatureIfActive: GenericDebugFeatureModel? {
        debugCapability?.genericFeature as? GenericDebugFeatureModel
    }

    func activateExecutionModule() async -> ExecutionFeatureAccess? {
        // Run and Debug can activate immediately after a project switch. Join
        // teardown first so it cannot release the capability we are returning.
        await awaitModuleRuntimeShutdown()
        if let mavenFeature = mavenFeatureIfActive,
           let runFeature = runFeatureIfActive,
           let tests = languageTestServiceIfActive,
           let projectDevelopment = executionCapability?.projectDevelopment {
            return ExecutionFeatureAccess(mavenFeature: mavenFeature, runFeature: runFeature, tests: tests, projectDevelopment: projectDevelopment)
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(.executionWorkspace)
            guard let capability = value as? LitheExecutionModule.ExecutionModuleCapability else { return nil }
            let mavenFeature = capability.mavenFeature
            let runFeature = capability.runFeature
            let tests = capability.testService
            let projectDevelopment = capability.projectDevelopment
            cacheModuleCapability(capability, id: .executionWorkspace, moduleID: .execution)
            observeModuleFeature(.execution, observation: runFeature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            observeModuleFeature(.execution, observation: tests.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            return ExecutionFeatureAccess(mavenFeature: mavenFeature, runFeature: runFeature, tests: tests, projectDevelopment: projectDevelopment)
        } catch {
            showNotification(error.localizedDescription)
            return nil
        }
    }

    func activateDebugModule() async -> DebugFeatureAccess? {
        await awaitModuleRuntimeShutdown()
        if let genericFeature = genericDebugFeatureIfActive {
            configureDebugHostHandlers(genericFeature)
            if let workspaceURL { genericFeature.openWorkspace(at: workspaceURL) }
            return DebugFeatureAccess(genericFeature: genericFeature)
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(.debugWorkspace)
            guard let capability = value as? LitheDebugModule.DebugModuleCapability,
                  let genericFeature = capability.genericFeature as? GenericDebugFeatureModel else { return nil }
            configureDebugHostHandlers(genericFeature)
            cacheModuleCapability(capability, id: .debugWorkspace, moduleID: .debug)
            if let workspaceURL { genericFeature.openWorkspace(at: workspaceURL) }
            observeModuleFeature(.debug, observation: genericFeature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            observeModuleFeature(.debug, observation: genericFeature.$state
                .removeDuplicates()
                .sink { [weak self] state in
                    self?.handleDebugSessionStateChange(state)
                })
            return DebugFeatureAccess(genericFeature: genericFeature)
        } catch {
            showNotification(error.localizedDescription)
            return nil
        }
    }

    private func configureDebugHostHandlers(_ feature: GenericDebugFeatureModel) {
        feature.onStoppedLocation = { [weak self] url, line, column in
            self?.revealDebugLocation(url: url, line: line, column: column)
        }
        feature.onAutomaticVariableInspectionRequest = { [weak self, weak feature] frame in
            guard let self, let feature else { return }
            requestAutomaticDebugVariables(for: frame, feature: feature)
        }
        configureDebugRunInTerminalHandler(feature)
    }

    private func requestAutomaticDebugVariables(
        for frame: DebugStackFrame,
        feature: GenericDebugFeatureModel
    ) {
        guard feature.providerID == "java",
              let sourceURL = frame.sourceURL?.standardizedFileURL,
              let source = debugSourceText(at: sourceURL) else {
            feature.requestAutomaticVariables([])
            return
        }
        let expressions = DebugAutomaticExpressionProjection.javaExpressions(
            forLine: max(0, frame.line - 1),
            in: source as NSString
        )
        feature.requestAutomaticVariables(expressions)
    }

    private func debugSourceText(at sourceURL: URL) -> String? {
        if let document = openDocuments.first(where: {
            $0.url.standardizedFileURL == sourceURL
        }) {
            return document.text
        }
        guard let metadata = services.fileStorage.metadata(for: sourceURL),
              metadata.isRegularFile,
              let byteCount = metadata.byteCount,
              byteCount <= 2_000_000,
              let data = try? services.fileStorage.readData(from: sourceURL, options: []),
              let source = String(data: data, encoding: .utf8) else { return nil }
        return source
    }

    private func configureDebugRunInTerminalHandler(_ feature: GenericDebugFeatureModel) {
        feature.onSessionSelectionChanged = { [weak self] debugSessionID in
            guard let self else { return }
            self.activeDebugTerminalSessionID = debugSessionID.flatMap {
                self.activeDebugTerminalSessionIDsByDebugSession[$0]
            }
        }
        feature.onSessionStopped = { [weak self] debugSessionID in
            self?.stopDebugTerminalProcesses(for: debugSessionID)
        }
        feature.onSessionRunInTerminalRequest = { [weak self] debugSessionID, request, completion in
            guard let self else {
                completion(.failure(DebugAdapterCapabilityError.unsupported("run in terminal")))
                return
            }
            handleDebugRunInTerminalRequest(
                request,
                debugSessionID: debugSessionID,
                completion: completion
            )
        }
        feature.onRunInTerminalRequest = { [weak self] request, completion in
            guard let self else {
                completion(.failure(DebugAdapterCapabilityError.unsupported("run in terminal")))
                return
            }
            handleDebugRunInTerminalRequest(request, debugSessionID: nil, completion: completion)
        }
    }

    func restoreDebugBreakpoints(for workspaceURL: URL) async {
        guard self.workspaceURL == workspaceURL,
              let persistence = services.debugBreakpointPersistence else { return }
        do {
            guard let snapshot = try persistence.loadBreakpoints(for: workspaceURL),
                  snapshot.version == DebugBreakpointSnapshot.currentVersion,
                  !snapshot.breakpoints.isEmpty,
                  self.workspaceURL == workspaceURL else { return }
            _ = await activateDebugModule()
        } catch {
            showNotification(error.localizedDescription)
        }
    }
}

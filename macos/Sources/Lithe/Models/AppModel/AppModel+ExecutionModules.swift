import Combine
import Foundation
import LitheDebugModule
import LitheExecutionModule

@MainActor
extension AppModel {
    var mavenFeatureIfActive: MavenFeatureModel? { executionCapability?.mavenFeature }
    var runFeatureIfActive: RunFeatureModel? { executionCapability?.runFeature }
    var genericDebugFeatureIfActive: GenericDebugFeatureModel? {
        debugCapability?.genericFeature as? GenericDebugFeatureModel
    }

    func activateExecutionModule() async -> ExecutionFeatureAccess? {
        // Run and Debug activate on demand, so they can arrive while the previous
        // session's module graph is still being torn down. Activating first would
        // hand back a run feature that teardown releases moments later, and the
        // deferred action waiting on it would never be resumed.
        await executionModuleCoordinator.activateAccess()
    }

    func activateDebugModule() async -> DebugFeatureAccess? {
        await debugModuleCoordinator.activateAccess(workspace: workspaceURL)
    }

    func configureDebugHostHandlers(_ feature: GenericDebugFeatureModel) {
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

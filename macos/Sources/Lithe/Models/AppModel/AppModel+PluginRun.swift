import Combine
import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheExecutionModule
import LitheModuleAPI

/// What a window keeps for the runs and debug sessions plugin backends started.
@MainActor
final class PluginRunSessions {
    struct Run {
        let onEnd: @MainActor (PluginRunEnd) -> Void
        /// Hears the end of this run only; dropping the run drops the subscription.
        let endSubscription: AnyCancellable
        /// Waits for the process to listen, then attaches the debugger; cancelled when the run ends.
        var attaching: Task<Void, Never>?
        /// The debugger attached to the process. It stops with the run, and the run stops with it.
        var debugSession: DebugSessionID?
    }

    var runs: [String: Run] = [:]
    /// Sessions started by `debug/start`, with what to tell the service when one is gone.
    var debugSessionEnds: [DebugSessionID: @MainActor (String) -> Void] = [:]
}

/// Why a plugin's run or debug session could not be set up. Each case is a sentence for the user.
private enum PluginRunSetupFailure: LocalizedError {
    case portNotOpened
    case noAdapter(configurationType: String)
    case adapterUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .portNotOpened:
            return L10n.string("The program did not open its debug port before the deadline. Check the Run output.")
        case .noAdapter(let configurationType):
            return L10n.string("No single debug adapter attaches to the “\(configurationType)” configuration type.")
        case .adapterUnavailable(let reason):
            return reason ?? L10n.string("The debug adapter could not start. Check that the plugin that provides it is enabled.")
        }
    }
}

/// Shows the runs and debug sessions of plugin backends in this window: the process in the Run
/// tool window, a debugger attached to it, or a debug session on one of the plugin's adapters.
@MainActor
extension AppModel: PluginRunWindowPort {
    // MARK: Runs

    func hostStartPluginRun(_ launch: PluginRunLaunch, debug: PluginRunStart.Debug?, rerun: (@MainActor @Sendable () -> Void)?,
                            onEnd: @escaping @MainActor @Sendable (PluginRunEnd) -> Void) async throws {
        guard let identity = currentWorkspaceIdentity,
              let run = await activateExecutionModule()?.runFeature,
              isCurrentWorkspace(identity) else { throw CancellationError() }
        try Task.checkCancellation()
        let runID = launch.runID
        // Listen before launching: the run may end at once, and the subject keeps no history.
        let endSubscription = run.pluginRunEnded.filter { $0.runID == runID }.sink { [weak self] end in
            self?.pluginRunEnded(end)
        }
        pluginRunSessions.runs[runID] = PluginRunSessions.Run(onEnd: onEnd, endSubscription: endSubscription)
        do {
            try run.launchPluginRun(launch, rerun: rerun)
        } catch {
            pluginRunSessions.runs[runID] = nil
            throw error
        }
        showToolWindow(.run)
        if let debug, case .connection(let number) = debug.target, let port = UInt16(exactly: number) {
            pluginRunSessions.runs[runID]?.attaching = Task { [weak self] in
                await self?.attachDebugger(toRun: runID, of: run, configurationType: debug.configurationType,
                                           port: port, identity: identity)
            }
        }
    }

    func hostStopPluginRun(runID: String) {
        runFeatureIfActive?.stopPluginRun(runID)
    }

    func hostReportPluginRunProblem(_ message: String) {
        showNotification(message)
    }

    /// The process is gone: nothing is left to attach to, so the debugger goes too.
    private func pluginRunEnded(_ end: PluginRunEnd) {
        guard let run = pluginRunSessions.runs.removeValue(forKey: end.runID) else { return }
        run.attaching?.cancel()
        if let session = run.debugSession { genericDebugFeatureIfActive?.stopSession(session) }
        run.onEnd(end)
    }

    /// Waits until the process listens on `port`, then attaches the one adapter that serves
    /// `configurationType`. The run keeps going meanwhile; a failure stops it and says why.
    private func attachDebugger(toRun runID: String, of run: RunFeatureModel, configurationType: String,
                                port: UInt16, identity: WorkspaceIdentity) async {
        let isCurrent: @MainActor () -> Bool = { [weak self, weak run] in
            guard let self, let run else { return false }
            return self.isCurrentWorkspace(identity) && run.isPluginRunActive(runID)
        }
        do {
            guard let debug = await activateDebugModule()?.genericFeature, isCurrent() else { return }
            let connection = try prepareConnection(configurationType: configurationType, port: port)
            try await waitForListener(port, run: run, runID: runID) { isCurrent() && connection.isCurrent() }
            guard isCurrent(), connection.isCurrent() else { return }
            guard debug.startAdditional(fileURL: identity.url, rootURL: identity.url, configuration: connection.configuration),
                  let session = debug.activeSessionID else {
                throw PluginRunSetupFailure.adapterUnavailable(debug.errorMessage)
            }
            guard pluginRunSessions.runs[runID] != nil else {
                // The run ended while the session started.
                debug.stopSession(session)
                return
            }
            pluginRunSessions.runs[runID]?.debugSession = session
            showDebugToolWindow()
        // log-exempt: the run was stopped or replaced while the debugger attached, which is no failure
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent() else { return }
            showNotification(error.localizedDescription)
            run.stopPluginRun(runID)
        }
    }

    private func prepareConnection(configurationType: String, port: UInt16) throws -> PreparedProviderConnectionDebug {
        do {
            return try debugLaunchConfigurationResolver.resolveProviderConnection(
                configurationType: configurationType, adapterID: nil, port: port)
        } catch DebugLaunchConfigurationResolutionError.providerDebugUnavailable {
            throw PluginRunSetupFailure.noAdapter(configurationType: configurationType)
        }
    }

    /// The checker's own deadline text is worded for one framework, so any failure but
    /// cancellation is reported with a neutral sentence here.
    private func waitForListener(_ port: UInt16, run: RunFeatureModel, runID: String,
                                 isCurrent: @escaping @MainActor () -> Bool) async throws {
        do {
            try await debugPortAvailabilityChecker.waitForLoopbackListener(
                port, processID: { [weak run] in run?.pluginRunProcessID(runID) }, isCurrent: isCurrent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PluginRunSetupFailure.portNotOpened
        }
    }

    // MARK: Debug sessions

    func hostStartPluginDebugSession(_ start: PluginDebugStart,
                                     onEnd: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        guard let identity = currentWorkspaceIdentity,
              let debug = await activateDebugModule()?.genericFeature,
              isCurrentWorkspace(identity) else { throw CancellationError() }
        try Task.checkCancellation()
        // Core has checked both; a host that cannot read them back has drifted from Core.
        guard let request = DebugRequestKind(rawValue: start.request) else { throw Self.invalidDebugStart(field: "request") }
        guard case .object(let arguments) = start.configuration else { throw Self.invalidDebugStart(field: "configuration") }
        let configuration = DebugLaunchConfiguration(name: start.label, request: request, arguments: arguments,
                                                     adapterProviderID: start.adapterID)
        guard debug.startAdditional(fileURL: identity.url, rootURL: identity.url, configuration: configuration),
              let session = debug.activeSessionID else {
            throw PluginRunSetupFailure.adapterUnavailable(debug.errorMessage)
        }
        pluginRunSessions.debugSessionEnds[session] = onEnd
        showDebugToolWindow()
        return session.description
    }

    private static func invalidDebugStart(field: String) -> DeclarativePluginRejection {
        DeclarativePluginRejection(code: "plugin.debug.invalidStart", message: "The debug start has an unreadable \(field).", field: field)
    }

    func hostStopPluginDebugSession(_ sessionID: String) {
        guard let session = pluginRunSessions.debugSessionEnds.keys.first(where: { $0.description == sessionID }) else { return }
        genericDebugFeatureIfActive?.stopSession(session)
    }

    /// A debug session is gone, however it ended. Tells the service about a plugin's session,
    /// and stops the process the debugger was attached to, as a build provider's debugger does.
    func pluginDebugSessionEnded(_ session: DebugSessionID) {
        pluginRunSessions.debugSessionEnds.removeValue(forKey: session)?(session.description)
        guard let runID = pluginRunSessions.runs.first(where: { $0.value.debugSession == session })?.key else { return }
        pluginRunSessions.runs[runID]?.debugSession = nil
        runFeatureIfActive?.stopPluginRun(runID)
    }
}

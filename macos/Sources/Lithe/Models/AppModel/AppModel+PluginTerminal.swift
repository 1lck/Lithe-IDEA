import Foundation
import LitheCoreContracts
import LitheModuleAPI
import LitheTerminalModule

@MainActor
extension AppModel: PluginTerminalWindowPort {
    func hostCreatePluginTerminal(
        _ request: PluginTerminalLaunch,
        onExit: @escaping @MainActor @Sendable (PluginTerminalExit) -> Void
    ) async throws -> any PluginTerminalSessionAccess {
        guard let identity = currentWorkspaceIdentity,
              services.remoteConnections?.workspaces.contains(identity.url) != true else {
            throw PluginHostError.remoteWorkspaceUnsupported
        }
        let invocation = String(data: try JSONEncoder().encode([request.executable] + request.arguments), encoding: .utf8) ?? ""
        let outcome = await hostMessages.present(PluginHostMessageEntry(
            id: UUID(), pluginID: request.pluginID, pluginName: request.pluginID, severity: .warning,
            text: String(format: L10n.string("Allow “%@” to open a terminal?"), request.pluginID)
                + "\n\n" + invocation + "\n" + request.workingDirectory.path,
            actions: [L10n.string("Allow"), L10n.string("Don’t Allow")], workspaceGeneration: identity.generation
        ))
        try Task.checkCancellation()
        guard currentWorkspaceIdentity == identity else { throw PluginHostError.workspaceChanged }
        guard outcome == .selected(index: 0) else {
            throw PluginHostServiceError(.cancelled, L10n.string("The plugin terminal was not opened."))
        }
        guard await activateTerminalModule(), let feature = terminalFeature else {
            throw PluginHostServiceError(.unavailable, L10n.string("The terminal is unavailable."))
        }
        try Task.checkCancellation()
        guard currentWorkspaceIdentity == identity else { throw PluginHostError.workspaceChanged }
        let root = identity.url.resolvingSymlinksInPath().standardizedFileURL.path
        let directory = request.workingDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard directory.path == root || directory.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw PluginHostError.outsideWorkspace
        }
        let launch = TerminalProcessLaunch(
            title: request.title, executablePath: request.executable, arguments: request.arguments,
            workingDirectory: directory.path,
            environmentChanges: request.environment.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) },
            initialDisplayText: request.displayHistory
        )
        let created = try await feature.createProcessSessionAsync(launch, workspaceURL: identity.url,
            showsWorkbenchBackground: workbenchBackgroundFeature.hasImage)
        let session = created.session
        do {
            try Task.checkCancellation()
            guard currentWorkspaceIdentity == identity else { throw PluginHostError.workspaceChanged }
        } catch {
            await session.stopAndWait()
            feature.closeSession(session)
            throw error
        }
        configureInteractiveTerminalSession(session)
        terminalPlacementFeature.registerSession(session.id)
        let access = AppPluginTerminalSession(model: self, session: session, onExit: onExit)
        if request.show { try access.show() }
        return access
    }

    func hostClosePluginTerminal(_ session: TerminalSession) async {
        await session.stopAndWait()
        closeTerminalSession(session)
    }
}

/// Retains the native session until its owner releases the API handle. It never
/// obtains the terminal emulator or exposes the user's other terminal sessions.
@MainActor
private final class AppPluginTerminalSession: PluginTerminalSessionAccess {
    private weak var model: AppModel?
    private let session: TerminalSession
    private(set) var exit: PluginTerminalExit?
    private let onExit: @MainActor @Sendable (PluginTerminalExit) -> Void

    init(model: AppModel, session: TerminalSession, onExit: @escaping @MainActor @Sendable (PluginTerminalExit) -> Void) {
        self.model = model; self.session = session; self.onExit = onExit
        let previous = session.onEnded
        session.onEnded = { [weak self] ended in
            self?.finish(.init(code: ended.lastExitCode, reason: "exited"))
            previous?(ended)
        }
        session.onStopped = { [weak self] in self?.finish(.init(code: nil, reason: "closed")) }
        // A short-lived process can exit while the async native launch returns.
        if !session.isRunning { finish(.init(code: session.lastExitCode, reason: "exited")) }
    }

    func show() throws {
        guard let model, model.terminalSessions.contains(where: { $0 === session }) else {
            throw PluginHostServiceError(.notFound, L10n.string("The plugin terminal does not exist."))
        }
        // Selecting a tab in its own window never raises a background window.
        model.revealTerminalSession(session.id)
    }

    func displayText(maximumBytes: Int) -> String { session.displayText(maximumBytes: maximumBytes) }

    func close() async {
        finish(.init(code: nil, reason: "closed"))
        if let model { await model.hostClosePluginTerminal(session) }
        else { await session.stopAndWait() }
    }

    private func finish(_ value: PluginTerminalExit) {
        guard exit == nil else { return }
        exit = value
        onExit(value)
    }
}

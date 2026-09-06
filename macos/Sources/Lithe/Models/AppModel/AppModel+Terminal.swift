import Combine
import Foundation
import LitheDebugModule
import LitheCoreContracts
import LitheTerminalModule

extension AppModel {
    var terminalCapability: LitheTerminalModule.TerminalModuleCapability? {
        cachedModuleCapability(.terminalWorkspace)
    }

    var terminalFeature: TerminalFeatureModel? { terminalCapability?.feature }
    var availableTerminalShells: [String] { terminalFeature?.availableShells ?? [] }

    @MainActor
    func activateTerminalModule() async -> Bool {
        await terminalModuleCoordinator.activate()
    }

    func toggleTerminal() {
        guard toggleToolWindow(.terminal) else { return }
        if terminalCapability == nil || activeTerminalSession == nil {
            terminalModuleCoordinator.activateThen { [weak self] in
                _ = self?.createTerminalSession()
            }
        }
    }

    var terminalSessions: [TerminalSession] { terminalFeature?.terminalSessions ?? [] }
    var activeTerminalSessionID: UUID? { terminalFeature?.activeTerminalSessionID }
    var activeTerminalSession: TerminalSession? { terminalFeature?.activeTerminalSession }
    var toolTerminalSessions: [TerminalSession] {
        sessions(orderedBy: terminalPlacementFeature.toolSessionIDs)
    }
    var editorTerminalSessions: [TerminalSession] {
        sessions(orderedBy: terminalPlacementFeature.editorSessionIDs)
    }
    var activeToolTerminalSession: TerminalSession? {
        let toolSessions = toolTerminalSessions
        if let activeTerminalSessionID,
           let activeSession = toolSessions.first(where: { $0.id == activeTerminalSessionID }) {
            return activeSession
        }
        return toolSessions.first
    }
    var activeEditorTerminalSession: TerminalSession? {
        guard let sessionID = terminalPlacementFeature.activeEditorSessionID else { return nil }
        return terminalSessions.first { $0.id == sessionID }
    }
    func terminalTitle(for session: TerminalSession) -> String { terminalFeature?.terminalTitle(for: session) ?? "Local" }

    @discardableResult
    func createTerminalSession(shellPath: String? = nil) -> TerminalSession? {
        guard let workspaceURL else { return nil }
        guard let feature = terminalFeature else {
            terminalModuleCoordinator.activateThen { [weak self] in
                _ = self?.createTerminalSession(shellPath: shellPath)
            }
            return nil
        }
        let session = feature.createSession(in: workspaceURL, shellPath: shellPath ?? settings.terminalShellPath)
        configureTerminalSession(session)
        terminalPlacementFeature.registerSession(session.id)
        showToolWindow(.terminal)
        return session
    }

    private func configureTerminalSession(_ session: TerminalSession) {
        let sessionID = session.id
        session.onLink = { [weak self] link, params in
            self?.openTerminalLink(link, params: params, sessionID: sessionID)
        }
    }

    func handleDebugRunInTerminalRequest(
        _ request: DebugRunInTerminalRequest,
        debugSessionID: DebugSessionID? = nil,
        completion: @escaping DebugRunInTerminalCompletion
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failure(DebugTerminalLaunchError.hostUnavailable))
                return
            }
            do {
                completion(.success(try await startDebugProcessInTerminal(
                    request,
                    debugSessionID: debugSessionID
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func startDebugProcessInTerminal(
        _ request: DebugRunInTerminalRequest,
        debugSessionID: DebugSessionID?
    ) async throws -> DebugRunInTerminalResponse {
        guard request.kind == .integrated else {
            throw DebugTerminalLaunchError.externalTerminalUnsupported
        }
        guard !request.argsCanBeInterpretedByShell else {
            throw DebugTerminalLaunchError.shellInterpretationUnsupported
        }
        guard let executablePath = request.args.first, !executablePath.isEmpty else {
            throw DebugTerminalLaunchError.missingExecutable
        }
        guard let workspaceURL else {
            throw DebugTerminalLaunchError.workspaceUnavailable
        }
        guard await activateTerminalModule(), let feature = terminalFeature else {
            throw DebugTerminalLaunchError.terminalUnavailable
        }
        let workingDirectory = request.cwd.isEmpty
            ? workspaceURL.standardizedFileURL.path
            : request.cwd
        guard workingDirectory.hasPrefix("/") else {
            throw DebugTerminalLaunchError.invalidWorkingDirectory
        }
        let launch = TerminalProcessLaunch(
            title: request.title,
            executablePath: executablePath,
            arguments: Array(request.args.dropFirst()),
            workingDirectory: workingDirectory,
            environmentChanges: request.environment.map {
                TerminalEnvironmentChange(name: $0.name, value: $0.value)
            }
        )
        let created = try feature.createProcessSession(launch) { [weak self] output in
            self?.genericDebugFeatureIfActive?.appendDebuggeeOutput(output)
        }
        configureTerminalSession(created.session)
        terminalPlacementFeature.registerSession(created.session.id)
        debugTerminalSessionIDs.insert(created.session.id)
        activeDebugTerminalSessionID = created.session.id
        if let debugSessionID {
            debugTerminalSessionIDsByDebugSession[debugSessionID, default: []].insert(created.session.id)
            activeDebugTerminalSessionIDsByDebugSession[debugSessionID] = created.session.id
        }
        showToolWindow(.terminal)
        created.session.focus()
        return DebugRunInTerminalResponse(processID: Int(created.processID))
    }

    func stopDebugTerminalProcesses() {
        for sessionID in debugTerminalSessionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            terminalSessions.first(where: { $0.id == sessionID })?.stop()
        }
        debugTerminalSessionIDs.removeAll()
        activeDebugTerminalSessionID = nil
        debugTerminalSessionIDsByDebugSession.removeAll()
        activeDebugTerminalSessionIDsByDebugSession.removeAll()
    }

    func stopDebugTerminalProcesses(for debugSessionID: DebugSessionID) {
        let sessionIDs = debugTerminalSessionIDsByDebugSession.removeValue(forKey: debugSessionID) ?? []
        for sessionID in sessionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            terminalSessions.first(where: { $0.id == sessionID })?.stop()
            debugTerminalSessionIDs.remove(sessionID)
        }
        activeDebugTerminalSessionIDsByDebugSession.removeValue(forKey: debugSessionID)
        if let activeDebugTerminalSessionID,
           sessionIDs.contains(activeDebugTerminalSessionID) {
            self.activeDebugTerminalSessionID = nil
        }
    }

    var isDebugStandardInputAvailable: Bool {
        guard let terminalFeature else { return false }
        let debugSessionID = genericDebugFeatureIfActive?.activeSessionID
        let scopedIDs = debugSessionID.flatMap { debugTerminalSessionIDsByDebugSession[$0] } ?? []
        let candidateIDs = [debugSessionID.flatMap { activeDebugTerminalSessionIDsByDebugSession[$0] }]
            .compactMap { $0 }
            + scopedIDs.sorted(by: { $0.uuidString < $1.uuidString })
            + [activeDebugTerminalSessionID].compactMap { $0 }
            + debugTerminalSessionIDs.sorted(by: { $0.uuidString < $1.uuidString })
        return candidateIDs.contains { sessionID in
            guard let session = terminalFeature.terminalSessions.first(where: { $0.id == sessionID }) else {
                return false
            }
            return session.isRunning && session.isReady
        }
    }

    @discardableResult
    func sendDebugStandardInput(_ input: String) -> Bool {
        guard !input.isEmpty, let terminalFeature else {
            showNotification("No running debug process accepts standard input")
            return false
        }
        let debugSessionID = genericDebugFeatureIfActive?.activeSessionID
        let scopedIDs = debugSessionID.flatMap { debugTerminalSessionIDsByDebugSession[$0] } ?? []
        let candidateIDs = [debugSessionID.flatMap { activeDebugTerminalSessionIDsByDebugSession[$0] }]
            .compactMap { $0 }
            + scopedIDs.sorted(by: { $0.uuidString < $1.uuidString })
            + [activeDebugTerminalSessionID].compactMap { $0 }
            + debugTerminalSessionIDs.sorted(by: { $0.uuidString < $1.uuidString })
        guard let sessionID = candidateIDs.first(where: { sessionID in
            guard let session = terminalFeature.terminalSessions.first(where: { $0.id == sessionID }) else {
                return false
            }
            return session.isRunning && session.isReady
        }) else {
            showNotification("No running debug process accepts standard input")
            return false
        }
        let payload = input.hasSuffix("\n") ? input : input + "\n"
        return terminalFeature.sendInput(payload, to: sessionID)
    }

    private func openTerminalLink(_ link: String, params: [String: String], sessionID: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }),
              let fallbackDirectory = session.currentDirectory ?? workspaceURL else { return }
        guard let target = TerminalLinkResolver.resolve(
            link,
            relativeTo: fallbackDirectory,
            fileExists: { [services] in services.fileStorage.fileExists(at: $0) }
        ) else { return }
        switch target {
        case .file(let location):
            guard let workspaceURL else { platformUI.open(location.url); return }
            if isFile(location.url, inside: workspaceURL) {
                openSourceLocation(url: location.url, line: location.line ?? 1, column: location.column)
            } else { platformUI.open(location.url) }
        case .external(let url): platformUI.open(url)
        }
    }

    private func isFile(_ fileURL: URL, inside directoryURL: URL) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        let directoryPath = directoryURL.standardizedFileURL.path
        guard filePath != directoryPath else { return true }
        return filePath.hasPrefix(directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/")
    }

    func selectTerminalSession(_ session: TerminalSession) {
        guard terminalPlacementFeature.toolSessionIDs.contains(session.id) else { return }
        guard terminalFeature?.selectSession(session) == true else { return }
        showToolWindow(.terminal)
    }

    func selectEditorTerminalSession(_ session: TerminalSession) {
        guard terminalPlacementFeature.editorSessionIDs.contains(session.id),
              terminalFeature?.selectSession(session) == true else { return }
        mediaFeature.deactivate()
        terminalPlacementFeature.activateEditorSession(session.id)
    }

    func selectEditorDocument(_ document: EditorDocument) {
        terminalPlacementFeature.activateDocument()
        activeDocumentID = document.id
    }

    func moveTerminalToEditor(_ sessionID: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }) else { return }
        terminalPlacementFeature.moveToEditor(sessionID)
        editorTabOrderFeature.moveToEnd(.terminal(sessionID))
        terminalPlacementFeature.reorderEditorSessions(
            orderedIDs: editorTabOrderFeature.terminalIDs
        )
        _ = terminalFeature?.selectSession(session)
    }

    func moveTerminalToEditor(_ sessionID: UUID, before targetSessionID: UUID) {
        moveEditorTab(.terminal(sessionID), before: .terminal(targetSessionID))
    }

    func moveTerminalToEditor(_ sessionID: UUID, after targetSessionID: UUID) {
        moveEditorTab(.terminal(sessionID), after: .terminal(targetSessionID))
    }

    func moveTerminalToTool(_ sessionID: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }) else { return }
        editorTabOrderFeature.remove(.terminal(sessionID))
        terminalPlacementFeature.moveToTool(sessionID)
        _ = terminalFeature?.selectSession(session)
        showToolWindow(.terminal)
    }

    func moveTerminalToTool(_ sessionID: UUID, before targetSessionID: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }) else { return }
        editorTabOrderFeature.remove(.terminal(sessionID))
        terminalPlacementFeature.moveToTool(sessionID, before: targetSessionID)
        _ = terminalFeature?.selectSession(session)
        showToolWindow(.terminal)
    }

    func moveTerminalToTool(_ sessionID: UUID, after targetSessionID: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }) else { return }
        editorTabOrderFeature.remove(.terminal(sessionID))
        terminalPlacementFeature.moveToTool(sessionID, after: targetSessionID)
        _ = terminalFeature?.selectSession(session)
        showToolWindow(.terminal)
    }

    func requestCloseTerminalSession(_ session: TerminalSession) {
        guard terminalSessions.contains(where: { $0.id == session.id }) else { return }
        guard session.isRunning else {
            closeTerminalSession(session)
            return
        }
        pendingTerminalCloseSessionID = session.id
    }

    var pendingTerminalCloseSession: TerminalSession? {
        guard let pendingTerminalCloseSessionID else { return nil }
        return terminalSessions.first { $0.id == pendingTerminalCloseSessionID }
    }

    func confirmTerminalClose() {
        guard let session = pendingTerminalCloseSession else {
            pendingTerminalCloseSessionID = nil
            return
        }
        pendingTerminalCloseSessionID = nil
        closeTerminalSession(session)
    }

    func cancelTerminalClose() {
        pendingTerminalCloseSessionID = nil
    }

    private func closeTerminalSession(_ session: TerminalSession) {
        guard terminalSessions.contains(where: { $0.id == session.id }) else { return }
        pendingTerminalCloseSessionID = nil
        debugTerminalSessionIDs.remove(session.id)
        for debugSessionID in debugTerminalSessionIDsByDebugSession.keys {
            debugTerminalSessionIDsByDebugSession[debugSessionID]?.remove(session.id)
            if debugTerminalSessionIDsByDebugSession[debugSessionID]?.isEmpty == true {
                debugTerminalSessionIDsByDebugSession[debugSessionID] = nil
            }
            if activeDebugTerminalSessionIDsByDebugSession[debugSessionID] == session.id {
                activeDebugTerminalSessionIDsByDebugSession[debugSessionID] = nil
            }
        }
        if activeDebugTerminalSessionID == session.id {
            activeDebugTerminalSessionID = nil
        }
        editorTabOrderFeature.remove(.terminal(session.id))
        terminalPlacementFeature.removeSession(session.id)
        terminalFeature?.closeSession(session)
        if terminalSessions.isEmpty {
            workbenchFeature.setVisibility(.terminal, isVisible: false)
            try? services.moduleRuntime.markIdle(.terminal)
        }
    }

    func restartActiveTerminal() { terminalFeature?.restartActiveSession() }
    func restartActiveTerminal(using shellPath: String) { terminalFeature?.restartActiveSession(using: shellPath) }
    func stopTerminalSessions() {
        debugTerminalSessionIDs.removeAll()
        activeDebugTerminalSessionID = nil
        debugTerminalSessionIDsByDebugSession.removeAll()
        activeDebugTerminalSessionIDsByDebugSession.removeAll()
        editorTabOrderFeature.removeAllTerminals()
        terminalPlacementFeature.reset()
        terminalModuleCoordinator.stopAllSessions(terminalFeature)
    }

    var activeTerminalShellPath: String {
        settings.terminalShellPath ?? terminalFeature?.availableShells.first ?? "/bin/zsh"
    }

    private func sessions(orderedBy sessionIDs: [UUID]) -> [TerminalSession] {
        let sessionsByID = Dictionary(uniqueKeysWithValues: terminalSessions.map { ($0.id, $0) })
        return sessionIDs.compactMap { sessionsByID[$0] }
    }
}

private enum DebugTerminalLaunchError: LocalizedError {
    case hostUnavailable
    case externalTerminalUnsupported
    case shellInterpretationUnsupported
    case missingExecutable
    case workspaceUnavailable
    case terminalUnavailable
    case invalidWorkingDirectory

    var errorDescription: String? {
        switch self {
        case .hostUnavailable:
            "The application closed before the debug terminal could start."
        case .externalTerminalUnsupported:
            "This debug session requires an external terminal, which is not supported."
        case .shellInterpretationUnsupported:
            "This debug session requires shell-interpreted terminal arguments."
        case .missingExecutable:
            "The debug adapter did not provide a terminal executable."
        case .workspaceUnavailable:
            "Open a project before starting a debug terminal."
        case .terminalUnavailable:
            "The integrated terminal is unavailable."
        case .invalidWorkingDirectory:
            "The debug adapter provided an invalid terminal working directory."
        }
    }
}

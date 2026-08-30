import Combine
import Foundation
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
        guard terminalCapability == nil else { return true }
        do {
            let value = try await services.moduleRuntime.activateCapability(.terminalWorkspace)
            guard let capability = value as? LitheTerminalModule.TerminalModuleCapability else { return false }
            let feature = capability.feature
            cacheModuleCapability(capability, id: .terminalWorkspace, moduleID: .terminal)
            observeModuleFeature(.terminal, observation: feature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            return true
        } catch {
            return false
        }
    }

    func toggleTerminal() {
        isTerminalVisible.toggle()
        guard isTerminalVisible else { return }
        isTestsVisible = false
        isGitLogVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        if terminalCapability == nil || activeTerminalSession == nil {
            Task { @MainActor [weak self] in
                guard let self, await self.activateTerminalModule() else { return }
                _ = self.createTerminalSession()
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
            Task { @MainActor [weak self] in
                guard let self, await self.activateTerminalModule() else { return }
                _ = self.createTerminalSession(shellPath: shellPath)
            }
            return nil
        }
        let session = feature.createSession(in: workspaceURL, shellPath: shellPath ?? settings.terminalShellPath)
        configureTerminalSession(session)
        terminalPlacementFeature.registerSession(session.id)
        isTerminalVisible = true
        isTestsVisible = false
        isGitLogVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
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
        completion: @escaping DebugRunInTerminalCompletion
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failure(DebugTerminalLaunchError.hostUnavailable))
                return
            }
            do {
                completion(.success(try await startDebugProcessInTerminal(request)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func startDebugProcessInTerminal(
        _ request: DebugRunInTerminalRequest
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
        let created = try feature.createProcessSession(launch)
        configureTerminalSession(created.session)
        terminalPlacementFeature.registerSession(created.session.id)
        debugTerminalSessionIDs.insert(created.session.id)
        isTerminalVisible = true
        isTestsVisible = false
        isGitLogVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        created.session.focus()
        return DebugRunInTerminalResponse(processID: Int(created.processID))
    }

    func stopDebugTerminalProcesses() {
        for sessionID in debugTerminalSessionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            terminalSessions.first(where: { $0.id == sessionID })?.stop()
        }
        debugTerminalSessionIDs.removeAll()
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
        isTerminalVisible = true
    }

    func selectEditorTerminalSession(_ session: TerminalSession) {
        guard terminalPlacementFeature.editorSessionIDs.contains(session.id),
              terminalFeature?.selectSession(session) == true else { return }
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
        isTerminalVisible = true
    }

    func moveTerminalToTool(_ sessionID: UUID, before targetSessionID: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }) else { return }
        editorTabOrderFeature.remove(.terminal(sessionID))
        terminalPlacementFeature.moveToTool(sessionID, before: targetSessionID)
        _ = terminalFeature?.selectSession(session)
        isTerminalVisible = true
    }

    func moveTerminalToTool(_ sessionID: UUID, after targetSessionID: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }) else { return }
        editorTabOrderFeature.remove(.terminal(sessionID))
        terminalPlacementFeature.moveToTool(sessionID, after: targetSessionID)
        _ = terminalFeature?.selectSession(session)
        isTerminalVisible = true
    }

    func closeTerminalSession(_ session: TerminalSession) {
        guard terminalSessions.contains(where: { $0.id == session.id }) else { return }
        debugTerminalSessionIDs.remove(session.id)
        editorTabOrderFeature.remove(.terminal(session.id))
        terminalPlacementFeature.removeSession(session.id)
        terminalFeature?.closeSession(session)
        if terminalSessions.isEmpty {
            isTerminalVisible = false
            try? services.moduleRuntime.markIdle(.terminal)
        }
    }

    func restartActiveTerminal() { terminalFeature?.restartActiveSession() }
    func restartActiveTerminal(using shellPath: String) { terminalFeature?.restartActiveSession(using: shellPath) }
    func stopTerminalSessions() {
        debugTerminalSessionIDs.removeAll()
        editorTabOrderFeature.removeAllTerminals()
        terminalPlacementFeature.reset()
        terminalFeature?.stopAllSessions()
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

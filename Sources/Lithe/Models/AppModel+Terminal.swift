import Foundation

extension AppModel {
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
        if activeTerminalSession == nil { createTerminalSession() }
    }

    var terminalSessions: [TerminalSession] { terminalFeature.terminalSessions }
    var activeTerminalSessionID: UUID? { terminalFeature.activeTerminalSessionID }
    var activeTerminalSession: TerminalSession? { terminalFeature.activeTerminalSession }
    func terminalTitle(for session: TerminalSession) -> String { terminalFeature.terminalTitle(for: session) }

    @discardableResult
    func createTerminalSession(shellPath: String? = nil) -> TerminalSession? {
        guard let workspaceURL else { return nil }
        let session = terminalFeature.createSession(in: workspaceURL, shellPath: shellPath ?? settings.terminalShellPath)
        configureTerminalSession(session)
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
        guard terminalFeature.selectSession(session) else { return }
        isTerminalVisible = true
    }

    func closeTerminalSession(_ session: TerminalSession) {
        guard terminalSessions.contains(where: { $0.id == session.id }) else { return }
        terminalFeature.closeSession(session)
        if terminalSessions.isEmpty { isTerminalVisible = false }
    }

    func restartActiveTerminal() { terminalFeature.restartActiveSession() }
    func restartActiveTerminal(using shellPath: String) { terminalFeature.restartActiveSession(using: shellPath) }
    func stopTerminalSessions() { terminalFeature.stopAllSessions() }

    var activeTerminalShellPath: String {
        settings.terminalShellPath ?? terminalFeature.availableShells.first ?? "/bin/zsh"
    }
}

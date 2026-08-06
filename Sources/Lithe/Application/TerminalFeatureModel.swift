import Combine
import Foundation

/// Owns terminal session state while leaving the actual PTY/ConPTY transport
/// to the platform composition root.
@MainActor
final class TerminalFeatureModel: ObservableObject {
    @Published private(set) var terminalSessions: [TerminalSession] = []
    @Published private(set) var activeTerminalSessionID: UUID?

    private let terminalFactory: () -> any TerminalTransport

    init(terminalFactory: @escaping () -> any TerminalTransport) {
        self.terminalFactory = terminalFactory
    }

    var activeTerminalSession: TerminalSession? {
        guard let activeTerminalSessionID else { return terminalSessions.first }
        return terminalSessions.first { $0.id == activeTerminalSessionID }
    }

    func terminalTitle(for session: TerminalSession) -> String {
        if let processTitle = session.processTitle, !processTitle.isEmpty {
            return processTitle
        }
        guard let index = terminalSessions.firstIndex(where: { $0.id == session.id }) else {
            return "Local"
        }
        return index == 0 ? "Local" : "Local (\(index + 1))"
    }

    @discardableResult
    func createSession(in workspaceURL: URL, shellPath: String? = nil) -> TerminalSession {
        let session = TerminalSession(transport: terminalFactory())
        session.start(in: workspaceURL, shellPath: shellPath)
        terminalSessions.append(session)
        activeTerminalSessionID = session.id
        return session
    }

    @discardableResult
    func selectSession(_ session: TerminalSession) -> Bool {
        guard terminalSessions.contains(where: { $0.id == session.id }) else { return false }
        activeTerminalSessionID = session.id
        return true
    }

    func closeSession(_ session: TerminalSession) {
        guard let index = terminalSessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasActive = activeTerminalSessionID == session.id
        let replacement = terminalSessions.dropFirst(index + 1).first
            ?? (index > 0 ? terminalSessions[index - 1] : nil)

        session.stop()
        terminalSessions.remove(at: index)

        if wasActive {
            activeTerminalSessionID = replacement?.id
        }
        if terminalSessions.isEmpty {
            activeTerminalSessionID = nil
        }
    }

    func restartActiveSession() {
        activeTerminalSession?.restart()
    }

    func restartActiveSession(using shellPath: String) {
        activeTerminalSession?.restart(using: shellPath)
    }

    func stopAllSessions() {
        terminalSessions.forEach { $0.stop() }
        terminalSessions.removeAll()
        activeTerminalSessionID = nil
    }
}

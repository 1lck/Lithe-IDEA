import Combine
import Foundation

/// Owns terminal sessions while the platform adapter owns the PTY and surface.
@MainActor
public final class TerminalFeatureModel: ObservableObject {
    @Published public private(set) var terminalSessions: [TerminalSession] = []
    @Published public private(set) var activeTerminalSessionID: UUID?

    @Published public private(set) var availableShells: [String] = []
    @Published public private(set) var isDiscoveringShells = false
    @Published public private(set) var shellDiscoveryError: String?

    private let terminalFactory: () -> any TerminalTransport
    private let workspaceTerminalFactory: ((URL) -> any TerminalTransport)?
    private let shellDiscovery: () -> [String]
    private let workspaceShellDiscovery: ((URL) async throws -> [String]?)?
    private var shellWorkspace: URL?
    private var shellDiscoveryTask: Task<Void, Never>?
    private var shellDiscoveryGeneration = UUID()
    private var pendingProcessSessions: [UUID: TerminalSession] = [:]

    public init(
        terminalFactory: @escaping () -> any TerminalTransport,
        workspaceTerminalFactory: ((URL) -> any TerminalTransport)? = nil,
        shellDiscovery: @escaping () -> [String] = { [] },
        workspaceShellDiscovery: ((URL) async throws -> [String]?)? = nil
    ) {
        self.terminalFactory = terminalFactory
        self.workspaceTerminalFactory = workspaceTerminalFactory
        self.shellDiscovery = shellDiscovery
        self.workspaceShellDiscovery = workspaceShellDiscovery
        refreshAvailableShells()
    }

    public func refreshAvailableShells() {
        shellDiscoveryTask?.cancel()
        let generation = UUID()
        shellDiscoveryGeneration = generation
        shellDiscoveryError = nil
        guard let root = shellWorkspace, let discover = workspaceShellDiscovery else {
            isDiscoveringShells = false
            availableShells = shellDiscovery()
            return
        }
        // Clear the previous host before starting I/O; stale results must never
        // offer a local executable in a remote workspace's shell menu.
        availableShells = []
        isDiscoveringShells = true
        shellDiscoveryTask = Task { [weak self] in
            do {
                let shells = try await discover(root)
                guard let self, !Task.isCancelled, shellDiscoveryGeneration == generation else { return }
                availableShells = shells ?? shellDiscovery()
                isDiscoveringShells = false
                shellDiscoveryTask = nil
            } catch {
                guard let self, !Task.isCancelled, shellDiscoveryGeneration == generation else { return }
                shellDiscoveryError = error.localizedDescription
                isDiscoveringShells = false
                shellDiscoveryTask = nil
            }
        }
    }

    /// Binds discovery to the window's workspace, independently of which
    /// terminal tab is selected or whether a terminal has been created yet.
    public func setShellWorkspace(_ root: URL?) {
        let root = root?.standardizedFileURL
        guard shellWorkspace != root else { return }
        shellWorkspace = root
        if workspaceShellDiscovery != nil { refreshAvailableShells() }
    }

    public var activeTerminalSession: TerminalSession? {
        guard let activeTerminalSessionID else { return terminalSessions.first }
        return terminalSessions.first { $0.id == activeTerminalSessionID }
    }

    /// A launch awaiting host acknowledgement still owns a process resource.
    public var hasActiveSessions: Bool {
        !pendingProcessSessions.isEmpty || terminalSessions.contains { $0.isRunning || $0.startedAt != nil && $0.endedAt == nil }
    }

    public func terminalTitle(for session: TerminalSession) -> String {
        if let processTitle = session.processTitle, !processTitle.isEmpty { return processTitle }
        guard let index = terminalSessions.firstIndex(where: { $0.id == session.id }) else { return "Local" }
        return index == 0 ? session.shellName : "\(session.shellName) (\(index + 1))"
    }

    public func toolTabTitle(for session: TerminalSession, orderedSessions: [TerminalSession]) -> String {
        guard !session.isManagedProcess else { return terminalTitle(for: session) }
        let base = session.preferredToolTabTitle ?? "Local"
        guard let index = orderedSessions.firstIndex(where: { $0.id == session.id }) else { return base }
        let number = orderedSessions[..<index].filter { ($0.preferredToolTabTitle ?? "Local") == base }.count + 1
        return number == 1 ? base : "\(base) (\(number))"
    }

    @discardableResult
    public func createSession(
        in workspaceURL: URL,
        shellPath: String? = nil,
        preferredToolTabTitle: String? = nil,
        showsWorkbenchBackground: Bool = false
    ) -> TerminalSession {
        setShellWorkspace(workspaceURL)
        let transport = workspaceTerminalFactory?(workspaceURL) ?? terminalFactory()
        transport.configureInitialSurface(showsWorkbenchBackground: showsWorkbenchBackground)
        let session = TerminalSession(transport: transport, preferredToolTabTitle: preferredToolTabTitle)
        session.start(in: workspaceURL, shellPath: shellPath)
        terminalSessions.append(session)
        activeTerminalSessionID = session.id
        return session
    }

    @discardableResult
    public func createProcessSession(
        _ launch: TerminalProcessLaunch,
        showsWorkbenchBackground: Bool = false,
        onOutput: ((String) -> Void)? = nil
    ) throws -> (session: TerminalSession, processID: Int32) {
        let transport = workspaceTerminalFactory?(URL(fileURLWithPath: launch.workingDirectory)) ?? terminalFactory()
        transport.configureInitialSurface(showsWorkbenchBackground: showsWorkbenchBackground)
        let session = TerminalSession(transport: transport)
        session.onOutput = onOutput
        let processID = try session.startProcess(launch)
        terminalSessions.append(session)
        activeTerminalSessionID = session.id
        return (session, processID)
    }

    /// Uses workspace identity for host selection even when a debugger supplies
    /// an absolute working directory on that host.
    public func createProcessSessionAsync(
        _ launch: TerminalProcessLaunch,
        workspaceURL: URL,
        showsWorkbenchBackground: Bool = false,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> (session: TerminalSession, processID: Int32) {
        let transport = workspaceTerminalFactory?(workspaceURL) ?? terminalFactory()
        transport.configureInitialSurface(showsWorkbenchBackground: showsWorkbenchBackground)
        let session = TerminalSession(transport: transport)
        session.onOutput = onOutput
        pendingProcessSessions[session.id] = session
        defer { pendingProcessSessions[session.id] = nil }
        let processID = try await session.startProcessAsync(launch)
        terminalSessions.append(session)
        activeTerminalSessionID = session.id
        return (session, processID)
    }

    @discardableResult
    public func selectSession(_ session: TerminalSession) -> Bool {
        guard terminalSessions.contains(where: { $0.id == session.id }) else { return false }
        activeTerminalSessionID = session.id
        return true
    }

    public func closeSession(_ session: TerminalSession) {
        guard let index = terminalSessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasActive = activeTerminalSessionID == session.id
        let replacement = terminalSessions.dropFirst(index + 1).first
            ?? (index > 0 ? terminalSessions[index - 1] : nil)
        session.stop()
        terminalSessions.remove(at: index)
        if wasActive { activeTerminalSessionID = replacement?.id }
        if terminalSessions.isEmpty { activeTerminalSessionID = nil }
    }

    public func restartActiveSession() { activeTerminalSession?.restart() }
    public func restartActiveSession(using shellPath: String) { activeTerminalSession?.restart(using: shellPath) }

    /// Sends UTF-8 input to a specific terminal session when its PTY is live.
    /// The session ID keeps callers from accidentally writing to whichever
    /// terminal happens to be selected in the UI.
    @discardableResult
    public func sendInput(_ input: String, to sessionID: UUID) -> Bool {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }),
              session.isRunning,
              session.isReady else { return false }
        session.sendInput(input)
        return true
    }

    public func stopAllSessions() {
        cancelShellDiscovery()
        pendingProcessSessions.values.forEach { $0.stop() }
        pendingProcessSessions.removeAll()
        terminalSessions.forEach { $0.stop() }
        terminalSessions.removeAll()
        activeTerminalSessionID = nil
    }

    /// Stops every session and waits until their process sessions are gone.
    public func stopAllSessionsAndWait() async {
        let discovery = shellDiscoveryTask
        cancelShellDiscovery()
        let sessions = terminalSessions + pendingProcessSessions.values
        pendingProcessSessions.removeAll()
        terminalSessions.removeAll()
        activeTerminalSessionID = nil
        // Started together so the bounded grace periods overlap.
        let stops = sessions.map { session in
            Task { @MainActor in await session.stopAndWait() }
        }
        for stop in stops { await stop.value }
        await discovery?.value
    }

    private func cancelShellDiscovery() {
        shellDiscoveryGeneration = UUID()
        shellDiscoveryTask?.cancel()
        shellDiscoveryTask = nil
        isDiscoveringShells = false
    }

    deinit { shellDiscoveryTask?.cancel() }
}

import Combine
import Foundation
import LitheModuleAPI

// Note: SSH 连接配置与测试连接见 .agents/notes/implemented/feature/2026-10-24-remote-ssh-connections.md

/// State of the Remote Development window: the saved SSH connections being
/// edited, the connection test, and the questions OpenSSH asks during it.
///
/// Like IntelliJ IDEA's run configurations, the whole list is edited as one
/// working copy; Save writes it, closing without saving discards it.
@MainActor
final class RemoteConnectionsFeatureModel: ObservableObject {
    enum TestState: Equatable {
        case idle
        case testing
        case finished(RemoteProbeResult)
        /// The test could not run, for example because `ssh` is missing.
        case failed(String)
    }

    @Published private(set) var connections: [RemoteSSHConnection]
    @Published var selectedID: UUID?
    @Published private(set) var testState: TestState = .idle
    /// Questions waiting for the user, oldest first. The window shows the
    /// first one; Core keeps the others waiting until they are answered.
    @Published private(set) var prompts: [RemoteAuthenticationPrompt] = []
    @Published var showsAdvancedSettings = false
    @Published private(set) var saveError: String?
    /// The remote folder browser, shown while a connection is open.
    @Published private(set) var browser: DirectoryBrowser?

    /// One open connection and the folder it shows.
    struct DirectoryBrowser: Equatable {
        let connectionID: UUID
        let session: RemoteOpenedSession
        var path: String
        var entries: [RemoteDirectoryEntry] = []
        var isLoading = true
        var error: String?

        /// Folders first, then files, each by name.
        var sortedEntries: [RemoteDirectoryEntry] {
            entries.sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }

        var parentPath: String? {
            guard path != "/" else { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        }
    }

    private let store: RemoteConnectionStore
    private let prober: any RemoteConnectionProbing
    private let sessions: any RemoteSessionConnecting
    private let locator: any RemoteHostLocating
    /// Opens a connected folder as a workspace; the session then belongs to
    /// the workspace instead of this window.
    private let openWorkspace: (RemoteSSHConnection, String, RemoteOpenedSession) throws -> Void
    /// The lost workspace this window reconnects; Open then restores its
    /// folder rather than the connection's saved one.
    let reconnect: RemoteConnectionLoss?
    /// Set once a workspace was opened, so the window can close.
    @Published private(set) var didOpenWorkspace = false
    @Published private(set) var isLocating = false
    @Published private(set) var locationError: String?
    /// Servers shipped with the app; `nil` when it was built without them.
    let servers: RemoteServerBundle?
    private var browseTask: Task<Void, Never>?
    private var savedConnections: [RemoteSSHConnection]
    /// Secrets typed in this window, by connection. Saving writes them to
    /// the keychain only for connections that remember their secret.
    private var secretDrafts: [UUID: String] = [:]
    /// Connection whose test produced `testState` and `prompts`.
    private var testedID: UUID?
    private var testTask: Task<Void, Never>?
    /// Prompts already answered from a remembered secret, so a rejected
    /// secret is never sent twice.
    private var autoAnsweredPrompts: Set<String> = []

    init(
        store: RemoteConnectionStore,
        prober: any RemoteConnectionProbing,
        sessions: any RemoteSessionConnecting,
        locator: any RemoteHostLocating,
        servers: RemoteServerBundle?,
        reconnect: RemoteConnectionLoss? = nil,
        openWorkspace: @escaping (RemoteSSHConnection, String, RemoteOpenedSession) throws -> Void = { _, _, _ in }
    ) {
        self.openWorkspace = openWorkspace
        self.reconnect = reconnect
        self.store = store
        self.prober = prober
        self.sessions = sessions
        self.locator = locator
        self.servers = servers
        let saved = store.load()
        savedConnections = saved
        connections = saved
        selectedID = saved.first(where: { $0.id == reconnect?.connectionID })?.id ?? saved.first?.id
    }

    var selection: RemoteSSHConnection? {
        connections.first { $0.id == selectedID }
    }

    var hasChanges: Bool {
        connections != savedConnections || secretDrafts.values.contains { !$0.isEmpty }
    }

    var canSave: Bool {
        connections.allSatisfy { $0.problem == nil } && testState != .testing
    }

    // MARK: Editing

    func addConnection() {
        let connection = RemoteSSHConnection(port: 22)
        connections.append(connection)
        selectedID = connection.id
    }

    func removeSelection() {
        guard let index = connections.firstIndex(where: { $0.id == selectedID }) else { return }
        let removed = connections.remove(at: index)
        secretDrafts[removed.id] = nil
        if testedID == removed.id { cancelTest() }
        selectedID = connections.indices.contains(index) ? connections[index].id : connections.last?.id
    }

    /// Applies `change` to the selected connection. Editing a connection
    /// makes an earlier test result stale, so it is cleared.
    func update(_ change: (inout RemoteSSHConnection) -> Void) {
        guard let index = connections.firstIndex(where: { $0.id == selectedID }) else { return }
        var connection = connections[index]
        change(&connection)
        guard connection != connections[index] else { return }
        connections[index] = connection
        if testedID == connection.id, testState != .testing { testState = .idle }
    }

    /// The secret shown in the selected connection's field: what was typed
    /// in this window, never the remembered value.
    var secretDraft: String {
        get { selectedID.flatMap { secretDrafts[$0] } ?? "" }
        set {
            guard let id = selectedID else { return }
            secretDrafts[id] = newValue
            objectWillChange.send()
        }
    }

    /// Whether the keychain already holds a secret for the selected connection.
    var hasRememberedSecret: Bool {
        guard let id = selectedID, savedConnections.contains(where: { $0.id == id && $0.remembersSecret }) else {
            return false
        }
        return store.secret(for: id) != nil
    }

    // MARK: Testing

    /// Result for the selected connection; results of another connection
    /// are not shown on this one.
    var selectionTestState: TestState {
        testedID == selectedID ? testState : .idle
    }

    func testSelection() {
        guard let connection = selection, connection.problem == nil else { return }
        cancelTest()
        testedID = connection.id
        testState = .testing
        autoAnsweredPrompts = []
        let prober = prober
        testTask = Task { [weak self] in
            let result = await prober.probe(connection.target) { [weak self] prompt in
                Task { @MainActor [weak self] in self?.receive(prompt, for: connection.id) }
            }
            guard let self, !Task.isCancelled, self.testedID == connection.id else { return }
            self.declineWaitingPrompts()
            switch result {
            case .success(let probe):
                self.testState = .finished(self.shippedServerCheck(probe))
                self.remember(probe.host, for: connection)
            case .failure(let failure): self.testState = .failed(failure.message)
            }
            self.testTask = nil
        }
    }

    /// Stores what a connection learned about its host, keeping a location
    /// the user looked up while the address stays the same.
    private func remember(_ host: RemoteProbedHost?, for connection: RemoteSSHConnection) {
        guard let host else { return }
        let id = connection.id
        let previous = connections.first { $0.id == id }?.lastKnownHost
        var known = RemoteKnownHost(
            checkedAt: Date(), system: host.system, machine: host.machine,
            homeDirectory: host.homeDirectory, details: host.details,
            address: previous?.address, location: previous?.location
        )
        setKnownHost(known, for: id)
        let locator = locator
        let hostName = connection.target.host
        Task { [weak self] in
            let address = await locator.resolveAddress(of: hostName)
            guard let self else { return }
            if address != known.address { known.location = nil }
            known.address = address
            self.setKnownHost(known, for: id)
        }
    }

    /// Host facts are not an edit: a saved connection keeps them right away,
    /// without saving the window's other unsaved changes.
    private func setKnownHost(_ host: RemoteKnownHost, for id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].lastKnownHost = host
        if let saved = savedConnections.firstIndex(where: { $0.id == id }) {
            savedConnections[saved].lastKnownHost = host
            try? store.save(savedConnections)
        }
    }

    /// Looks up where the selected host's address is registered. This sends
    /// the address to an external service, so it runs only on request.
    func locateSelectedHost() {
        guard let connection = selection, let address = connection.lastKnownHost?.address, !isLocating else { return }
        isLocating = true
        locationError = nil
        let locator = locator
        Task { [weak self] in
            let result = await locator.locate(address)
            guard let self else { return }
            self.isLocating = false
            switch result {
            case .success(let location):
                guard var known = self.connections.first(where: { $0.id == connection.id })?.lastKnownHost,
                      known.address == address else { return }
                known.location = location
                self.setKnownHost(known, for: connection.id)
            case .failure(let failure):
                self.locationError = failure.message
            }
        }
    }

    /// Whether connecting and browsing are possible in this build.
    var canConnect: Bool { servers != nil }

    /// Connects to the selected connection's host, installing the server
    /// when needed, and opens the folder browser at the connection's folder
    /// or the remote home directory.
    func browseRemoteFolder() {
        connectSelection { connection, session in
            let start = connection.remoteDirectory.hasPrefix("/") ? connection.remoteDirectory
                : (session.homeDirectory ?? "/")
            self.browser = DirectoryBrowser(connectionID: connection.id, session: session, path: start)
            self.loadBrowser(start)
        }
    }

    /// Saves the window, connects, and opens the connection's folder (or the
    /// remote home directory) as a workspace in this window.
    func openSelection() {
        guard save() else { return }
        connectSelection { connection, session in
            let folder = self.reconnect.flatMap { $0.connectionID == connection.id ? $0.remoteRoot : nil }
                ?? connection.effectiveRemoteDirectory ?? session.homeDirectory ?? "/"
            do {
                try self.openWorkspace(connection, folder, session)
                self.didOpenWorkspace = true
            } catch {
                self.testState = .failed(String(format: L10n.string("Could not open the remote folder: %@"), error.localizedDescription))
                let sessions = self.sessions
                Task { await sessions.disconnect(session: session.id) }
            }
        }
    }

    /// Connects the selected connection, relaying prompts, and hands the open
    /// session to `connected`. Failures are shown like test results.
    private func connectSelection(_ connected: @escaping (RemoteSSHConnection, RemoteOpenedSession) -> Void) {
        guard let connection = selection, connection.problem == nil, let servers else { return }
        cancelTest()
        testedID = connection.id
        testState = .testing
        autoAnsweredPrompts = []
        let sessions = sessions
        testTask = Task { [weak self] in
            let result = await sessions.connect(connection.target, servers: servers) { [weak self] prompt in
                Task { @MainActor [weak self] in self?.receive(prompt, for: connection.id) }
            }
            guard let self, !Task.isCancelled, self.testedID == connection.id else {
                if case .success(let opened) = result, let session = opened.session {
                    await sessions.disconnect(session: session.id)
                }
                return
            }
            self.declineWaitingPrompts()
            self.testTask = nil
            switch result {
            case .failure(let failure):
                self.testState = .failed(failure.message)
            case .success(let opened):
                let probe = RemoteProbeResult(status: opened.status, host: opened.host, diagnostics: opened.diagnostics)
                self.remember(opened.host, for: connection)
                guard let session = opened.session else {
                    self.testState = .finished(self.shippedServerCheck(probe))
                    return
                }
                self.testState = .finished(probe)
                // The snapshot that was connected: the form may have been edited
                // since, and the session belongs to this host.
                connected(connection, session)
            }
        }
    }

    /// Lists `path` in the browser; a folder that cannot be read keeps the
    /// previous listing and shows why.
    func openBrowserPath(_ path: String) {
        guard browser != nil else { return }
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else {
            browser?.error = L10n.string("Enter an absolute path that starts with /.")
            return
        }
        loadBrowser(trimmed)
    }

    func openBrowserEntry(_ entry: RemoteDirectoryEntry) {
        guard let browser, entry.isDirectory else { return }
        openBrowserPath((browser.path as NSString).appendingPathComponent(entry.name))
    }

    /// Opens the browsed folder as a workspace. The open session passes to the
    /// workspace, so it is not disconnected here.
    func openBrowsedFolder() {
        guard let browser, !browser.isLoading else { return }
        guard let connection = connections.first(where: { $0.id == browser.connectionID }) else {
            self.browser?.error = String(
                format: L10n.string("Could not open the remote folder: %@"), L10n.string("The connection failed.")
            )
            return
        }
        do {
            try openWorkspace(connection, browser.path, browser.session)
            browseTask?.cancel()
            browseTask = nil
            self.browser = nil
            didOpenWorkspace = true
        } catch {
            self.browser?.error = String(format: L10n.string("Could not open the remote folder: %@"), error.localizedDescription)
        }
    }

    /// Saves the browsed folder as the connection's project folder.
    func chooseBrowserFolder() {
        guard let browser else { return }
        let path = browser.path
        if let index = connections.firstIndex(where: { $0.id == browser.connectionID }) {
            connections[index].remoteDirectory = path
        }
        closeBrowser()
    }

    func closeBrowser() {
        browseTask?.cancel()
        browseTask = nil
        guard let browser else { return }
        self.browser = nil
        let sessions = sessions
        Task { await sessions.disconnect(session: browser.session.id) }
    }

    private func loadBrowser(_ path: String) {
        guard let current = browser else { return }
        browseTask?.cancel()
        browser?.isLoading = true
        browser?.error = nil
        let sessions = sessions
        let sessionID = current.session.id
        browseTask = Task { [weak self] in
            let result = await sessions.readDirectory(path, session: sessionID)
            guard let self, !Task.isCancelled, self.browser?.session.id == sessionID else { return }
            self.browser?.isLoading = false
            switch result {
            case .success(let entries):
                self.browser?.path = path
                self.browser?.entries = entries
            case .failure(let failure):
                self.browser?.error = failure.message
            }
        }
    }

    /// A host the probe calls supported still needs a server build shipped
    /// in this app; macOS hosts are not shipped yet.
    private func shippedServerCheck(_ result: RemoteProbeResult) -> RemoteProbeResult {
        guard result.status == .connected, let servers, !servers.supports(result.host?.serverTarget) else {
            return result
        }
        return RemoteProbeResult(status: .unsupportedPlatform, host: result.host, diagnostics: result.diagnostics)
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        declineWaitingPrompts()
        if testState == .testing { testState = .idle }
    }

    /// Answers the first waiting prompt; `nil` declines it and stops the
    /// test, because OpenSSH would otherwise just ask again.
    func answerPrompt(_ answer: String?) {
        guard let prompt = prompts.first else { return }
        prompts.removeFirst()
        _ = prober.answer(prompt.requestId, with: answer)
        if answer == nil { cancelTest() }
    }

    private func receive(_ prompt: RemoteAuthenticationPrompt, for id: UUID) {
        guard testedID == id, testState == .testing else {
            _ = prober.answer(prompt.requestId, with: nil)
            return
        }
        if let secret = automaticAnswer(to: prompt, for: id) {
            autoAnsweredPrompts.insert(prompt.prompt)
            _ = prober.answer(prompt.requestId, with: secret)
            return
        }
        prompts.append(prompt)
    }

    /// A secret is answered without asking only for the first time OpenSSH
    /// asks exactly for it. One-time codes, host keys and any repeated
    /// question go to the user, so a wrong secret is never retried silently.
    private func automaticAnswer(to prompt: RemoteAuthenticationPrompt, for id: UUID) -> String? {
        guard prompt.secret, prompt.attempt == 1, !autoAnsweredPrompts.contains(prompt.prompt),
              let connection = connections.first(where: { $0.id == id }) else { return nil }
        let text = prompt.prompt.lowercased()
        let asksForSecret = switch connection.authentication {
        case .password: text.contains("password")
        case .privateKey: text.contains("passphrase")
        case .auto, .agent: false
        }
        guard asksForSecret else { return nil }
        if let typed = secretDrafts[id], !typed.isEmpty { return typed }
        guard connection.remembersSecret, savedConnections.contains(where: { $0.id == id && $0.remembersSecret })
        else { return nil }
        return store.secret(for: id)
    }

    private func declineWaitingPrompts() {
        for prompt in prompts { _ = prober.answer(prompt.requestId, with: nil) }
        prompts = []
    }

    // MARK: Saving

    /// Writes the list and the remembered secrets. Returns `false` and keeps
    /// the window open when something could not be saved.
    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        do {
            try store.save(connections)
            let current = Set(connections.map(\.id))
            for removed in savedConnections where !current.contains(removed.id) {
                try store.deleteSecret(for: removed.id)
            }
            savedConnections = connections
            for connection in connections {
                if !connection.remembersSecret || !connection.usesSecret {
                    try store.deleteSecret(for: connection.id)
                } else if let secret = secretDrafts[connection.id], !secret.isEmpty {
                    try store.saveSecret(secret, for: connection.id)
                }
            }
            saveError = nil
            return true
        } catch {
            saveError = String(format: L10n.string("Could not save the connections: %@"), error.localizedDescription)
            return false
        }
    }

    /// Stops a running test when the window closes.
    func close() {
        cancelTest()
        closeBrowser()
        secretDrafts = [:]
    }
}

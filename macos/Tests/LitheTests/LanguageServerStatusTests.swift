import Combine
import AppKit
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing
import SwiftUI
@testable import Lithe

@Suite("Language server status and logs")
@MainActor
struct LanguageServerStatusTests {
    @Test func statusListIncludesDormantAndDisabledRegisteredProvidersAndKeepsFailures() {
        let registrations = [registration("z", "Same"), registration("a", "Same"), registration("b", "Alpha"),
                             registration("d", "Disabled"), registration("s", "Stopped"), registration("n", "Never started")]
        let servers = LSPControlCenterPresenter.statusBarServers(
            registrations: registrations,
            states: ["z": .ready, "a": .initializing, "b": .failed(.init(exitCode: 1, message: "failure")),
                     "d": .ready, "s": .stopped],
            infos: ["z": .init(name: "Same", version: " 1.2 "), "a": .init(name: "Same", version: "stale")],
            disabledProviderIDs: ["d"]
        )
        #expect(servers.map(\.id) == ["b", "d", "n", "a", "z", "s"])
        #expect(servers.map(\.version) == [nil, nil, nil, nil, "1.2", nil])
        #expect(servers.first { $0.id == "d" }?.status == .disabled)
        #expect(servers.first { $0.id == "n" }?.status == .stopped)
        #expect(LSPControlCenterPresenter.aggregateStatus(servers) == .error)
        #expect(LSPControlCenterPresenter.aggregateStatus([]) == .stopped)
        #expect(LSPControlCenterPresenter.aggregateStatus(Array(servers.dropFirst())) == .initializing)
    }

    @Test func statusProjectionPublishesOnlyWhenSessionChromeChanges() throws {
        let harness = Harness()
        defer { harness.sessions.stopAllLanguageServers() }
        harness.feature.bindSessions(harness.sessions)
        var changes = 0
        let observation = harness.feature.$serverRuntimeSnapshot.dropFirst().sink { _ in changes += 1 }
        defer { observation.cancel() }
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        #expect(harness.feature.serverRuntimeSnapshot.states["example"] == .ready)
        let beforeLog = changes
        #expect(changes == beforeLog)
        harness.feature.stop(providerID: "example")
        #expect(harness.feature.serverRuntimeSnapshot.states["example"] == .stopped)
    }

    @Test func serverNamesUseExistingExecutableMetadataAndOtherwiseThePluginID() {
        let registrations = [registration("a", "server-a"), registration("c", "clangd"),
            LanguageServerRegistration(id: "legacy", pluginID: "org.example.legacy", executableNames: ["", " "])]
        let rows = LSPControlCenterPresenter.statusBarServers(registrations: registrations,
            states: ["a": .ready, "c": .ready, "unregistered": .ready],
            infos: ["a": .init(name: "Example Language Server", version: "1"),
                    "c": .init(name: "Apple clangd", version: "21")], disabledProviderIDs: [])
        #expect(Set(rows.map(\.displayName)) == ["server-a", "clangd", "org.example.legacy"])
        #expect(rows.allSatisfy { $0.id != "unregistered" })
        #expect(LSPControlCenterPresenter.statusBarServers(registrations: [],
            states: ["a": .ready], infos: [:], disabledProviderIDs: []).isEmpty)
    }

    @Test func idleMenuKeepsLogsAndSettingsAvailableWithoutAnySessions() throws {
        var viewed = false, configured = false
        let menu = LanguageServerStatusMenu.items(servers: [], viewLogs: { _ in viewed = true },
            restart: { _ in Issue.record("An idle menu must not restart a server") },
            stop: { _ in Issue.record("An idle menu must not stop a server") },
            settings: { configured = true })
        let logs = try #require(menu.first { $0.title == L10n.string(key: "native.inline.viewLogs") })
        #expect(logs.isEnabled)
        logs.action()
        let settings = try #require(menu.first { $0.title == "Language Server Settings..." })
        #expect(settings.isEnabled)
        settings.action()
        #expect(viewed && configured)
        #expect(menu.first { $0.title == "Restart All Servers" }?.isEnabled == false)
        #expect(menu.first { $0.title == "Stop All Servers" }?.isEnabled == false)
    }

    @Test func restartStopsBeforeReopeningOnlyMatchingDocumentsAndPreservesPreferences() async throws {
        let harness = Harness()
        defer { harness.sessions.stopAllLanguageServers() }
        let matching = EditorDocument(url: harness.workspace.appendingPathComponent("a.example"), text: "", modificationDate: nil)
        let other = EditorDocument(url: harness.workspace.appendingPathComponent("README.txt"), text: "", modificationDate: nil)
        var activated: [URL] = []
        let reopened = TestGate()
        harness.feature.configure(documentsProvider: { [other, matching] }, activateDocument: { document in
            #expect(harness.session.stopCount == 1)
            activated.append(document.url)
            reopened.open()
            return true
        }, notify: { _ in })
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        let preferences = harness.store.values
        let token = harness.feature.activationToken(providerID: "example")
        harness.feature.restart(providerID: "example")
        try #require(await reopened.waitUntilOpen())
        #expect(activated == [matching.url])
        #expect(harness.feature.activationToken(providerID: "example") != token)
        #expect(harness.store.values.keys.sorted() == preferences.keys.sorted())
        #expect(!harness.feature.isDisabled("example"))
    }

    @Test func restartWithoutDocumentsRestartsTheSameProviderAndDisabledRestartDoesNothing() async throws {
        let harness = Harness()
        defer { harness.sessions.stopAllLanguageServers() }
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        let restarted = TestGate()
        harness.session.onStart = { restarted.open() }
        harness.feature.restart(providerID: "example")
        try #require(await restarted.waitUntilOpen())
        #expect(harness.session.startCount == 2)
        #expect(harness.session.stopCount == 1)
        harness.feature.setEnabled(false, providerID: "example")
        harness.feature.restart(providerID: "example")
        #expect(harness.session.startCount == 2)
        #expect(harness.feature.isDisabled("example"))
    }

    @Test func restartWaitsForDelayedShutdownAndKeepsStoppingUntilTheSlotIsReleased() async throws {
        let harness = Harness()
        let released = TestGate(), restarted = TestGate()
        harness.session.releaseStop = released
        defer { released.open(); harness.feature.stop(providerID: "example") }
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        harness.feature.bindSessions(harness.sessions)
        harness.session.onStart = { restarted.open() }
        harness.feature.restart(providerID: "example")
        try #require(await harness.session.stopRequested.waitUntilOpen())
        #expect(harness.session.startCount == 1)
        #expect(harness.feature.serverRuntimeSnapshot.states["example"] == .stopping)
        #expect(throws: (any Error).self) {
            try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        }
        released.open()
        try #require(await restarted.waitUntilOpen())
        #expect(harness.session.startCount == 2)
    }

    @Test func stoppingWhileRestartWaitsCannotResurrectTheServer() async throws {
        let harness = Harness()
        let released = TestGate()
        harness.session.releaseStop = released
        defer { released.open(); harness.sessions.stopAllLanguageServers() }
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        harness.feature.restart(providerID: "example")
        try #require(await harness.session.stopRequested.waitUntilOpen())
        harness.feature.stop(providerID: "example")
        released.open()
        #expect(await harness.sessions.stopLanguageServerAndWait(providerID: "example"))
        #expect(harness.session.startCount == 1)
    }

    @Test func aFailedShutdownKeepsItsSlotUntilAnExplicitRetryConfirmsRelease() async throws {
        let harness = Harness()
        defer { harness.sessions.stopAllLanguageServers() }
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        harness.session.stopCompletes = false
        #expect(await harness.sessions.stopLanguageServerAndWait(providerID: "example") == false)
        #expect(throws: (any Error).self) {
            try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        }
        harness.session.stopCompletes = true
        #expect(await harness.sessions.stopLanguageServerAndWait(providerID: "example"))
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        #expect(harness.session.startCount == 2)
    }

    @Test func providerResetPreservesOtherLiveServers() throws {
        let harness = Harness(includesSecondProvider: true)
        defer { harness.sessions.stopAllLanguageServers() }
        harness.feature.bindSessions(harness.sessions)
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        try harness.sessions.startLanguageServer(providerID: "second", rootURL: harness.workspace)
        let before = harness.feature.serverRuntimeSnapshot
        try harness.sessions.rebuildWorkspaceState(providerID: "second", rootURL: harness.workspace)
        harness.feature.resetProviderState(providerID: "second")
        #expect(harness.feature.serverRuntimeSnapshot.states["example"] == .ready)
        #expect(harness.feature.serverRuntimeSnapshot.states["second"] == .stopped)
        #expect(harness.feature.serverRuntimeSnapshot.states["example"] == before.states["example"])
    }

    @Test func stopInvalidatesPendingActivation() {
        let harness = Harness()
        let old = harness.feature.activationToken(providerID: "example")
        let other = harness.feature.activationToken(providerID: "other")
        harness.feature.stop(providerID: "example")
        #expect(harness.feature.activationToken(providerID: "example") != old)
        #expect(harness.feature.activationToken(providerID: "other") == other)
        harness.feature.resetWorkspaceState()
        #expect(harness.feature.activationToken(providerID: "other") != other)
    }

    @Test func menuActionsTargetTheirServerAndBulkActionsUseTheSnapshot() throws {
        let servers = ["a", "b"].map { LSPStatusBarServer(id: $0, displayName: $0, status: .active, version: "1") }
        var viewed: [String] = [], restarted: [String] = [], stopped: [String] = []
        var openedSettings = false
        let items = LanguageServerStatusMenu.items(servers: servers,
            viewLogs: { viewed.append($0) }, restart: { restarted.append($0) }, stop: { stopped.append($0) },
            settings: { openedSettings = true })
        let server = try #require(items.first { $0.title == "b" })
        #expect(!server.localizesTitle)
        #expect(server.icon != nil)
        guard case .submenu(let actions) = server.kind else {
            Issue.record("Server row must expose a standard submenu")
            return
        }
        actions.forEach { $0.action() }
        #expect(viewed == ["b"])
        #expect(restarted == ["b"])
        #expect(stopped == ["b"])
        try #require(items.first { $0.title == "Restart All Servers" }).action()
        try #require(items.first { $0.title == "Stop All Servers" }).action()
        try #require(items.first { $0.title == "Language Server Settings..." }).action()
        #expect(restarted == ["b", "a", "b"])
        #expect(stopped == ["b", "a", "b"])
        #expect(openedSettings)
    }


    private func registration(_ id: String, _ name: String) -> LanguageServerRegistration {
        LanguageServerRegistration(id: id, pluginID: "org.example.tools", executableNames: [name])
    }
}

@MainActor
private final class Harness {
    let workspace = URL(fileURLWithPath: "/example/workspace")
    let session = StatusTestSession()
    let store = StatusTestStore()
    let sessions: LanguageToolingSessionManager
    let feature: LanguageToolingFeatureModel

    init(includesSecondProvider: Bool = false) {
        let descriptor = LanguageProviderDescriptor(id: "example", displayName: "Example", fileExtensions: ["example"],
            capabilities: .languageServer, activationPolicy: .onDemand)
        let second = LanguageProviderDescriptor(id: "second", displayName: "Second", fileExtensions: ["second"],
            capabilities: .languageServer, activationPolicy: .onDemand)
        let source = StatusTestCatalog(catalog: LanguageProviderCatalog(descriptors: includesSecondProvider ? [descriptor, second] : [descriptor]))
        var runtimes: [any LanguageProviderRuntime] = [StatusTestRuntime(descriptor: descriptor, session: session)]
        if includesSecondProvider { runtimes.append(StatusTestRuntime(descriptor: second, session: StatusTestSession())) }
        let sessions = LanguageToolingSessionManager(catalog: source.catalog,
            runtimes: runtimes, workspaceStateResetter: { _, _ in })
        self.sessions = sessions
        feature = LanguageToolingFeatureModel(catalogSource: source, catalogSnapshot: source.load(workspaceURL: nil),
            preferences: MacWorkspaceLanguageServerPreferencesStore(store: store), sessionsProvider: { sessions })
        feature.reloadCatalog(for: workspace)
    }
}

private struct StatusTestCatalog: LanguageProviderCatalogSource {
    let catalog: LanguageProviderCatalog
    func load(workspaceURL: URL?) -> LanguageProviderCatalogSnapshot {
        .init(catalog: catalog, schemaVersion: nil, origin: .builtin, issues: [])
    }
}

private final class StatusTestStore: KeyValueStore {
    private(set) var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor
private final class StatusTestRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let session: StatusTestSession
    let supportsLanguageServerSession = true
    init(descriptor: LanguageProviderDescriptor, session: StatusTestSession) {
        self.descriptor = descriptor
        self.session = session
    }
    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}

@MainActor
private final class StatusTestSession: LanguageServerSession {
    var isRunning = false
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    var onStateChange: ((LanguageServerSessionState) -> Void)?
    var startCount = 0
    var stopCount = 0
    var releaseStop: TestGate?
    var stopCompletes = true
    let stopRequested = TestGate()
    var onStart: (() -> Void)?
    func start(rootURL: URL) throws {
        isRunning = true
        startCount += 1
        onStateChange?(.ready)
        onStart?()
    }
    func stop() { isRunning = false; stopCount += 1 }
    func stopAndWait() async -> Bool {
        stopRequested.open()
        guard stopCompletes else { return false }
        if let releaseStop {
            guard await releaseStop.waitUntilOpen() else { return false }
        }
        stop()
        return true
    }
    func synchronize(fileURL: URL, text: String, languageID: String) throws {}
    func closeDocument(_ fileURL: URL) {}
    func completions(fileURL: URL, position: LanguageServerPosition, completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void) throws { completion(.success([])) }
    func hover(fileURL: URL, position: LanguageServerPosition, completion: @escaping (Result<LanguageServerHover?, Error>) -> Void) throws { completion(.success(nil)) }
    func navigate(method: String, fileURL: URL, position: LanguageServerPosition, completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void) throws { completion(.success([])) }
    func rename(fileURL: URL, position: LanguageServerPosition, newName: String, completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void) throws { completion(.success(.init())) }
    func format(fileURL: URL, completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void) throws { completion(.success([])) }
    func codeActions(fileURL: URL, range: LanguageServerRange, diagnostics: [LanguageServerDiagnostic], completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void) throws { completion(.success([])) }
    func resolveCompletion(_ item: LanguageServerCompletionItem, fileURL: URL, completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void) throws { completion(.success(item)) }
    func resolveCodeAction(_ action: LanguageServerCodeAction, fileURL: URL, completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void) throws { completion(.success(action)) }
    func execute(_ command: LanguageServerCommand, fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) throws { completion(.success(())) }
    func resolveVirtualDocument(uri: String, completion: @escaping (Result<String, Error>) -> Void) throws { completion(.success("")) }
}

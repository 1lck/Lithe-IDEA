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
        harness.feature.bindProjectPreparation(harness.sessions)
        var changes = 0
        let observation = harness.feature.$serverRuntimeSnapshot.dropFirst().sink { _ in changes += 1 }
        defer { observation.cancel() }
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        #expect(harness.feature.serverRuntimeSnapshot.states["example"] == .ready)
        let beforeLog = changes
        harness.sessions.recordLanguageServerLog(providerID: "example", level: .info, message: "server output")
        #expect(changes == beforeLog)
        harness.feature.stop(providerID: "example")
        #expect(harness.feature.serverRuntimeSnapshot.states["example"] == .stopped)
    }

    @Test func serverNamesUseExistingExecutableMetadataAndOtherwiseThePluginID() {
        let registrations = [registration("java", "jdtls"), registration("c", "clangd"),
            LanguageServerRegistration(id: "legacy", pluginID: "org.example.legacy", executableNames: ["", " "])]
        let rows = LSPControlCenterPresenter.statusBarServers(registrations: registrations,
            states: ["java": .ready, "c": .ready, "unregistered": .ready],
            infos: ["java": .init(name: "Eclipse JDT Language Server", version: "1"),
                    "c": .init(name: "Apple clangd", version: "21")], disabledProviderIDs: [])
        #expect(Set(rows.map(\.displayName)) == ["jdtls", "clangd", "org.example.legacy"])
        #expect(rows.allSatisfy { $0.id != "unregistered" })
        #expect(LSPControlCenterPresenter.statusBarServers(registrations: [],
            states: ["java": .ready], infos: [:], disabledProviderIDs: []).isEmpty)
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

    @Test func restartStopsBeforeReopeningOnlyMatchingDocumentsAndPreservesPreferences() throws {
        let harness = Harness()
        defer { harness.sessions.stopAllLanguageServers() }
        let matching = EditorDocument(url: harness.workspace.appendingPathComponent("a.example"), text: "", modificationDate: nil)
        let other = EditorDocument(url: harness.workspace.appendingPathComponent("README.txt"), text: "", modificationDate: nil)
        var activated: [URL] = []
        harness.feature.configure(documentsProvider: { [other, matching] }, activateDocument: { document in
            #expect(harness.session.stopCount == 1)
            activated.append(document.url)
            return true
        }, notify: { _ in })
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        let preferences = harness.store.values
        let token = harness.feature.activationToken(providerID: "example")
        harness.feature.restart(providerID: "example")
        #expect(activated == [matching.url])
        #expect(harness.feature.activationToken(providerID: "example") != token)
        #expect(harness.store.values.keys.sorted() == preferences.keys.sorted())
        #expect(!harness.feature.isDisabled("example"))
    }

    @Test func restartWithoutDocumentsRestartsTheSameProviderAndDisabledRestartDoesNothing() throws {
        let harness = Harness()
        defer { harness.sessions.stopAllLanguageServers() }
        try harness.sessions.startLanguageServer(providerID: "example", rootURL: harness.workspace)
        harness.feature.restart(providerID: "example")
        #expect(harness.session.startCount == 2)
        #expect(harness.session.stopCount == 1)
        harness.feature.setEnabled(false, providerID: "example")
        harness.feature.restart(providerID: "example")
        #expect(harness.session.startCount == 2)
        #expect(harness.feature.isDisabled("example"))
    }

    @Test func stopInvalidatesPendingActivationAndCallsRegisteredPreparationOwner() {
        let harness = Harness()
        var cancelled = 0
        harness.feature.registerPreparationCancellation(providerID: "example") { cancelled += 1 }
        let old = harness.feature.activationToken(providerID: "example")
        let other = harness.feature.activationToken(providerID: "other")
        harness.feature.stop(providerID: "example")
        #expect(cancelled == 1)
        #expect(harness.feature.activationToken(providerID: "example") != old)
        #expect(harness.feature.activationToken(providerID: "other") == other)
        harness.feature.resetWorkspaceState()
        #expect(harness.feature.activationToken(providerID: "other") != other)
    }

    @Test func logFiltersAndClearArePerProviderAndNewEntriesRemainVisible() {
        let logs = LanguageServerLogsModel()
        let first = LanguageServerLogEntry(providerID: "a", level: .info, message: "one")
        let second = LanguageServerLogEntry(providerID: "b", level: .warning, message: "two")
        let third = LanguageServerLogEntry(providerID: "a", level: .error, message: "three")
        logs.replace([third, second, first])
        logs.providerID = "a"
        #expect(logs.visibleEntries.map(\.id) == [first.id, third.id])
        logs.minimumLevel = .warning
        #expect(logs.visibleEntries.map(\.id) == [third.id])
        logs.clear()
        logs.minimumLevel = .info
        #expect(logs.visibleEntries.isEmpty)
        logs.providerID = "b"
        #expect(logs.visibleEntries.map(\.id) == [second.id])
        let newer = LanguageServerLogEntry(providerID: "a", level: .warning, message: "new")
        logs.replace([newer, third, second, first])
        logs.providerID = "a"
        #expect(logs.visibleEntries.map(\.id) == [newer.id])
        logs.reset()
        #expect(logs.entries.isEmpty)
        #expect(logs.providerID.isEmpty)
    }

    @Test func logsTabReusesSelectionAndClosesBackToTheUnsavedDocument() async throws {
        let store = StatusTestStore()
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            model.documentFeature.openVirtualDocument(URL(string: "lithe-test://lsp/source.txt")!, text: "unsaved", displayPath: nil)
            let document = try #require(model.activeDocument)
            let file = EditorTabItem.document(document.id)
            model.showLanguageServerLogs(providerID: "a")
            #expect(model.editorTabItems == [file, .languageLogs])
            #expect(model.editorTabOrderFeature.focusedItem == .languageLogs)
            #expect(model.activeDocument == nil)
            model.showLanguageServerLogs(providerID: "b")
            #expect(model.editorTabItems == [file, .languageLogs])
            #expect(model.languageToolingFeature.logs.providerID == "b")
            model.selectEditorTab(file)
            #expect(model.activeDocument === document)
            model.selectEditorTab(.languageLogs)
            model.documentFeature.openVirtualDocument(URL(string: "lithe-test://lsp/another.txt")!, text: "second", displayPath: nil)
            #expect(model.editorTabOrderFeature.focusedItem != .languageLogs)
            model.selectEditorTab(.languageLogs)
            #expect(model.requestCloseActiveWorkbenchItem())
            #expect(!model.editorTabItems.contains(.languageLogs))
            #expect(model.activeDocument != nil)
            #expect(document.text == "unsaved")
            model.showLanguageServerLogs(providerID: "a")
            model.openMediaFile(URL(fileURLWithPath: "/example/image.png"), kind: .image)
            let media = try #require(model.activeMediaDocument)
            #expect(model.editorTabOrderFeature.focusedItem == .media(media.id))
            model.closeMediaDocument(media)
            model.showLanguageServerLogs(providerID: "a")
            model.featureGraph.editorSession.resetContent()
            #expect(!model.editorTabItems.contains(.languageLogs))
        }
    }

    @Test func logsTabUsesSharedReorderingAndSplitGroupLifecycle() throws {
        let order = EditorTabOrderFeatureModel()
        let file = EditorTabItem.document(UUID())
        order.moveToEnd(file)
        order.moveToEnd(.languageLogs)
        order.focus(.languageLogs)
        let group = try #require(order.groupLayout.groups.first)
        #expect(order.drop(.languageLogs, into: group, side: .right))
        #expect(order.groupLayout.groups.count == 2)
        order.reconcileDocuments(orderedIDs: [order.documentIDs[0]])
        #expect(order.contains(.languageLogs))
        order.remove(.languageLogs)
        #expect(order.groupLayout.groups.count == 1)
        #expect(order.items == [file])
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

    @Test(arguments: [ColorScheme.light, .dark], [CGFloat(360), 900])
    func logPanelRendersInNarrowAndWideDocks(scheme: ColorScheme, width: CGFloat) async throws {
        let settings = AppSettings(store: StatusTestStore())
        let container = MacServiceContainer(store: StatusTestStore(), settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            let logs = model.languageToolingFeature.logs
            logs.providerID = "example"
            logs.replace([
                LanguageServerLogEntry(timestamp: Date(timeIntervalSince1970: 100), providerID: "example", level: .error,
                    message: "Server exited", detail: "Example failure detail"),
                LanguageServerLogEntry(timestamp: Date(timeIntervalSince1970: 99), providerID: "example", level: .warning,
                    message: "Server warning"),
                LanguageServerLogEntry(timestamp: Date(timeIntervalSince1970: 98), providerID: "example", level: .info,
                    message: "Server ready")
            ])
            let host = NSHostingView(rootView: LanguageServerLogsView(feature: logs)
                .environmentObject(model).environmentObject(settings).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 320),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            #expect(host.frame.width == width)
            func textView(in view: NSView) -> NSTextView? {
                if let text = view as? NSTextView { return text }
                return view.subviews.lazy.compactMap { textView(in: $0) }.first
            }
            let nativeText = try #require(textView(in: host))
            #expect(nativeText.string.contains("Server ready"))
            #expect(nativeText.enclosingScrollView?.frame.width == width)
            #expect(nativeText.isEditable == false)
            #expect(nativeText.isSelectable)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            if let directory = ProcessInfo.processInfo.environment["LITHE_LSP_SNAPSHOT_DIR"] {
                let output = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("logs-\(scheme)-\(Int(width)).png"))
            }
        }
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

    init() {
        let descriptor = LanguageProviderDescriptor(id: "example", displayName: "Example", fileExtensions: ["example"],
            capabilities: .languageServer, activationPolicy: .onDemand)
        let source = StatusTestCatalog(catalog: LanguageProviderCatalog(descriptors: [descriptor]))
        let sessions = LanguageToolingSessionManager(catalog: source.catalog,
            runtimes: [StatusTestRuntime(descriptor: descriptor, session: session)])
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
    var javaTestRunnerURL: URL? { nil }
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    var onStateChange: ((LanguageServerSessionState) -> Void)?
    var startCount = 0
    var stopCount = 0
    func start(rootURL: URL, workspaceFingerprint: String?) throws {
        isRunning = true
        startCount += 1
        onStateChange?(.ready)
    }
    func stop() { isRunning = false; stopCount += 1 }
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
    func javaEntrypoints(completion: @escaping (Result<JavaEntrypoints, Error>) -> Void) throws { throw CancellationError() }
}

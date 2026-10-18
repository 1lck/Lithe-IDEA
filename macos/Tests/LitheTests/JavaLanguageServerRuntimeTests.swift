import Foundation
import CryptoKit
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("Java language server runtime")
struct JavaLanguageServerRuntimeTests {
    @Test
    func projectPreparationFixtureDecodesEverySharedStage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable { let snapshots: [ProjectPreparationSnapshot] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/lsp/project-preparation-v1.json")))
        #expect(fixture.snapshots.map(\.phase) == ["starting", "importing", "configuring", "building", "ready", "configuring", "stopped"])
        #expect(fixture.snapshots.filter { !$0.blocksRun }.map(\.phase) == ["ready", "configuring"])
        #expect(fixture.snapshots.filter { $0.status == "failed" }.allSatisfy { !$0.blocksRun })
    }

    @Test
    func mavenRuntimeFixtureDecodesStructuredTaskAndDistinctProjects() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable {
            let events: [RustCoreBridge.LspRuntimeEventPayload]
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/lsp/maven-profile-events-v1.json")))
        #expect(fixture.events.first?.mavenProfileTask == "running")
        #expect(fixture.events.last?.mavenProfileTask == "partiallySucceeded")
        let results = fixture.events.compactMap(\.mavenProfileProject)
        #expect(results.map(\.status) == ["running", "failed", "succeeded"])
        #expect(Set(results.map(\.projectUri)).count == 2)
    }

    @Test
    func coreInitializationTimeoutCodesRemainUserVisibleTimeouts() {
        #expect(LanguageServerSessionFailure(code: "timed_out").isTimedOut)
        #expect(LanguageServerSessionFailure(code: "initializeTimeout").isTimedOut)
        #expect(LanguageServerSessionFailure(code: "serviceReadyTimeout").isTimedOut)
        #expect(!LanguageServerSessionFailure(code: "serverExited").isTimedOut)
    }

    @Test
    func macJavaLaunchPlannerFindsReleaseFileInStandardJdkHomeLayout() throws {
        let fileManager = FileManager.default
        let jdkRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-java-release-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: jdkRoot) }
        let executable = jdkRoot.appendingPathComponent("Contents/Home/bin/java")
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("JAVA_VERSION=\"21.0.2\"\n".utf8)
            .write(to: jdkRoot.appendingPathComponent("Contents/Home/release"))

        #expect(RustCoreBridge.javaFeatureVersion(executable.path) == 21)
    }

    @Test
    func parsesModernAndLegacyJavaVersions() {
        #expect(javaRuntime("/jdk-17", "17.0.18").majorVersion == 17)
        #expect(javaRuntime("/jdk-21", "21-ea").majorVersion == 21)
        #expect(javaRuntime("/jdk-8", "1.8.0_442").majorVersion == 8)
        #expect(javaRuntime("/jdk-unknown", "unknown").majorVersion == nil)
    }

    @Test
    func jdtlsCompatibilityRequiresJava21OrNewer() {
        #expect(!javaRuntime("/jdk-11", "11.0.26").supportsJDTLS)
        #expect(!javaRuntime("/jdk-17", "17.0.18").supportsJDTLS)
        #expect(javaRuntime("/jdk-21", "21.0.10").supportsJDTLS)
        #expect(javaRuntime("/jdk-25", "25.0.4").supportsJDTLS)
    }

    @Test
    @MainActor
    func pluginJavaRuntimeIgnoresProjectRunJDK() async {
        let projectRuntime = javaRuntime("/project/jdk-11", "11.0.26")
        let jdtlsRuntime = javaRuntime("/language-server/jdk-21", "21.0.10")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(runtimes: [projectRuntime, jdtlsRuntime]),
            store: JavaLanguageServerTestStore()
        )
        service.setJavaLanguageServerRuntimeHome(URL(fileURLWithPath: jdtlsRuntime.homePath, isDirectory: true))

        #expect(
            service.javaHomeURL(overridePath: projectRuntime.homePath)?.path
                == projectRuntime.homePath
        )
        #expect(service.javaLanguageServerExecutableURL() == nil)
        await service.prepareJavaLanguageServerRuntime()
        #expect(
            service.javaLanguageServerExecutableURL()?.path
                == "/language-server/jdk-21/bin/java"
        )
    }

    @Test
    @MainActor
    func pluginJavaRuntimeOlderThanJava21IsRejected() async {
        let unsupportedRuntime = javaRuntime("/jdk-17", "17.0.18")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(runtimes: [unsupportedRuntime]),
            store: JavaLanguageServerTestStore()
        )
        service.setJavaLanguageServerRuntimeHome(URL(fileURLWithPath: unsupportedRuntime.homePath, isDirectory: true))

        let result = await service.prepareJavaLanguageServerRuntime()

        #expect(service.javaLanguageServerExecutableURL() == nil)
        guard case .failed(let message) = result else {
            Issue.record("Expected the plugin runtime version check to fail")
            return
        }
        #expect(message.contains("Java 21"))
    }

    @Test
    @MainActor
    func withoutTheJavaPluginNoDiscoveredJDKIsUsed() async {
        let discoveredRuntime = javaRuntime("/system/jdk-21", "21.0.10")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(runtimes: [discoveredRuntime]),
            store: JavaLanguageServerTestStore()
        )
        service.setJavaLanguageServerRuntimeHome(nil)

        let result = await service.prepareJavaLanguageServerRuntime()

        #expect(service.javaLanguageServerExecutableURL() == nil)
        guard case .failed(let message) = result else {
            Issue.record("Expected a missing Java Support plugin failure")
            return
        }
        // The user is told which plugin provides Java, not to reinstall Lithe.
        #expect(message.contains("Java Support plugin"))
    }

    @Test
    @MainActor
    func preparationOwnerCancelsAndReleasesItsTask() {
        let owner = JavaLanguageServerPreparationOwner(
            workspaceURL: URL(fileURLWithPath: "/workspace", isDirectory: true),
            operationID: UUID()
        )
        let task = Task { @MainActor () -> Void in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
        }
        owner.task = task

        owner.cancel()

        #expect(task.isCancelled)
        #expect(owner.task == nil)
    }

    @Test
    @MainActor
    func preparationCoordinatorReplacesThePreviousTask() {
        let coordinator = JavaLanguageServerPreparationCoordinator()
        let owner = JavaLanguageServerPreparationOwner(
            workspaceURL: URL(fileURLWithPath: "/workspace", isDirectory: true),
            operationID: UUID()
        )
        coordinator.schedule(for: owner) {}
        let previous = owner.task
        coordinator.schedule(for: owner) {}

        #expect(previous?.isCancelled == true)
        #expect(owner.task != nil)
        coordinator.cancel(owner)
        #expect(owner.task == nil)
    }

    @Test
    @MainActor
    func workspaceStateKeepsPreparationOperationIdentity() {
        let workspaceURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let operationID = UUID()
        let owner = JavaLanguageServerPreparationOwner(
            workspaceURL: workspaceURL,
            operationID: operationID
        )
        let state = JavaLanguageServerWorkspaceState.preparing(owner: owner)

        #expect(state.operationID == operationID)
        #expect(state.belongs(to: workspaceURL))
        #expect(!state.belongs(to: URL(fileURLWithPath: "/other", isDirectory: true)))
    }

    @Test
    @MainActor
    func startupRechecksImportInvalidatedDuringRuntimePreparation() async throws {
        let root = URL(fileURLWithPath: "/workspace/import-during-runtime", isDirectory: true)
        let session = JavaImportTestSession()
        let manager = try javaImportManager(root: root, session: session)
        let coordinator = JavaLanguageServerPreparationCoordinator()
        let owner = JavaLanguageServerPreparationOwner(workspaceURL: root, operationID: UUID())
        let runtimeStarted = TestGate(), releaseRuntime = TestGate()
        let importWaitStarted = TestGate(), releaseImport = TestGate()
        var configuration: JavaLanguageImportConfiguration? = .init()
        manager.configureJavaLanguageImportProvider { _, _ in
            try #require(configuration, "The synchronous start must read the refreshed import")
        }
        defer {
            releaseRuntime.open(); releaseImport.open()
            owner.cancel(); manager.stopAllLanguageServers()
        }
        coordinator.prepareAndStart(
            owner: owner, workspaceURL: root,
            runtimePreparation: {
                runtimeStarted.open()
                guard await releaseRuntime.waitUntilOpen() else { return .unprepared }
                return .ready(executableURL: URL(fileURLWithPath: "/jdk/bin/java"))
            },
            sessionsProvider: { manager },
            languageImportPreparation: {
                importWaitStarted.open()
                guard await releaseImport.waitUntilOpen() else { throw CancellationError() }
            },
            ownsPreparation: { true },
            onStarted: { #expect($0 == owner.operationID) },
            onFailure: { Issue.record("Startup failed: \($0)") }
        )
        let task = try #require(owner.task)
        try #require(await runtimeStarted.waitUntilOpen(), "Runtime preparation did not begin")
        // The initial import was ready. A watched-file change invalidates it
        // while JDK preparation is suspended, before the first session exists.
        configuration = nil
        releaseRuntime.open()
        try #require(await importWaitStarted.waitUntilOpen(), "Startup skipped its final import wait")
        #expect(session.starts.isEmpty)
        let latest = JavaLanguageImportConfiguration(mavenContext: pluginMavenContext(profiles: ["latest"]))
        configuration = latest
        releaseImport.open()
        await task.value
        #expect(session.starts.map(\.mavenContext) == [latest.mavenContext])
    }

    @Test(arguments: [false, true])
    @MainActor
    func startupImportWaitRejectsCancellationAndReopenedWorkspace(cancel: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace/reopened-import", isDirectory: true)
        let identity = WorkspaceIdentity(url: root, generation: 1)
        var current = identity
        let session = JavaImportTestSession()
        let manager = try javaImportManager(root: root, session: session)
        let coordinator = JavaLanguageServerPreparationCoordinator()
        let owner = JavaLanguageServerPreparationOwner(workspaceURL: root, operationID: UUID())
        let waiting = TestGate(), release = TestGate()
        defer { release.open(); owner.cancel(); manager.stopAllLanguageServers() }
        coordinator.prepareAndStart(
            owner: owner, workspaceURL: root,
            runtimePreparation: { .ready(executableURL: URL(fileURLWithPath: "/jdk/bin/java")) },
            sessionsProvider: { manager },
            languageImportPreparation: {
                waiting.open()
                _ = await release.waitUntilOpen()
            },
            ownsPreparation: { current == identity },
            onStarted: { _ in Issue.record("Stale preparation must not start") },
            onFailure: { _ in Issue.record("Stale preparation must not report failure") }
        )
        let task = try #require(owner.task)
        try #require(await waiting.waitUntilOpen(), "Final import wait did not begin")
        if cancel { owner.cancel() }
        else { current = WorkspaceIdentity(url: root, generation: 2) }
        release.open()
        await task.value
        #expect(session.starts.isEmpty)
    }

    @Test
    @MainActor
    func pluginMavenImportRestartsASessionStartedWithoutMavenInputs() async throws {
        let root = URL(fileURLWithPath: "/workspace/new-plugin-maven", isDirectory: true)
        let session = JavaImportTestSession()
        let manager = try javaImportManager(root: root, session: session)
        let coordinator = JavaLanguageServerPreparationCoordinator()
        var configuration = JavaLanguageImportConfiguration()
        manager.configureJavaLanguageImportProvider { _, _ in configuration }
        defer { coordinator.cancelMavenConfigurationSynchronization(); manager.stopAllLanguageServers() }
        try manager.startLanguageServer(providerID: "java", rootURL: root)
        session.publish(.ready)
        #expect(session.starts.first?.mavenContext == nil)

        configuration = JavaLanguageImportConfiguration(mavenContext: pluginMavenContext(profiles: ["plugin"]))
        let restarted = TestGate()
        defer { restarted.open() }
        session.onStart = { restarted.open() }
        let recovery = coordinator.synchronizeMavenConfiguration(
            sessions: manager, workspaceURL: root,
            languageImportPreparation: {}, ownsWorkspace: { true }
        )
        defer { recovery.cancel() }
        try #require(await restarted.waitUntilOpen(), "Rejected Maven update did not restart Java")
        #expect(session.stopCount == 1)
        #expect(session.starts.count == 2)
        #expect(session.starts.last?.mavenContext == configuration.mavenContext)
        session.publish(.ready)
        try await awaitImportSynchronization(recovery)
        #expect(manager.languageServerStates["java"] == .ready)

        configuration = JavaLanguageImportConfiguration(mavenContext: pluginMavenContext(profiles: ["next"]))
        session.mavenUpdateResult = .success(.init(settingsChanged: false, projectsReloaded: false, profilesUpdating: true))
        let update = coordinator.synchronizeMavenConfiguration(
            sessions: manager, workspaceURL: root,
            languageImportPreparation: {}, ownsWorkspace: { true }
        )
        try await awaitImportSynchronization(update)
        #expect(session.starts.count == 2)
        #expect(session.updates.last?.profiles == ["next"])
    }

    @Test
    @MainActor
    func newerPluginImportJoinsCancelledRecoveryBeforeRestarting() async throws {
        let root = URL(fileURLWithPath: "/workspace/replaced-maven-recovery", isDirectory: true)
        let session = JavaImportTestSession()
        let manager = try javaImportManager(root: root, session: session)
        let coordinator = JavaLanguageServerPreparationCoordinator()
        var configuration = JavaLanguageImportConfiguration()
        manager.configureJavaLanguageImportProvider { _, _ in configuration }
        defer { coordinator.cancelMavenConfigurationSynchronization(); manager.stopAllLanguageServers() }
        try manager.startLanguageServer(providerID: "java", rootURL: root)
        session.publish(.ready)
        configuration = .init(mavenContext: pluginMavenContext(profiles: ["first"]))
        let firstRestart = TestGate()
        session.onStart = { firstRestart.open() }
        let first = coordinator.synchronizeMavenConfiguration(
            sessions: manager, workspaceURL: root,
            languageImportPreparation: {}, ownsWorkspace: { true }
        )
        defer { first.cancel() }
        try #require(await firstRestart.waitUntilOpen(), "First recovery did not reach its new session")
        configuration = .init(mavenContext: pluginMavenContext(profiles: ["latest"]))
        let nextRestart = TestGate()
        session.onStart = { nextRestart.open() }
        let next = coordinator.synchronizeMavenConfiguration(
            sessions: manager, workspaceURL: root,
            languageImportPreparation: {}, ownsWorkspace: { true }
        )
        defer { next.cancel() }
        try #require(await nextRestart.waitUntilOpen(), "Latest selection did not replace cancelled recovery")
        #expect(session.starts.count == 3)
        #expect(session.stopCount == 2)
        #expect(session.starts.last?.mavenContext?.profiles == ["latest"])
        session.publish(.ready)
        try await awaitImportSynchronization(first)
        try await awaitImportSynchronization(next)
        #expect(manager.languageServerStates["java"] == .ready)
        #expect(session.isRunning)
    }

    @Test(arguments: [false, true])
    @MainActor
    func pluginImportRecoveryDoesNotStartAfterCancellationOrWorkspaceReopen(cancel: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace/stale-maven-import", isDirectory: true)
        let identity = WorkspaceIdentity(url: root, generation: 1)
        var current = identity
        let session = JavaImportTestSession()
        let manager = try javaImportManager(root: root, session: session)
        let coordinator = JavaLanguageServerPreparationCoordinator()
        manager.configureJavaLanguageImportProvider { _, _ in
            .init(mavenContext: pluginMavenContext(profiles: ["plugin"]))
        }
        try manager.startLanguageServer(providerID: "java", rootURL: root)
        session.publish(.ready)
        let waiting = TestGate(), release = TestGate()
        defer {
            release.open(); coordinator.cancelMavenConfigurationSynchronization()
            manager.stopAllLanguageServers()
        }
        let task = coordinator.synchronizeMavenConfiguration(
            sessions: manager, workspaceURL: root,
            languageImportPreparation: {
                waiting.open()
                _ = await release.waitUntilOpen()
            },
            ownsWorkspace: { current == identity }
        )
        defer { task.cancel() }
        try #require(await waiting.waitUntilOpen(), "Import preparation did not begin")
        if cancel { coordinator.cancelMavenConfigurationSynchronization() }
        else { current = WorkspaceIdentity(url: root, generation: 2) }
        release.open()
        try await awaitImportSynchronization(task)
        #expect(session.starts.count == 1)
        #expect(session.updates.isEmpty)
        #expect(session.stopCount == 0)
    }

    @MainActor
    private func awaitImportSynchronization(_ task: Task<Void, Never>) async throws {
        let finished = TestGate()
        let observer = Task { await task.value; finished.open() }
        defer { observer.cancel(); task.cancel() }
        try #require(await finished.waitUntilOpen(), "Import synchronization did not terminate")
        await observer.value
    }

    @MainActor
    private func javaImportManager(root: URL, session: JavaImportTestSession) throws -> LanguageToolingSessionManager {
        let descriptor = try #require(LanguageProviderCatalog.compatibilityFallback.provider(for: root.appendingPathComponent("Main.java")))
        return LanguageToolingSessionManager(runtimes: [JavaImportTestRuntime(descriptor: descriptor, session: session)])
    }

    private func pluginMavenContext(profiles: [String]) -> MavenLaunchContext {
        MavenLaunchContext(reactorPath: ".", profiles: profiles, settingsPath: nil, skipTests: false,
                           mavenExecutablePath: nil, javaHomePath: nil)
    }

    private func javaRuntime(_ homePath: String, _ version: String) -> JavaRuntimeCandidate {
        JavaRuntimeCandidate(homePath: homePath, version: version, vendor: "Test JDK")
    }
}

@MainActor
private final class JavaImportTestRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let supportsLanguageServerSession = true
    let session: JavaImportTestSession

    init(descriptor: LanguageProviderDescriptor, session: JavaImportTestSession) {
        self.descriptor = descriptor
        self.session = session
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}

@MainActor
private final class JavaImportTestSession: LanguageServerSession {
    var isRunning = false
    var javaTestRunnerURL: URL? { nil }
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    var onStateChange: ((LanguageServerSessionState) -> Void)?
    var onStart: (() -> Void)?
    private(set) var starts: [JavaLanguageImportConfiguration] = []
    private(set) var stopCount = 0
    private(set) var updates: [MavenLaunchContext] = []
    var mavenUpdateResult: Result<LanguageServerMavenConfigurationUpdate, LanguageServerRuntimeFailure> =
        .failure(.init(code: "invalidMavenContext", message: "Session started without Maven inputs"))

    func start(rootURL: URL, workspaceFingerprint: String?) throws {
        try start(rootURL: rootURL, workspaceFingerprint: workspaceFingerprint, mavenContext: nil, javaGradle: nil)
    }

    func start(rootURL: URL, workspaceFingerprint: String?, mavenContext: MavenLaunchContext?,
               javaGradle: JavaGradleImportConfiguration?) throws {
        starts.append(.init(mavenContext: mavenContext, javaGradle: javaGradle))
        isRunning = true
        onStart?()
    }

    func publish(_ state: LanguageServerSessionState) { onStateChange?(state) }

    func updateMavenConfiguration(_ context: MavenLaunchContext, reloadProjects: Bool)
        -> Result<LanguageServerMavenConfigurationUpdate, LanguageServerRuntimeFailure> {
        updates.append(context)
        return mavenUpdateResult
    }

    func stop() { isRunning = false; stopCount += 1 }
    func synchronize(fileURL: URL, text: String, languageID: String) throws {}
    func completions(fileURL: URL, position: LanguageServerPosition,
                     completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void) throws { completion(.success([])) }
    func hover(fileURL: URL, position: LanguageServerPosition,
               completion: @escaping (Result<LanguageServerHover?, Error>) -> Void) throws { completion(.success(nil)) }
    func navigate(method: String, fileURL: URL, position: LanguageServerPosition,
                  completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void) throws { completion(.success([])) }
    func rename(fileURL: URL, position: LanguageServerPosition, newName: String,
                completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void) throws { completion(.success(.init())) }
    func format(fileURL: URL,
                completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void) throws { completion(.success([])) }
    func codeActions(fileURL: URL, range: LanguageServerRange, diagnostics: [LanguageServerDiagnostic],
                     completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void) throws { completion(.success([])) }
    func resolveCompletion(_ item: LanguageServerCompletionItem, fileURL: URL,
                           completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void) throws { completion(.success(item)) }
    func resolveCodeAction(_ action: LanguageServerCodeAction, fileURL: URL,
                           completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void) throws { completion(.success(action)) }
    func execute(_ command: LanguageServerCommand, fileURL: URL,
                 completion: @escaping (Result<Void, Error>) -> Void) throws { completion(.success(())) }
    func resolveVirtualDocument(uri: String,
                                completion: @escaping (Result<String, Error>) -> Void) throws { completion(.success("")) }
    func javaEntrypoints(completion: @escaping (Result<JavaEntrypoints, Error>) -> Void) throws { throw CancellationError() }
}

private struct JavaLanguageServerTestRuntimeLocator: RuntimeLocator {
    let runtimes: [JavaRuntimeCandidate]

    func environment() -> [String: String] { [:] }

    func discover() -> RuntimeDiscoveryResult {
        return RuntimeDiscoveryResult(javaRuntimes: runtimes, mavenRuntimes: [])
    }

    func validJavaHome(path: String) -> URL? {
        runtimes.contains(where: { $0.homePath == path })
            ? URL(fileURLWithPath: path, isDirectory: true)
            : nil
    }

    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? {
        runtimes.first(where: { $0.homePath == homeURL.standardizedFileURL.path })
    }

    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}

private struct JavaLanguageServerTestStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}

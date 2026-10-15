import Foundation
import CryptoKit
import LitheCoreContracts
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

    private func javaRuntime(_ homePath: String, _ version: String) -> JavaRuntimeCandidate {
        JavaRuntimeCandidate(homePath: homePath, version: version, vendor: "Test JDK")
    }
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

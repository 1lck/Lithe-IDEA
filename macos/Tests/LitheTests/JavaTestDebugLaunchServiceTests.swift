import Foundation
import LitheCoreContracts
import LitheExecutionModule
import Testing
@testable import Lithe

@Suite("Java test debug launch workflow")
@MainActor
struct JavaTestDebugLaunchServiceTests {
    @Test
    func fileSelectionResolvesTargetStartsResultsAndBuildsSharedConfiguration() async throws {
        let root = URL(fileURLWithPath: "/workspace/java-tests", isDirectory: true)
        let source = root.appendingPathComponent(
            "src/test/java/example/UserServiceTest.java"
        )
        let target = javaTestTarget(fileURL: source)
        let targetResolver = TestJavaTestTargetResolver(target: target)
        let resultServer = TestJavaTestResultServer(port: 43_128)
        let expectedConfiguration = DebugLaunchConfiguration(
            name: "UserServiceTest",
            request: .launch,
            arguments: ["mainClass": .string(target.mainClass)]
        )
        let core = TestJavaTestLaunchCore(result: .success(expectedConfiguration))
        let service = JavaTestDebugLaunchService(
            configurationResolver: DebugLaunchConfigurationResolver(
                fileExists: { _ in true },
                javaTestLaunchResolver: core
            ),
            resultServerFactory: { resultServer }
        )

        let prepared = try await service.prepare(
            fileURL: source,
            testIdentifier: "service@example.UserServiceTest#logsIn",
            rootURL: root,
            targetResolver: targetResolver
        )

        #expect(targetResolver.requests == [TestJavaTestTargetResolver.Request(
            fileURL: source,
            testIdentifier: "service@example.UserServiceTest#logsIn",
            rootURL: root
        )])
        #expect(resultServer.startCount == 1)
        #expect(resultServer.stopCount == 0)
        #expect(core.requests == [TestJavaTestLaunchCore.Request(
            target: target,
            resultPort: 43_128
        )])
        #expect(prepared.target == target)
        #expect(prepared.configuration == expectedConfiguration)

        prepared.stop()
        #expect(resultServer.stopCount == 1)
    }

    @Test
    func sharedConfigurationFailureStopsTheResultServer() async {
        let source = URL(fileURLWithPath: "/workspace/UserServiceTest.java")
        let resultServer = TestJavaTestResultServer(port: 43_128)
        let service = JavaTestDebugLaunchService(
            configurationResolver: DebugLaunchConfigurationResolver(
                fileExists: { _ in true },
                javaTestLaunchResolver: TestJavaTestLaunchCore(
                    result: .failure(TestJavaTestDebugError.configurationFailed)
                )
            ),
            resultServerFactory: { resultServer }
        )

        await #expect(throws: TestJavaTestDebugError.configurationFailed) {
            _ = try await service.prepare(
                fileURL: source,
                testIdentifier: nil,
                rootURL: source.deletingLastPathComponent(),
                targetResolver: TestJavaTestTargetResolver(
                    target: javaTestTarget(fileURL: source)
                )
            )
        }
        #expect(resultServer.startCount == 1)
        #expect(resultServer.stopCount == 1)
    }

    @Test
    func workspaceSelectionIsRejectedBeforeStartingAnAsyncLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-java-test-debug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JavaTestDebugStore()
        let settings = AppSettings(store: store)
        let model = AppModel(
            settings: settings,
            services: MacServiceContainer(
                store: store,
                settings: settings,
                moduleLaunchMode: .safeMode
            ).services
        )
        model.openProjectDirectly(root)
        model.clearNotifications()

        model.debugTest(providerID: "java", scope: .workspace)

        #expect(model.activeNotifications.last?.message == "Select a Java test file or test case to debug")
        #expect(model.javaTestWorkflowState.debugLaunchTask == nil)
        #expect(model.javaTestWorkflowState.debugLaunchOperationID == nil)
    }

    @Test
    func stoppingDebuggingReleasesTheJavaTestResultServer() {
        let store = JavaTestDebugStore()
        let settings = AppSettings(store: store)
        let model = AppModel(
            settings: settings,
            services: MacServiceContainer(
                store: store,
                settings: settings,
                moduleLaunchMode: .safeMode
            ).services
        )
        let resultServer = TestJavaTestResultServer(port: 43_128)
        model.javaTestWorkflowState.resultServer = resultServer

        model.stopDebugging()

        #expect(resultServer.stopCount == 1)
        #expect(model.javaTestWorkflowState.resultServer == nil)
    }

    @Test
    func terminalDebugStateReleasesTheJavaTestResultServer() {
        let store = JavaTestDebugStore()
        let settings = AppSettings(store: store)
        let model = AppModel(
            settings: settings,
            services: MacServiceContainer(
                store: store,
                settings: settings,
                moduleLaunchMode: .safeMode
            ).services
        )
        let resultServer = TestJavaTestResultServer(port: 43_128)
        model.javaTestWorkflowState.resultServer = resultServer
        model.isTerminalVisible = true

        model.handleDebugSessionStateChange(.running)
        #expect(resultServer.stopCount == 0)
        #expect(model.javaTestWorkflowState.resultServer != nil)
        #expect(model.isDebugVisible)
        #expect(!model.isTerminalVisible)

        model.handleDebugSessionStateChange(.terminated)
        #expect(resultServer.stopCount == 1)
        #expect(model.javaTestWorkflowState.resultServer == nil)
    }

    @Test
    func workflowCoordinatorCleansUpWhenGenericDebugStartFails() async {
        let notifications = NotificationSpy()
        let state = JavaTestWorkflowState(notify: notifications.notify)
        let coordinator = JavaTestDebugWorkflowCoordinator(notify: notifications.notify)
        let actions = WorkflowActionsSpy()
        coordinator.connect(actions: actions)
        let resultServer = TestJavaTestResultServer(port: 43_128)
        let prepared = PreparedJavaTestDebugLaunch(
            target: javaTestTarget(
                fileURL: URL(fileURLWithPath: "/workspace/UserServiceTest.java")
            ),
            configuration: DebugLaunchConfiguration(
                name: "UserServiceTest",
                request: .launch,
                arguments: [:]
            ),
            resultServer: resultServer
        )

        coordinator.start(
            request: JavaTestDebugRequest(
                fileURL: prepared.target.fileURL,
                testIdentifier: nil
            ),
            state: state,
            prepareDirtyDocument: { true },
            prepareLaunch: { prepared },
            startDebug: { _ in false },
            errorMessage: { "debug launch failed" }
        )
        await Task.yield()
        await Task.yield()

        #expect(resultServer.stopCount == 1)
        #expect(state.resultServer == nil)
        #expect(notifications.messages == ["debug launch failed"])
        #expect(!actions.events.contains("show-debug"))
    }

    @Test
    func pausedDebugStateShowsDebuggerAndActivatesApplication() {
        let store = JavaTestDebugStore()
        let settings = AppSettings(store: store)
        let platformUI = DebugActivationPlatformUI()
        let model = AppModel(
            settings: settings,
            services: MacServiceContainer(
                store: store,
                settings: settings,
                moduleLaunchMode: .safeMode,
                platformUI: platformUI
            ).services
        )

        model.handleDebugSessionStateChange(.paused)

        #expect(model.isDebugVisible)
        #expect(platformUI.activationCount == 1)
    }

    private func javaTestTarget(fileURL: URL) -> JavaTestDebugLaunchTarget {
        JavaTestDebugLaunchTarget(
            fileURL: fileURL,
            name: "UserServiceTest",
            framework: .junit,
            workingDirectory: fileURL.deletingLastPathComponent().path,
            mainClass: "org.eclipse.jdt.internal.junit.runner.RemoteTestRunner",
            projectName: "service",
            classPaths: ["/workspace/classes"],
            modulePaths: [],
            vmArguments: [],
            programArguments: ["-port", "-1"]
        )
    }
}

@MainActor
private final class DebugActivationPlatformUI: PlatformUI {
    private(set) var activationCount = 0

    func activateApplication() {
        activationCount += 1
    }

    func chooseDirectory(title: String, prompt: String) -> URL? { nil }
    func chooseFile(title: String, prompt: String) -> URL? { nil }
    func revealInFileBrowser(_ url: URL) {}
    func open(_ url: URL) {}
    func copyToClipboard(_ value: String) {}
    func markdownImageFromClipboard() -> MarkdownImageSource? { nil }
}

@MainActor
private final class TestJavaTestTargetResolver: JavaTestDebugLaunchTargetResolving {
    struct Request: Equatable {
        let fileURL: URL
        let testIdentifier: String?
        let rootURL: URL
    }

    private let target: JavaTestDebugLaunchTarget
    private(set) var requests: [Request] = []

    init(target: JavaTestDebugLaunchTarget) {
        self.target = target
    }

    func resolveJavaTestDebugLaunchTarget(
        fileURL: URL,
        testIdentifier: String?,
        rootURL: URL
    ) async throws -> JavaTestDebugLaunchTarget {
        requests.append(Request(
            fileURL: fileURL.standardizedFileURL,
            testIdentifier: testIdentifier,
            rootURL: rootURL.standardizedFileURL
        ))
        return target
    }
}

@MainActor
private final class TestJavaTestResultServer: JavaTestResultServing {
    private let port: UInt16
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(port: UInt16) {
        self.port = port
    }

    func start() async throws -> UInt16 {
        startCount += 1
        return port
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class TestJavaTestLaunchCore: JavaTestDebugLaunchResolving, @unchecked Sendable {
    struct Request: Equatable {
        let target: JavaTestDebugLaunchTarget
        let resultPort: UInt16
    }

    private let result: Result<DebugLaunchConfiguration, TestJavaTestDebugError>
    private(set) var requests: [Request] = []

    init(result: Result<DebugLaunchConfiguration, TestJavaTestDebugError>) {
        self.result = result
    }

    func resolveJavaTestDebugLaunch(
        target: JavaTestDebugLaunchTarget,
        resultPort: UInt16
    ) throws -> DebugLaunchConfiguration {
        requests.append(Request(target: target, resultPort: resultPort))
        return try result.get()
    }
}

private enum TestJavaTestDebugError: Error, Equatable {
    case configurationFailed
}

private final class JavaTestDebugStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

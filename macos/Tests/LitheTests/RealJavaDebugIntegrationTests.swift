import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheLanguageIntelligenceModule
import LitheTerminalModule
import Testing
@testable import Lithe

@Suite("Real Java Debug integration", .serialized)
@MainActor
struct RealJavaDebugIntegrationTests {
    @Test
    func springRequestHitsBreakpointInspectsStepsAndResumes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LITHE_RUN_JAVA_DEBUG_INTEGRATION"] == "1" else { return }

        let repositoryRoot = Self.repositoryRoot
        let jdtlsRoot = URL(
            fileURLWithPath: environment["LITHE_JDTLS_ROOT"]
                ?? repositoryRoot.appendingPathComponent(".artifacts/jdtls").path,
            isDirectory: true
        )
        let javaURL = URL(
            fileURLWithPath: environment["LITHE_JAVA_PATH"]
                ?? repositoryRoot.appendingPathComponent(".artifacts/jdk-arm64/bin/java").path
        )
        let jdtlsURL = jdtlsRoot.appendingPathComponent("bin/jdtls")
        let fileManager = FileManager.default
        #expect(fileManager.isExecutableFile(atPath: javaURL.path))
        #expect(fileManager.isExecutableFile(atPath: jdtlsURL.path))
        guard fileManager.isExecutableFile(atPath: javaURL.path),
              fileManager.isExecutableFile(atPath: jdtlsURL.path) else { return }

        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "lithe-real-java-debug-\(UUID().uuidString)",
            isDirectory: true
        )
        let cacheURL = fileManager.temporaryDirectory.appendingPathComponent(
            "\(rootURL.lastPathComponent)-jdtls-cache",
            isDirectory: true
        )
        let fixtureURL = repositoryRoot.appendingPathComponent(
            "shared/fixtures/projects/lithe-spring-boot-git-graph",
            isDirectory: true
        )
        try fileManager.copyItem(at: fixtureURL, to: rootURL)
        let mainURL = rootURL.appendingPathComponent(
            "src/main/java/com/example/demo/DemoApplication.java"
        )
        let serviceURL = rootURL.appendingPathComponent(
            "src/main/java/com/example/demo/user/UserService.java"
        )
        let serviceSource = try String(contentsOf: serviceURL, encoding: .utf8)
        let serviceBreakpointLine = try #require(Self.line(
            containing: "return repository.findAll();",
            in: serviceSource
        ))
        let serviceConstructorLine = try #require(Self.line(
            containing: "this.repository = repository;",
            in: serviceSource
        ))
        let controllerSource = try String(contentsOf: rootURL.appendingPathComponent(
            "src/main/java/com/example/demo/user/UserController.java"
        ), encoding: .utf8)
        let controllerURL = rootURL.appendingPathComponent(
            "src/main/java/com/example/demo/user/UserController.java"
        )
        let controllerBreakpointLine = try #require(Self.line(
            containing: "return service.listUsers();",
            in: controllerSource
        ))

        let core = RustCoreBridge()
        #expect(core.isAvailable)
        guard core.isAvailable else { return }
        let resources: JDTLSLaunchResources
        switch MacJDTLSLaunchResourceResolver(
            bundledJdtlsRootURL: jdtlsRoot
        ).resolve(for: jdtlsURL) {
        case .direct(let value):
            resources = value
        case .wrapperFallback:
            Issue.record("The real Java Debug test requires direct JDT LS resources.")
            return
        case .unavailable(let message):
            Issue.record("JDT LS resources are unavailable: \(message)")
            return
        }

        let descriptor = try #require(LanguageProviderCatalog.standard.provider(for: mainURL))
        let launch = try #require(descriptor.languageServerLaunch)
        let languageSession = LanguageServerRuntimeSession(
            providerID: descriptor.id,
            executableURL: jdtlsURL,
            arguments: launch.arguments,
            environment: environment,
            initializationOptions: launch.initializationOptions,
            runtimeExecutableURL: javaURL,
            jdtlsLaunchResources: resources,
            cacheDirectoryURL: cacheURL,
            initializeTimeout: 120,
            requestTimeout: 120,
            shutdownTimeout: 5,
            core: core
        )
        let languageRuntime = RealJavaDebugLanguageRuntime(
            descriptor: descriptor,
            session: languageSession
        )
        let languageManager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimes: [languageRuntime],
            builtinCore: core
        )
        let protocolTrace = RealJavaDebugProtocolTrace()
        let debugManager = DebugAdapterSessionManager(
            providers: [DebugProviderDescriptor(
                id: "java",
                displayName: "Java",
                fileExtensions: ["java"]
            )]
        ) { _, _ in
            CoreDebugAdapterProtocolSession(
                adapterID: "java",
                transport: RealJavaDebugRecordingTransport(
                    wrapping: MacJavaDebugAdapterTransport(
                        portResolver: { rootURL in
                            try await languageManager.startJavaDebugServer(rootURL: rootURL)
                        }
                    ),
                    trace: protocolTrace
                ),
                core: core,
                deadlineScheduler: MacDebugOperationDeadlineScheduler()
            )
        }
        let feature = GenericDebugFeatureModel(sessions: debugManager)
        let debugTerminals = RealJavaDebugTerminalOwner(workspaceURL: rootURL)
        feature.onRunInTerminalRequest = debugTerminals.handle
        let portAllocator = MacJavaTestResultServer()
        let springPort = try await portAllocator.start()
        portAllocator.stop()
        var requestTask: Task<(Data, URLResponse), Error>?
        defer {
            requestTask?.cancel()
            feature.stop()
            debugTerminals.stop()
            languageManager.stopAll()
            try? fileManager.removeItem(at: rootURL)
            try? fileManager.removeItem(at: cacheURL)
        }

        let mainSource = try String(contentsOf: mainURL, encoding: .utf8)
        try languageManager.synchronizeLanguageServer(
            for: mainURL,
            text: mainSource,
            rootURL: rootURL
        )
        let target: JavaDebugLaunchTarget
        do {
            target = try await languageManager.resolveJavaDebugLaunchTarget(
                fileURL: mainURL,
                rootURL: rootURL
            )
        } catch {
            throw RealJavaDebugIntegrationError.languageToolingFailed(
                message: String(describing: error),
                logs: Self.languageServerLogSummary(languageManager.languageServerLogs)
            )
        }
        // Start at the controller call so the real integration test exercises
        // both Java step-into and step-out, not only a step-over at a leaf line.
        feature.toggleBreakpoint(fileURL: controllerURL, line: controllerBreakpointLine)
        feature.toggleBreakpoint(fileURL: serviceURL, line: serviceBreakpointLine)
        feature.toggleBreakpoint(fileURL: serviceURL, line: serviceConstructorLine)
        // Verify the Java adapter receives and honors the condition field,
        // rather than only exercising an unconditional source breakpoint.
        feature.updateBreakpoint(
            fileURL: controllerURL,
            line: controllerBreakpointLine,
            enabled: true,
            condition: "true",
            hitCondition: "1",
            logMessage: nil
        )
        // A logpoint must emit a Debug Console message without stopping the
        // application. Keep it on the constructor so it is exercised during
        // Spring Boot startup before the HTTP request breakpoint.
        feature.updateBreakpoint(
            fileURL: serviceURL,
            line: serviceConstructorLine,
            enabled: true,
            condition: nil,
            hitCondition: nil,
            logMessage: "entered UserService constructor"
        )
        var arguments: [String: ToolingJSONValue] = [
            "mainClass": .string(target.mainClass),
            "cwd": .string(rootURL.path),
            "console": .string("integratedTerminal"),
            "args": .string("--server.port=\(springPort)")
        ]
        if let projectName = target.projectName {
            arguments["projectName"] = .string(projectName)
        }
        if !target.modulePaths.isEmpty {
            arguments["modulePaths"] = .array(target.modulePaths.map(ToolingJSONValue.string))
        }
        if !target.classPaths.isEmpty {
            arguments["classPaths"] = .array(target.classPaths.map(ToolingJSONValue.string))
        }
        #expect(feature.start(
            fileURL: mainURL,
            rootURL: rootURL,
            configuration: DebugLaunchConfiguration(
                name: "Spring Debug Integration",
                request: .launch,
                arguments: arguments
            )
        ))

        #expect(await Self.waitUntil(timeout: .seconds(120)) {
            feature.state == .running
        }, "Java Debug Server did not reach the running state. Output:\n\(feature.output)")
        #expect(await Self.waitUntil(timeout: .seconds(120)) {
            feature.breakpoints.count == 3 && feature.breakpoints.allSatisfy(\.verified)
        }, "The Java breakpoints were not verified. Output:\n\(feature.output)")
        #expect(
            protocolTrace.entries.contains { $0.contains("\"condition\":\"true\"") },
            "The Java condition breakpoint was not sent to the adapter."
        )
        #expect(
            protocolTrace.entries.contains { $0.contains("\"hitCondition\":\"1\"") },
            "The Java hit-count breakpoint was not sent to the adapter."
        )
        #expect(
            protocolTrace.entries.contains {
                $0.contains("\"logMessage\":\"entered UserService constructor\"")
            },
            "The Java logpoint was not sent to the adapter."
        )
        guard await Self.waitForSpringServer(port: springPort, timeout: .seconds(120)) else {
            throw RealJavaDebugIntegrationError.springServerDidNotStart(
                "expectedPort=\(springPort)\n" + Self.debugSnapshot(feature, protocolTrace: protocolTrace)
            )
        }
        #expect(
            feature.output.contains("entered UserService constructor"),
            "The Java logpoint did not produce a Debug Console message."
        )

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(springPort)/api/users")!
        )
        request.timeoutInterval = 60
        requestTask = Task { try await URLSession.shared.data(for: request) }
        guard await Self.waitUntil(timeout: .seconds(60), condition: {
            feature.state == .paused
        }) else {
            throw RealJavaDebugIntegrationError.debuggerDidNotPause(
                Self.debugSnapshot(feature, protocolTrace: protocolTrace)
            )
        }
        guard await Self.waitUntil(timeout: .seconds(30), condition: {
            feature.selectedFrame?.sourceURL?.standardizedFileURL
                == controllerURL.standardizedFileURL
                && feature.selectedFrame?.line == controllerBreakpointLine
        }) else {
            throw RealJavaDebugIntegrationError.stoppedFrameUnavailable(
                Self.debugSnapshot(feature, protocolTrace: protocolTrace)
            )
        }
        #expect(await Self.waitUntil(timeout: .seconds(30)) {
            !feature.variables.isEmpty
        }, "No variables were loaded for the stopped Java frame.")
        // Exercise the same frame-scoped evaluation path used by the Debug
        // console and inline inspection, not only the variables request.
        let outputBeforeEvaluation = feature.output
        feature.evaluate("service")
        #expect(await Self.waitUntil(timeout: .seconds(30)) {
            feature.output.count > outputBeforeEvaluation.count
                && feature.output.contains("service =")
        }, "The stopped Java frame did not evaluate the service expression.")

        feature.execute(.stepIn)
        #expect(await Self.waitUntil(timeout: .seconds(30)) {
            feature.state == .paused
                && feature.selectedFrame?.sourceURL?.standardizedFileURL
                    == serviceURL.standardizedFileURL
                && feature.selectedFrame?.line == serviceBreakpointLine
        }, "Step into did not enter UserService.listUsers().\n\(Self.debugSnapshot(feature, protocolTrace: protocolTrace))")

        feature.execute(.stepOut)
        #expect(await Self.waitUntil(timeout: .seconds(30)) {
            feature.state == .paused
                && feature.selectedFrame?.sourceURL?.standardizedFileURL
                    == controllerURL.standardizedFileURL
                && feature.selectedFrame?.line == controllerBreakpointLine
        }, "Step out did not return to UserController.list().\n\(Self.debugSnapshot(feature, protocolTrace: protocolTrace))")

        let frameBeforeStepOver = try #require(feature.selectedFrame)
        feature.execute(.next)
        #expect(await Self.waitUntil(timeout: .seconds(30)) {
            feature.state == .paused && feature.selectedFrame?.id != frameBeforeStepOver.id
        }, "Step over did not reach the next Java source position.\n\(Self.debugSnapshot(feature, protocolTrace: protocolTrace))")
        feature.execute(.continueExecution)
        guard await Self.waitUntil(timeout: .seconds(10), condition: {
            feature.state == .running || feature.state == .terminated
        }) else {
            throw RealJavaDebugIntegrationError.debuggerDidNotResume(
                "Continue did not leave the paused state.\n" + Self.debugSnapshot(feature, protocolTrace: protocolTrace)
            )
        }

        let response: (Data, URLResponse)
        do {
            response = try await Self.value(of: try #require(requestTask), timeout: .seconds(60))
        } catch {
            throw RealJavaDebugIntegrationError.debuggerDidNotResume(
                "(error)\n" + Self.debugSnapshot(feature, protocolTrace: protocolTrace)
            )
        }
        let httpResponse = try #require(response.1 as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        let body = String(decoding: response.0, as: UTF8.self)
        #expect(body.contains("Ada Lovelace"))
        #expect(body.contains("Grace Hopper"))
    }

    @Test
    func junitMethodHitsBreakpointAndResumes() async throws {
        try await Self.runJavaTestDebug(.junit)
    }

    @Test
    func testngMethodHitsBreakpointAndResumes() async throws {
        try await Self.runJavaTestDebug(.testng)
    }

    private static func runJavaTestDebug(_ scenario: RealJavaTestDebugScenario) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LITHE_RUN_JAVA_TEST_DEBUG_INTEGRATION"] == "1" else { return }

        let repositoryRoot = Self.repositoryRoot
        let jdtlsRoot = URL(
            fileURLWithPath: environment["LITHE_JDTLS_ROOT"]
                ?? repositoryRoot.appendingPathComponent(".artifacts/jdtls").path,
            isDirectory: true
        )
        let javaURL = URL(
            fileURLWithPath: environment["LITHE_JAVA_PATH"]
                ?? repositoryRoot.appendingPathComponent(".artifacts/jdk-arm64/bin/java").path
        )
        let jdtlsURL = jdtlsRoot.appendingPathComponent("bin/jdtls")
        let fileManager = FileManager.default
        #expect(fileManager.isExecutableFile(atPath: javaURL.path))
        #expect(fileManager.isExecutableFile(atPath: jdtlsURL.path))
        guard fileManager.isExecutableFile(atPath: javaURL.path),
              fileManager.isExecutableFile(atPath: jdtlsURL.path) else { return }

        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "lithe-real-java-test-debug-\(scenario.rawValue)-\(UUID().uuidString)",
            isDirectory: true
        )
        let cacheURL = fileManager.temporaryDirectory.appendingPathComponent(
            "\(rootURL.lastPathComponent)-jdtls-cache",
            isDirectory: true
        )
        let fixtureURL = repositoryRoot.appendingPathComponent(
            "shared/fixtures/projects/lithe-spring-boot-git-graph",
            isDirectory: true
        )
        try fileManager.copyItem(at: fixtureURL, to: rootURL)
        defer {
            try? fileManager.removeItem(at: rootURL)
            try? fileManager.removeItem(at: cacheURL)
        }
        try scenario.prepareProject(at: rootURL, fileManager: fileManager)
        let testURL = rootURL.appendingPathComponent(
            "src/test/java/com/example/demo/user/UserServiceTest.java"
        )
        let testSource = try String(contentsOf: testURL, encoding: .utf8)
        let breakpointLine = try #require(line(
            containing: scenario.breakpointNeedle,
            in: testSource
        ))

        let core = RustCoreBridge()
        #expect(core.isAvailable)
        guard core.isAvailable else { return }
        let resources: JDTLSLaunchResources
        switch MacJDTLSLaunchResourceResolver(
            bundledJdtlsRootURL: jdtlsRoot
        ).resolve(for: jdtlsURL) {
        case .direct(let value):
            resources = value
        case .wrapperFallback:
            Issue.record("The real Java test Debug test requires direct JDT LS resources.")
            return
        case .unavailable(let message):
            Issue.record("JDT LS resources are unavailable: \(message)")
            return
        }

        let descriptor = try #require(LanguageProviderCatalog.standard.provider(for: testURL))
        let launch = try #require(descriptor.languageServerLaunch)
        let languageSession = LanguageServerRuntimeSession(
            providerID: descriptor.id,
            executableURL: jdtlsURL,
            arguments: launch.arguments,
            environment: environment,
            initializationOptions: launch.initializationOptions,
            runtimeExecutableURL: javaURL,
            jdtlsLaunchResources: resources,
            cacheDirectoryURL: cacheURL,
            initializeTimeout: 120,
            requestTimeout: 120,
            shutdownTimeout: 5,
            core: core
        )
        let languageRuntime = RealJavaDebugLanguageRuntime(
            descriptor: descriptor,
            session: languageSession
        )
        let languageManager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimes: [languageRuntime],
            builtinCore: core
        )
        let protocolTrace = RealJavaDebugProtocolTrace()
        let debugManager = DebugAdapterSessionManager(
            providers: [DebugProviderDescriptor(
                id: "java",
                displayName: "Java",
                fileExtensions: ["java"]
            )]
        ) { _, _ in
            CoreDebugAdapterProtocolSession(
                adapterID: "java",
                transport: RealJavaDebugRecordingTransport(
                    wrapping: MacJavaDebugAdapterTransport(
                        portResolver: { rootURL in
                            try await languageManager.startJavaDebugServer(rootURL: rootURL)
                        }
                    ),
                    trace: protocolTrace
                ),
                core: core,
                deadlineScheduler: MacDebugOperationDeadlineScheduler()
            )
        }
        let feature = GenericDebugFeatureModel(sessions: debugManager)
        let debugTerminals = RealJavaDebugTerminalOwner(workspaceURL: rootURL)
        feature.onRunInTerminalRequest = debugTerminals.handle
        let launchService = JavaTestDebugLaunchService(
            configurationResolver: DebugLaunchConfigurationResolver(
                fileExists: { fileManager.fileExists(atPath: $0.path) },
                javaTestLaunchResolver: core
            ),
            resultServerFactory: { MacJavaTestResultServer() }
        )
        defer {
            feature.stop()
            debugTerminals.stop()
            languageManager.stopAll()
        }

        let prepared: PreparedJavaTestDebugLaunch
        do {
            prepared = try await launchService.prepare(
                fileURL: testURL,
                testIdentifier: scenario.testIdentifier,
                rootURL: rootURL,
                targetResolver: languageManager
            )
        } catch {
            throw RealJavaDebugIntegrationError.languageToolingFailed(
                message: String(describing: error),
                logs: languageServerLogSummary(languageManager.languageServerLogs)
            )
        }
        defer { prepared.stop() }

        #expect(prepared.target.framework == scenario.framework)
        feature.toggleBreakpoint(fileURL: testURL, line: breakpointLine)
        #expect(feature.start(
            fileURL: testURL,
            rootURL: rootURL,
            configuration: prepared.configuration
        ))

        guard await waitUntil(timeout: .seconds(120), condition: {
            feature.state == .paused
        }) else {
            throw RealJavaDebugIntegrationError.debuggerDidNotPause(
                debugSnapshot(feature, protocolTrace: protocolTrace)
            )
        }
        #expect(
            feature.breakpoints.first?.verified == true,
            "The Java test breakpoint was not verified.\n\(debugSnapshot(feature, protocolTrace: protocolTrace))"
        )
        guard await waitUntil(timeout: .seconds(30), condition: {
            feature.selectedFrame?.sourceURL?.standardizedFileURL
                == testURL.standardizedFileURL
                && feature.selectedFrame?.line == breakpointLine
        }) else {
            throw RealJavaDebugIntegrationError.stoppedFrameUnavailable(
                debugSnapshot(feature, protocolTrace: protocolTrace)
            )
        }
        #expect(await waitUntil(timeout: .seconds(30)) {
            feature.variables.contains { $0.name == scenario.expectedVariable }
        }, "The stopped Java test frame did not expose \(scenario.expectedVariable).")

        feature.execute(.continueExecution)
        #expect(await waitUntil(timeout: .seconds(60)) {
            feature.state == .terminated
        }, "Java test Debug did not terminate.\n\(debugSnapshot(feature, protocolTrace: protocolTrace))")
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func line(containing needle: String, in source: String) -> Int? {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.contains(needle) }
            .map { $0 + 1 }
    }

    private static func languageServerLogSummary(
        _ entries: [LanguageServerLogEntry]
    ) -> String {
        entries.reversed().map { entry in
            [entry.level.rawValue, entry.message, entry.detail]
                .compactMap { $0 }
                .joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private static func debugSnapshot(
        _ feature: GenericDebugFeatureModel,
        protocolTrace: RealJavaDebugProtocolTrace
    ) -> String {
        let breakpointSummary = feature.breakpoints.map {
            "\($0.title) enabled=\($0.enabled) verified=\($0.verified) message=\($0.message ?? "nil")"
        }.joined(separator: "\n")
        let threadSummary = feature.threads.map { "\($0.id):\($0.name)" }.joined(separator: ", ")
        let recentTrace = protocolTrace.entries.suffix(40).joined(separator: "\n")
        return """
        state=\(feature.state)
        stoppedReason=\(feature.stoppedReason ?? "nil")
        selectedThreadID=\(feature.selectedThreadID.map(String.init) ?? "nil")
        selectedFrame=\(feature.selectedFrame.map { "\($0.name) @ \($0.line)" } ?? "nil")
        threads=\(threadSummary)
        breakpoints:
        \(breakpointSummary)
        output:
        \(feature.output)
        Recent DAP trace:
        \(recentTrace)
        """
    }

    private static func waitForSpringServer(
        port: UInt16,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        while clock.now < deadline {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            do {
                _ = try await URLSession.shared.data(for: request)
                return true
            } catch {
                // Spring Boot may still be starting while the debuggee is
                // already attached and accepting debugger requests.
            }
            // test-stability: allow(swift-real-sleep) reason: The external Spring process exposes readiness only through its loopback listener.
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            // test-stability: allow(swift-real-sleep) reason: External JDT LS and JVM state arrives only through production process callbacks.
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private static func value<T>(
        of task: Task<T, Error>,
        timeout: Duration
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                // test-stability: allow(swift-real-sleep) reason: The real HTTP request needs a local deadline independent of the test runner.
                try await Task.sleep(for: timeout)
                throw RealJavaDebugIntegrationError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private enum RealJavaTestDebugScenario: String {
    case junit
    case testng

    var framework: JavaTestDebugFramework {
        switch self {
        case .junit: .junit
        case .testng: .testng
        }
    }

    var testIdentifier: String {
        switch self {
        case .junit: "com.example.demo.user.UserServiceTest#addsNumbers()"
        case .testng: "com.example.demo.user.UserServiceTest#multipliesNumbers()"
        }
    }

    var breakpointNeedle: String {
        switch self {
        case .junit: "int total = left + right;"
        case .testng: "int product = left * right;"
        }
    }

    var expectedVariable: String {
        switch self {
        case .junit: "left"
        case .testng: "left"
        }
    }

    func prepareProject(at rootURL: URL, fileManager: FileManager) throws {
        let testDirectory = rootURL.appendingPathComponent(
            "src/test/java/com/example/demo/user",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = testDirectory.appendingPathComponent("UserServiceTest.java")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        guard self == .testng else { return }

        let pomURL = rootURL.appendingPathComponent("pom.xml")
        var pom = try String(contentsOf: pomURL, encoding: .utf8)
        guard let insertion = pom.range(of: "</dependencies>") else {
            throw RealJavaDebugIntegrationError.invalidFixture("Missing Maven dependencies section")
        }
        pom.insert(contentsOf: testNGDependency, at: insertion.lowerBound)
        try pom.write(to: pomURL, atomically: true, encoding: .utf8)
    }

    private var source: String {
        switch self {
        case .junit:
            """
            package com.example.demo.user;

            import static org.junit.jupiter.api.Assertions.assertEquals;

            import org.junit.jupiter.api.Test;

            class UserServiceTest {
                @Test
                void addsNumbers() {
                    int left = 20;
                    int right = 22;
                    int total = left + right;
                    assertEquals(42, total);
                }
            }
            """
        case .testng:
            """
            package com.example.demo.user;

            import org.testng.Assert;
            import org.testng.annotations.Test;

            public class UserServiceTest {
                @Test
                public void multipliesNumbers() {
                    int left = 6;
                    int right = 7;
                    int product = left * right;
                    Assert.assertEquals(product, 42);
                }
            }
            """
        }
    }

    private var testNGDependency: String {
        """
                <dependency>
                    <groupId>org.testng</groupId>
                    <artifactId>testng</artifactId>
                    <version>7.10.2</version>
                    <scope>test</scope>
                </dependency>
        """
    }
}

@MainActor
private final class RealJavaDebugTerminalOwner {
    private let workspaceURL: URL
    private let feature = TerminalFeatureModel(
        terminalFactory: { MacTerminalTransport() }
    )

    init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL.standardizedFileURL
    }

    func handle(
        _ request: DebugRunInTerminalRequest,
        completion: @escaping DebugRunInTerminalCompletion
    ) {
        do {
            guard request.kind == .integrated else {
                throw RealJavaDebugTerminalError.externalTerminalUnsupported
            }
            guard !request.argsCanBeInterpretedByShell else {
                throw RealJavaDebugTerminalError.shellInterpretationUnsupported
            }
            guard let executablePath = request.args.first, !executablePath.isEmpty else {
                throw RealJavaDebugTerminalError.missingExecutable
            }
            let workingDirectory = request.cwd.isEmpty ? workspaceURL.path : request.cwd
            guard workingDirectory.hasPrefix("/") else {
                throw RealJavaDebugTerminalError.invalidWorkingDirectory
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
            completion(.success(DebugRunInTerminalResponse(processID: Int(created.processID))))
        } catch {
            completion(.failure(error))
        }
    }

    func stop() {
        feature.stopAllSessions()
    }
}

private enum RealJavaDebugTerminalError: Error {
    case externalTerminalUnsupported
    case shellInterpretationUnsupported
    case missingExecutable
    case invalidWorkingDirectory
}

@MainActor
private final class RealJavaDebugProtocolTrace {
    private(set) var entries: [String] = []

    func record(direction: String, data: Data) {
        entries.append("\(direction) \(Self.payload(in: data))")
    }

    private static func payload(in data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8),
              let separator = text.range(of: "\r\n\r\n") else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(text[separator.upperBound...])
    }
}

@MainActor
private final class RealJavaDebugRecordingTransport: DebugAdapterTransport {
    private let wrapped: any DebugAdapterTransport
    private let trace: RealJavaDebugProtocolTrace

    var isRunning: Bool { wrapped.isRunning }
    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        wrapping wrapped: any DebugAdapterTransport,
        trace: RealJavaDebugProtocolTrace
    ) {
        self.wrapped = wrapped
        self.trace = trace
        wrapped.onData = { [weak self] data in
            self?.trace.record(direction: "<-", data: data)
            self?.onData?(data)
        }
        wrapped.onErrorOutput = { [weak self] data in self?.onErrorOutput?(data) }
        wrapped.onTermination = { [weak self] code in self?.onTermination?(code) }
    }

    func start(rootURL: URL) throws {
        try wrapped.start(rootURL: rootURL)
    }

    func send(_ data: Data) throws {
        trace.record(direction: "->", data: data)
        try wrapped.send(data)
    }

    func stop() {
        wrapped.stop()
    }
}

@MainActor
private final class RealJavaDebugLanguageRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let supportsLanguageServerSession = true
    private let session: any LanguageServerSession

    init(descriptor: LanguageProviderDescriptor, session: any LanguageServerSession) {
        self.descriptor = descriptor
        self.session = session
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}

private enum RealJavaDebugIntegrationError: Error {
    case timedOut
    case languageToolingFailed(message: String, logs: String)
    case springServerDidNotStart(String)
    case debuggerDidNotPause(String)
    case debuggerDidNotResume(String)
    case stoppedFrameUnavailable(String)
    case invalidFixture(String)
}

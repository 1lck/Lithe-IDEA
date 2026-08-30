import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheLanguageIntelligenceModule
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
        let breakpointLine = try #require(Self.line(
            containing: "return repository.findAll();",
            in: serviceSource
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
        var requestTask: Task<(Data, URLResponse), Error>?
        defer {
            requestTask?.cancel()
            feature.stop()
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
        feature.toggleBreakpoint(fileURL: serviceURL, line: breakpointLine)
        var arguments: [String: ToolingJSONValue] = [
            "mainClass": .string(target.mainClass),
            "cwd": .string(rootURL.path),
            "console": .string("internalConsole"),
            "args": .string("--server.port=0")
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
            feature.breakpoints.first?.verified == true
        }, "The Java breakpoint was not verified. Output:\n\(feature.output)")
        let port = await Self.waitForSpringPort(feature: feature, timeout: .seconds(120))
        let resolvedPort = try #require(port)

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(resolvedPort)/api/users")!
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
                == serviceURL.standardizedFileURL
                && feature.selectedFrame?.line == breakpointLine
        }) else {
            throw RealJavaDebugIntegrationError.stoppedFrameUnavailable(
                Self.debugSnapshot(feature, protocolTrace: protocolTrace)
            )
        }
        #expect(await Self.waitUntil(timeout: .seconds(30)) {
            !feature.variables.isEmpty
        }, "No variables were loaded for the stopped Java frame.")

        let stoppedFrame = try #require(feature.selectedFrame)
        feature.execute(.next)
        #expect(await Self.waitUntil(timeout: .seconds(30)) {
            feature.state == .paused && feature.selectedFrame != stoppedFrame
        }, "Step over did not reach the next Java frame.")
        feature.execute(.continueExecution)

        let response = try await Self.value(of: try #require(requestTask), timeout: .seconds(60))
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
        let launchService = JavaTestDebugLaunchService(
            configurationResolver: DebugLaunchConfigurationResolver(
                fileExists: { fileManager.fileExists(atPath: $0.path) },
                javaTestLaunchResolver: core
            ),
            resultServerFactory: { MacJavaTestResultServer() }
        )
        defer {
            feature.stop()
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
        return """
        state=\(feature.state)
        stoppedReason=\(feature.stoppedReason ?? "nil")
        threads=\(threadSummary)
        breakpoints:
        \(breakpointSummary)
        output:
        \(feature.output)
        DAP trace:
        \(protocolTrace.entries.joined(separator: "\n"))
        """
    }

    private static func waitForSpringPort(
        feature: GenericDebugFeatureModel,
        timeout: Duration
    ) async -> Int? {
        var port: Int?
        _ = await waitUntil(timeout: timeout) {
            port = springPort(in: feature.output)
            return port != nil
        }
        return port
    }

    private static func springPort(in output: String) -> Int? {
        let expression = try? NSRegularExpression(
            pattern: "Tomcat started on port ([0-9]+)"
        )
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression?.firstMatch(in: output, range: range),
              let portRange = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[portRange])
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
    case debuggerDidNotPause(String)
    case stoppedFrameUnavailable(String)
    case invalidFixture(String)
}

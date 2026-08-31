import Foundation
import LitheApplicationKernel
import LitheCoreContracts
@testable import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing

@MainActor
struct LanguageIntelligenceModuleTests {
    @Test
    func disabledModuleDoesNotConstructFactoryOrServiceGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: LanguageIntelligenceModule.moduleManifest, contributions: LanguageIntelligenceModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        }, enabled: false)

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.languageIntelligence)) {
            _ = try await runtime.activateCapability(.languageIntelligence)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.graphCalls == 0)
        #expect(try !runtime.snapshot(for: .languageIntelligence).isInstantiated)
    }

    @Test
    func sleepReleasesGraphAndWakeConstructsANewInstance() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: LanguageIntelligenceModule.moduleManifest, contributions: LanguageIntelligenceModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        })

        var firstCapability: LanguageIntelligenceCapability? = try #require(
            try await runtime.activateCapability(.languageIntelligence)
                as? LanguageIntelligenceCapability
        )
        weak var firstSessions = try #require(firstCapability?.sessions)
        weak var firstGraph = recorder.latestGraph
        firstCapability = nil

        try await runtime.sleep(.languageIntelligence)

        #expect(firstGraph == nil)
        #expect(firstSessions == nil)
        #expect(runtime.capability(.languageIntelligence) == nil)
        #expect(try runtime.snapshot(for: .languageIntelligence).activity.activeResourceCount == 0)

        let secondCapability = try #require(
            try await runtime.activateCapability(.languageIntelligence)
                as? LanguageIntelligenceCapability
        )
        #expect(secondCapability.sessions.activeLanguageServerIDs.isEmpty)
        #expect(recorder.factoryCalls == 2)
        #expect(recorder.graphCalls == 2)
    }

    @Test
    func goLanguageServerRequiresExtensionRuntimeAndUsesPluginModuleOwner() throws {
        let factory = TestLanguageProviderRuntimeFactory()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimeFactory: factory,
            extensionRequiredProviderIDs: ["go"]
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let source = root.appendingPathComponent("main.go")

        try manager.synchronizeLanguageServer(for: source, text: "package main", rootURL: root)
        #expect(factory.standardRequests.isEmpty)

        let provider = TestLanguageServerExtensionProvider()
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            languageServerModuleID: .languageServerExtension("go")
        )
        #expect(manager.registerLanguageServerExtension(provider, support: support))
        #expect(factory.extensionRequests.count == 1)
        #expect(factory.extensionRequests.first?.ownerModuleID == .languageServerExtension("go"))
        #expect(factory.extensionRequests.first?.launch.executableNames == ["gopls"])
    }

    @Test
    func unregisteringAnExtensionDropsItsRuntimeBeforeReactivation() {
        let factory = TestLanguageProviderRuntimeFactory()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimeFactory: factory,
            extensionRequiredProviderIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            languageServerModuleID: .languageServerExtension("go")
        )
        let provider = TestLanguageServerExtensionProvider()

        #expect(manager.registerLanguageServerExtension(provider, support: support))
        manager.unregisterLanguageServerExtension(languageID: "go")
        #expect(manager.registerLanguageServerExtension(provider, support: support))

        #expect(factory.extensionRequests.count == 2)
        #expect(factory.standardRequests.isEmpty)
    }

    @Test
    func javaWorkspaceResetUsesTheFingerprintFromTheActiveSession() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("src/Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let runtime = WorkspaceStateLanguageProviderRuntime(
            descriptor: descriptor,
            session: session
        )
        var resetRoot: URL?
        var resetFingerprint: String?
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [runtime],
            workspaceFingerprintProvider: { _, _ in "active-fingerprint" },
            workspaceStateResetter: { _, rootURL, fingerprint in
                resetRoot = rootURL
                resetFingerprint = fingerprint
            }
        )

        try manager.synchronizeLanguageServer(
            for: source,
            text: "class Main {}",
            rootURL: root
        )
        try manager.rebuildWorkspaceState(providerID: "java", rootURL: root)

        #expect(session.startedFingerprint == "active-fingerprint")
        #expect(session.stopCallCount == 1)
        #expect(resetRoot == root.standardizedFileURL)
        #expect(resetFingerprint == "active-fingerprint")
    }

    @Test
    func languageServerLifecycleLogsAndCallbacksRetainTheOperationID() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let operationID = UUID()
        var callbacks: [(LanguageServerSessionState, UUID?)] = []
        manager.onLanguageServerStateChange = { providerID, state, callbackOperationID in
            guard providerID == "java" else { return }
            callbacks.append((state, callbackOperationID))
        }

        try manager.startLanguageServer(
            providerID: "java",
            rootURL: root,
            operationID: operationID
        )
        session.publish(.ready)
        manager.stopLanguageServer(providerID: "java")

        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString && $0.message == "Language server ready"
        })
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString && $0.message == "Stopping language server"
        })
        #expect(callbacks.contains { $0.0 == .ready && $0.1 == operationID })
        #expect(callbacks.contains { $0.0 == .stopped && $0.1 == operationID })
        #expect(manager.languageServerOperationIDs["java"] == nil)
    }

    @Test
    func javaDebugServerWaitsForJdtlsReadyAndReturnsItsPort() async throws {
        let root = URL(fileURLWithPath: "/workspace/java-debug", isDirectory: true)
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(
                for: root.appendingPathComponent("Main.java")
            )
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let task = Task { try await manager.startJavaDebugServer(rootURL: root) }
        defer { task.cancel() }

        try await session.waitUntilStarted()
        #expect(session.executedCommands.isEmpty)
        session.publish(.ready)
        let command = try await session.waitForExecuteCommand()
        #expect(command.command == "vscode.java.startDebugSession")
        #expect(command.arguments.isEmpty)
        session.completeExecuteReturningValue(.success(.integer(5005)))

        #expect(try await task.value == 5005)
    }

    @Test
    func javaDebugLaunchTargetUsesJdtlsProjectMetadataForTheCurrentFile() async throws {
        let root = URL(fileURLWithPath: "/workspace/java-debug", isDirectory: true)
        let source = root.appendingPathComponent("service/src/main/java/example/Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let task = Task {
            try await manager.resolveJavaDebugLaunchTarget(fileURL: source, rootURL: root)
        }
        defer { task.cancel() }

        try await session.waitUntilStarted()
        session.publish(.ready)
        let command = try await session.waitForExecuteCommand()
        #expect(command.command == "vscode.java.resolveMainClass")
        #expect(command.arguments.isEmpty)
        session.completeExecuteReturningValue(.success(.array([
            .object([
                "mainClass": .string("other/example.Main"),
                "projectName": .string("other"),
                "filePath": .string(root.appendingPathComponent("other/Main.java").path),
            ]),
            .object([
                "mainClass": .string("service/example.Main"),
                "projectName": .string("service"),
                "filePath": .string(source.path),
            ]),
        ])))

        let classpathCommand = try await session.waitForExecuteCommand(number: 2)
        #expect(classpathCommand.command == "vscode.java.resolveClasspath")
        #expect(classpathCommand.arguments == [
            .string("service/example.Main"),
            .string("service"),
            .string("runtime"),
        ])
        session.completeExecuteReturningValue(.success(.array([
            .array([.string("/workspace/modules")]),
            .array([.string("/workspace/classes")]),
        ])))

        #expect(try await task.value == JavaDebugLaunchTarget(
            mainClass: "service/example.Main",
            projectName: "service",
            modulePaths: ["/workspace/modules"],
            classPaths: ["/workspace/classes"]
        ))
    }

    @Test
    func javaDebugLaunchTargetDoesNotBorrowAnotherFileWhenJdtlsReportsItsPath() async throws {
        let root = URL(fileURLWithPath: "/workspace/java-debug", isDirectory: true)
        let source = root.appendingPathComponent("service/src/main/java/example/UserService.java")
        let otherMain = root.appendingPathComponent("service/src/main/java/example/Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let task = Task {
            try await manager.resolveJavaDebugLaunchTarget(fileURL: source, rootURL: root)
        }
        defer { task.cancel() }

        try await session.waitUntilStarted()
        session.publish(.ready)
        _ = try await session.waitForExecuteCommand()
        session.completeExecuteReturningValue(.success(.array([
            .object([
                "mainClass": .string("service/example.Main"),
                "projectName": .string("service"),
                "filePath": .string(otherMain.path),
            ])
        ])))

        await #expect(throws: LanguageToolingSessionError.toolingUnavailable(
            "No Java main method was found in UserService.java."
        )) {
            try await task.value
        }
    }

    @Test
    func javaTestDiscoveryProjectsSortedClassesAndMethodsForTheTestsTree() async throws {
        let root = URL(fileURLWithPath: "/workspace/java-tests", isDirectory: true)
        let source = root.appendingPathComponent(
            "service/src/test/java/example/UserServiceTest.java"
        )
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let task = Task {
            try await manager.discoverJavaTestItems(fileURL: source, rootURL: root)
        }
        defer { task.cancel() }

        try await session.waitUntilStarted()
        session.publish(.ready)
        let discovery = try await session.waitForExecuteCommand()
        #expect(discovery.command == "vscode.java.test.findTestTypesAndMethods")
        #expect(discovery.arguments == [.string(source.standardizedFileURL.absoluteString)])
        session.completeExecuteReturningValue(.success(.array([
            .object([
                "id": .string("service@example.UserServiceTest"),
                "label": .string("UserServiceTest"),
                "fullName": .string("example.UserServiceTest"),
                "projectName": .string("service"),
                "testKind": .integer(0),
                "testLevel": .integer(5),
                "jdtHandler": .string("class-handler"),
                "sortText": .string("002"),
                "children": .array([
                    .object([
                        "id": .string("service@example.UserServiceTest#logsOut"),
                        "label": .string("logsOut()"),
                        "fullName": .string("example.UserServiceTest#logsOut"),
                        "projectName": .string("service"),
                        "testKind": .integer(0),
                        "testLevel": .integer(6),
                        "jdtHandler": .string("logout-handler"),
                        "sortText": .string("002"),
                        "children": .array([]),
                    ]),
                    .object([
                        "id": .string("service@example.UserServiceTest#logsIn"),
                        "label": .string("logsIn()"),
                        "fullName": .string("example.UserServiceTest#logsIn"),
                        "projectName": .string("service"),
                        "testKind": .integer(0),
                        "testLevel": .integer(6),
                        "jdtHandler": .string("login-handler"),
                        "sortText": .string("001"),
                        "children": .array([]),
                    ]),
                ]),
            ]),
            .object([
                "id": .string("service@example.AccountTest"),
                "label": .string("AccountTest"),
                "fullName": .string("example.AccountTest"),
                "projectName": .string("service"),
                "testKind": .integer(0),
                "testLevel": .integer(5),
                "jdtHandler": .string("account-handler"),
                "sortText": .string("001"),
                "children": .array([]),
            ]),
        ])))

        let items = try await task.value
        #expect(items.map(\.label) == [
            "AccountTest", "UserServiceTest", "logsIn()", "logsOut()",
        ])
        #expect(items.map(\.depth) == [1, 1, 2, 2])
        #expect(items.map(\.kind) == [.testCase, .testCase, .testCase, .testCase])
        #expect(items.map(\.fileURL) == Array(repeating: source.standardizedFileURL, count: 4))
        #expect(items.map(\.testIdentifier) == [
            "example.AccountTest",
            "example.UserServiceTest",
            "example.UserServiceTest#logsIn",
            "example.UserServiceTest#logsOut",
        ])
    }

    @Test
    func junitDebugTargetUsesJavaTestDiscoveryAndLaunchArguments() async throws {
        let root = URL(fileURLWithPath: "/workspace/java-tests", isDirectory: true)
        let source = root.appendingPathComponent(
            "service/src/test/java/example/UserServiceTest.java"
        )
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let task = Task {
            try await manager.resolveJavaTestDebugLaunchTarget(
                fileURL: source,
                rootURL: root
            )
        }
        defer { task.cancel() }

        try await session.waitUntilStarted()
        session.publish(.ready)
        let discovery = try await session.waitForExecuteCommand()
        #expect(discovery.command == "vscode.java.test.findTestTypesAndMethods")
        #expect(discovery.arguments == [.string(source.standardizedFileURL.absoluteString)])
        session.completeExecuteReturningValue(.success(.array([
            .object([
                "id": .string("service@example.UserServiceTest"),
                "label": .string("UserServiceTest"),
                "fullName": .string("example.UserServiceTest"),
                "projectName": .string("service"),
                "testKind": .integer(0),
                "testLevel": .integer(5),
                "jdtHandler": .string("=service/src<example{UserServiceTest.java[UserServiceTest"),
                "children": .array([
                    .object([
                        "id": .string("service@example.UserServiceTest#logsIn"),
                        "label": .string("logsIn()"),
                        "fullName": .string("example.UserServiceTest#logsIn"),
                        "projectName": .string("service"),
                        "testKind": .integer(0),
                        "testLevel": .integer(6),
                        "jdtHandler": .string("=service/src<example{UserServiceTest.java[UserServiceTest~logsIn"),
                        "children": .array([]),
                    ]),
                ]),
            ]),
        ])))

        let launchCommand = try await session.waitForExecuteCommand(number: 2)
        #expect(launchCommand.command == "vscode.java.test.junit.argument")
        let launchRequest = try javaTestLaunchRequest(from: launchCommand)
        #expect(launchRequest["projectName"] as? String == "service")
        #expect(launchRequest["testLevel"] as? Int == 5)
        #expect(launchRequest["testKind"] as? Int == 0)
        #expect(launchRequest["testNames"] as? [String] == ["example.UserServiceTest"])
        session.completeExecuteReturningValue(.success(.object([
            "body": .object([
                "workingDirectory": .string("/workspace/java-tests/service"),
                "mainClass": .string("org.eclipse.jdt.internal.junit.runner.RemoteTestRunner"),
                "projectName": .string("service"),
                "classpath": .array([.string("/workspace/java-tests/service/classes")]),
                "modulepath": .array([]),
                "vmArguments": .array([.string("--enable-preview")]),
                "programArguments": .array([
                    .string("-version"), .string("3"), .string("-port"), .string("-1"),
                ]),
            ]),
            "status": .integer(0),
            "errorMessage": .null,
        ])))

        #expect(try await task.value == JavaTestDebugLaunchTarget(
            fileURL: source,
            name: "UserServiceTest",
            framework: .junit,
            workingDirectory: "/workspace/java-tests/service",
            mainClass: "org.eclipse.jdt.internal.junit.runner.RemoteTestRunner",
            projectName: "service",
            classPaths: ["/workspace/java-tests/service/classes"],
            modulePaths: [],
            vmArguments: ["--enable-preview"],
            programArguments: ["-version", "3", "-port", "-1"]
        ))
    }

    @Test
    func testngDebugTargetRetainsThePackagedRunnerAndSelectedMethod() async throws {
        let root = URL(fileURLWithPath: "/workspace/java-tests", isDirectory: true)
        let source = root.appendingPathComponent(
            "service/src/test/java/example/UserServiceTest.java"
        )
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        session.javaTestRunnerURL = URL(fileURLWithPath: "/lithe/java-test-runner.jar")
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let methodID = "service@example.UserServiceTest#logsIn"
        let task = Task {
            try await manager.resolveJavaTestDebugLaunchTarget(
                fileURL: source,
                testIdentifier: methodID,
                rootURL: root
            )
        }
        defer { task.cancel() }

        try await session.waitUntilStarted()
        session.publish(.ready)
        _ = try await session.waitForExecuteCommand()
        session.completeExecuteReturningValue(.success(.array([
            .object([
                "id": .string("service@example.UserServiceTest"),
                "label": .string("UserServiceTest"),
                "fullName": .string("example.UserServiceTest"),
                "projectName": .string("service"),
                "testKind": .integer(2),
                "testLevel": .integer(5),
                "jdtHandler": .string("class-handler"),
                "children": .array([
                    .object([
                        "id": .string(methodID),
                        "label": .string("logsIn()"),
                        "fullName": .string("example.UserServiceTest#logsIn"),
                        "projectName": .string("service"),
                        "testKind": .integer(2),
                        "testLevel": .integer(6),
                        "jdtHandler": .string("method-handler"),
                        "children": .array([]),
                    ]),
                ]),
            ]),
        ])))

        let launchCommand = try await session.waitForExecuteCommand(number: 2)
        #expect(launchCommand.command == "vscode.java.test.junit.argument")
        let launchRequest = try javaTestLaunchRequest(from: launchCommand)
        #expect(launchRequest["testLevel"] as? Int == 6)
        #expect(launchRequest["testKind"] as? Int == 2)
        #expect(launchRequest["testNames"] as? [String] == ["example.UserServiceTest#logsIn"])
        session.completeExecuteReturningValue(.success(.object([
            "body": .object([
                "workingDirectory": .string("/workspace/java-tests/service"),
                "projectName": .string("service"),
                "classpath": .array([.string("/workspace/java-tests/service/classes")]),
                "modulepath": .array([]),
                "vmArguments": .array([]),
                "programArguments": .array([]),
            ]),
            "status": .integer(0),
            "errorMessage": .null,
        ])))

        #expect(try await task.value == JavaTestDebugLaunchTarget(
            fileURL: source,
            name: "logsIn()",
            framework: .testng,
            workingDirectory: "/workspace/java-tests/service",
            mainClass: "com.microsoft.java.test.runner.Launcher",
            projectName: "service",
            classPaths: ["/workspace/java-tests/service/classes"],
            modulePaths: [],
            vmArguments: [],
            programArguments: [],
            testNGRunnerPath: "/lithe/java-test-runner.jar",
            testNGTestNames: ["example.UserServiceTest#logsIn"]
        ))
    }

    @Test
    func cancellingJavaDebugServerStartupReleasesTheReadyWait() async throws {
        let root = URL(fileURLWithPath: "/workspace/java-debug-cancel", isDirectory: true)
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(
                for: root.appendingPathComponent("Main.java")
            )
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let task = Task { try await manager.startJavaDebugServer(rootURL: root) }

        try await session.waitUntilStarted()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        session.publish(.ready)
        #expect(session.executedCommands.isEmpty)
    }

    @Test
    func languageServerStartTimeoutIsLoggedWithTheOperationID() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let timeoutFailure = LanguageServerSessionFailure(
            code: "timed_out",
            stage: "initialize",
            message: WorkspaceStateSessionError.timedOut.localizedDescription
        )
        session.startError = LanguageServerSessionStartError(failure: timeoutFailure)
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )]
        )
        let operationID = UUID()

        #expect(throws: LanguageServerSessionStartError.self) {
            try manager.startLanguageServer(
                providerID: "java",
                rootURL: root,
                operationID: operationID
            )
        }

        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.message == "Language server start timed out"
        })
        #expect(manager.languageServerStates["java"] == .failed(timeoutFailure))
    }

    @Test
    func workspaceCacheCleanupLogsTheLanguageServerOperationID() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        var cleanedFingerprint: String?
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )],
            workspaceFingerprintProvider: { _, _ in "active-fingerprint" },
            workspaceStateCleaner: { _, cleanedRoot, fingerprint in
                #expect(cleanedRoot == root.standardizedFileURL)
                cleanedFingerprint = fingerprint
                return 2
            }
        )
        let operationID = UUID()

        try manager.startLanguageServer(
            providerID: "java",
            rootURL: root,
            operationID: operationID
        )

        #expect(cleanedFingerprint == "active-fingerprint")
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.message == "Language server cache cleanup started"
        })
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.message == "Language server cache cleanup succeeded"
                && $0.detail == "removedCount=2"
        })
    }

    @Test
    func workspaceFingerprintFailureIsLoggedAndBlocksStartup() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )],
            workspaceFingerprintProvider: { _, _ in
                throw WorkspaceStateSessionError.unexpectedOperation
            }
        )
        let operationID = UUID()

        #expect(throws: WorkspaceStateSessionError.self) {
            try manager.startLanguageServer(
                providerID: "java",
                rootURL: root,
                operationID: operationID
            )
        }

        #expect(!session.isRunning)
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.level == .error
                && $0.message == "Language server workspace fingerprint failed"
        })
        #expect(manager.languageServerStates["java"] == .failed(LanguageServerSessionFailure(
            code: "workspace_fingerprint_failed",
            stage: "workspaceFingerprint",
            message: WorkspaceStateSessionError.unexpectedOperation.localizedDescription
        )))
    }

    @Test
    func workspaceCacheCleanupFailureIsLoggedAndDoesNotBlockStartup() throws {
        let root = URL(fileURLWithPath: "/workspace/java", isDirectory: true)
        let source = root.appendingPathComponent("Main.java")
        let descriptor = try #require(
            LanguageProviderCatalog.compatibilityFallback.provider(for: source)
        )
        let session = WorkspaceStateLanguageServerSession()
        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            runtimes: [WorkspaceStateLanguageProviderRuntime(
                descriptor: descriptor,
                session: session
            )],
            workspaceFingerprintProvider: { _, _ in "active-fingerprint" },
            workspaceStateCleaner: { _, _, _ in
                throw WorkspaceStateSessionError.unexpectedOperation
            }
        )
        let operationID = UUID()

        try manager.startLanguageServer(
            providerID: "java",
            rootURL: root,
            operationID: operationID
        )

        #expect(session.isRunning)
        #expect(session.startedFingerprint == "active-fingerprint")
        #expect(manager.languageServerLogs.contains {
            $0.operationID == operationID.uuidString
                && $0.level == .warning
                && $0.message == "Language server cache cleanup failed"
        })
    }

    private func makeModule(recorder: Recorder) -> LanguageIntelligenceModule {
        LanguageIntelligenceModule(makeGraph: {
            recorder.graphCalls += 1
            let graph = TestGraph()
            recorder.latestGraph = graph
            return graph
        })
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(
            manifest: ModuleManifest(
                id: .workspace,
                displayName: "Workspace",
                scope: .workspace
            )
        ) {
            EmptyWorkspaceModule()
        }
    }
}

@MainActor
private final class Recorder {
    var factoryCalls = 0
    var graphCalls = 0
    weak var latestGraph: TestGraph?
}

@MainActor
private final class TestGraph: LanguageIntelligenceServiceGraph {
    let sessions = LanguageToolingSessionManager()
    let tools = LanguageServerToolService(
        runtimeService: TestLanguageToolRuntime(),
        commandRunner: TestLanguageToolCommandRunner(),
        settingsStore: TestLanguageToolSettingsStore()
    )
    var hasActiveLanguageServers = false

    func activate(context: ModuleContext) {}
    func prepareForSleep() async throws {}
    func stop() async {}
}

@MainActor
private final class TestLanguageToolRuntime: LanguageToolRuntimePort {
    func executableOnPath(_: String) -> URL? { nil }
    func executableURL(at _: String) -> URL? { nil }
    func executableCandidates(_: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment() -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { "Missing \(name)." }
}

private struct TestLanguageToolCommandRunner: LanguageToolCommandRunning {
    func runLanguageToolCommand(
        operationID _: String,
        executableURL _: URL,
        arguments _: [String],
        environment _: [String: String],
        timeoutMilliseconds _: Int
    ) -> LanguageToolCommandResult {
        LanguageToolCommandResult(output: "", exitCode: 0)
    }
}

private final class TestLanguageToolSettingsStore: LanguageToolSettingsStoring {
    func loadLanguageToolExecutablePaths() -> [String: String] { [:] }
    func saveLanguageToolExecutablePaths(_: [String: String]) {}
}

@MainActor
private final class TestLanguageProviderRuntimeFactory: LanguageProviderRuntimeFactory {
    struct ExtensionRequest {
        let launch: LanguageServerLaunchDescriptor
        let ownerModuleID: ModuleID
    }

    private(set) var standardRequests: [LanguageProviderDescriptor] = []
    private(set) var extensionRequests: [ExtensionRequest] = []

    func makeRuntime(for descriptor: LanguageProviderDescriptor) -> (any LanguageProviderRuntime)? {
        standardRequests.append(descriptor)
        return TestLanguageProviderRuntime(descriptor: descriptor)
    }

    func makeRuntime(
        for descriptor: LanguageProviderDescriptor,
        languageServerLaunch: LanguageServerLaunchDescriptor,
        ownerModuleID: ModuleID
    ) -> (any LanguageProviderRuntime)? {
        extensionRequests.append(ExtensionRequest(
            launch: languageServerLaunch,
            ownerModuleID: ownerModuleID
        ))
        return TestLanguageProviderRuntime(descriptor: descriptor)
    }
}

@MainActor
private final class TestLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    init(descriptor: LanguageProviderDescriptor) { self.descriptor = descriptor }
}

@MainActor
private final class WorkspaceStateLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let session: WorkspaceStateLanguageServerSession
    var supportsLanguageServerSession: Bool { true }

    init(
        descriptor: LanguageProviderDescriptor,
        session: WorkspaceStateLanguageServerSession
    ) {
        self.descriptor = descriptor
        self.session = session
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}

@MainActor
private final class WorkspaceStateLanguageServerSession: LanguageServerSession {
    var isRunning = false
    var javaTestRunnerURL: URL?
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)?
    var onStateChange: ((LanguageServerSessionState) -> Void)?
    var features: LanguageServerFeatureSet = []
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)?
    var serverInfo: LanguageServerInfo?
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)?
    private(set) var startedFingerprint: String?
    private(set) var stopCallCount = 0
    var startError: Error?
    private(set) var executedCommands: [LanguageServerCommand] = []
    private var startWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var startTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var executeWaiters: [UUID: (
        number: Int,
        continuation: CheckedContinuation<LanguageServerCommand, Error>
    )] = [:]
    private var executeTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var executeValueCompletion: ((Result<ToolingJSONValue, Error>) -> Void)?

    func start(rootURL _: URL, workspaceFingerprint: String?) throws {
        if let startError { throw startError }
        startedFingerprint = workspaceFingerprint
        isRunning = true
        let waiterIDs = Array(startWaiters.keys)
        waiterIDs.forEach { finishStartWaiter($0, result: .success(())) }
    }

    func publish(_ state: LanguageServerSessionState) {
        onStateChange?(state)
    }

    func waitUntilStarted(timeout: Duration = .seconds(2)) async throws {
        if isRunning { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !isRunning else {
                    continuation.resume()
                    return
                }
                startWaiters[waiterID] = continuation
                let timeoutTask = Task { @MainActor [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: this watchdog bounds a failed continuation wait while successful synchronization remains event-driven.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishStartWaiter(
                        waiterID,
                        result: .failure(WorkspaceStateSessionError.timedOut)
                    )
                }
                if startWaiters[waiterID] == nil {
                    timeoutTask.cancel()
                } else {
                    startTimeoutTasks[waiterID] = timeoutTask
                }
                if Task.isCancelled {
                    finishStartWaiter(waiterID, result: .failure(CancellationError()))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishStartWaiter(waiterID, result: .failure(CancellationError()))
            }
        }
    }

    func waitForExecuteCommand(
        number: Int = 1,
        timeout: Duration = .seconds(2)
    ) async throws -> LanguageServerCommand {
        precondition(number > 0)
        if executedCommands.count >= number { return executedCommands[number - 1] }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard executedCommands.count < number else {
                    continuation.resume(returning: executedCommands[number - 1])
                    return
                }
                executeWaiters[waiterID] = (number, continuation)
                let timeoutTask = Task { @MainActor [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: this watchdog bounds a failed continuation wait while successful synchronization remains event-driven.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishExecuteWaiter(
                        waiterID,
                        result: .failure(WorkspaceStateSessionError.timedOut)
                    )
                }
                if executeWaiters[waiterID] == nil {
                    timeoutTask.cancel()
                } else {
                    executeTimeoutTasks[waiterID] = timeoutTask
                }
                if Task.isCancelled {
                    finishExecuteWaiter(waiterID, result: .failure(CancellationError()))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishExecuteWaiter(waiterID, result: .failure(CancellationError()))
            }
        }
    }

    func completeExecuteReturningValue(_ result: Result<ToolingJSONValue, Error>) {
        let completion = executeValueCompletion
        executeValueCompletion = nil
        completion?(result)
    }

    func synchronize(fileURL _: URL, text _: String, languageID _: String) throws {}
    func closeDocument(_: URL) {}

    func completions(
        fileURL _: URL,
        position _: LanguageServerPosition,
        completion _: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func hover(
        fileURL _: URL,
        position _: LanguageServerPosition,
        completion _: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func navigate(
        method _: String,
        fileURL _: URL,
        position _: LanguageServerPosition,
        completion _: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func rename(
        fileURL _: URL,
        position _: LanguageServerPosition,
        newName _: String,
        completion _: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func format(
        fileURL _: URL,
        completion _: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func codeActions(
        fileURL _: URL,
        range _: LanguageServerRange,
        diagnostics _: [LanguageServerDiagnostic],
        completion _: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func resolveCompletion(
        _: LanguageServerCompletionItem,
        fileURL _: URL,
        completion _: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func resolveCodeAction(
        _: LanguageServerCodeAction,
        fileURL _: URL,
        completion _: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func execute(
        _: LanguageServerCommand,
        fileURL _: URL,
        completion _: @escaping (Result<Void, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func executeReturningValue(
        _ command: LanguageServerCommand,
        fileURL _: URL,
        completion: @escaping (Result<ToolingJSONValue, Error>) -> Void
    ) throws {
        executedCommands.append(command)
        executeValueCompletion = completion
        let readyWaiterIDs = executeWaiters.compactMap { waiterID, waiter in
            waiter.number <= executedCommands.count ? waiterID : nil
        }
        readyWaiterIDs.forEach { waiterID in
            guard let waiter = executeWaiters[waiterID] else { return }
            finishExecuteWaiter(
                waiterID,
                result: .success(executedCommands[waiter.number - 1])
            )
        }
    }

    func resolveVirtualDocument(
        uri _: String,
        completion _: @escaping (Result<String, Error>) -> Void
    ) throws {
        throw WorkspaceStateSessionError.unexpectedOperation
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
        Array(startWaiters.keys).forEach {
            finishStartWaiter($0, result: .failure(CancellationError()))
        }
        Array(executeWaiters.keys).forEach {
            finishExecuteWaiter($0, result: .failure(CancellationError()))
        }
        let completion = executeValueCompletion
        executeValueCompletion = nil
        completion?(.failure(CancellationError()))
    }

    private func finishStartWaiter(_ waiterID: UUID, result: Result<Void, Error>) {
        let continuation = startWaiters.removeValue(forKey: waiterID)
        let timeoutTask = startTimeoutTasks.removeValue(forKey: waiterID)
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }

    private func finishExecuteWaiter(
        _ waiterID: UUID,
        result: Result<LanguageServerCommand, Error>
    ) {
        let waiter = executeWaiters.removeValue(forKey: waiterID)
        let timeoutTask = executeTimeoutTasks.removeValue(forKey: waiterID)
        timeoutTask?.cancel()
        waiter?.continuation.resume(with: result)
    }
}

private func javaTestLaunchRequest(
    from command: LanguageServerCommand
) throws -> [String: Any] {
    guard command.arguments.count == 1,
          case .string(let value) = command.arguments[0],
          let data = value.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw WorkspaceStateSessionError.unexpectedOperation
    }
    return object
}

private enum WorkspaceStateSessionError: LocalizedError {
    case unexpectedOperation
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unexpectedOperation: "Unexpected language-server operation."
        case .timedOut: "Language server initialization timed out."
        }
    }
}

@MainActor
private final class TestLanguageServerExtensionProvider: LanguageServerExtensionProviding {
    let configuration = LanguageServerExtensionConfiguration(
        languageID: "go",
        displayName: "Go",
        executableNames: ["gopls"],
        languageIdentifier: "go"
    )
    let lifecycle: any LanguageServerExtensionLifecycle = TestLanguageServerExtensionLifecycle()
}

@MainActor
private final class TestLanguageServerExtensionLifecycle: LanguageServerExtensionLifecycle {
    private var running: @MainActor () -> Bool = { false }
    private var stopAction: @MainActor () -> Void = {}
    var isRunning: Bool { running() }
    func attach(
        isRunning: @escaping @MainActor () -> Bool,
        stop: @escaping @MainActor () -> Void
    ) {
        running = isRunning
        stopAction = stop
    }
    func stop() { stopAction() }
}

@MainActor
private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(
        id: .workspace,
        displayName: "Workspace",
        scope: .workspace
    )

    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

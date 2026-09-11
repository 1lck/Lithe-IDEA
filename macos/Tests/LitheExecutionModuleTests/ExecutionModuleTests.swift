import Combine
import Foundation
import LitheApplicationKernel
@testable import LitheExecutionModule
import LitheCoreContracts
import LitheModuleAPI
import Testing

@MainActor
struct ExecutionModuleTests {
    @Test(arguments: ["pom-failure", "reload-failure", "reload-success"])
    func mavenReloadInvalidatesAlreadyRunningInventory(outcome: String) async throws {
        let gate = ReloadScanGate()
        let graph = makeTestGraph(mavenOperations: ReloadMavenOperations(scanGate: gate))
        let service = graph.maven
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        await service.loadProject(at: root, files: [root.appendingPathComponent("old")])
        let background = Task {
            await service.loadProject(at: root, files: [root.appendingPathComponent("inventory")])
        }
        let watchdog = Task {
            // test-stability: allow(swift-real-sleep) reason: watchdog bounds the event wait if the background scan never enters the controlled synchronous port.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            Issue.record("Background Maven scan did not reach its gate")
            gate.entered.continuation.finish()
            gate.release.signal()
            background.cancel()
        }
        defer {
            watchdog.cancel()
            background.cancel()
            gate.entered.continuation.finish()
            gate.release.signal()
            service.reset()
        }
        for await _ in gate.entered.stream { break }
        if outcome == "pom-failure" { service.markPomChanged(root.appendingPathComponent("pom.xml")) }
        await service.reloadProject(files: [root.appendingPathComponent("new")], rescan: true) {
            if outcome != "reload-success" { throw ReloadTestError.failed }
        }
        gate.release.signal()
        await background.value
        #expect(service.project?.artifactID == (outcome == "reload-success" ? "new" : "old"))
        #expect(service.projectState == .ready)
        #expect((service.reloadError != nil) == (outcome != "reload-success"))
        #expect(!service.isReloading)
    }

    @Test(arguments: ["success", "failure", "new-pom", "workspace"])
    func mavenReloadSynchronizesAcceptedRunProfiles(outcome: String) async throws {
        let graph = makeTestGraph(mavenOperations: ReloadMavenOperations())
        defer { graph.maven.reset(); graph.run.reset() }
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let snapshot = UUID()
        let pom = root.appendingPathComponent("pom.xml")
        await graph.projectDevelopment.loadProject(
            at: root, files: [root.appendingPathComponent("old"), pom], snapshotID: snapshot
        )
        graph.maven.markPomChanged(pom)
        await graph.projectDevelopment.loadProject(
            at: root, files: [root.appendingPathComponent("new"), pom], snapshotID: snapshot
        )
        #expect(graph.run.mavenProfiles.map(\.id) == ["old"])
        await graph.maven.reloadProject(files: [root.appendingPathComponent("new")], rescan: true) {
            switch outcome {
            case "failure": throw ReloadTestError.failed
            case "new-pom": graph.maven.markPomChanged(pom)
            case "workspace":
                await graph.run.loadProject(at: URL(fileURLWithPath: "/other"), files: [], mavenProject: nil)
            default: break
            }
        }
        #expect(graph.run.mavenProfiles.map(\.id) == (outcome == "workspace" ? [] : [outcome == "success" ? "new" : "old"]))
        if outcome != "workspace" {
            #expect(graph.run.isProjectReady(for: root, snapshotID: snapshot))
        }
    }

    @Test
    func runInventoryReturningAfterReloadKeepsAcceptedProfiles() async throws {
        let gate = ReloadScanGate()
        let graph = makeTestGraph(
            mavenOperations: ReloadMavenOperations(),
            runOperations: TestRunConfigurationOperations(inspectionGate: gate)
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let snapshot = UUID()
        let pom = root.appendingPathComponent("pom.xml")
        gate.release.signal()
        await graph.projectDevelopment.loadProject(at: root, files: [root.appendingPathComponent("old"), pom])
        for await _ in gate.entered.stream { break }
        graph.maven.markPomChanged(pom)
        let background = Task {
            await graph.projectDevelopment.loadProject(
                at: root, files: [root.appendingPathComponent("new"), pom], snapshotID: snapshot
            )
        }
        let watchdog = Task {
            // test-stability: allow(swift-real-sleep) reason: watchdog bounds the event wait if Run inspection never enters the controlled synchronous port.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            Issue.record("Run inspection did not reach its gate")
            gate.entered.continuation.finish()
            gate.release.signal()
            background.cancel()
        }
        defer {
            watchdog.cancel()
            background.cancel()
            gate.entered.continuation.finish()
            gate.release.signal()
            graph.maven.reset()
            graph.run.reset()
        }
        for await _ in gate.entered.stream { break }
        await graph.maven.reloadProject(files: [root.appendingPathComponent("new")], rescan: true) {}
        gate.release.signal()
        await background.value
        #expect(graph.run.mavenProfiles.map(\.id) == ["new"])
        #expect(graph.run.isProjectReady(for: root, snapshotID: snapshot))
    }

    @Test
    func mavenReloadCoalescesConcurrentRequests() async throws {
        let (service, root) = await makeReloadService()
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var javaCalls = 0
        let first = Task {
            await service.reloadProject(files: [root.appendingPathComponent("new")], rescan: true) {
                javaCalls += 1
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
        }
        let watchdog = Task {
            // test-stability: allow(swift-real-sleep) reason: watchdog bounds both event-driven gates if reload never reaches or leaves Java import.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            Issue.record("Maven reload did not reach its synchronization boundary")
            entered.continuation.finish()
            release.continuation.finish()
            first.cancel()
        }
        defer {
            watchdog.cancel()
            entered.continuation.finish()
            release.continuation.finish()
            first.cancel()
            service.reset()
        }
        for await _ in entered.stream { break }
        // The first task cannot resume on MainActor until the second call reaches
        // its await, so it must observe and join the in-flight operation.
        release.continuation.yield(())
        await service.reloadProject(files: [root.appendingPathComponent("invalid")], rescan: true) {
            javaCalls += 1
        }
        await first.value
        #expect(javaCalls == 1)
        #expect(service.project?.artifactID == "new")
        #expect(service.reloadError == nil)
    }

    @Test
    func mavenReloadCommitsOnlyAfterJavaImportAndPreservesConfiguration() async throws {
        let (service, root) = await makeReloadService()
        defer { service.reset() }
        service.setSkipTests(true)
        service.markPomChanged(root.appendingPathComponent("module/pom.xml"))
        await service.reloadProject(files: [root.appendingPathComponent("new")], rescan: true) {
            #expect(service.project?.artifactID == "old")
            #expect(service.isReloading)
            #expect(service.isProjectReloadRequired)
        }
        #expect(service.project?.artifactID == "new")
        #expect(service.skipTests)
        #expect(!service.isReloadRequired)
        #expect(!service.isReloading)
        #expect(service.reloadError == nil)
    }

    @Test(arguments: [true, false])
    func mavenReloadFailureKeepsAcceptedModel(scanFailure: Bool) async throws {
        let (service, root) = await makeReloadService()
        defer { service.reset() }
        service.markPomChanged(root.appendingPathComponent("pom.xml"))
        var javaCalls = 0
        await service.reloadProject(files: [root.appendingPathComponent(scanFailure ? "invalid" : "new")], rescan: true) {
            javaCalls += 1
            throw ReloadTestError.failed
        }
        #expect(javaCalls == (scanFailure ? 0 : 1))
        #expect(service.project?.artifactID == "old")
        #expect(service.projectState == .ready)
        #expect(service.isReloadRequired)
        #expect(service.reloadError != nil)
    }

    @Test(arguments: ["pom", "configuration", "reset", "workspace"])
    func mavenReloadRejectsChangesDuringJavaImport(change: String) async throws {
        let (service, root) = await makeReloadService()
        defer { service.reset() }
        service.markPomChanged(root.appendingPathComponent("pom.xml"))
        await service.reloadProject(files: [root.appendingPathComponent("new")], rescan: true) {
            switch change {
            case "pom": service.markPomChanged(root.appendingPathComponent("module/pom.xml"))
            case "configuration": service.setSkipTests(true)
            case "workspace":
                let next = URL(fileURLWithPath: "/next-workspace")
                await Task { @MainActor in
                    await service.loadProject(at: next, files: [next.appendingPathComponent("other")])
                }.value
            default: service.reset()
            }
        }
        #expect(service.project?.artifactID == (change == "reset" ? nil : change == "workspace" ? "other" : "old"))
        #expect(service.isReloadRequired == (change == "pom" || change == "configuration"))
        #expect(service.reloadError == nil)
        #expect(!service.isReloading)
    }

    @Test
    func mavenPomChangeSurvivesInventoryRefreshAndAcknowledgement() async throws {
        let (service, root) = await makeReloadService()
        defer { service.reset() }
        service.markPomChanged(URL(fileURLWithPath: "/workspace-copy/pom.xml"))
        service.markPomChanged(root.appendingPathComponent("README.md"))
        #expect(!service.isReloadRequired)
        service.markPomChanged(root.appendingPathComponent("pom.xml"))
        service.acknowledgeReload()
        await service.loadProject(at: root, files: [root.appendingPathComponent("new")])
        #expect(service.project?.artifactID == "old")
        #expect(service.isProjectReloadRequired)
    }

    @Test
    func mavenConfigurationOnlyReloadDoesNotScanPom() async throws {
        let (service, root) = await makeReloadService()
        defer { service.reset() }
        service.setSkipTests(true)
        await service.reloadProject(files: [root.appendingPathComponent("invalid")], rescan: false) {}
        #expect(service.project?.artifactID == "old")
        #expect(service.reloadError == nil)
        #expect(!service.isReloadRequired)
    }

    @Test
    func mavenReloadCancellationReleasesJavaWaitWithoutAcceptingTheCandidate() async throws {
        let (service, root) = await makeReloadService()
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let waiting = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var javaWaitEnded = false
        service.markPomChanged(root.appendingPathComponent("pom.xml"))
        let reload = Task {
            await service.reloadProject(files: [root.appendingPathComponent("new")], rescan: true) {
                entered.continuation.yield(())
                for await _ in waiting.stream { }
                javaWaitEnded = true
                try Task.checkCancellation()
            }
        }
        let watchdog = Task {
            // test-stability: allow(swift-real-sleep) reason: bounds cancellation regression when the Java readiness stand-in fails to terminate.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            Issue.record("Maven reload did not cancel its Java readiness wait")
            entered.continuation.finish()
            waiting.continuation.finish()
            reload.cancel()
            service.stop()
        }
        defer {
            watchdog.cancel()
            entered.continuation.finish()
            waiting.continuation.finish()
            reload.cancel()
            service.reset()
        }
        for await _ in entered.stream { break }
        // Cancel the caller, not the Java stand-in: the service must forward it.
        reload.cancel()
        await reload.value
        #expect(javaWaitEnded)
        #expect(service.project?.artifactID == "old")
        #expect(service.isProjectReloadRequired)
        #expect(service.reloadError != nil)
        #expect(!service.isReloading)
    }

    @Test
    func configuredServerPortUsesArgumentsEnvironmentResourcesAndFrameworkDefault() async throws {
        let root = URL(fileURLWithPath: "/workspace/service-port", isDirectory: true)
        let properties = root.appendingPathComponent("src/main/resources/application.properties")
        let configuration = RunConfiguration(
            id: "spring:api",
            name: "API",
            kind: .springBoot,
            modulePath: ".",
            mainClass: "example.Application"
        )

        let argumentService = makeRunService(
            configuration: configuration,
            options: RunOptions(
                vmArguments: "-Dserver.port=18081",
                programArguments: "--server.port=18082",
                environment: ["SERVER_PORT": "18083"]
            ),
            fileAccess: TestRunFileAccess(contents: [properties: "server.port=18084"]),
            serverPortParser: FixedServerPortParser(port: 18084)
        )
        await argumentService.loadProject(at: root, files: [properties], mavenProject: nil)
        #expect(argumentService.configuredServerPort(for: configuration) == 18082)

        let environmentService = makeRunService(
            configuration: configuration,
            options: RunOptions(environment: ["SERVER_PORT": "18083"]),
            fileAccess: TestRunFileAccess(contents: [properties: "server.port=18084"]),
            serverPortParser: FixedServerPortParser(port: 18084)
        )
        await environmentService.loadProject(at: root, files: [properties], mavenProject: nil)
        #expect(environmentService.configuredServerPort(for: configuration) == 18083)

        let resourceService = makeRunService(
            configuration: configuration,
            options: RunOptions(),
            fileAccess: TestRunFileAccess(contents: [properties: "server.port=18084"]),
            serverPortParser: FixedServerPortParser(port: 18084)
        )
        await resourceService.loadProject(at: root, files: [properties], mavenProject: nil)
        #expect(resourceService.configuredServerPort(for: configuration) == 18084)

        let defaultService = makeRunService(
            configuration: configuration,
            options: RunOptions(),
            fileAccess: TestRunFileAccess(),
            serverPortParser: FixedServerPortParser(port: nil)
        )
        await defaultService.loadProject(at: root, files: [], mavenProject: nil)
        #expect(defaultService.configuredServerPort(for: configuration) == 8080)
    }

    @Test
    func disabledExecutionDoesNotConstructGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(factory(recorder: recorder), enabled: false)

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.execution)) {
            _ = try await runtime.activateCapability(.executionWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.graphCalls == 0)
    }

    @Test
    func sleepReleasesExecutionGraphAndWakeCreatesNewServices() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(factory(recorder: recorder))

        let first = try #require(
            try await runtime.activateCapability(.executionWorkspace) as? ExecutionModuleCapability
        )
        let firstRunID = ObjectIdentifier(first.runFeature)
        weak var released = recorder.latestGraph
        try await runtime.sleep(.execution)

        #expect(released == nil)
        #expect(runtime.capability(.executionWorkspace) == nil)
        #expect(try runtime.snapshot(for: .execution).activity.activeResourceCount == 0)

        let second = try #require(
            try await runtime.activateCapability(.executionWorkspace) as? ExecutionModuleCapability
        )
        #expect(ObjectIdentifier(second.runFeature) != firstRunID)
        #expect(recorder.factoryCalls == 2)
        #expect(recorder.graphCalls == 2)
    }

    /// Run and Debug can reach identification before the workspace snapshot has
    /// bound a project. Reporting nothing at all made the confirmed dialog look
    /// like a dead button, so the unloaded project must become visible state.
    @Test
    func identificationBeforeProjectLoadReportsUnloadedProjectWithoutGenerating() async throws {
        let operations = RecordingRunConfigurationOperations()
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )

        #expect(service.projectLoadState == .idle)
        await service.generateRunConfigurations()

        #expect(service.generationState == .projectNotReady)
        #expect(operations.generateCallCount == 0)
        #expect(service.configurationStatus == .missing)
    }

    @Test
    func selectingBetweenRunningServicesSynchronizesLogIdentityAndControls() async {
        let first = RunConfiguration(id: "service:a", name: "A", kind: .javaMain,
                                     execution: .service, modulePath: nil, mainClass: "demo.A")
        let second = RunConfiguration(id: "service:b", name: "B", kind: .javaMain,
                                      execution: .service, modulePath: nil, mainClass: "demo.B")
        let service = RunService(
            runtime: TestRuntime(), process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: SelectionRunConfigurationOperations(configurations: [first, second]),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [], mavenProject: nil)
        // Model two already-running sessions: changing selection must not need
        // a process transition or a new output event to update the log target.
        service.startConfiguration(first)
        service.startConfiguration(second)
        let feature = RunFeatureModel(service: service)
        for configuration in [second, first, second] {
            feature.select(configuration)
            #expect(feature.selectedProjectSessionID == configuration.id)
            #expect(feature.isSelectedConfigurationRunning)
            #expect(feature.moduleSessions.first { $0.id == feature.selectedProjectSessionID }?.title == configuration.name)
            #expect(feature.moduleSessions.filter(\.isRunning).count == 2)
        }
        feature.select(.currentFile)
        #expect(feature.selectedProjectSessionID == nil)
        #expect(!feature.isSelectedConfigurationRunning)
    }

    /// Once the project is bound, identification must behave exactly as before.
    @Test
    func identificationAfterProjectLoadGeneratesAndClearsTheUnloadedState() async throws {
        let operations = RecordingRunConfigurationOperations()
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)

        await service.generateRunConfigurations()
        #expect(service.generationState == .projectNotReady)

        // Binding without a snapshot only unlocks reading existing configuration.
        await service.loadProject(at: root, files: [], mavenProject: nil)
        #expect(service.projectLoadState == .bound(workspace: root))
        #expect(!service.isProjectReady(for: root, snapshotID: UUID()))
        await service.generateRunConfigurations()
        #expect(service.generationState == .projectNotReady)
        #expect(operations.generateCallCount == 0)

        let snapshotID = UUID()
        await service.loadProject(at: root, files: [], mavenProject: nil, snapshotID: snapshotID)
        #expect(service.projectLoadState == .ready(workspace: root, snapshotID: snapshotID))
        #expect(service.isProjectReady(for: root, snapshotID: snapshotID))
        // A superseded snapshot of the same workspace is not ready.
        #expect(!service.isProjectReady(for: root, snapshotID: UUID()))
        await service.generateRunConfigurations()

        #expect(operations.generateCallCount == 1)
        #expect(service.generationState == .succeeded(entryCount: 1))
        #expect(service.configurationStatus == .ready)
    }

    /// Generation scans the inventory the service holds, so a workspace that was
    /// bound before its snapshot arrived must not be scanned with the provisional
    /// list. Doing so writes a configuration that omits real entry points.
    @Test
    func generationScansTheSnapshotInventoryAndNeverAProvisionalOne() async throws {
        let operations = RecordingRunConfigurationOperations()
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let source = root.appendingPathComponent("src/main/java/demo/App.java")

        // The workspace snapshot has not arrived, so the inventory is empty.
        await service.loadProject(at: root, files: [], mavenProject: nil)
        await service.generateRunConfigurations()
        #expect(service.generationState == .projectNotReady)
        #expect(operations.generatedInventories.isEmpty, "a provisional inventory must not be scanned")

        await service.loadProject(
            at: root,
            files: [source],
            mavenProject: nil,
            snapshotID: UUID()
        )
        await service.generateRunConfigurations()

        #expect(service.generationState == .succeeded(entryCount: 1))
        #expect(
            operations.generatedInventories == [[source]],
            "generation must scan exactly the inventory the snapshot reported"
        )
    }

    /// A broken configuration must stay regenerable. Inventory readiness and
    /// configuration validity are separate concerns, so an unreadable
    /// `generated.json` must not make the project un-ready and lock the user out
    /// of the only action that repairs it.
    @Test
    func unreadableConfigurationStillAllowsRegeneration() async throws {
        let operations = FailingInspectionRunConfigurationOperations()
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let snapshotID = UUID()

        await service.loadProject(at: root, files: [], mavenProject: nil, snapshotID: snapshotID)

        #expect(service.configurationStatus == .invalid("generated.json is invalid"))
        #expect(service.isProjectReady(for: root, snapshotID: snapshotID))

        await service.generateRunConfigurations()
        #expect(service.generationState != .projectNotReady)
    }

    @Test
    func currentGoFileRunsThroughExtensionOwnedSession() async throws {
        let builtInProcess = TestStreamingProcess()
        let extensionSession = TestLanguageExecutionSession()
        let service = RunService(
            runtime: TestRuntime(),
            process: builtInProcess,
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: TestReadyRunConfigurationOperations(),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback),
            extensionRequiredLanguageIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            executionModuleID: .languageExecutionExtension("go")
        )
        let extensionProvider = TestGoRunExtension(session: extensionSession)
        #expect(service.registerLanguageRunExtension(
            extensionProvider,
            support: support
        ))

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let source = root.appendingPathComponent("cmd/server/main.go")
        await service.loadProject(at: root, files: [source], mavenProject: nil)
        service.run(configuration: .currentFile, currentFileURL: source)

        #expect(builtInProcess.startRequests.isEmpty)
        #expect(extensionSession.startRequests.count == 1)
        #expect(extensionSession.startRequests.first?.arguments == ["run", "cmd/server/main.go"])
        #expect(extensionSession.isRunning)

        service.stop()
        #expect(!extensionSession.isRunning)
    }

    @Test
    func detectedGoProjectRunsThroughExtensionOwnedSession() async throws {
        let builtInProcess = TestStreamingProcess()
        let extensionSession = TestLanguageExecutionSession()
        let service = RunService(
            runtime: TestRuntime(),
            process: builtInProcess,
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: TestGoProjectRunConfigurationOperations(),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback),
            extensionRequiredLanguageIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            projectFileNames: ["go.mod"],
            executionModuleID: .languageExecutionExtension("go")
        )
        let extensionProvider = TestGoRunExtension(session: extensionSession)
        #expect(service.registerLanguageRunExtension(extensionProvider, support: support))

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        await service.loadProject(
            at: root,
            files: [root.appendingPathComponent("go.mod")],
            mavenProject: nil
        )
        let configuration = try #require(
            service.configurations.first { $0.kind.providerID == "go" }
        )
        service.run(configuration: configuration, currentFileURL: nil)

        #expect(builtInProcess.startRequests.isEmpty)
        #expect(extensionSession.startRequests.count == 1)
        #expect(extensionSession.startRequests.first?.arguments == ["run", "./cmd/api"])
        #expect(extensionSession.isRunning)

        service.stop()
        service.unregisterLanguageRunExtension(languageID: "go")
        service.run(configuration: configuration, currentFileURL: nil)
        #expect(builtInProcess.startRequests.isEmpty)
        #expect(service.output.contains("go execution extension is not active"))
    }

    @Test
    func goTestsRunThroughExtensionOwnedSession() throws {
        let builtInProcess = TestStreamingProcess()
        let extensionSession = TestLanguageExecutionSession()
        let service = LanguageTestService(
            catalog: .compatibilityFallback,
            registry: .standard(catalog: .compatibilityFallback),
            executableResolver: TestExecutableResolver(),
            processFactory: { builtInProcess },
            extensionRequiredLanguageIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            projectFileNames: ["go.mod"],
            executionModuleID: .languageExecutionExtension("go"),
            testingModuleID: .languageExecutionExtension("go")
        )
        let extensionProvider = TestGoRunExtension(session: extensionSession)
        #expect(service.registerLanguageTestExtension(extensionProvider, support: support))

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let files = [
            root.appendingPathComponent("go.mod"),
            root.appendingPathComponent("cmd/api/main_test.go")
        ]
        service.discover(workspaceURL: root, files: files)
        #expect(service.itemsByProviderID["go"]?.map(\.id) == [
            "go:workspace", "go:file:cmd/api/main_test.go"
        ])

        #expect(service.run(
            providerID: "go",
            scope: .file(files[1]),
            workspaceURL: root,
            projectFiles: files
        ))
        #expect(builtInProcess.startRequests.isEmpty)
        #expect(extensionSession.startRequests.first?.arguments == ["test", "./cmd/api"])

        service.unregisterLanguageTestExtension(languageID: "go")
        service.discover(workspaceURL: root, files: files)
        #expect(service.itemsByProviderID["go"] == nil)
        #expect(!service.run(
            providerID: "go",
            scope: .workspace,
            workspaceURL: root,
            projectFiles: files
        ))
        #expect(builtInProcess.startRequests.isEmpty)
        #expect(service.errorMessage == "go testing extension is not active.")
    }

    @Test
    func mavenTestsParseResultsAndRerunTheLastSelection() async throws {
        let root = URL(fileURLWithPath: "/workspace/maven-tests", isDirectory: true)
        let source = root.appendingPathComponent(
            "src/test/java/com/example/CalculatorTest.java"
        )
        let pom = root.appendingPathComponent("pom.xml")
        let firstProcess = TestStreamingProcess()
        let secondProcess = TestStreamingProcess()
        var factoryCall = 0
        let parsedResults = MavenTestResults(
            testsRun: 3,
            failures: 1,
            errors: 0,
            skipped: 1,
            passed: 1,
            success: false,
            failureDetails: []
        )
        let parser = TestResultParserRecorder(result: parsedResults)
        let service = LanguageTestService(
            executableResolver: TestExecutableResolver(),
            processFactory: {
                factoryCall += 1
                return factoryCall == 1 ? firstProcess : secondProcess
            },
            resultParser: parser.parse
        )

        #expect(service.run(
            providerID: "java",
            scope: .file(source),
            workspaceURL: root,
            projectFiles: [pom, source]
        ))
        #expect(firstProcess.startRequests.first?.arguments == ["-Dtest=CalculatorTest", "test"])
        #expect(firstProcess.startRequests.first?.timeoutMilliseconds == 120_000)
        defer { service.reset() }

        firstProcess.onOutput?("Tests run: 3, Failures: 1, Errors: 0, Skipped: 1\n")
        firstProcess.onTermination?(1)
        try await awaitTestValue(service.$state, matching: { $0 == .failed(exitCode: 1) })
        #expect(service.state == .failed(exitCode: 1))
        #expect(service.results == parsedResults)
        #expect(parser.calls == 1)
        #expect(parser.output.contains("Tests run: 3"))
        #expect(!parser.ranOnMainThread)
        #expect(service.canRerun)

        #expect(service.rerun())
        #expect(secondProcess.startRequests.first?.arguments == ["-Dtest=CalculatorTest", "test"])
    }

    @Test
    func mavenTestTimeoutIsPreservedWhenTerminationArrivesLate() async throws {
        let root = URL(fileURLWithPath: "/workspace/maven-timeout", isDirectory: true)
        let source = root.appendingPathComponent(
            "src/test/java/com/example/CalculatorTest.java"
        )
        let process = TestStreamingProcess()
        let service = LanguageTestService(
            executableResolver: TestExecutableResolver(),
            processFactory: { process },
            resultParser: { _, _ in nil }
        )

        #expect(service.run(
            providerID: "java",
            scope: .file(source),
            workspaceURL: root,
            projectFiles: [root.appendingPathComponent("pom.xml"), source]
        ))
        let request = try #require(process.startRequests.first)
        #expect(request.timeoutMilliseconds == 120_000)
        defer { service.reset() }

        process.onStateChange?(ProcessLifecycleEvent(
            operationID: request.operationID,
            state: .stopping,
            exitCode: nil,
            message: "Process timed out"
        ))
        try await awaitTestValue(service.$errorMessage, matching: { $0 != nil })
        #expect(service.state == .running)
        #expect(service.errorMessage == "Maven test run timed out after 120 seconds.")

        process.onTermination?(0)
        try await awaitTestValue(service.$state, matching: { $0 == .timedOut })
        #expect(service.state == .timedOut)
        #expect(!service.isRunning)
    }

    @Test
    func nonMavenLanguageTestsDoNotParseMavenResults() async throws {
        let root = URL(fileURLWithPath: "/workspace/gradle-tests", isDirectory: true)
        let source = root.appendingPathComponent(
            "src/test/java/com/example/CalculatorTest.java"
        )
        let buildFile = root.appendingPathComponent("build.gradle")
        let process = TestStreamingProcess()
        let parser = TestResultParserRecorder(result: MavenTestResults(
            testsRun: 1,
            failures: 0,
            errors: 0,
            skipped: 0,
            passed: 1,
            success: true,
            failureDetails: []
        ))
        let service = LanguageTestService(
            executableResolver: TestExecutableResolver(),
            processFactory: { process },
            resultParser: parser.parse
        )

        #expect(service.run(
            providerID: "java",
            scope: .file(source),
            workspaceURL: root,
            projectFiles: [buildFile, source]
        ))
        #expect(service.activePlan?.frameworkID == "gradle")
        defer { service.reset() }

        process.onTermination?(0)
        try await awaitTestValue(service.$state, matching: { $0 == .passed })
        #expect(service.state == .passed)
        #expect(service.results == nil)
        #expect(parser.calls == 0)
    }

    @Test
    func stoppingMavenTestsIgnoresLateTerminationEvents() async throws {
        let root = URL(fileURLWithPath: "/workspace/maven-cancel", isDirectory: true)
        let source = root.appendingPathComponent(
            "src/test/java/com/example/CalculatorTest.java"
        )
        let process = TestStreamingProcess()
        let service = LanguageTestService(
            executableResolver: TestExecutableResolver(),
            processFactory: { process },
            resultParser: { _, _ in
                MavenTestResults(
                    testsRun: 1,
                    failures: 0,
                    errors: 0,
                    skipped: 0,
                    passed: 1,
                    success: true,
                    failureDetails: []
                )
            }
        )

        #expect(service.run(
            providerID: "java",
            scope: .file(source),
            workspaceURL: root,
            projectFiles: [root.appendingPathComponent("pom.xml"), source]
        ))
        service.stop()
        #expect(service.state == .cancelled)
        #expect(!process.isRunning)

        process.onTermination?(0)
        await Task.yield()
        await Task.yield()

        #expect(service.state == .cancelled)
        #expect(service.results == nil)
    }

    @Test
    func mavenServiceExecutesTheSharedLaunchPlanWithLocalRuntimeOverrides() async throws {
        let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let reactor = workspace.appendingPathComponent("projects/demo", isDirectory: true)
        let module = MavenModule(
            relativePath: "service-api",
            url: reactor.appendingPathComponent("service-api", isDirectory: true),
            groupID: "dev.lithe",
            artifactID: "service-api",
            version: "1.0",
            packaging: "jar",
            modules: []
        )
        let project = MavenProject(
            rootURL: reactor,
            pomURL: reactor.appendingPathComponent("pom.xml"),
            groupID: "dev.lithe",
            artifactID: "demo",
            version: "1.0",
            packaging: "pom",
            modules: [module],
            profiles: [MavenProfile(id: "dev", isActiveByDefault: false)],
            hasWrapper: false
        )
        let plan = MavenLaunchPlan(
            version: 1,
            toolchain: "project-maven",
            arguments: ["core-owned-argument", "-s", "/local/settings.xml", "verify"],
            workingDirectory: "projects/demo",
            configurationFingerprint: "sha256:test"
        )
        let operations = RecordingMavenOperations(project: project, plan: plan)
        let process = MavenRecordingProcess()
        let runtime = MavenRecordingRuntime()
        let store = RecordingMavenConfigurationStore(configuration: MavenStoredConfiguration(
            portable: MavenPortableConfiguration(
                selectedProfiles: ["dev"],
                customProfiles: [],
                skipTests: true
            ),
            local: MavenLocalConfiguration(
                settingsPath: "/local/settings.xml",
                mavenExecutablePath: "/local/apache-maven",
                javaHomePath: "/local/jdk"
            )
        ))
        let service = MavenService(
            runtimeService: runtime,
            process: process,
            dependencyProcess: TestStreamingProcess(),
            mavenOperations: operations,
            configurationStore: store
        )

        await service.loadProject(at: workspace, files: [project.pomURL])
        service.runCustomGoal(
            "help:evaluate -Dexpression=fixture.config -q -DforceStdout",
            module: module
        )
        let request = try #require(await process.nextStart(timeout: .seconds(1)))

        #expect(request.arguments == plan.arguments)
        #expect(request.workingDirectory == reactor.path)
        #expect(request.environment?["TEST_JAVA_HOME"] == "/local/jdk")
        #expect(runtime.lastMavenOverride == "/local/apache-maven")
        #expect(operations.lastContext?.reactorPath == "projects/demo")
        #expect(operations.lastContext?.profiles == ["dev"])
        #expect(operations.lastContext?.settingsPath == "/local/settings.xml")
        #expect(operations.lastContext?.skipTests == true)
        #expect(operations.lastModule == "service-api")
        #expect(operations.lastGoals == [
            "help:evaluate",
            "-Dexpression=fixture.config",
            "-q",
            "-DforceStdout"
        ])
        #expect(service.output.contains("-s <settings.xml>"))
        #expect(!service.output.contains("/local/settings.xml"))
    }

    @Test
    func mavenServiceReportsCancellationWithoutInventingAnExitCode() async throws {
        let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let project = MavenProject(
            rootURL: workspace,
            pomURL: workspace.appendingPathComponent("pom.xml"),
            groupID: "dev.lithe",
            artifactID: "demo",
            version: "1.0",
            packaging: "jar",
            modules: [],
            profiles: [],
            hasWrapper: false
        )
        let plan = MavenLaunchPlan(
            version: 1,
            toolchain: "project-maven",
            arguments: ["-B", "-ntp", "validate"],
            workingDirectory: ".",
            configurationFingerprint: "sha256:test"
        )
        let process = MavenRecordingProcess()
        let service = MavenService(
            runtimeService: MavenRecordingRuntime(),
            process: process,
            dependencyProcess: TestStreamingProcess(),
            mavenOperations: RecordingMavenOperations(project: project, plan: plan)
        )

        await service.loadProject(at: workspace, files: [project.pomURL])
        service.run(phase: .validate, module: nil)
        _ = try #require(await process.nextStart(timeout: .seconds(1)))
        service.stop()

        #expect(service.taskState == .cancelled)
        #expect(service.runningTitle == nil)
        #expect(service.lastExitCode == nil)
        #expect(service.output.hasSuffix("Maven task cancelled.\n"))
        #expect(!process.isRunning)
    }

    @Test
    func mavenServiceClearsReloadWhenConfigurationFingerprintReturnsToBaseline() async throws {
        let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let project = MavenProject(
            rootURL: workspace,
            pomURL: workspace.appendingPathComponent("pom.xml"),
            groupID: "dev.lithe",
            artifactID: "demo",
            version: "1.0",
            packaging: "jar",
            modules: [],
            profiles: [],
            hasWrapper: false
        )
        let process = MavenRecordingProcess()
        let service = MavenService(
            runtimeService: MavenRecordingRuntime(),
            process: process,
            dependencyProcess: TestStreamingProcess(),
            mavenOperations: FingerprintingMavenOperations(project: project)
        )

        await service.loadProject(at: workspace, files: [project.pomURL])
        #expect(!service.isReloadRequired)

        service.setSkipTests(true)
        service.run(phase: .validate, module: nil)
        _ = try #require(await process.nextStart(timeout: .seconds(1)))
        #expect(service.isReloadRequired)

        service.stop()
        service.setSkipTests(false)
        service.run(phase: .validate, module: nil)
        _ = try #require(await process.nextStart(timeout: .seconds(1)))
        #expect(!service.isReloadRequired)
    }

    @Test
    func mavenServiceResolvesDependenciesOnTheSecondBoundedProcess() async throws {
        let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let module = MavenModule(
            relativePath: "service",
            url: workspace.appendingPathComponent("service", isDirectory: true),
            groupID: "dev.lithe",
            artifactID: "service",
            version: "1.0",
            packaging: "jar",
            modules: []
        )
        let project = MavenProject(
            rootURL: workspace,
            pomURL: workspace.appendingPathComponent("pom.xml"),
            groupID: "dev.lithe",
            artifactID: "demo",
            version: "1.0",
            packaging: "pom",
            modules: [module],
            profiles: [],
            hasWrapper: false
        )
        let plan = MavenLaunchPlan(
            version: 1,
            toolchain: "project-maven",
            arguments: ["dependency:tree"],
            workingDirectory: ".",
            configurationFingerprint: "sha256:dependency"
        )
        let dependency = MavenDependency(
            modulePath: "service",
            groupID: "org.example",
            artifactID: "library",
            version: "1.0",
            type: "jar",
            classifier: nil,
            scope: "compile",
            resolution: .resolved,
            selectedVersion: nil,
            children: []
        )
        let operations = RecordingMavenOperations(
            project: project,
            plan: plan,
            dependencyTree: MavenDependencyTree(modulePath: "service", dependencies: [dependency])
        )
        let buildProcess = MavenRecordingProcess()
        let dependencyProcess = MavenRecordingProcess()
        let service = MavenService(
            runtimeService: MavenRecordingRuntime(),
            process: buildProcess,
            dependencyProcess: dependencyProcess,
            mavenOperations: operations
        )

        await service.loadProject(at: workspace, files: [project.pomURL, module.url])
        service.loadDependencies(for: "service")
        let request = try #require(await dependencyProcess.nextStart(timeout: .seconds(1)))

        #expect(request.arguments == plan.arguments)
        #expect(request.timeoutMilliseconds == 60_000)
        #expect(!buildProcess.isRunning)
        #expect(operations.lastDependencyModule == "service")
        dependencyProcess.onOutput?("[INFO] dependency tree\n")
        dependencyProcess.onTermination?(0)
        let state = await dependencyState(
            service,
            modulePath: "service",
            matching: { if case .ready = $0 { true } else { false } }
        )

        #expect(state == .ready([dependency]))
        #expect(operations.lastDependencyOutput == "[INFO] dependency tree\n")
    }

    @Test
    func mavenServiceStopCancelsAnActiveDependencyProcess() async throws {
        let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let project = MavenProject(
            rootURL: workspace,
            pomURL: workspace.appendingPathComponent("pom.xml"),
            groupID: "dev.lithe",
            artifactID: "demo",
            version: "1.0",
            packaging: "jar",
            modules: [],
            profiles: [],
            hasWrapper: false
        )
        let plan = MavenLaunchPlan(
            version: 1,
            toolchain: "project-maven",
            arguments: ["dependency:tree"],
            workingDirectory: ".",
            configurationFingerprint: "sha256:dependency"
        )
        let dependencyProcess = MavenRecordingProcess()
        let service = MavenService(
            runtimeService: MavenRecordingRuntime(),
            process: MavenRecordingProcess(),
            dependencyProcess: dependencyProcess,
            mavenOperations: RecordingMavenOperations(project: project, plan: plan)
        )

        await service.loadProject(at: workspace, files: [project.pomURL])
        service.loadDependencies(for: ".")
        _ = try #require(await dependencyProcess.nextStart(timeout: .seconds(1)))

        service.stop()

        #expect(!dependencyProcess.isRunning)
        #expect(service.dependencyState(for: ".") == .cancelled)
        #expect(!service.isResolvingDependencies)
    }

    @Test
    func mavenServiceReportsDependencyTimeoutFromTheProcessLifecycle() async throws {
        let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let project = MavenProject(
            rootURL: workspace,
            pomURL: workspace.appendingPathComponent("pom.xml"),
            groupID: "dev.lithe",
            artifactID: "demo",
            version: "1.0",
            packaging: "jar",
            modules: [],
            profiles: [],
            hasWrapper: false
        )
        let plan = MavenLaunchPlan(
            version: 1,
            toolchain: "project-maven",
            arguments: ["dependency:tree"],
            workingDirectory: ".",
            configurationFingerprint: "sha256:dependency"
        )
        let dependencyProcess = MavenRecordingProcess()
        let service = MavenService(
            runtimeService: MavenRecordingRuntime(),
            process: MavenRecordingProcess(),
            dependencyProcess: dependencyProcess,
            mavenOperations: RecordingMavenOperations(project: project, plan: plan)
        )

        await service.loadProject(at: workspace, files: [project.pomURL])
        service.loadDependencies(for: ".")
        let request = try #require(await dependencyProcess.nextStart(timeout: .seconds(1)))
        dependencyProcess.onStateChange?(ProcessLifecycleEvent(
            operationID: request.operationID,
            state: .stopping,
            exitCode: nil,
            message: "Process timed out"
        ))
        dependencyProcess.onStateChange?(ProcessLifecycleEvent(
            operationID: request.operationID,
            state: .finished,
            exitCode: 15,
            message: nil
        ))
        let state = await dependencyState(
            service,
            modulePath: ".",
            matching: { if case .failed = $0 { true } else { false } }
        )

        guard case .failed(let message) = state else {
            Issue.record("Expected a failed Maven dependency state")
            return
        }
        #expect(message == "Maven dependency resolution timed out after 60 seconds.")
    }

    private func factory(recorder: Recorder) -> ModuleFactory {
        ModuleFactory(manifest: ExecutionModule.moduleManifest, contributions: ExecutionModule.moduleContributions) {
            recorder.factoryCalls += 1
            return ExecutionModule(makeGraph: {
                recorder.graphCalls += 1
                let graph = makeTestGraph()
                recorder.latestGraph = graph
                return graph
            })
        }
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            EmptyWorkspaceModule()
        }
    }
}

private struct SelectionRunConfigurationOperations: RunConfigurationOperations {
    let configurations: [RunConfiguration]
    func inspect(at _: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at _: URL, files _: [URL], modulePaths _: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: configurations.count)
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: ([.currentFile] + configurations).map {
                EffectiveRunConfiguration(configuration: $0, options: RunOptions())
            }, diagnostics: [], defaultConfigurationID: configurations.first?.id
        )
    }
    func launchPlan(at _: URL, configurationID: String, currentFile _: String?, classPath _: String?, debugPort _: Int?) throws -> SharedLaunchPlan {
        SharedLaunchPlan(executable: .toolchain("java"), arguments: [configurationID], workingDirectory: ".")
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at _: URL) throws -> String { draft.name }
    func migrateLegacySettings(at _: URL, configurationIDs _: [String]) throws {}
}

@MainActor
private func makeRunService(
    configuration: RunConfiguration,
    options: RunOptions,
    fileAccess: TestRunFileAccess,
    serverPortParser: FixedServerPortParser
) -> RunService {
    RunService(
        runtime: TestRuntime(),
        process: TestStreamingProcess(),
        processFactory: { TestStreamingProcess() },
        fileAccess: fileAccess,
        preferences: TestRunPreferences(),
        serverPortParser: serverPortParser,
        runConfigurationOperations: SingleRunConfigurationOperations(
            configuration: configuration,
            options: options
        ),
        executableResolver: TestExecutableResolver(),
        languageProviderCatalog: .compatibilityFallback,
        languageRunProviders: .standard(catalog: .compatibilityFallback)
    )
}

@MainActor private final class Recorder {
    var factoryCalls = 0
    var graphCalls = 0
    weak var latestGraph: ExecutionFeatureGraph?
}

@MainActor
private func makeTestGraph(
    mavenOperations: any MavenProjectOperations = TestMavenOperations(),
    runOperations: any RunConfigurationOperations = TestRunConfigurationOperations()
) -> ExecutionFeatureGraph {
    let runtime = TestRuntime()
    let resolver = TestExecutableResolver()
    let maven = MavenService(
        runtimeService: runtime,
        process: TestStreamingProcess(),
        dependencyProcess: TestStreamingProcess(),
        mavenOperations: mavenOperations
    )
    let run = RunService(
        runtime: runtime,
        process: TestStreamingProcess(),
        processFactory: { TestStreamingProcess() },
        fileAccess: TestRunFileAccess(),
        preferences: TestRunPreferences(),
        serverPortParser: TestServerPortParser(),
        runConfigurationOperations: runOperations,
        executableResolver: resolver,
        languageProviderCatalog: .compatibilityFallback,
        languageRunProviders: .standard(catalog: .compatibilityFallback)
    )
    let tests = LanguageTestService(
        catalog: .compatibilityFallback,
        registry: LanguageTestProviderRegistry(providers: []),
        executableResolver: resolver,
        processFactory: { TestStreamingProcess() }
    )
    return ExecutionFeatureGraph(maven: maven, run: run, tests: tests)
}

@MainActor
private func dependencyState(
    _ service: MavenService,
    modulePath: String,
    matching: @escaping @Sendable (MavenDependencyLoadState) -> Bool
) async -> MavenDependencyLoadState? {
    let stateTask: Task<MavenDependencyLoadState?, Never> = Task { @MainActor in
        let initial = service.dependencyState(for: modulePath)
        if matching(initial) { return initial }
        for await states in service.$dependencyStates.values {
            let state = states[modulePath] ?? .idle
            if matching(state) { return state }
        }
        return nil
    }
    return await withTaskGroup(of: MavenDependencyLoadState?.self) { group in
        group.addTask { await stateTask.value }
        group.addTask {
            // test-stability: allow(swift-real-sleep) reason: this task is the bounded failure deadline for event-driven dependency-state observation.
            try? await ContinuousClock().sleep(for: .seconds(1))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        stateTask.cancel()
        return result
    }
}

/// Subscribe synchronously so an event between setup and suspension is buffered.
/// The watchdog fails a missing event; elapsed time never advances the happy path.
@MainActor
private func awaitTestValue<Value: Sendable>(
    _ publisher: Published<Value>.Publisher,
    matching: @escaping @Sendable (Value) -> Bool
) async throws {
    let events = AsyncStream<Value>.makeStream(bufferingPolicy: .unbounded)
    let subscription = publisher.sink { events.continuation.yield($0) }
    let watchdog = Task {
        // test-stability: allow(swift-real-sleep) reason: deadline ends a missing publisher event, never synchronizes successful test completion.
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        events.continuation.finish()
    }
    defer {
        subscription.cancel()
        watchdog.cancel()
        events.continuation.finish()
    }
    for await value in events.stream {
        if matching(value) { return }
    }
    throw TestObservationError.deadlineExceeded
}

private enum TestObservationError: Error {
    case deadlineExceeded
}

private final class TestResultParserRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: MavenTestResults?
    private var recordedCalls = 0
    private var recordedOutput = ""
    private var recordedMainThread = false

    init(result: MavenTestResults?) {
        self.result = result
    }

    func parse(output: String, rootURL: URL) -> MavenTestResults? {
        lock.lock()
        recordedCalls += 1
        recordedOutput = output
        recordedMainThread = Thread.isMainThread
        lock.unlock()
        return result
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return recordedOutput
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedMainThread
    }
}

@MainActor
private final class TestRuntime: MavenRuntimePort, RunRuntimePort {
    func mavenExecutable(for project: MavenProject, overridePath: String?) -> URL? { nil }
    func mavenProcessEnvironment(javaHomePath: String?) -> [String: String] { [:] }
    func setActiveServiceJavaHomePath(_ path: String) {}
    func javaHomeURL(overridePath: String?) -> URL? { nil }
    func mavenJavaHomeURL(overridePath: String?) -> URL? { nil }
    func runConfigurationToolchainCandidates(
        for project: MavenProject?,
        projectRoot: URL?,
        javaHomeOverride: String?,
        mavenExecutableOverride: String?
    ) -> [ProjectToolchainCandidate] { [] }
}

private final class TestStreamingProcess: StreamingProcess, @unchecked Sendable {
    var isRunning = false
    private(set) var startRequests: [ProcessRequest] = []
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?
    func start(_ request: ProcessRequest) throws {
        startRequests.append(request)
        isRunning = true
    }
    func send(_ input: Data) throws {}
    func stop() { isRunning = false }
}

private enum ReloadTestError: Error { case failed }

@MainActor
private func makeReloadService() async -> (MavenService, URL) {
    let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
    let service = MavenService(
        runtimeService: TestRuntime(), process: TestStreamingProcess(),
        dependencyProcess: TestStreamingProcess(), mavenOperations: ReloadMavenOperations()
    )
    await service.loadProject(at: root, files: [root.appendingPathComponent("old")])
    return (service, root)
}

private struct ReloadMavenOperations: MavenProjectOperations {
    var scanGate: ReloadScanGate? = nil
    func scanMavenProject(at rootURL: URL, files: [URL]) throws -> MavenProject? {
        let name = files.first?.lastPathComponent ?? "old"
        if name == "inventory", let scanGate {
            scanGate.entered.continuation.yield(())
            guard scanGate.release.wait(timeout: .now() + 2) == .success else {
                Issue.record("Background Maven scan was not released before its deadline")
                throw ReloadTestError.failed
            }
        }
        if name == "invalid" { throw ReloadTestError.failed }
        return MavenProject(
            rootURL: rootURL, pomURL: rootURL.appendingPathComponent("pom.xml"),
            groupID: "example", artifactID: name, version: "1", packaging: "jar",
            modules: [], profiles: [MavenProfile(id: name, isActiveByDefault: false)], hasWrapper: false
        )
    }
    func mavenLaunchPlan(at rootURL: URL, context: MavenLaunchContext, module: String?, goals: [String]) throws -> MavenLaunchPlan {
        MavenLaunchPlan(version: 1, toolchain: "project-maven", arguments: goals,
                        workingDirectory: ".", configurationFingerprint: context.skipTests ? "skip" : "run")
    }
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }
}

private final class ReloadScanGate: Sendable {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let release = DispatchSemaphore(value: 0)
}

private struct TestMavenOperations: MavenProjectOperations {
    func scanMavenProject(at rootURL: URL, files: [URL]) throws -> MavenProject? { nil }
    func mavenLaunchPlan(
        at rootURL: URL,
        context: MavenLaunchContext,
        module: String?,
        goals: [String]
    ) throws -> MavenLaunchPlan {
        MavenLaunchPlan(
            version: 1,
            toolchain: "project-maven",
            arguments: goals,
            workingDirectory: ".",
            configurationFingerprint: "test"
        )
    }
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }
}

private final class RecordingMavenOperations: MavenProjectOperations, @unchecked Sendable {
    private let lock = NSLock()
    private let project: MavenProject
    private let plan: MavenLaunchPlan
    private let dependencyTree: MavenDependencyTree
    private var recordedContext: MavenLaunchContext?
    private var recordedModule: String?
    private var recordedGoals: [String] = []
    private var recordedDependencyModule: String?
    private var recordedDependencyOutput: String?

    init(
        project: MavenProject,
        plan: MavenLaunchPlan,
        dependencyTree: MavenDependencyTree = MavenDependencyTree(modulePath: ".", dependencies: [])
    ) {
        self.project = project
        self.plan = plan
        self.dependencyTree = dependencyTree
    }

    var lastContext: MavenLaunchContext? {
        lock.lock()
        defer { lock.unlock() }
        return recordedContext
    }

    var lastModule: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedModule
    }

    var lastGoals: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedGoals
    }

    var lastDependencyModule: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedDependencyModule
    }

    var lastDependencyOutput: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedDependencyOutput
    }

    func scanMavenProject(at rootURL: URL, files: [URL]) throws -> MavenProject? {
        project
    }

    func mavenLaunchPlan(
        at rootURL: URL,
        context: MavenLaunchContext,
        module: String?,
        goals: [String]
    ) throws -> MavenLaunchPlan {
        lock.lock()
        recordedContext = context
        recordedModule = module
        recordedGoals = goals
        lock.unlock()
        return plan
    }

    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }

    func mavenDependencyPlan(
        at rootURL: URL,
        context: MavenLaunchContext,
        module: String?
    ) throws -> MavenLaunchPlan {
        lock.lock()
        recordedDependencyModule = module
        lock.unlock()
        return plan
    }

    func mavenDependencies(modulePath: String, output: String) throws -> MavenDependencyTree {
        lock.lock()
        recordedDependencyOutput = output
        lock.unlock()
        return dependencyTree
    }
}

private final class FingerprintingMavenOperations: MavenProjectOperations, @unchecked Sendable {
    private let project: MavenProject

    init(project: MavenProject) {
        self.project = project
    }

    func scanMavenProject(at rootURL: URL, files: [URL]) throws -> MavenProject? {
        project
    }

    func mavenLaunchPlan(
        at rootURL: URL,
        context: MavenLaunchContext,
        module: String?,
        goals: [String]
    ) throws -> MavenLaunchPlan {
        MavenLaunchPlan(
            version: 1,
            toolchain: "project-maven",
            arguments: goals,
            workingDirectory: context.reactorPath,
            configurationFingerprint: context.skipTests ? "sha256:skip-tests" : "sha256:run-tests"
        )
    }

    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] { [] }
}

private final class RecordingMavenConfigurationStore: MavenConfigurationStoring, @unchecked Sendable {
    private let configuration: MavenStoredConfiguration

    init(configuration: MavenStoredConfiguration) {
        self.configuration = configuration
    }

    func loadMavenConfiguration(
        workspaceURL: URL,
        reactorPath: String
    ) throws -> MavenStoredConfiguration {
        configuration
    }

    func saveMavenConfiguration(
        _ configuration: MavenStoredConfiguration,
        workspaceURL: URL,
        reactorPath: String
    ) throws {}
}

@MainActor
private final class MavenRecordingRuntime: MavenRuntimePort {
    private(set) var lastMavenOverride: String?

    func mavenExecutable(for project: MavenProject, overridePath: String?) -> URL? {
        lastMavenOverride = overridePath
        return URL(fileURLWithPath: "/test/bin/mvn")
    }

    func mavenProcessEnvironment(javaHomePath: String?) -> [String: String] {
        ["TEST_JAVA_HOME": javaHomePath ?? ""]
    }
}

private final class MavenRecordingProcess: StreamingProcess, @unchecked Sendable {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?

    private let stream: AsyncStream<ProcessRequest>
    private let continuation: AsyncStream<ProcessRequest>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    func start(_ request: ProcessRequest) throws {
        isRunning = true
        continuation.yield(request)
    }

    func send(_ input: Data) throws {}
    func stop() { isRunning = false }

    func nextStart(timeout: Duration) async -> ProcessRequest? {
        await withTaskGroup(of: ProcessRequest?.self) { group in
            let stream = stream
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private struct TestRunFileAccess: RunFileAccess {
    let contents: [URL: String]

    init(contents: [URL: String] = [:]) {
        self.contents = contents
    }

    func isDirectory(at url: URL) -> Bool { false }
    func readData(from url: URL) throws -> Data {
        Data((contents[url.standardizedFileURL] ?? "").utf8)
    }
}

@MainActor
private final class TestRunPreferences: RunPreferenceStore {
    func data(forKey key: String) -> Data? { nil }
    func string(forKey key: String) -> String? { nil }
    func setData(_ data: Data, forKey key: String) {}
    func setString(_ value: String, forKey key: String) {}
}

private struct TestServerPortParser: RunServerPortParsing {
    func serverPort(content: String, fileExtension: String) -> Int? { nil }
}

private struct FixedServerPortParser: RunServerPortParsing {
    let port: Int?
    func serverPort(content _: String, fileExtension _: String) -> Int? { port }
}

private struct SingleRunConfigurationOperations: RunConfigurationOperations {
    let configuration: RunConfiguration
    let options: RunOptions

    func inspect(at _: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at _: URL, files _: [URL], modulePaths _: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(configuration: configuration, options: options)],
            diagnostics: [],
            defaultConfigurationID: configuration.id
        )
    }
    func launchPlan(
        at _: URL,
        configurationID _: String,
        currentFile _: String?,
        classPath _: String?,
        debugPort _: Int?
    ) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Not required by the port resolution test")
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at _: URL) throws -> String { draft.name }
    func migrateLegacySettings(at _: URL, configurationIDs _: [String]) throws {}
}

@MainActor
private final class TestExecutableResolver: RunExecutableResolving {
    func resolve(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) throws -> ResolvedRunExecutable {
        ResolvedRunExecutable(executableURL: URL(fileURLWithPath: "/test"), environment: [:])
    }
    func refreshCandidates(projectURL: URL) async {}
    func candidates(projectURL: URL) -> [ProjectToolchainCandidate] { [] }
}

private struct TestRunConfigurationOperations: RunConfigurationOperations {
    var inspectionGate: ReloadScanGate? = nil
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        if let inspectionGate {
            inspectionGate.entered.continuation.yield(())
            if inspectionGate.release.wait(timeout: .now() + 2) != .success {
                Issue.record("Run inspection was not released before its deadline")
            }
        }
        return ProjectRunConfigurationInspection(status: .missing, diagnostics: [])
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 0)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(configurations: [], diagnostics: [], defaultConfigurationID: nil)
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Unavailable in lifecycle test")
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String { draft.name }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

/// Records the file inventory each generation attempt was given, so a test can
/// prove both that a pending workspace never reaches the store and that a ready
/// one is scanned with the complete inventory.
private final class RecordingRunConfigurationOperations: RunConfigurationOperations, @unchecked Sendable {
    private(set) var generatedInventories: [[URL]] = []

    var generateCallCount: Int { generatedInventories.count }

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(
            status: generatedInventories.isEmpty ? .missing : .ready,
            diagnostics: []
        )
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        generatedInventories.append(files)
        return RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(
                configuration: .currentFile,
                options: RunOptions()
            )],
            diagnostics: [],
            defaultConfigurationID: RunConfiguration.currentFileID
        )
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Unavailable in identification test")
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String { draft.name }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

/// Reports an unreadable configuration so a test can observe the failed state.
private struct FailingInspectionRunConfigurationOperations: RunConfigurationOperations {
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(
            status: .invalid("generated.json is invalid"),
            diagnostics: [],
            recoveryAction: .editConfiguration
        )
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 0)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(configurations: [], diagnostics: [], defaultConfigurationID: nil)
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Unavailable in inspection test")
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String { draft.name }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

private struct TestReadyRunConfigurationOperations: RunConfigurationOperations {
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(
                configuration: .currentFile,
                options: RunOptions()
            )],
            diagnostics: [],
            defaultConfigurationID: RunConfiguration.currentFileID
        )
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "The extension must supply this launch plan")
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String { draft.name }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

private struct TestGoProjectRunConfigurationOperations: RunConfigurationOperations {
    private let configuration = RunConfiguration(
        id: "go:api",
        name: "Go API",
        kind: .process(provider: "go.main"),
        execution: .application,
        modulePath: "cmd/api",
        mainClass: nil
    )

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(
                configuration: configuration,
                options: RunOptions()
            )],
            diagnostics: [],
            defaultConfigurationID: configuration.id
        )
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        SharedLaunchPlan(
            executable: .toolchain("project-go"),
            arguments: ["run", "./cmd/api"],
            workingDirectory: "."
        )
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String { draft.name }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

@MainActor
private final class TestGoRunExtension: LanguageRunExtensionProviding, LanguageTestExtensionProviding {
    let languageID = "go"
    private let executionSession: any LanguageExecutionSession

    init(session: any LanguageExecutionSession) {
        executionSession = session
    }

    func makeExecutionSession() -> any LanguageExecutionSession { executionSession }
    func makeTestExecutionSession() -> any LanguageExecutionSession { executionSession }

    func launchPlan(for request: LanguageRunExtensionRequest) throws -> LanguageRunExtensionPlan {
        LanguageRunExtensionPlan(
            executable: .toolchain("project-go"),
            arguments: ["run", request.relativeFilePath] + request.arguments,
            environment: request.environment
        )
    }

    func discoverTests(
        for request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem] {
        [LanguageTestExtensionItem(id: "go:workspace", label: "All Go Tests", kind: .workspace)]
            + request.relativeProjectFilePaths
                .filter { $0.hasSuffix("_test.go") }
                .map {
                    LanguageTestExtensionItem(
                        id: "go:file:" + $0,
                        label: $0,
                        kind: .file,
                        relativeFilePath: $0
                    )
                }
    }

    func testPlan(for request: LanguageTestExtensionRequest) throws -> LanguageTestExtensionPlan {
        let package: String
        switch request.scope {
        case .workspace:
            package = "./..."
        case .file(let path), .testCase(_, let path?):
            package = "./" + path.split(separator: "/").dropLast().joined(separator: "/")
        case .testCase(_, nil):
            package = "./..."
        }
        return LanguageTestExtensionPlan(
            label: "Go Tests",
            frameworkID: "go",
            launchPlan: LanguageRunExtensionPlan(
                executable: .toolchain("project-go"),
                arguments: ["test", package]
            )
        )
    }
}

@MainActor
private final class TestLanguageExecutionSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    private(set) var startRequests: [LanguageExecutionProcessRequest] = []

    func start(_ request: LanguageExecutionProcessRequest) throws {
        startRequests.append(request)
        isRunning = true
        onStateChange?(LanguageExecutionLifecycleEvent(
            operationID: request.operationID,
            state: .running
        ))
    }

    func stop() { isRunning = false }
}
@MainActor private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

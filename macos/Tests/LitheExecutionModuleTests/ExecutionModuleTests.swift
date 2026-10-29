import Combine
import Foundation
import LitheApplicationKernel
@testable import LitheExecutionModule
import LitheCoreContracts
import LitheModuleAPI
import Testing

@MainActor
struct ExecutionModuleTests {
    @Test
    func backendTestsPreserveProjectIdentityAndRerunWithFreshFactsWithoutAHostProcess() async throws {
        var processes = 0
        let service = LanguageTestService(executableResolver: TestExecutableResolver(), processFactory: {
            processes += 1; return TestStreamingProcess()
        })
        defer { service.reset() }
        let report = try JSONDecoder().decode(BuildTestResults.self, from: Data(#"{"tests":[{"project":"a","suite":"Same","case":"checks","status":"failed"},{"project":"b","suite":"Same","case":"checks","status":"passed"}],"summary":{"total":2,"passed":1,"failed":1,"errors":0,"skipped":0},"success":false}"#.utf8))
        var requests = 0
        service.runUsingBackend(providerID: "java", scope: .workspace, workspaceURL: URL(fileURLWithPath: "/workspace"), label: "Tests") { output, _ in
            requests += 1
            output("request \(requests)")
            return LanguageTestBackendResult(exitCode: 1, reports: [report])
        }
        try await awaitTestValue(service.$state) { $0 == .failed(exitCode: 1) }
        #expect(service.results?.testsRun == 2)
        #expect(service.testOutcomes.map(\.project) == ["a", "b"])
        #expect(service.canRerun)
        #expect(service.rerun())
        try await awaitTestValue(service.$state) { $0 == .failed(exitCode: 1) }
        #expect(requests == 2)
        #expect(service.output == "request 2")
        #expect(service.testOutcomes.count == 2)
        #expect(processes == 0)
    }

    @Test
    func backendCoverageClearsRemovedClassMethodsButPreservesMethodSiblingsAndOtherProjects() async throws {
        let service = LanguageTestService(executableResolver: TestExecutableResolver(), processFactory: { TestStreamingProcess() })
        defer { service.reset() }
        func run(_ tests: [[String: String]], coverage: [[String: String]]? = nil) async throws {
            var json: [String: Any] = ["tests": tests, "summary": ["total": tests.count, "passed": tests.count, "failed": 0, "errors": 0, "skipped": 0], "success": true]
            if let coverage { json["coverage"] = coverage }
            let report = try JSONDecoder().decode(BuildTestResults.self, from: JSONSerialization.data(withJSONObject: json))
            service.runUsingBackend(providerID: "java", scope: .workspace, workspaceURL: URL(fileURLWithPath: "/workspace"), label: "Tests") { _, _ in
                LanguageTestBackendResult(exitCode: 0, reports: [report])
            }
            try await awaitTestValue(service.$state) { $0 == .passed }
        }
        func test(_ project: String, _ method: String) -> [String: String] {
            ["project": project, "suite": "Same", "case": method, "status": "passed"]
        }
        try await run([test("a", "old"), test("a", "kept"), test("b", "old")])
        try await run([test("a", "kept")], coverage: [["project": "a", "suite": "Same", "case": "kept"]])
        #expect(service.testOutcomes.count == 3)
        try await run([test("a", "new")], coverage: [["project": "a", "suite": "Same"]])
        #expect(service.testOutcomes.map { ($0.project ?? "") + ":" + $0.method }.sorted() == ["a:new", "b:old"])
        try await run([], coverage: [["project": "a", "suite": "Same"]])
        #expect(service.testOutcomes.map(\.project) == ["b"])
    }

    @Test
    func backendTestsIgnoreCancelledRequestsThatReturnAfterReplacement() async throws {
        let service = LanguageTestService(executableResolver: TestExecutableResolver(), processFactory: { TestStreamingProcess() })
        var observedProcesses: [Int32] = []
        let observation = service.$processID.sink { if let pid = $0 { observedProcesses.append(pid) } }
        defer { observation.cancel() }
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        defer { service.reset(); entered.continuation.finish(); release.continuation.finish(); finished.continuation.finish() }
        service.runUsingBackend(providerID: "java", scope: .workspace, workspaceURL: URL(fileURLWithPath: "/old"), label: "Old") { output, process in
            entered.continuation.yield(())
            for await _ in release.stream { break }
            process(999)
            output("late old output")
            finished.continuation.yield(())
            return LanguageTestBackendResult(exitCode: 3, reports: [])
        }
        try await awaitSignal(entered.stream)
        service.stop()
        #expect(service.state == .cancelled)
        service.runUsingBackend(providerID: "java", scope: .workspace, workspaceURL: URL(fileURLWithPath: "/new"), label: "New") { output, process in
            process(412)
            output("new output")
            return LanguageTestBackendResult(exitCode: 0, reports: [])
        }
        release.continuation.yield(())
        try await awaitSignal(finished.stream)
        try await awaitTestValue(service.$state) { $0 == .passed }
        #expect(service.output == "new output")
        #expect(service.errorMessage == nil)
        #expect(observedProcesses.contains(412))
        #expect(!observedProcesses.contains(999))
        #expect(service.processID == nil)
    }

    @Test
    func projectLoadingUsesProviderFactsAndRevokesTheirProjectionWhenTheModelDisappears() async {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let graph = makeTestGraph(runOperations: TestReadyRunConfigurationOperations())
        defer { graph.stop() }
        var models = [BuildModel(projects: [.init(id: "module", path: "apps/service", name: "Service")],
            optionValues: ["profiles": ["qa", "ci", "qa"]])]
        graph.run.configureBuildModels { models }
        // POM files are inventory entries. Opening them cannot create another
        // Maven scanner, run its toolchain, or inject a second project model.
        await graph.projectDevelopment.loadProject(at: root, files: [root.appendingPathComponent("pom.xml")], snapshotID: UUID())
        #expect(graph.run.hasReadyInventory(for: root))
        #expect(graph.run.sourceSearchRoots == [root, root.appendingPathComponent("apps/service", isDirectory: true)])
        #expect(graph.run.mavenProfiles.map(\.id) == ["ci", "qa"])
        models = []
        #expect(graph.run.sourceSearchRoots == [root])
        #expect(graph.run.mavenProfiles.isEmpty)
        await graph.projectDevelopment.loadProject(at: URL(fileURLWithPath: "/other"), files: [], snapshotID: UUID())
        #expect(graph.run.sourceSearchRoots.map(\.path) == ["/other"])
    }

    @Test
    func providerLaunchUsesNativeProcessAndOldOwnerCannotStopReplacement() async throws {
        let process = TestStreamingProcess()
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let resolver = TestExecutableResolver()
        let service = RunService(runtime: TestRuntime(), process: process, processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(directories: [root.appendingPathComponent("app", isDirectory: true)]),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: TestRunConfigurationOperations(toolchain: ProjectToolchainSelection(javaHomePath: "/fixture/jdk"),
                rejectsResolutionWithoutGeneratedDocument: true),
            executableResolver: resolver,
            languageProviderCatalog: .compatibilityFallback, languageRunProviders: .standard(catalog: .compatibilityFallback))
        defer { service.reset() }
        let launch = try JSONDecoder().decode(BuildRunPreparation.self, from: Data(
            #"{"executable":{"kind":"command","value":"java"},"arguments":["Main","a b"],"workingDirectory":"app","environment":{}}"#.utf8))
        let old = try service.launchPreparedRun(launch, workspaceURL: root, title: "Provider Main")
        let oldOutput = process.onOutput
        let oldTermination = process.onTermination
        let current = try service.launchPreparedRun(launch, workspaceURL: root, title: "Replacement")
        let request = try #require(process.startRequests.last)
        #expect(request.operationID == current)
        #expect(request.arguments == ["Main", "a b"])
        #expect(request.workingDirectory == "/workspace/app")
        #expect(service.primaryExecutionID == current)
        #expect(resolver.lastOptions?.javaHomePath == "/fixture/jdk")
        #expect(service.lastConfiguration == nil)
        let received = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = service.$output.sink { if $0.contains("replacement output") { received.continuation.yield(()) } }
        defer { observation.cancel(); received.continuation.finish() }
        oldOutput?("stale output")
        oldTermination?(7)
        process.onOutput?("replacement output")
        try await awaitSignal(received.stream)
        #expect(!service.output.contains("stale output"))
        #expect(service.lastExitCode == nil)
        service.stopPreparedRun(old)
        #expect(service.isRunning)
        service.stopPreparedRun(current)
        #expect(!service.isRunning)
        #expect(!process.isRunning)
    }

    @Test(arguments: [false, true])
    func providerLaunchFailureLeavesNoRunningProcess(invalidDirectory: Bool) throws {
        let process = TestStreamingProcess()
        process.startFailure = RunFixtureError.failed
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let service = RunService(runtime: TestRuntime(), process: process, processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(directories: invalidDirectory ? [] : [root]),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: TestRunConfigurationOperations(), executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback, languageRunProviders: .standard(catalog: .compatibilityFallback))
        defer { service.reset() }
        let launch = try JSONDecoder().decode(BuildRunPreparation.self, from: Data(
            #"{"executable":{"kind":"command","value":"java"},"arguments":[],"workingDirectory":".","environment":{}}"#.utf8))
        #expect(throws: (any Error).self) { _ = try service.launchPreparedRun(launch, workspaceURL: root, title: "Main") }
        #expect(!service.isRunning)
        #expect(!process.isRunning)
    }

    @Test
    func savedProviderRunRepreparesAndStopCancelsOnlyItsPreparation() async throws {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let process = TestStreamingProcess()
        let reference = BuildProviderRunReference(pluginID: "dev.example", buildSystemID: "fixture", root: ".",
            run: "application", projectID: "p", targetID: "t", userArguments: ["a b"])
        let configuration = RunConfiguration(id: "user:provider", name: "Main", kind: .process(provider: "build.provider"),
            modulePath: nil, mainClass: nil, buildProvider: reference)
        let service = RunService(runtime: TestRuntime(), process: process, processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(directories: [root]), preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: TestRunConfigurationOperations(savedProvider: reference), executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback, languageRunProviders: .standard(catalog: .compatibilityFallback))
        defer { service.reset() }
        let launch = try JSONDecoder().decode(BuildRunPreparation.self, from: Data(
            #"{"executable":{"kind":"command","value":"java"},"arguments":["Main"],"workingDirectory":".","environment":{}}"#.utf8))
        _ = try service.launchPreparedRun(launch, workspaceURL: root, title: "Main", configuration: configuration)
        #expect(service.saveBuildProviderConfiguration())
        #expect(service.lastConfiguration?.id == "user:provider")
        let feature = RunFeatureModel(service: service)
        #expect(feature.configurations.first { $0.id == "user:provider" }?.buildProvider == reference)
        var calls: [BuildProviderRunReference] = []
        var cancellations: [UUID] = []
        var id = UUID()
        service.configureBuildProviderRuns(start: { config, workspace in
            #expect(workspace == root)
            if let reference = config.buildProvider { calls.append(reference) }
            return id
        }, cancel: { cancellations.append($0) })
        service.restart()
        #expect(feature.isRunning)
        #expect(service.isPreparingBuildRun)
        #expect(service.primaryExecutionID == id.uuidString)
        #expect(!process.isRunning)
        let old = id
        service.stop()
        #expect(cancellations == [old])
        #expect(!feature.isRunning)
        id = UUID()
        service.restart()
        service.finishBuildPreparation(old, message: "stale failure")
        #expect(service.isPreparingBuildRun)
        _ = try service.launchPreparedRun(launch, workspaceURL: root, title: "Main", configuration: configuration)
        #expect(service.primaryExecutionID == id.uuidString)
        #expect(!service.isPreparingBuildRun)
        #expect(cancellations == [old])
        #expect(calls == [reference, reference])
        #expect(process.startRequests.count == 2)
        #expect(feature.isSelectedConfigurationRunning)
        await service.loadProject(at: URL(fileURLWithPath: "/other"), files: [])
        #expect(!process.isRunning)
        #expect(!service.hasBuildProviderRun)
        #expect(service.lastConfiguration == nil)
        #expect(service.primaryExecutionID == nil)
    }

    @Test(arguments: ["services/alpha", "services/beta"])
    func moduleRunPassesMavenContextOnlyToItsOwningReactor(reactor: String) async {
        let configuration = RunConfiguration(
            id: "main", name: "Main", kind: .javaMain, modulePath: ".", mainClass: "example.Main",
            mavenReactorPath: reactor)
        let operations = MavenContextRunOperations(configuration: configuration)
        let graph = makeTestGraph(runOperations: operations)
        defer { graph.run.reset() }
        let context = MavenLaunchContext(reactorPath: "services/alpha", profiles: ["dev"],
                                         settingsPath: "/fixture/settings.xml", skipTests: true,
                                         mavenExecutablePath: nil, javaHomePath: nil)
        graph.run.configureBuildLanguageImportProvider { workspace, requestedRoot in
            #expect(workspace.path == "/workspace")
            #expect(requestedRoot == reactor)
            return .init(mavenContext: context)
        }
        await graph.run.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])
        #expect(graph.run.defaultConfigurationID == configuration.id)
        graph.run.startConfiguration(configuration)
        #expect(operations.called)
        #expect(operations.context == (reactor == context.reactorPath ? context : nil))
        // A failed plan remains in the existing Run output and supports a retry.
        #expect(graph.run.moduleSessions.first?.exitCode == 1)
    }

    @Test(arguments: ["complete", "reset", "switch", "cancel"])
    func projectLoadAwaitsToolchainProbesWithoutBlockingOrApplyingStaleResults(outcome: String) async throws {
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let runtime = TestRuntime()
        let root = URL(fileURLWithPath: "/workspace")
        let other = URL(fileURLWithPath: "/other")
        runtime.loadCandidates = { target in
            if target == root {
                entered.continuation.yield(())
                try await awaitSignal(release.stream)
            }
            return []
        }
        let service = RunService(
            runtime: runtime, process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: SingleRunConfigurationOperations(configuration: .currentFile, options: RunOptions()),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let snapshotID = UUID()
        let loading = Task { await service.loadProject(at: root, files: [], snapshotID: snapshotID) }
        defer {
            loading.cancel()
            entered.continuation.finish()
            release.continuation.finish()
            service.reset()
        }
        do {
            try await awaitSignal(entered.stream)
        } catch {
            release.continuation.finish()
            loading.cancel()
            await loading.value
            throw error
        }
        // This actor continues to run while the real load path awaits its port.
        #expect(runtime.synchronousToolchainCalls == 0)
        #expect(service.isLoadingProject)
        #expect(!service.isProjectReady(for: root, snapshotID: snapshotID))
        switch outcome {
        case "reset": service.reset()
        case "switch": await service.loadProject(at: other, files: [])
        case "cancel": loading.cancel()
        default: break
        }
        release.continuation.yield(())
        await loading.value
        switch outcome {
        case "reset": #expect(service.projectLoadState == .idle && service.configurations == [.currentFile])
        case "switch": #expect(service.projectLoadState == .bound(workspace: other) && !service.isLoadingProject)
        case "cancel": #expect(service.defaultConfigurationID == nil)
        default:
            #expect(service.defaultConfigurationID == RunConfiguration.currentFileID)
            #expect(service.isProjectReady(for: root, snapshotID: snapshotID))
        }
        #expect(runtime.synchronousToolchainCalls == 0)
    }

    @Test
    func overlappingProjectLoadsDoNotPersistTheProvisionalCurrentFileSelection() async throws {
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let runtime = TestRuntime()
        var probes = 0
        runtime.loadCandidates = { _ in
            probes += 1
            if probes == 1 {
                entered.continuation.yield(())
                try await awaitSignal(release.stream)
            }
            return []
        }
        let configuration = RunConfiguration(
            id: "main", name: "Main", kind: .javaMain, modulePath: nil, mainClass: "demo.App")
        let service = RunService(
            runtime: runtime, process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: SelectionRunConfigurationOperations(configurations: [configuration]),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let root = URL(fileURLWithPath: "/workspace")
        let snapshot = UUID()
        let loading = Task { await service.loadProject(at: root, files: [], snapshotID: snapshot) }
        defer {
            loading.cancel()
            entered.continuation.finish()
            release.continuation.finish()
            service.reset()
        }
        do {
            try await awaitSignal(entered.stream)
        } catch {
            release.continuation.finish()
            await loading.value
            throw error
        }
        // An entry point must not consume the inventory before its configuration
        // resolves. A concurrent snapshot load must not save the initial placeholder.
        #expect(!service.isProjectReady(for: root, snapshotID: snapshot))
        await service.loadProject(at: root, files: [], snapshotID: snapshot)
        #expect(service.selectedConfigurationID == configuration.id)
        #expect(service.isProjectReady(for: root, snapshotID: snapshot))
        release.continuation.yield(())
        await loading.value
        #expect(service.selectedConfigurationID == configuration.id)
        // A completed user's explicit Current File choice still survives reload.
        service.selectedConfigurationID = RunConfiguration.currentFileID
        await service.loadProject(at: root, files: [], snapshotID: snapshot)
        #expect(service.selectedConfigurationID == RunConfiguration.currentFileID)
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
        await argumentService.loadProject(at: root, files: [properties])
        #expect(argumentService.configuredServerPort(for: configuration) == 18082)

        let environmentService = makeRunService(
            configuration: configuration,
            options: RunOptions(environment: ["SERVER_PORT": "18083"]),
            fileAccess: TestRunFileAccess(contents: [properties: "server.port=18084"]),
            serverPortParser: FixedServerPortParser(port: 18084)
        )
        await environmentService.loadProject(at: root, files: [properties])
        #expect(environmentService.configuredServerPort(for: configuration) == 18083)

        let resourceService = makeRunService(
            configuration: configuration,
            options: RunOptions(),
            fileAccess: TestRunFileAccess(contents: [properties: "server.port=18084"]),
            serverPortParser: FixedServerPortParser(port: 18084)
        )
        await resourceService.loadProject(at: root, files: [properties])
        #expect(resourceService.configuredServerPort(for: configuration) == 18084)

        let defaultService = makeRunService(
            configuration: configuration,
            options: RunOptions(),
            fileAccess: TestRunFileAccess(),
            serverPortParser: FixedServerPortParser(port: nil)
        )
        await defaultService.loadProject(at: root, files: [])
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
    func serviceUpdateUsesTheRunningTargetAndDiscardsResultsAfterStop() async throws {
        let configuration = RunConfiguration(
            id: "service:update", name: "Service", kind: .javaMain,
            execution: .service, modulePath: nil, mainClass: "example.Main", sourcePath: "src/Main.java"
        )
        let service = RunService(
            runtime: TestRuntime(), process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: SelectionRunConfigurationOperations(configurations: [configuration]),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])
        let target = JavaDebugLaunchTarget(mainClass: "example.Main", projectName: "app",
            classPaths: ["/workspace/classes", "/repository/spring-boot-devtools-3.5.0.jar"])
        service.startConfiguration(configuration, javaLaunch: target)
        let feature = RunFeatureModel(service: service)
        let running = try #require(feature.moduleSessions.first)
        #expect(feature.canUpdateService(running))
        await feature.updateService(running) { receivedTarget, source in
            #expect(receivedTarget == target)
            #expect(source.path == "/workspace/src/Main.java")
            feature.stopModule(running)
        }
        #expect(feature.serviceUpdateMessage == nil)
        #expect(feature.updatingServiceExecutionID == nil)
        #expect(!feature.canUpdateService(try #require(feature.moduleSessions.first)))
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
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])
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

    /// Issue #507: editing a run document changes no project input, so the
    /// service must not re-read every input on the main actor, and the
    /// freshness warning the load reported must stay visible.
    @Test
    func documentEditsKeepFreshnessWithoutRereadingProjectInputs() async {
        let operations = FreshnessRecordingRunConfigurationOperations()
        let service = makeFreshnessRecordingService(operations)
        defer { service.reset() }
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])
        #expect(service.configurationDiagnostics.map(\.code) == ["staleFingerprint"])

        let created = service.createConfiguration(RunConfigurationDraft(
            name: "Custom", kind: .javaMain, modulePath: ".", mainClass: "demo.Custom", scope: .project
        ))

        #expect(created)
        #expect(operations.fingerprintChecks == [true, false])
        #expect(service.configurationDiagnostics.map(\.code) == ["staleFingerprint"])
    }

    /// A main method added to an existing class is found by comparing JDT's
    /// answer with the generated entries, once per distinct message.
    @Test
    func jdtFreshnessIsReportedOnceWithoutHashingInputs() async {
        let operations = FreshnessRecordingRunConfigurationOperations()
        operations.inputsChanged = false
        let service = makeFreshnessRecordingService(operations)
        defer { service.reset() }
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])
        #expect(service.configurationDiagnostics.isEmpty)

        let entrypoints = JavaEntrypoints(entries: [])
        await service.reportJavaEntrypointFreshness(entrypoints)
        await service.reportJavaEntrypointFreshness(entrypoints)

        #expect(operations.fingerprintChecks == [true, false, false])
        #expect(operations.comparedEntrypoints == [entrypoints, entrypoints])
        #expect(service.configurationDiagnostics.map(\.message) == [
            "Java entry points changed: 1 added, 0 removed",
        ])
    }

    private func makeFreshnessRecordingService(
        _ operations: FreshnessRecordingRunConfigurationOperations
    ) -> RunService {
        RunService(
            runtime: TestRuntime(), process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
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
        await service.loadProject(at: root, files: [])
        #expect(service.projectLoadState == .bound(workspace: root))
        #expect(!service.isProjectReady(for: root, snapshotID: UUID()))
        await service.generateRunConfigurations()
        #expect(service.generationState == .projectNotReady)
        #expect(operations.generateCallCount == 0)

        let snapshotID = UUID()
        await service.loadProject(at: root, files: [], snapshotID: snapshotID)
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
        await service.loadProject(at: root, files: [])
        await service.generateRunConfigurations()
        #expect(service.generationState == .projectNotReady)
        #expect(operations.generatedInventories.isEmpty, "a provisional inventory must not be scanned")

        await service.loadProject(
            at: root,
            files: [source],
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

        await service.loadProject(at: root, files: [], snapshotID: snapshotID)

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
        await service.loadProject(at: root, files: [source])
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
            files: [root.appendingPathComponent("go.mod")]
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
    func dependencyBrowserRequiresExplicitLanguageRegistration() async throws {
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(contents: [
                URL(fileURLWithPath: "/workspace/go.mod"): "module example.dev/api"
            ]),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: TestGoProjectRunConfigurationOperations(),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let goModule = root.appendingPathComponent("go.mod")
        let main = root.appendingPathComponent("cmd/api/main.go")

        await service.loadProject(at: root, files: [goModule, main])

        #expect(service.configurations.contains { $0.id == "go:api" })
        #expect(service.dependencyServices.isEmpty)
        #expect(try await service.resolveDependencies(serviceID: "go:api") == nil)
        service.registerDependencySource(languageID: "go", displayName: "Go")
        service.registerDependencySource(languageID: "go", displayName: "Go")
        let dependencyService = try #require(service.dependencyServices.first)
        #expect(service.dependencyServices.count == 1)
        #expect(dependencyService.id == "language:go")
        #expect(dependencyService.displayName == "Go")
        #expect(dependencyService.providerID == "go")

        service.updateDependencyPaths(
            DependencyPathConfiguration(dependencyPaths: ["vendor/modules"]),
            serviceID: dependencyService.id
        )
        let graph = try #require(
            try await service.resolveDependencies(serviceID: dependencyService.id)
        )
        let rootNode = try #require(graph.roots.first)
        #expect(rootNode.title == "Go")
        #expect(rootNode.subtitle == "Go")
        #expect(rootNode.children[0].children.isEmpty)
        #expect(rootNode.children[2].children.map(\.id) == ["/workspace/vendor/modules"])

        let revision = service.dependencyRevision
        service.markDependencyFilesChanged([WorkspaceFileChange(fileURL: goModule, kind: .changed)])
        #expect(service.dependencyRevision == revision + 1)
        service.unregisterDependencySource(languageID: "go")
        #expect(service.dependencyServices.isEmpty)
        #expect(try await service.resolveDependencies(serviceID: dependencyService.id) == nil)
    }

    @Test(arguments: ["docker.compose", "node.script", "java.main"])
    func runConfigurationsDoNotInjectDependencySources(provider: String) async {
        let configuration = RunConfiguration(
            id: "run:\(provider)", name: provider,
            kind: .process(provider: provider), modulePath: ".", mainClass: nil
        )
        let service = makeRunService(
            configuration: configuration,
            options: RunOptions(),
            fileAccess: TestRunFileAccess(),
            serverPortParser: FixedServerPortParser(port: nil)
        )
        defer { service.reset() }
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])

        #expect(service.configurations.contains { $0.id == configuration.id })
        #expect(service.dependencyServices.isEmpty)
    }

    @Test
    func languagePluginContributesResolvedRootsAndVirtualDocuments() async throws {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let moduleFile = root.appendingPathComponent("go.mod")
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            dependencies: LanguageDependencyDeclaration(
                managementFileNames: ["go.mod", "go.sum", "vendor/modules.txt"],
                projectDependencyPaths: ["vendor"]
            ),
            virtualDocumentSchemes: ["gopls"],
            languageServerModuleID: .languageServerExtension("go")
        )
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(
                contents: [moduleFile: "module example.dev/api"],
                directories: [root.appendingPathComponent("vendor", isDirectory: true)]
            ),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: TestGoProjectRunConfigurationOperations(),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback),
            languageSupports: [support]
        )
        defer { service.reset() }
        let virtualURI = try #require(URL(string: "gopls://example.dev/api/external.go"))
        var resolvedRoot = URL(fileURLWithPath: "/modules/example.dev/api", isDirectory: true)
        service.configureLanguageDependencyProvider { languageID, workspace, serviceID in
            guard languageID == "go", workspace == root, serviceID == "language:go" else { return nil }
            return LanguageDependencySnapshot(
                binaryRoots: [root.appendingPathComponent("bin", isDirectory: true)],
                dependencyRoots: [resolvedRoot, root.appendingPathComponent("vendor", isDirectory: true),
                                  URL(fileURLWithPath: "/workspace-other/valid", isDirectory: true), resolvedRoot],
                virtualDocuments: [.init(title: "external.go", uri: virtualURI)]
            )
        }
        await service.loadProject(at: root, files: [moduleFile])
        #expect(service.dependencyServices.isEmpty)
        service.registerDependencySource(languageID: "go", displayName: "Go")
        let graph = try #require(try await service.resolveDependencies(serviceID: "language:go"))
        let groups = try #require(graph.roots.first?.children)
        #expect(groups[1].children.isEmpty)
        #expect(groups[2].children.map(\.id) == [
            "/modules/example.dev/api", "/workspace-other/valid", virtualURI.absoluteString
        ])
        #expect(groups[2].children.last?.source == .virtualDocument(virtualURI))

        service.updateDependencyPaths(
            DependencyPathConfiguration(dependencyPaths: ["vendor"]), serviceID: "language:go"
        )
        let configured = try #require(try await service.resolveDependencies(serviceID: "language:go"))
        #expect(configured.roots.first?.children[2].children.map(\.id) == [
            "/modules/example.dev/api", "/workspace-other/valid", "/workspace/vendor", virtualURI.absoluteString
        ])

        let revision = service.dependencyRevision
        service.syncLanguageDependencyPaths(languageID: "go")
        #expect(service.dependencyRevision == revision)
        resolvedRoot = URL(fileURLWithPath: "/modules/example.dev/new-api", isDirectory: true)
        service.syncLanguageDependencyPaths(languageID: "go")
        #expect(service.dependencyRevision == revision + 1)
        let refreshed = try #require(try await service.resolveDependencies(serviceID: "language:go"))
        #expect(refreshed.roots.first?.children[2].children.first?.id == resolvedRoot.path)
        let repeatGraph = try #require(try await service.resolveDependencies(serviceID: "language:go"))
        #expect(repeatGraph == refreshed)
        service.configureLanguageDependencyProvider { _, _, _ in nil }
        service.syncLanguageDependencyPaths(languageID: "go")
        #expect(service.dependencyRevision == revision + 1)
        let cached = try #require(try await service.resolveDependencies(serviceID: "language:go"))
        #expect(cached == refreshed)

        let refreshedRevision = service.dependencyRevision
        service.markDependencyFilesChanged([WorkspaceFileChange(
            fileURL: root.appendingPathComponent("package-lock.json"), kind: .created
        )])
        #expect(service.dependencyRevision == refreshedRevision)
        service.markDependencyFilesChanged([WorkspaceFileChange(
            fileURL: root.appendingPathComponent("go.sum"), kind: .created
        )])
        #expect(service.dependencyRevision == refreshedRevision + 1)
        service.markDependencyFilesChanged([WorkspaceFileChange(
            fileURL: root.appendingPathComponent("vendor/modules.txt"), kind: .created
        )])
        #expect(service.dependencyRevision == refreshedRevision + 2)
        service.markDependencyFilesChanged([WorkspaceFileChange(fileURL: moduleFile, kind: .deleted)])
        #expect(service.dependencyRevision == refreshedRevision + 3)
    }

    @Test
    func dependencyIndexSurvivesRunConfigurationApplyAndReusesPersistedGraph() async throws {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let moduleFile = root.appendingPathComponent("go.mod")
        let cachedDependency = URL(fileURLWithPath: "/external/cache/cached.jar")
        let store = TestWorkspaceDependencyStore()

        let firstService = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(contents: [moduleFile: "module example.dev/api"]),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: TestGoProjectRunConfigurationOperations(),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback),
            dependencyStore: store
        )
        defer { firstService.reset() }
        firstService.configureLanguageDependencyProvider { _, _, _ in
            LanguageDependencySnapshot(dependencyRoots: [cachedDependency])
        }
        await firstService.loadProject(at: root, files: [moduleFile])
        firstService.registerDependencySource(languageID: "go", displayName: "Go")
        _ = try await firstService.resolveDependencies(serviceID: "language:go")
        #expect(store.indexes.services["language:go"] != nil)

        let secondService = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(contents: [moduleFile: "module example.dev/api"]),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: TestGoProjectRunConfigurationOperations(),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback),
            dependencyStore: store
        )
        defer { secondService.reset() }
        secondService.configureLanguageDependencyProvider { _, _, _ in nil }
        await secondService.loadProject(at: root, files: [moduleFile])
        secondService.registerDependencySource(languageID: "go", displayName: "Go")

        let graph = try #require(
            try await secondService.resolveDependencies(serviceID: "language:go")
        )
        #expect(graph.roots.first?.children[2].children.map(\.id) == [cachedDependency.path])
    }

    @Test
    func goTestsRunThroughExtensionOwnedSession() async throws {
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
        let id = try #require(service.runID)
        extensionSession.onStateChange?(LanguageExecutionLifecycleEvent(operationID: id.uuidString,
            state: .running, processID: 201))
        try await awaitTestValue(service.$processID, matching: { $0 == 201 })


        service.unregisterLanguageTestExtension(languageID: "go")
        #expect(service.processID == nil)
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

    @Test func testProcessIdentityRejectsOldRunsAndClearsOnStop() async throws {
        let root = URL(fileURLWithPath: "/workspace/test-performance")
        let process = TestStreamingProcess()
        let service = LanguageTestService(executableResolver: TestExecutableResolver(), processFactory: { process })
        defer { service.reset() }
        #expect(service.run(providerID: "java", scope: .workspace, workspaceURL: root,
                            projectFiles: [root.appendingPathComponent("build.gradle")]))
        let firstID = try #require(service.runID)
        let firstEvent = try #require(process.onStateChange)
        firstEvent(ProcessLifecycleEvent(operationID: firstID.uuidString, state: .running,
            exitCode: nil, message: nil, processID: 101))
        try await awaitTestValue(service.$processID, matching: { $0 == 101 })
        service.stop()
        #expect(service.processID == nil)
        #expect(service.runID == firstID)
        #expect(service.rerun())
        let secondID = try #require(service.runID)
        #expect(secondID != firstID)
        firstEvent(ProcessLifecycleEvent(operationID: firstID.uuidString, state: .running,
            exitCode: nil, message: nil, processID: 999))
        process.onStateChange?(ProcessLifecycleEvent(operationID: secondID.uuidString, state: .running,
            exitCode: nil, message: nil, processID: 102))
        try await awaitTestValue(service.$processID, matching: { $0 == 102 })
        #expect(service.processID == 102)
        process.onTermination?(0)
        try await awaitTestValue(service.$state, matching: { $0 == .passed })
        #expect(service.processID == nil)
        #expect(service.runID == secondID)
        #expect(!service.run(providerID: "missing-provider", scope: .workspace,
                            workspaceURL: root, projectFiles: []))
        #expect(service.runID == nil)
        service.closeRun()
        #expect(service.runID == nil)
    }

    @Test(arguments: [false, true])
    func closingOrClearingResultsKeepsEditorHistoryAndDiscoveredScopes(clearOnly: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace/results-lifecycle")
        let first = root.appendingPathComponent("src/test/java/demo/FirstTest.java")
        let second = root.appendingPathComponent("src/test/java/demo/SecondTest.java")
        let files = [root.appendingPathComponent("pom.xml"), first, second,
            root.appendingPathComponent("package.json"), root.appendingPathComponent("sample.test.js"),
            root.appendingPathComponent("pyproject.toml"), root.appendingPathComponent("test_sample.py")]
        let report = try JSONDecoder().decode(BuildTestResults.self, from: Data(#"{"tests":[{"suite":"demo.FirstTest","case":"check","status":"passed"}],"summary":{"total":1,"passed":1,"failed":0,"errors":0,"skipped":0},"success":true}"#.utf8))
        let service = LanguageTestService(executableResolver: TestExecutableResolver(), processFactory: { TestStreamingProcess() })
        func run(_ scope: LanguageTestScope) {
            service.runUsingBackend(providerID: "java", scope: scope, workspaceURL: root, label: "Tests") { _, _ in
                LanguageTestBackendResult(exitCode: 0, reports: [report])
            }
        }
        defer { service.reset() }
        service.discover(workspaceURL: root, files: files)
        let discovered = service.itemsByProviderID
        for provider in ["java", "node", "python"] {
            #expect(discovered[provider]?.contains { $0.kind == .workspace } == true)
        }
        run(.testCase(identifier: "demo.FirstTest#check", fileURL: first))
        try await awaitTestValue(service.$state, matching: { $0 == .passed })
        let outcomes = service.testOutcomes
        #expect(service.results?.testsRun == 1)
        #expect(outcomes.first?.className == "demo.FirstTest")
        if clearOnly { service.clearOutput() } else { service.closeRun() }
        #expect(service.results == nil)
        #expect(service.testOutcomes == outcomes, "Editor marker history must outlive the visible result")
        #expect(service.itemsByProviderID == discovered)
        run(.file(second))
        #expect(service.hasRun(providerID: "java", scope: .file(second)))
        run(.workspace)
        #expect(service.hasRun(providerID: "java", scope: .workspace))
    }

    @Test(arguments: [false, true])
    func closingTestRunPreservesDiscoveryAndAllowsNewRun(completed: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace/test-tab", isDirectory: true)
        let files = [root.appendingPathComponent("build.gradle")]
        let process = TestStreamingProcess()
        let service = LanguageTestService(
            executableResolver: TestExecutableResolver(),
            processFactory: { process }
        )
        defer { service.reset() }
        service.discover(workspaceURL: root, files: files)
        let discovered = service.itemsByProviderID
        #expect(!discovered.isEmpty)
        #expect(!service.hasRun(providerID: "java", scope: .workspace))
        #expect(service.run(providerID: "java", scope: .workspace,
                            workspaceURL: root, projectFiles: files))
        #expect(service.activePlan != nil)
        #expect(!service.output.isEmpty)
        #expect(service.hasRun(providerID: "java", scope: .workspace))
        #expect(!service.hasRun(providerID: "java", scope: .file(files[0])))
        #expect(!service.hasRun(providerID: "go", scope: .workspace))
        if completed {
            process.isRunning = false
            process.onTermination?(0)
            try await awaitTestValue(service.$state, matching: { $0 == .passed })
        }

        service.closeRun()
        #expect(!process.isRunning)
        #expect(service.activePlan == nil)
        #expect(service.state == .idle)
        #expect(service.output.isEmpty)
        #expect(service.results == nil)
        #expect(service.errorMessage == nil)
        #expect(!service.canRerun)
        #expect(!service.hasRun(providerID: "java", scope: .workspace))
        #expect(service.itemsByProviderID == discovered)

        // Closing a result must leave the discovered scopes runnable.
        #expect(service.run(providerID: "java", scope: .workspace,
                            workspaceURL: root, projectFiles: files))
        #expect(service.activePlan != nil)
        #expect(service.isRunning)
    }

    @Test
    func standaloneJavaCompilesWithJavacBeforeLaunchingByClassName() async throws {
        let mainProcess = TestStreamingProcess()
        let stepProcesses = StepProcessRecorder()
        let outputDirectory = ".lithe/run/classes/java-main-Standalone"
        let configuration = RunConfiguration(
            id: "java-main:Standalone", name: "Standalone", kind: .javaMain,
            execution: .application, modulePath: nil, mainClass: "Standalone"
        )
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-jdk"),
            arguments: ["Standalone"],
            workingDirectory: ".",
            preLaunchSteps: [
                SharedLaunchPlan.PreLaunchStep(
                    executable: .toolchain("project-jdk"),
                    tool: "javac",
                    arguments: ["-d", outputDirectory, "Standalone.java"]
                )
            ],
            classpath: [outputDirectory]
        )
        let service = RunService(
            runtime: TestRuntime(), process: mainProcess,
            processFactory: { stepProcesses.make() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration, plan: plan
            ),
            executableResolver: JavacAwareExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        await service.loadProject(at: root, files: [])

        let mainStarted = AsyncStream<Void>.makeStream()
        mainProcess.onStart = { mainStarted.continuation.yield(()) }

        service.run(configuration: configuration, currentFileURL: nil)

        // The javac compile step runs first; the main process must wait for it.
        let step = try #require(stepProcesses.processes.first)
        let stepRequest = try #require(step.startRequests.first)
        #expect(stepRequest.executablePath == "/test/bin/javac")
        #expect(stepRequest.arguments == ["-d", outputDirectory, "Standalone.java"])
        // The application entry bounds its compile step exactly like Windows.
        #expect(stepRequest.timeoutMilliseconds == 600_000)
        #expect(mainProcess.startRequests.isEmpty)

        // A zero exit chains to the main process, which launches by class name
        // with the compile output prepended as `-cp`.
        step.onTermination?(0)
        try await awaitSignal(mainStarted.stream)
        let mainRequest = try #require(mainProcess.startRequests.first)
        #expect(mainRequest.executablePath == "/test/bin/java")
        #expect(mainRequest.arguments == ["-cp", outputDirectory, "Standalone"])
        #expect(service.isRunning)
    }

    @Test
    func mavenJavaMainValidatesTheProjectJDKInsteadOfTheMavenJDK() async throws {
        let moduleProcess = TestStreamingProcess()
        let configuration = RunConfiguration(
            id: "java-main:example.Main", name: "Main", kind: .javaMain,
            execution: .application, modulePath: "app", mainClass: "example.Main",
            mavenReactorPath: "."
        )
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-jdk"),
            arguments: ["example.Main"],
            workingDirectory: ".",
            classpath: ["/workspace/app/target/classes"]
        )
        let service = RunService(
            runtime: TestRuntime(javaHome: URL(fileURLWithPath: "/valid/project-jdk")),
            process: TestStreamingProcess(),
            processFactory: { moduleProcess },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration,
                plan: plan,
                options: RunOptions(
                    javaHomePath: "/valid/project-jdk",
                    mavenJavaHomePath: "/invalid/maven-jdk"
                )
            ),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }

        await service.loadProject(
            at: URL(fileURLWithPath: "/workspace", isDirectory: true),
            files: []
        )
        service.startConfiguration(configuration, javaLaunch: JavaDebugLaunchTarget(
            mainClass: "example.Main",
            projectName: "app",
            classPaths: ["/workspace/app/target/classes"]
        ))

        #expect(moduleProcess.startRequests.first?.arguments == [
            "-cp", "/workspace/app/target/classes", "example.Main",
        ])
        #expect(service.moduleSessions.first?.isRunning == true)
    }

    @Test
    func stoppingTheGraphStopsServiceSessions() async throws {
        let moduleProcess = TestStreamingProcess()
        let configuration = RunConfiguration(
            id: "java-main:example.Main", name: "Main", kind: .javaMain,
            execution: .application, modulePath: "app", mainClass: "example.Main",
            mavenReactorPath: "."
        )
        let runtime = TestRuntime(javaHome: URL(fileURLWithPath: "/valid/project-jdk"))
        let resolver = TestExecutableResolver()
        let service = RunService(
            runtime: runtime,
            process: TestStreamingProcess(),
            processFactory: { moduleProcess },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            serverPortParser: TestServerPortParser(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration,
                plan: SharedLaunchPlan(
                    executable: .toolchain("project-jdk"),
                    arguments: ["example.Main"],
                    workingDirectory: ".",
                    classpath: ["/workspace/app/target/classes"]
                ),
                options: RunOptions(javaHomePath: "/valid/project-jdk")
            ),
            executableResolver: resolver,
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let graph = ExecutionFeatureGraph(
            run: service,
            tests: LanguageTestService(
                catalog: .compatibilityFallback,
                registry: LanguageTestProviderRegistry(providers: []),
                executableResolver: resolver,
                processFactory: { TestStreamingProcess() }
            )
        )
        defer { service.reset() }

        await service.loadProject(
            at: URL(fileURLWithPath: "/workspace", isDirectory: true),
            files: []
        )
        service.startConfiguration(configuration, javaLaunch: JavaDebugLaunchTarget(
            mainClass: "example.Main",
            projectName: "app",
            classPaths: ["/workspace/app/target/classes"]
        ))

        // A service session is not the "current run", yet it owns a process
        // that must keep the module awake and must end with the session.
        #expect(moduleProcess.isRunning)
        #expect(!service.isRunning)
        #expect(service.hasRunningServices)
        #expect(graph.hasActiveExecutionWork)

        graph.stop()

        #expect(!moduleProcess.isRunning)
        #expect(!service.hasRunningServices)
        #expect(!graph.hasActiveExecutionWork)
    }

    @Test
    func standaloneJavaMergesCompileOutputIntoUserClasspath() async throws {
        let mainProcess = TestStreamingProcess()
        let stepProcesses = StepProcessRecorder()
        let outputDirectory = ".lithe/run/classes/java-main-Standalone"
        let configuration = RunConfiguration(
            id: "java-main:Standalone", name: "Standalone", kind: .javaMain,
            execution: .application, modulePath: nil, mainClass: "Standalone"
        )
        // The user already supplies a `-cp`; a second one would override it, so the
        // compiled output must merge into that flag ahead of the user's entry.
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-jdk"),
            arguments: ["-cp", "libs/foo.jar", "Standalone"],
            workingDirectory: ".",
            preLaunchSteps: [
                SharedLaunchPlan.PreLaunchStep(
                    executable: .toolchain("project-jdk"),
                    tool: "javac",
                    arguments: ["-d", outputDirectory, "Standalone.java"]
                )
            ],
            classpath: [outputDirectory]
        )
        let service = RunService(
            runtime: TestRuntime(), process: mainProcess,
            processFactory: { stepProcesses.make() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration, plan: plan
            ),
            executableResolver: JavacAwareExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        await service.loadProject(at: root, files: [])

        let mainStarted = AsyncStream<Void>.makeStream()
        mainProcess.onStart = { mainStarted.continuation.yield(()) }

        service.run(configuration: configuration, currentFileURL: nil)
        let step = try #require(stepProcesses.processes.first)
        step.onTermination?(0)
        try await awaitSignal(mainStarted.stream)
        let mainRequest = try #require(mainProcess.startRequests.first)
        #expect(
            mainRequest.arguments == ["-cp", "\(outputDirectory):libs/foo.jar", "Standalone"]
        )
    }

    @Test
    func standaloneJavaCompileFailureAbortsBeforeLaunchingMainProcess() async throws {
        let mainProcess = TestStreamingProcess()
        let stepProcesses = StepProcessRecorder()
        let outputDirectory = ".lithe/run/classes/java-main-Standalone"
        let configuration = RunConfiguration(
            id: "java-main:Standalone", name: "Standalone", kind: .javaMain,
            execution: .application, modulePath: nil, mainClass: "Standalone"
        )
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-jdk"),
            arguments: ["Standalone"],
            workingDirectory: ".",
            preLaunchSteps: [
                SharedLaunchPlan.PreLaunchStep(
                    executable: .toolchain("project-jdk"),
                    tool: "javac",
                    arguments: ["-d", outputDirectory, "Standalone.java"]
                )
            ],
            classpath: [outputDirectory]
        )
        let service = RunService(
            runtime: TestRuntime(), process: mainProcess,
            processFactory: { stepProcesses.make() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration, plan: plan
            ),
            executableResolver: JavacAwareExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        await service.loadProject(at: root, files: [])
        service.run(configuration: configuration, currentFileURL: nil)

        let step = try #require(stepProcesses.processes.first)
        // A non-zero compile exit aborts the run and surfaces the failure; the
        // main process never starts.
        step.onTermination?(1)
        try await awaitTestValue(service.$lastExitCode, matching: { $0 == 1 })
        #expect(mainProcess.startRequests.isEmpty)
        #expect(!service.isRunning)
        #expect(service.output.contains("Pre-launch step failed (exit code 1)"))
    }

    /// Issue #1133: the service entries of the Run panel go through
    /// `startModuleSession`, so they must consume the same pre-launch steps the
    /// application entry does. A Maven resource step also resolves and runs from
    /// its reactor directory when the application cwd is overridden; only then
    /// can it find the project wrapper next to the reactor POM.
    @Test
    func serviceSessionRunsItsPreLaunchStepFromTheReactorBeforeLaunching() async throws {
        let recorder = SessionProcessRecorder()
        let resourceArguments = [
            "-B", "-ntp", "-f", "/workspace/app/pom.xml", "resources:resources",
        ]
        let configuration = RunConfiguration(
            id: "service:demo", name: "demo", kind: .javaMain,
            execution: .service, modulePath: "app", mainClass: "example.Main"
        )
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-jdk"),
            arguments: ["example.Main"],
            workingDirectory: "custom-run",
            preLaunchSteps: [
                SharedLaunchPlan.PreLaunchStep(
                    executable: .toolchain("project-maven"),
                    arguments: resourceArguments,
                    workingDirectory: "app"
                )
            ],
            classpath: ["/workspace/app/target/classes"]
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let service = RunService(
            runtime: TestRuntime(), process: TestStreamingProcess(),
            processFactory: { recorder.make() },
            // Built the same way `resolvedWorkingDirectory` builds its result,
            // so the directory check compares equal directory URLs.
            fileAccess: TestRunFileAccess(directories: [
                URL(fileURLWithPath: "app", relativeTo: root).standardizedFileURL,
                URL(fileURLWithPath: "custom-run", relativeTo: root).standardizedFileURL,
            ]),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration, plan: plan
            ),
            executableResolver: ToolNamedExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }
        await service.loadProject(at: root, files: [])

        service.startConfiguration(configuration)

        // The resource step starts first, from the reactor directory, and the
        // service process must wait for it.
        let step = try #require(recorder.processes.first)
        let stepRequest = try #require(step.startRequests.first)
        #expect(stepRequest.executablePath == "/test/bin/project-maven")
        #expect(stepRequest.arguments == resourceArguments)
        let stepWorkingDirectory = try #require(stepRequest.workingDirectory)
        #expect(stepWorkingDirectory.hasSuffix("/workspace/app"))
        // A resource step that never finishes must fail within the same bound
        // Windows applies instead of leaving the session running forever.
        #expect(stepRequest.timeoutMilliseconds == 600_000)
        #expect(recorder.processes.count == 1)
        #expect(service.moduleSessions.first?.isRunning == true)

        step.onTermination?(0)
        try await awaitSignal(recorder.started.stream)
        let launcher = try #require(recorder.processes.dropFirst().first)
        let launcherRequest = try #require(launcher.startRequests.first)
        #expect(launcherRequest.executablePath == "/test/bin/project-jdk")
        #expect(
            launcherRequest.arguments == ["-cp", "/workspace/app/target/classes", "example.Main"]
        )
        let launcherWorkingDirectory = try #require(launcherRequest.workingDirectory)
        #expect(launcherWorkingDirectory.hasSuffix("/workspace/custom-run"))
    }

    /// Issue #1133: a failed resource step must fail the service session rather
    /// than start the JVM against the resources it failed to update.
    @Test
    func serviceSessionPreLaunchFailureLeavesTheServiceFailed() async throws {
        let recorder = SessionProcessRecorder()
        let configuration = RunConfiguration(
            id: "service:demo", name: "demo", kind: .javaMain,
            execution: .service, modulePath: "app", mainClass: "example.Main"
        )
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-jdk"),
            arguments: ["example.Main"],
            workingDirectory: "app",
            preLaunchSteps: [
                SharedLaunchPlan.PreLaunchStep(
                    executable: .toolchain("project-maven"),
                    arguments: ["-B", "-ntp", "-f", "/workspace/app/pom.xml", "resources:resources"]
                )
            ]
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let service = RunService(
            runtime: TestRuntime(), process: TestStreamingProcess(),
            processFactory: { recorder.make() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration, plan: plan
            ),
            executableResolver: ToolNamedExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }
        await service.loadProject(at: root, files: [])

        service.startConfiguration(configuration)
        let step = try #require(recorder.processes.first)
        step.onTermination?(1)

        try await awaitTestValue(service.$moduleSessions, matching: { $0.first?.exitCode == 1 })
        #expect(service.moduleSessions.first?.isRunning == false)
        #expect(
            service.moduleSessions.first?.output.contains("Pre-launch step failed (exit code 1)")
                == true
        )
        #expect(recorder.processes.count == 1)
    }

    /// Issue #1133: stopping a service while its resource step is still running
    /// cancels the step, and a termination report that arrives afterwards must
    /// not start the JVM for the stopped session.
    @Test
    func stoppingAServiceCancelsItsRunningPreLaunchStep() async throws {
        let recorder = SessionProcessRecorder()
        let configuration = RunConfiguration(
            id: "service:demo", name: "demo", kind: .javaMain,
            execution: .service, modulePath: "app", mainClass: "example.Main"
        )
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-jdk"),
            arguments: ["example.Main"],
            workingDirectory: "app",
            preLaunchSteps: [
                SharedLaunchPlan.PreLaunchStep(
                    executable: .toolchain("project-maven"),
                    arguments: ["-B", "-ntp", "-f", "/workspace/app/pom.xml", "resources:resources"]
                )
            ]
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let service = RunService(
            runtime: TestRuntime(), process: TestStreamingProcess(),
            processFactory: { recorder.make() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration, plan: plan
            ),
            executableResolver: ToolNamedExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }
        await service.loadProject(at: root, files: [])

        service.startConfiguration(configuration)
        // Drain the step's own start signal so the later check observes only a
        // service launch.
        try await awaitSignal(recorder.started.stream)
        let step = try #require(recorder.processes.first)
        let session = try #require(service.moduleSessions.first)

        service.stopModule(session)

        #expect(!step.isRunning)
        #expect(service.moduleSessions.first?.isRunning == false)
        // The cancelled session released its operation, so a late termination
        // report cannot start the service. The deadline makes a missing launch
        // a bounded observation rather than a hang.
        step.onTermination?(0)
        await #expect(throws: TestObservationError.self) {
            try await awaitSignal(recorder.started.stream, timeout: .milliseconds(500))
        }
        #expect(recorder.processes.count == 1)
    }

    /// Issue #1133 / PR review: the platform deadline must fail the session and
    /// name that deadline. Windows reports the same wording, so a stuck Maven
    /// resource step ends the same way on both platforms.
    @Test
    func servicePreLaunchDeadlineFailsTheSessionAndNamesTheDeadline() async throws {
        let recorder = SessionProcessRecorder()
        let configuration = RunConfiguration(
            id: "service:demo", name: "demo", kind: .javaMain,
            execution: .service, modulePath: "app", mainClass: "example.Main"
        )
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-jdk"),
            arguments: ["example.Main"],
            workingDirectory: "app",
            preLaunchSteps: [
                SharedLaunchPlan.PreLaunchStep(
                    executable: .toolchain("project-maven"),
                    arguments: ["-B", "-ntp", "-f", "/workspace/app/pom.xml", "resources:resources"]
                )
            ]
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let service = RunService(
            runtime: TestRuntime(), process: TestStreamingProcess(),
            processFactory: { recorder.make() },
            // Built the same way `resolvedWorkingDirectory` builds its result,
            // so the reactor directory resolves instead of falling back.
            fileAccess: TestRunFileAccess(directories: [
                URL(fileURLWithPath: "app", relativeTo: root).standardizedFileURL,
            ]),
            preferences: TestRunPreferences(), serverPortParser: TestServerPortParser(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration, plan: plan
            ),
            executableResolver: ToolNamedExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }
        await service.loadProject(at: root, files: [])

        service.startConfiguration(configuration)
        let step = try #require(recorder.processes.first)
        let stepRequest = try #require(step.startRequests.first)
        #expect(stepRequest.timeoutMilliseconds == 600_000)

        // The platform reports its deadline and then terminates the owned
        // process, exactly as `MacStreamingProcess` does on timeout.
        step.onStateChange?(ProcessLifecycleEvent(
            operationID: stepRequest.operationID,
            state: .stopping,
            exitCode: nil,
            message: "Process timed out"
        ))
        try await awaitTestValue(service.$moduleSessions, matching: {
            $0.first?.output.contains("Pre-launch step timed out after 600 seconds.") == true
        })

        step.onTermination?(15)
        try await awaitTestValue(service.$moduleSessions, matching: { $0.first?.exitCode == 15 })
        #expect(service.moduleSessions.first?.isRunning == false)
        #expect(recorder.processes.count == 1)
    }

    @Test(arguments: [LanguageTestRunState.passed, .failed(exitCode: 7), .cancelled])
    func processLanguageTestsRemainIndependentFromProviderReports(expectedState: LanguageTestRunState) async throws {
        let root = URL(fileURLWithPath: "/workspace/gradle-tests", isDirectory: true)
        let source = root.appendingPathComponent(
            "src/test/java/com/example/CalculatorTest.java"
        )
        let buildFile = root.appendingPathComponent("build.gradle")
        let process = TestStreamingProcess()
        let service = LanguageTestService(
            executableResolver: TestExecutableResolver(),
            processFactory: { process }
        )

        #expect(service.run(
            providerID: "java",
            scope: .file(source),
            workspaceURL: root,
            projectFiles: [buildFile, source]
        ))
        #expect(service.activePlan?.frameworkID == "gradle")
        #expect(service.activePlan?.launchPlan.arguments.contains("--no-daemon") == true)
        defer { service.reset() }

        if expectedState == .cancelled { service.stop() }
        if case .failed(let code) = expectedState { process.onTermination?(code) }
        else { process.onTermination?(0) }
        try await awaitTestValue(service.$state, matching: { $0 == expectedState })
        #expect(service.state == expectedState)
        #expect(service.results == nil)
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
    func generate(
        at _: URL,
        files _: [URL],
        modulePaths _: [String],
        javaEntrypoints _: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
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

/// Records how the service inspects: a full check reads every project input,
/// so only project loads may request it (issue #507).
private final class FreshnessRecordingRunConfigurationOperations: RunConfigurationOperations, @unchecked Sendable {
    var inputsChanged = true
    private(set) var fingerprintChecks: [Bool] = []
    private(set) var comparedEntrypoints: [JavaEntrypoints] = []
    private let custom = RunConfiguration(
        id: "Custom", name: "Custom", kind: .javaMain,
        execution: .service, modulePath: nil, mainClass: "demo.Custom"
    )

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        inspect(at: projectURL, checkFingerprint: true, javaEntrypoints: nil)
    }
    func inspect(
        at _: URL,
        checkFingerprint: Bool,
        javaEntrypoints: JavaEntrypoints?
    ) -> ProjectRunConfigurationInspection {
        fingerprintChecks.append(checkFingerprint)
        var diagnostics: [RunConfigurationDiagnostic] = []
        if checkFingerprint && inputsChanged {
            diagnostics.append(RunConfigurationDiagnostic(
                configurationID: nil, code: "staleFingerprint",
                message: "Project inputs changed: 0 added, 0 removed, 1 modified"
            ))
        }
        if let javaEntrypoints {
            comparedEntrypoints.append(javaEntrypoints)
            diagnostics.append(RunConfigurationDiagnostic(
                configurationID: nil, code: "staleFingerprint",
                message: "Java entry points changed: 1 added, 0 removed"
            ))
        }
        return ProjectRunConfigurationInspection(status: .ready, diagnostics: diagnostics)
    }
    func generate(
        at _: URL,
        files _: [URL],
        modulePaths _: [String],
        javaEntrypoints _: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [.currentFile, custom].map {
                EffectiveRunConfiguration(configuration: $0, options: RunOptions())
            },
            diagnostics: [],
            defaultConfigurationID: nil
        )
    }
    func launchPlan(at _: URL, configurationID: String, currentFile _: String?, classPath _: String?, debugPort _: Int?) throws -> SharedLaunchPlan {
        SharedLaunchPlan(executable: .toolchain("java"), arguments: [configurationID], workingDirectory: ".")
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at _: URL) throws -> String { draft.name }
    func migrateLegacySettings(at _: URL, configurationIDs _: [String]) throws {}
}

/// Returns a fixed launch plan (optionally carrying pre-launch steps and a
/// classpath) so a test can drive the compile-then-run orchestration without a
/// real Rust core.
private struct FixedLaunchPlanRunConfigurationOperations: RunConfigurationOperations {
    let configuration: RunConfiguration
    let plan: SharedLaunchPlan
    var options = RunOptions()

    func inspect(at _: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(
        at _: URL,
        files _: [URL],
        modulePaths _: [String],
        javaEntrypoints _: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [.currentFile, configuration].map {
                EffectiveRunConfiguration(configuration: $0, options: options)
            },
            diagnostics: [],
            defaultConfigurationID: configuration.id
        )
    }
    func launchPlan(at _: URL, configurationID _: String, currentFile _: String?, classPath _: String?, debugPort _: Int?) throws -> SharedLaunchPlan {
        plan
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at _: URL) throws -> String { draft.name }
    func migrateLegacySettings(at _: URL, configurationIDs _: [String]) throws {}
}

/// Resolves the JDK launcher to `/test/bin/java`, so the shared `resolve(step:)`
/// default can swap the last path component to `/test/bin/javac` for a compile
/// step that names `tool: "javac"`.
@MainActor
private final class JavacAwareExecutableResolver: RunExecutableResolving {
    func resolve(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) throws -> ResolvedRunExecutable {
        ResolvedRunExecutable(
            executableURL: URL(fileURLWithPath: "/test/bin/java"),
            environment: [:]
        )
    }
    func refreshCandidates(projectURL: URL) async {}
    func candidates(projectURL: URL) -> [ProjectToolchainCandidate] { [] }
}

/// Hands out and remembers every process the pre-launch factory creates, so a
/// test can fire each step's termination and assert its start request.
private final class StepProcessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TestStreamingProcess] = []
    var processes: [TestStreamingProcess] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func make() -> TestStreamingProcess {
        let process = TestStreamingProcess()
        lock.lock(); storage.append(process); lock.unlock()
        return process
    }
}

/// Hands out the processes one module session creates — the pre-launch step and
/// then the service — and yields on every start, so a test can await the exact
/// moment the JVM launches instead of sleeping.
private final class SessionProcessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TestStreamingProcess] = []
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)

    var processes: [TestStreamingProcess] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func make() -> TestStreamingProcess {
        let process = TestStreamingProcess()
        let continuation = started.continuation
        process.onStart = { continuation.yield(()) }
        lock.lock(); storage.append(process); lock.unlock()
        return process
    }
}

/// Resolves a toolchain to `/test/bin/<identifier>`, so a test can tell a
/// session's resource step apart from the service launcher it gates.
@MainActor
private final class ToolNamedExecutableResolver: RunExecutableResolving {
    func resolve(
        _ plan: SharedLaunchPlan,
        projectURL: URL,
        options: RunOptions
    ) throws -> ResolvedRunExecutable {
        let name: String
        switch plan.executable {
        case .toolchain(let identifier): name = identifier
        case .command(let command): name = command
        }
        return ResolvedRunExecutable(
            executableURL: URL(fileURLWithPath: "/test/bin/" + name),
            environment: [:]
        )
    }
    func refreshCandidates(projectURL: URL) async {}
    func candidates(projectURL: URL) -> [ProjectToolchainCandidate] { [] }
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
func makeBuildSystemTestRuntime(
    _ buildSystems: BuildSystemService,
    runOperations: any RunConfigurationOperations = TestRunConfigurationOperations()
) async throws -> (runtime: ModuleRuntime, graph: ExecutionFeatureGraph) {
    let graph = makeTestGraph(runOperations: runOperations, buildSystems: buildSystems)
    let runtime = ModuleRuntime()
    try runtime.register(ModuleFactory(
        manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    ) { EmptyWorkspaceModule() })
    try runtime.register(ModuleFactory(
        manifest: ExecutionModule.moduleManifest,
        contributions: ExecutionModule.moduleContributions
    ) { ExecutionModule(makeGraph: { graph }) })
    _ = try await runtime.activateCapability(.executionWorkspace)
    return (runtime, graph)
}

@MainActor
private func makeTestGraph(
    runOperations: any RunConfigurationOperations = TestRunConfigurationOperations(),
    buildSystems: BuildSystemService? = nil
) -> ExecutionFeatureGraph {
    let runtime = TestRuntime()
    let resolver = TestExecutableResolver()
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
    return ExecutionFeatureGraph(run: run, tests: tests, buildSystems: buildSystems)
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

/// Awaits the first element of a signal stream against a bounded deadline, so a
/// test can wait for an event that is delivered through a closure rather than a
/// `@Published` value (e.g. the main process launching after a compile step).
private func awaitSignal(_ stream: AsyncStream<Void>, timeout: Duration = .seconds(2)) async throws {
    let received: Bool = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream { return true }
            return false
        }
        group.addTask {
            // test-stability: allow(swift-real-sleep) reason: bounded deadline for a closure-delivered signal, never synchronizes successful completion.
            try? await Task.sleep(for: timeout)
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
    if !received { throw TestObservationError.deadlineExceeded }
}

@MainActor
private final class TestRuntime: RunRuntimePort {
    var synchronousToolchainCalls = 0
    var loadCandidates: (@MainActor (URL?) async throws -> [ProjectToolchainCandidate])?
    func loadRunConfigurationToolchainCandidates(
        projectRoot: URL?,
        javaHomeOverride: String?, mavenExecutableOverride: String?
    ) async throws -> [ProjectToolchainCandidate] {
        try await loadCandidates?(projectRoot) ?? []
    }
    private let javaHome: URL?
    private let mavenJavaHome: URL?

    init(javaHome: URL? = nil, mavenJavaHome: URL? = nil) {
        self.javaHome = javaHome
        self.mavenJavaHome = mavenJavaHome
    }

    func setActiveServiceJavaHomePath(_ path: String) {}
    func javaHomeURL(overridePath: String?) -> URL? { javaHome }
    func mavenJavaHomeURL(overridePath: String?) -> URL? { mavenJavaHome }
    func runConfigurationToolchainCandidates(
        projectRoot: URL?,
        javaHomeOverride: String?,
        mavenExecutableOverride: String?
    ) -> [ProjectToolchainCandidate] { synchronousToolchainCalls += 1; return [] }
}

private final class TestStreamingProcess: StreamingProcess, @unchecked Sendable {
    var isRunning = false
    var startFailure: (any Error)?
    private(set) var startRequests: [ProcessRequest] = []
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?
    /// Fires after a start request is recorded so a test can observe the exact
    /// moment the main process launches once every pre-launch step exits zero.
    var onStart: (@Sendable () -> Void)?
    func start(_ request: ProcessRequest) throws {
        if let startFailure { throw startFailure }
        startRequests.append(request)
        isRunning = true
        onStart?()
    }
    func send(_ input: Data) throws {}
    func stop() { isRunning = false }
}


private struct TestRunFileAccess: RunFileAccess {
    let contents: [URL: String]
    let directories: Set<URL>

    init(contents: [URL: String] = [:], directories: Set<URL> = []) {
        self.contents = contents
        self.directories = directories
    }

    func isDirectory(at url: URL) -> Bool { directories.contains(url.standardizedFileURL) }
    func readData(from url: URL) throws -> Data {
        Data((contents[url.standardizedFileURL] ?? "").utf8)
    }
}

private final class TestWorkspaceDependencyStore: WorkspaceDependencyStoring, @unchecked Sendable {
    var configuration = WorkspaceDependencyConfiguration()
    var indexes = WorkspaceDependencyIndexes()

    func loadDependencyConfiguration(workspaceURL: URL) throws -> WorkspaceDependencyConfiguration? {
        configuration
    }

    func saveDependencyConfiguration(
        _ configuration: WorkspaceDependencyConfiguration,
        workspaceURL: URL
    ) throws {
        self.configuration = configuration
    }

    func loadDependencyIndexes(workspaceURL: URL) throws -> WorkspaceDependencyIndexes? {
        indexes
    }

    func saveDependencyIndexes(
        _ indexes: WorkspaceDependencyIndexes,
        workspaceURL: URL
    ) throws {
        self.indexes = indexes
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

final class MavenContextRunOperations: RunConfigurationOperations, @unchecked Sendable {
    let configuration: RunConfiguration
    private let lock = NSLock()
    private var recordedContext: MavenLaunchContext?
    private var didCall = false
    private var recordedCallCount = 0
    var context: MavenLaunchContext? { lock.lock(); defer { lock.unlock() }; return recordedContext }
    var called: Bool { lock.lock(); defer { lock.unlock() }; return didCall }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return recordedCallCount }
    init(configuration: RunConfiguration) { self.configuration = configuration }
    func inspect(at _: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(configurations: [EffectiveRunConfiguration(configuration: configuration, options: RunOptions())],
                                   diagnostics: [], defaultConfigurationID: configuration.id)
    }
    func generate(
        at _: URL,
        files _: [URL],
        modulePaths _: [String],
        javaEntrypoints _: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func launchPlan(at _: URL, configurationID _: String, currentFile _: String?, classPath _: String?, debugPort _: Int?) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Expected the context-aware launch boundary")
    }
    func launchPlan(at _: URL, configurationID _: String, currentFile _: String?, classPath _: String?, debugPort _: Int?,
                    mavenContext: MavenLaunchContext?) throws -> SharedLaunchPlan {
        lock.lock()
        recordedContext = mavenContext
        didCall = true
        recordedCallCount += 1
        lock.unlock()
        throw RunConfigurationOperationFailure(message: "Fixture launch failure")
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at _: URL) throws -> String { draft.name }
    func migrateLegacySettings(at _: URL, configurationIDs _: [String]) throws {}
}

private struct SingleRunConfigurationOperations: RunConfigurationOperations {
    let configuration: RunConfiguration
    let options: RunOptions

    func inspect(at _: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(
        at _: URL,
        files _: [URL],
        modulePaths _: [String],
        javaEntrypoints _: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
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
    private(set) var lastOptions: RunOptions?
    func resolve(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) throws -> ResolvedRunExecutable {
        lastOptions = options
        return ResolvedRunExecutable(executableURL: URL(fileURLWithPath: "/test"), environment: [:])
    }
    func refreshCandidates(projectURL: URL) async {}
    func candidates(projectURL: URL) -> [ProjectToolchainCandidate] { [] }
}

private enum RunFixtureError: Error { case failed }

private final class InventoryInspectionGate: Sendable {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let release = DispatchSemaphore(value: 0)
}

private struct TestRunConfigurationOperations: RunConfigurationOperations {
    var toolchain = ProjectToolchainSelection()
    var rejectsResolutionWithoutGeneratedDocument = false
    var savedProvider: BuildProviderRunReference? = nil
    func saveBuildProviderConfiguration(_ reference: BuildProviderRunReference, name: String, at projectURL: URL) throws -> String {
        guard reference == savedProvider else { throw RunFixtureError.failed }
        return "user:provider"
    }
    var inspectionGate: InventoryInspectionGate? = nil
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        if let inspectionGate {
            inspectionGate.entered.continuation.yield(())
            if inspectionGate.release.wait(timeout: .now() + 2) != .success {
                Issue.record("Run inspection was not released before its deadline")
            }
        }
        return ProjectRunConfigurationInspection(status: .missing, diagnostics: [],
            projectToolchain: toolchain == ProjectToolchainSelection() ? nil : toolchain)
    }
    func generate(
        at projectURL: URL,
        files: [URL],
        modulePaths: [String],
        javaEntrypoints: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 0)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        if rejectsResolutionWithoutGeneratedDocument { throw RunFixtureError.failed }
        if let savedProvider {
            let configuration = RunConfiguration(id: "user:provider", name: "Main", kind: .process(provider: "build.provider"),
                modulePath: nil, mainClass: nil, buildProvider: savedProvider)
            return RunConfigurationResolution(configurations: [.init(configuration: configuration, options: RunOptions())],
                diagnostics: [], defaultConfigurationID: nil)
        }
        return RunConfigurationResolution(configurations: [], diagnostics: [], defaultConfigurationID: nil, projectToolchain: toolchain)
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
    func generate(
        at projectURL: URL,
        files: [URL],
        modulePaths: [String],
        javaEntrypoints: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
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
    func generate(
        at projectURL: URL,
        files: [URL],
        modulePaths: [String],
        javaEntrypoints: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
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
    func generate(
        at projectURL: URL,
        files: [URL],
        modulePaths: [String],
        javaEntrypoints: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
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
    func generate(
        at projectURL: URL,
        files: [URL],
        modulePaths: [String],
        javaEntrypoints: JavaEntrypoints?
    ) throws -> RunConfigurationGenerationResult {
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

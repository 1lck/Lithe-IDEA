import Combine
import Foundation
import LitheApplicationKernel
@testable import LitheExecutionModule
import LitheCoreContracts
import LitheModuleAPI
import Testing

@MainActor
struct ExecutionModuleTests {
    @Test(arguments: ["launch", "stop", "reset", "disable", "changed", "cancel"])
    func providerDebugKeepsCanonicalInputsAndOwnsItsProcessAcrossCancellation(outcome: String) async throws {
        let owner = BuildSystemPluginSource(pluginID: "dev.first", manifest: Data(), packageURL: URL(fileURLWithPath: "/fixture/first"), buildSystems: [
            .init(id: "maven", displayName: "Provider", modelSource: .provider, tasks: [], testScopes: [], dependencyScopes: [],
                  providerRuns: [.init(id: "service", displayName: "Service", targetTags: ["service"], debugConfigurationType: "example", execution: .service)])])
        let operations = ProviderChoicesRunOperations(withReference: true), gate = ProviderPreparationGate(), process = TestStreamingProcess()
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let service = RunService(process: process, processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(directories: [root]), preferences: TestRunPreferences(), runConfigurationOperations: operations, executableResolver: TestExecutableResolver(), languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback))
        var current = true
        var cancelled = false
        var ended: [String] = []
        let observation = service.providerDebugEnded.sink { ended.append($0) }
        service.configureProviderConfigurationRuns(source: { _, _ in owner }) { inputs, _, _, _, _, _ in
            #expect(inputs.launchOptions.debug == .init(adapterID: "dev.adapter/remote", configurationType: "example", port: 51235))
            #expect(inputs.launchOptions.arguments == ["a b", "雪"])
            gate.entered.continuation.yield(())
            let waiter = Task { try await awaitSignal(gate.release.stream) }
            defer { waiter.cancel() }
            try await waiter.value
            cancelled = Task.isCancelled
            return try JSONDecoder().decode(BuildRunPreparation.self, from: Data(#"{"executable":{"kind":"toolchain","value":"project-maven"},"arguments":["prepared-debug"],"workingDirectory":".","environment":{}}"#.utf8))
        }
        await service.loadProject(at: root, files: [])
        let task = Task { try await service.prepareProviderDebug(operations.configurations[0], debug: { type in
            #expect(type == "example")
            return .init(adapterID: "dev.adapter/remote", configurationType: type, port: 51235)
        }, isCurrent: { current }) }
        let feature = RunFeatureModel(service: service)
        defer { task.cancel(); gate.release.continuation.yield(()); service.reset(); observation.cancel() }
        try await awaitSignal(gate.entered.stream)
        #expect(feature.selectedProjectSessionID == nil && feature.isSelectedConfigurationRunning)
        if outcome == "stop" { service.stopProviderDebug() }
        if outcome == "reset" { service.reset() }
        if outcome == "disable" { service.retainProviderConfigurations([]) }
        if outcome == "changed" { current = false }
        if outcome == "cancel" { task.cancel() }
        gate.release.continuation.yield(())
        if outcome == "launch" {
            let operation = try await task.value
            #expect(service.isProviderDebugActive(operation))
            #expect(process.startRequests.first?.arguments == ["prepared-debug"])
            service.retainProviderConfigurations([])
            #expect(!service.isProviderDebugActive(operation) && !process.isRunning)
            #expect(feature.selectedProjectSessionID == nil && !feature.isSelectedConfigurationRunning)
            #expect(ended.filter { $0 == operation }.count == 1)
        } else {
            do { _ = try await task.value; Issue.record("Stale debug preparation launched") }
            catch is CancellationError { }
            #expect(process.startRequests.isEmpty && !service.isRunning)
            #expect(cancelled == (outcome != "changed"))
        }
    }

    @Test
    func providerServicesPrepareIndependentlyAndStoppedRepliesCannotLaunchOverReplacements() async throws {
        let firstOwner = BuildSystemPluginSource(pluginID: "dev.first", manifest: Data(), packageURL: URL(fileURLWithPath: "/fixture/first"), buildSystems: [])
        let secondOwner = BuildSystemPluginSource(pluginID: "dev.second", manifest: Data(), packageURL: URL(fileURLWithPath: "/fixture/second"), buildSystems: [])
        let operations = ProviderChoicesRunOperations()
        let root = URL(fileURLWithPath: "/workspace")
        var processes: [TestStreamingProcess] = []
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        let first = ProviderPreparationGate(), second = ProviderPreparationGate(), replacement = ProviderPreparationGate()
        var calls: [String: Int] = [:]
        let service = RunService(process: TestStreamingProcess(), processFactory: {
            let process = TestStreamingProcess(); process.onStart = { started.continuation.yield(()) }; processes.append(process); return process
        }, fileAccess: TestRunFileAccess(directories: [root]), preferences: TestRunPreferences(), runConfigurationOperations: operations, executableResolver: TestExecutableResolver(), languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback))
        defer { service.reset(); first.release.continuation.yield(()); second.release.continuation.yield(()); replacement.release.continuation.yield(()); started.continuation.finish() }
        service.configureProviderConfigurationRuns(source: { inputs, _ in inputs.projectPath == "second" ? secondOwner : firstOwner }) { inputs, _, _, _, current, progress in
            let count = calls[inputs.projectPath, default: 0]; calls[inputs.projectPath] = count + 1
            let gate = inputs.projectPath == "second" ? second : (count == 0 ? first : replacement)
            gate.entered.continuation.yield(())
            // This bounded fake deliberately ignores caller cancellation until its owned gate opens.
            let waiter = Task { try await awaitSignal(gate.release.stream) }
            defer { waiter.cancel(); gate.finished.continuation.yield(()) }
            try await waiter.value
            progress(BuildProviderProgress(message: current() ? "current preparation" : "stale preparation"))
            return try JSONDecoder().decode(BuildRunPreparation.self, from: Data(#"{"executable":{"kind":"toolchain","value":"project-maven"},"arguments":["prepared"],"workingDirectory":".","environment":{}}"#.utf8))
        }
        await service.loadProject(at: root, files: [])
        service.runAllServices()
        try await awaitSignal(first.entered.stream); try await awaitSignal(second.entered.stream)
        #expect(service.hasRunningServices && processes.isEmpty)
        let oldSession = try #require(service.moduleSessions.first { $0.configurationID == "first" })
        service.stopModule(oldSession)
        second.release.continuation.yield(())
        try await awaitSignal(started.stream)
        #expect(processes.count == 1)
        #expect(service.moduleSessions.first { $0.configurationID == "second" }?.isRunning == true)
        service.startConfiguration(operations.configurations[0])
        try await awaitSignal(replacement.entered.stream)
        first.release.continuation.yield(())
        try await awaitSignal(first.finished.stream)
        replacement.release.continuation.yield(())
        try await awaitSignal(started.stream)
        #expect(processes.count == 2)
        #expect(!service.moduleSessions.contains { $0.output.contains("stale preparation") })
        #expect(service.moduleSessions.allSatisfy { $0.isRunning })
        let oldOutput = processes[0].onOutput, oldExit = processes[0].onTermination
        let secondSession = try #require(service.moduleSessions.first { $0.configurationID == "second" })
        service.retainProviderConfigurations([firstOwner])
        #expect(service.moduleSessions.first { $0.id == secondSession.id }?.isRunning == false)
        #expect(service.moduleSessions.first { $0.configurationID == "first" }?.isRunning == true)
        oldOutput?("late stopped output"); oldExit?(7)
        processes[1].onOutput?("replacement barrier")
        try await awaitTestValue(service.$moduleSessions) { $0.contains { $0.output.contains("replacement barrier") } }
        #expect(!service.moduleSessions.contains { $0.output.contains("late stopped output") })
        service.retainProviderConfigurations([])
        #expect(!service.hasRunningServices && processes.allSatisfy { !$0.isRunning })
    }

    @Test(arguments: ["launch", "stop", "reset", "disable"])
    func providerPrimaryPreparationRetainsIdentityAndRejectsStoppedOrResetResults(outcome: String) async throws {
        let firstOwner = BuildSystemPluginSource(pluginID: "dev.first", manifest: Data(), packageURL: URL(fileURLWithPath: "/fixture/first"), buildSystems: [])
        let secondOwner = BuildSystemPluginSource(pluginID: "dev.second", manifest: Data(), packageURL: URL(fileURLWithPath: "/fixture/second"), buildSystems: [])
        let operations = ProviderChoicesRunOperations(), gate = ProviderPreparationGate()
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true), process = TestStreamingProcess()
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.onStart = { started.continuation.yield(()) }
        let service = RunService(process: process, processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(directories: [root]),
            preferences: TestRunPreferences(), runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(), languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback))
        defer { service.reset(); gate.release.continuation.yield(()); started.continuation.finish() }
        service.configureProviderConfigurationRuns(source: { _, _ in firstOwner }) { inputs, _, _, _, _, _ in
            #expect(inputs.launchOptions.arguments == ["a b", "雪"])
            gate.entered.continuation.yield(())
            let waiter = Task { try await awaitSignal(gate.release.stream) }
            defer { waiter.cancel(); gate.finished.continuation.yield(()) }
            try await waiter.value
            return try JSONDecoder().decode(BuildRunPreparation.self, from: Data(#"{"executable":{"kind":"toolchain","value":"project-maven"},"arguments":["prepared"],"workingDirectory":".","environment":{}}"#.utf8))
        }
        await service.loadProject(at: root, files: [])
        service.run(configuration: operations.configurations[0], currentFileURL: nil)
        let identity = service.primaryExecutionID
        try await awaitSignal(gate.entered.stream)
        #expect(service.isRunning && service.isPreparingBuildRun)
        if outcome == "stop" { service.stop() }
        if outcome == "reset" { service.reset() }
        if outcome == "disable" { service.retainProviderConfigurations([]) }
        gate.release.continuation.yield(())
        if outcome == "launch" {
            try await awaitSignal(started.stream)
            #expect(service.primaryExecutionID == identity)
            #expect(process.startRequests.first?.arguments == ["prepared"])
            #expect(service.isRunning && !service.isPreparingBuildRun)
            service.retainProviderConfigurations([firstOwner, secondOwner])
            #expect(service.isRunning)
            service.retainProviderConfigurations([])
            #expect(!service.isRunning && !process.isRunning)
        } else {
            try await awaitSignal(gate.finished.stream)
            #expect(process.startRequests.isEmpty && !service.isRunning)
        }
    }

    @Test
    func staleProviderGenerationBlocksPrimaryServicesAndAgentPathsAndClearsAfterABA() async throws {
        let operations = FreshnessRecordingRunConfigurationOperations()
        operations.staleProviderModel = true
        let primary = TestStreamingProcess()
        var created = 0
        let service = RunService(process: primary,
            processFactory: { created += 1; return TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(), languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback))
        defer { service.reset() }
        var pending = false
        service.configureProviderRunConfigurations {
            if pending { throw CancellationError() }
            return []
        }
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])
        #expect(service.configurations.contains { $0.id == "Custom" })
        #expect(service.configurationDiagnostics.contains { $0.code == "staleProviderModel" })
        operations.staleProviderModel = false
        await service.refreshProviderGeneration()
        #expect(!service.configurationDiagnostics.contains { $0.code == "staleProviderModel" })
        pending = true
        await service.refreshProviderGeneration()
        #expect(service.configurationDiagnostics.contains { $0.code == "providerModelNotReady" })
        pending = false
        await service.refreshProviderGeneration()
        #expect(!service.configurationDiagnostics.contains { ["staleProviderModel", "providerModelNotReady"].contains($0.code) })
        #expect(!operations.providerInspections.isEmpty)
        #expect(created == 0)
    }

    @Test
    func genericProviderOnlyInventoryRefreshesTheIndependentRunSnapshot() async throws {
        let operations = FreshnessRecordingRunConfigurationOperations()
        let reference = BuildProviderRunReference(pluginID: "dev.example", buildSystemID: "engine", root: ".",
            run: "serve", projectID: "opaque/project", targetID: "opaque/target", execution: .service)
        operations.providerConfiguration = RunConfiguration(id: "build.provider:generated", name: "Service", kind: .process(provider: "build.provider"),
            execution: .service, buildProvider: reference)
        let service = RunService(process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(), languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback))
        defer { service.reset() }
        service.configureProviderRunConfigurations { [] }
        var runs = [RunProviderConfiguration(projectPath: ".", name: "Service", reference: reference)]
        service.configureProviderRunConfigurations { runs }
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])
        #expect(operations.runInspections.last == runs)
        operations.staleProviderModel = true
        runs = []
        await service.refreshProviderGeneration()
        #expect(operations.runInspections.last == [])
        #expect(service.configurationDiagnostics.contains { $0.code == "staleProviderModel" })
        operations.staleProviderModel = false
        runs = [RunProviderConfiguration(projectPath: ".", name: "Service", reference: reference)]
        await service.refreshProviderGeneration()
        #expect(!service.configurationDiagnostics.contains { $0.code == "staleProviderModel" })
    }

    @Test(arguments: ["task", "workspace", "model", "reset", "new-generation"])
    func generationPublicationLeaseIsRevokedBeforeAnObsoleteWorkerCanPublish(change: String) async throws {
        let operations = FreshnessRecordingRunConfigurationOperations()
        let service = RunService(process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(), languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback))
        service.configureProviderRunConfigurations { [] }
        service.configureProviderRunConfigurations { [] }
        let gate = InventoryInspectionGate()
        defer { service.reset(); gate.release.signal(); gate.entered.continuation.finish() }
        await service.loadProject(at: URL(fileURLWithPath: "/old"), files: [], snapshotID: UUID())
        operations.generationGate = gate
        let worker = Task { await service.generateRunConfigurations() }
        defer { worker.cancel(); gate.release.signal() }
        try await awaitSignal(gate.entered.stream)
        let lease = try #require(operations.generationLeases.first)
        operations.generationGate = nil
        if change == "task" { worker.cancel() }
        else if change == "workspace" { await service.loadProject(at: URL(fileURLWithPath: "/new"), files: [], snapshotID: UUID()) }
        else if change == "model" { service.requestProviderGenerationInspection() }
        else if change == "reset" { service.reset() }
        else { await service.generateRunConfigurations() }
        #expect(!lease.isCurrent)
        let status = service.configurationStatus, state = service.generationState, ids = service.configurations.map(\.id)
        gate.release.signal()
        await worker.value
        #expect(service.configurationStatus == status)
        #expect(service.generationState == state)
        #expect(service.configurations.map(\.id) == ids)
        #expect(!service.isLoadingProject)
    }

    @Test(arguments: ["inputs", "workspace", "reset"])
    func lateProviderInspectionCannotReplaceNewerInputWorkspaceOrReset(change: String) async throws {
        let operations = FreshnessRecordingRunConfigurationOperations()
        let service = RunService(process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(), languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback))
        service.configureProviderRunConfigurations { [] }
        let gate = InventoryInspectionGate()
        defer { service.reset(); gate.release.signal(); gate.entered.continuation.finish() }
        await service.loadProject(at: URL(fileURLWithPath: "/old"), files: [])
        operations.providerInspectionGate = gate
        let old = Task { await service.refreshProviderGeneration() }
        defer { old.cancel(); gate.release.signal() }
        try await awaitSignal(gate.entered.stream)
        operations.providerInspectionGate = nil
        operations.staleProviderModel = true
        if change == "inputs" { await service.refreshProviderGeneration() }
        else if change == "workspace" { await service.loadProject(at: URL(fileURLWithPath: "/new"), files: []) }
        else { service.reset() }
        let expected = service.configurationDiagnostics
        gate.release.signal()
        await old.value
        #expect(service.configurationDiagnostics == expected)
        if change != "reset" { #expect(expected.contains { $0.code == "staleProviderModel" }) }
    }

    @Test
    func providerGenerationNotificationsCoalesceBehindOneOwnedInspection() async throws {
        let operations = FreshnessRecordingRunConfigurationOperations()
        let service = RunService(process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(), languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback))
        service.configureProviderRunConfigurations { [] }
        let gate = InventoryInspectionGate()
        defer { service.reset(); gate.release.signal(); gate.entered.continuation.finish() }
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])
        let baseline = operations.providerInspections.count
        operations.providerInspectionGate = gate
        service.requestProviderGenerationInspection()
        try await awaitSignal(gate.entered.stream)
        operations.providerInspectionGate = nil
        operations.staleProviderModel = true
        for _ in 0..<100 { service.requestProviderGenerationInspection() }
        #expect(operations.providerInspections.count == baseline + 1, "No second worker may start while the first is held")
        gate.release.signal()
        try await awaitTestValue(service.$configurationDiagnostics) { $0.contains { $0.code == "staleProviderModel" } }
        #expect(operations.providerInspections.count == baseline + 2, "All pending changes need only one current read")
    }

    @Test
    func backendTestsPreserveProjectIdentityAndRerunWithFreshFactsWithoutAHostProcess() async throws {
        var processes = 0
        let service = LanguageTestService(outcomeResolver: LinkedCoreTestRunOutcome(), executableResolver: TestExecutableResolver(), processFactory: {
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
        #expect(service.results?.summary.total == 2)
        #expect(service.testOutcomes(for: "java").map(\.project) == ["a", "b"])
        #expect(service.canRerun)
        #expect(service.rerun())
        try await awaitTestValue(service.$state) { $0 == .failed(exitCode: 1) }
        #expect(requests == 2)
        #expect(service.output == "request 2")
        #expect(service.testOutcomes(for: "java").count == 2)
        #expect(processes == 0)
    }

    @Test
    func backendReportsPreserveInvocationSummariesSourceLocationsAndOpaqueRerunReferences() async throws {
        let service = LanguageTestService(outcomeResolver: LinkedCoreTestRunOutcome(), executableResolver: TestExecutableResolver(), processFactory: { TestStreamingProcess() })
        defer { service.reset() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let report = try JSONDecoder().decode(BuildTestResults.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/build-provider/test-results-v1.json")))
        let second = BuildTestResults(tests: [.init(project: "other", suite: "other", name: "repeated", status: .passed, invocations: 3)],
            summary: .init(total: 1, passed: 1, failed: 0, errors: 0, skipped: 0), success: true)
        let test = report.tests[1]
        let reference = BuildTestReference(pluginID: "org.example.build", buildSystemID: "example", root: ".",
            projectID: "project-token", suite: "opaque-suite", testCase: "opaque-case")
        service.runUsingBackend(providerID: "example", scope: .workspace, workspaceURL: URL(fileURLWithPath: "/workspace"), label: "Tests") { _, _ in
            LanguageTestBackendResult(exitCode: 1, reports: [report, second], references: [BuildTestCaseKey(test): reference])
        }
        try await awaitTestValue(service.$state) { $0 == .failed(exitCode: 1) }
        let result = try #require(service.results)
        #expect(result.tests == report.tests + second.tests)
        #expect(result.summary == .init(total: 5, passed: 3, failed: 0, errors: 1, skipped: 1))
        #expect(result.tests.first?.invocations == 2)
        #expect(result.tests.last?.invocations == 3)
        #expect(!result.success)
        #expect(service.resultReferences[BuildTestCaseKey(test)] == reference)
        #expect(service.sourceURL(for: test)?.path == "/workspace/tests/checkout.spec")
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(test)) as? [String: Any])
        #expect(wire["suite"] as? String == "checkout / HTTP")
        #expect(wire["case"] as? String == "accepts(payload)[2]")
        #expect(wire["className"] == nil)
        #expect(wire["method"] == nil)
        #expect(try JSONDecoder().decode(BuildTestResults.TestCase.self, from: JSONEncoder().encode(test)) == test)
        service.clearOutput()
        #expect(service.resultReferences.isEmpty)
        #expect(service.sourceURL(for: test) == nil)
        #expect(service.testOutcomes(for: "example") == report.tests + second.tests)
    }

    @Test
    func genericReportHistoryNeverCrossesLanguageProviderBoundaries() async throws {
        let service = LanguageTestService(outcomeResolver: LinkedCoreTestRunOutcome(), executableResolver: TestExecutableResolver(), processFactory: { TestStreamingProcess() })
        defer { service.reset() }
        func run(_ provider: String, status: BuildTestResults.TestCase.Status) async throws {
            // RUN-03: a reported failure outranks exit code 0.
            let expected: LanguageTestRunState = status == .passed ? .passed : .failed(exitCode: 0)
            let report = BuildTestResults(tests: [.init(suite: "Same", name: "checks", status: status)],
                summary: .init(total: 1, passed: status == .passed ? 1 : 0, failed: status == .failed ? 1 : 0, errors: 0, skipped: 0), success: status == .passed)
            service.runUsingBackend(providerID: provider, scope: .workspace, workspaceURL: URL(fileURLWithPath: "/workspace"), label: "Tests") { _, _ in
                LanguageTestBackendResult(exitCode: 0, reports: [report])
            }
            try await awaitTestValue(service.$state) { $0 == expected }
        }
        try await run("java", status: .failed)
        try await run("example", status: .passed)
        #expect(service.testOutcomes(for: "java").first?.status == .failed)
        #expect(service.testOutcomes(for: "example").first?.status == .passed)
        service.closeRun()
        #expect(service.testOutcomes(for: "java").count == 1)
        #expect(service.testOutcomes(for: "example").count == 1)
    }

    @Test
    func backendCoverageClearsRemovedClassMethodsButPreservesMethodSiblingsAndOtherProjects() async throws {
        let service = LanguageTestService(outcomeResolver: LinkedCoreTestRunOutcome(), executableResolver: TestExecutableResolver(), processFactory: { TestStreamingProcess() })
        defer { service.reset() }
        func run(_ tests: [[String: String]], coverage: [[String: String]]? = nil) async throws {
            // RUN-03: a run that executed no test is a failure, never a pass on exit code 0.
            let expected: LanguageTestRunState = tests.isEmpty ? .failed(exitCode: 0) : .passed
            var json: [String: Any] = ["tests": tests, "summary": ["total": tests.count, "passed": tests.count, "failed": 0, "errors": 0, "skipped": 0], "success": true]
            if let coverage { json["coverage"] = coverage }
            let report = try JSONDecoder().decode(BuildTestResults.self, from: JSONSerialization.data(withJSONObject: json))
            service.runUsingBackend(providerID: "java", scope: .workspace, workspaceURL: URL(fileURLWithPath: "/workspace"), label: "Tests") { _, _ in
                LanguageTestBackendResult(exitCode: 0, reports: [report])
            }
            try await awaitTestValue(service.$state) { $0 == expected }
            #expect(service.errorMessage == (tests.isEmpty ? L10n.string("No tests were found.") : nil))
        }
        func test(_ project: String, _ method: String) -> [String: String] {
            ["project": project, "suite": "Same", "case": method, "status": "passed"]
        }
        try await run([test("a", "old"), test("a", "kept"), test("b", "old")])
        try await run([test("a", "kept")], coverage: [["project": "a", "suite": "Same", "case": "kept"]])
        #expect(service.testOutcomes(for: "java").count == 3)
        try await run([test("a", "new")], coverage: [["project": "a", "suite": "Same"]])
        #expect(service.testOutcomes(for: "java").map { ($0.project ?? "") + ":" + $0.name }.sorted() == ["a:new", "b:old"])
        try await run([], coverage: [["project": "a", "suite": "Same"]])
        #expect(service.testOutcomes(for: "java").map(\.project) == ["b"])
    }

    @Test
    func coverageNamingACaseWithoutItsSuiteIsRejectedAndNeverWidenedToTheProject() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "tests": [], "summary": ["total": 0, "passed": 0, "failed": 0, "errors": 0, "skipped": 0],
            "success": true, "coverage": [["project": "a", "case": "kept"]],
        ] as [String: Any])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BuildTestResults.self, from: json) }
    }

    @Test
    func backendTestsIgnoreCancelledRequestsThatReturnAfterReplacement() async throws {
        let service = LanguageTestService(outcomeResolver: LinkedCoreTestRunOutcome(), executableResolver: TestExecutableResolver(), processFactory: { TestStreamingProcess() })
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
        models = []
        #expect(graph.run.sourceSearchRoots == [root])
        await graph.projectDevelopment.loadProject(at: URL(fileURLWithPath: "/other"), files: [], snapshotID: UUID())
        #expect(graph.run.sourceSearchRoots.map(\.path) == ["/other"])
    }

    @Test
    func providerLaunchUsesNativeProcessAndOldOwnerCannotStopReplacement() async throws {
        let process = TestStreamingProcess()
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let resolver = TestExecutableResolver()
        let service = RunService(process: process, processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(directories: [root.appendingPathComponent("app", isDirectory: true)]),
            preferences: TestRunPreferences(), runConfigurationOperations: TestRunConfigurationOperations(rejectsResolutionWithoutGeneratedDocument: true),
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
        let service = RunService(process: process, processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(directories: invalidDirectory ? [] : [root]),
            preferences: TestRunPreferences(), runConfigurationOperations: TestRunConfigurationOperations(), executableResolver: TestExecutableResolver(),
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
        let configuration = RunConfiguration(id: "user:provider", name: "Main", kind: .process(provider: "build.provider"), buildProvider: reference)
        let service = RunService(process: process, processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(directories: [root]), preferences: TestRunPreferences(), runConfigurationOperations: TestRunConfigurationOperations(savedProvider: reference), executableResolver: TestExecutableResolver(),
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
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
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
        let first = RunConfiguration(id: "service:a", name: "A", kind: .process(provider: "fixture"),
                                     execution: .service)
        let second = RunConfiguration(id: "service:b", name: "B", kind: .process(provider: "fixture"),
                                      execution: .service)
        let service = RunService(
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(), runConfigurationOperations: SelectionRunConfigurationOperations(configurations: [first, second]),
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

    /// Once the project is bound, identification must behave exactly as before.
    @Test
    func identificationAfterProjectLoadGeneratesAndClearsTheUnloadedState() async throws {
        let operations = RecordingRunConfigurationOperations()
        let service = RunService(
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
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
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
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
        #expect(operations.generateCallCount == 0, "a provisional inventory must not be scanned")

        await service.loadProject(
            at: root,
            files: [source],
            snapshotID: UUID()
        )
        await service.generateRunConfigurations()

        #expect(service.generationState == .succeeded(entryCount: 1))
        #expect(
            operations.generateCallCount == 1,
            "generation must run once the snapshot reported its inventory"
        )
    }

    /// A broken configuration must not block identification. Inventory
    /// readiness and configuration validity are separate concerns, so an
    /// unreadable `configurations.json` must not make the project un-ready and
    /// lock the user out of identifying it again.
    @Test
    func unreadableConfigurationStillAllowsRegeneration() async throws {
        let operations = FailingInspectionRunConfigurationOperations()
        let service = RunService(
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let snapshotID = UUID()

        await service.loadProject(at: root, files: [], snapshotID: snapshotID)

        #expect(service.configurationStatus == .invalid("configurations.json is invalid"))
        #expect(service.isProjectReady(for: root, snapshotID: snapshotID))

        await service.generateRunConfigurations()
        #expect(service.generationState != .projectNotReady)
    }

    @Test
    func currentGoFileRunsThroughExtensionOwnedSession() async throws {
        let builtInProcess = TestStreamingProcess()
        let extensionSession = TestLanguageExecutionSession()
        let service = RunService(
            process: builtInProcess,
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
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
            process: builtInProcess,
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
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
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(contents: [
                URL(fileURLWithPath: "/workspace/go.mod"): "module example.dev/api"
            ]),
            preferences: TestRunPreferences(),
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
            kind: .process(provider: provider)
        )
        let service = makeRunService(
            configuration: configuration,
            options: RunOptions(),
            fileAccess: TestRunFileAccess()
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
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(
                contents: [moduleFile: "module example.dev/api"],
                directories: [root.appendingPathComponent("vendor", isDirectory: true)]
            ),
            preferences: TestRunPreferences(),
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
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(contents: [moduleFile: "module example.dev/api"]),
            preferences: TestRunPreferences(),
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
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(contents: [moduleFile: "module example.dev/api"]),
            preferences: TestRunPreferences(),
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
            outcomeResolver: LinkedCoreTestRunOutcome(),
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
        let service = LanguageTestService(outcomeResolver: LinkedCoreTestRunOutcome(), executableResolver: TestExecutableResolver(), processFactory: { process })
        defer { service.reset() }
        #expect(service.run(providerID: "go", scope: .workspace, workspaceURL: root,
                            projectFiles: [root.appendingPathComponent("go.mod")]))
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
        let first = root.appendingPathComponent("pkg/first_test.go")
        let second = root.appendingPathComponent("pkg/second_test.go")
        let files = [root.appendingPathComponent("go.mod"), first, second,
            root.appendingPathComponent("package.json"), root.appendingPathComponent("sample.test.js"),
            root.appendingPathComponent("pyproject.toml"), root.appendingPathComponent("test_sample.py")]
        let report = try JSONDecoder().decode(BuildTestResults.self, from: Data(#"{"tests":[{"suite":"demo.FirstTest","case":"check","status":"passed"}],"summary":{"total":1,"passed":1,"failed":0,"errors":0,"skipped":0},"success":true}"#.utf8))
        let service = LanguageTestService(outcomeResolver: LinkedCoreTestRunOutcome(), executableResolver: TestExecutableResolver(), processFactory: { TestStreamingProcess() })
        func run(_ scope: LanguageTestScope) {
            service.runUsingBackend(providerID: "go", scope: scope, workspaceURL: root, label: "Tests") { _, _ in
                LanguageTestBackendResult(exitCode: 0, reports: [report])
            }
        }
        defer { service.reset() }
        service.discover(workspaceURL: root, files: files)
        let discovered = service.itemsByProviderID
        for provider in ["go", "node", "python"] {
            #expect(discovered[provider]?.contains { $0.kind == .workspace } == true)
        }
        run(.testCase(identifier: "demo.FirstTest#check", fileURL: first))
        try await awaitTestValue(service.$state, matching: { $0 == .passed })
        let outcomes = service.testOutcomes(for: "go")
        #expect(service.results?.summary.total == 1)
        #expect(outcomes.first?.suite == "demo.FirstTest")
        if clearOnly { service.clearOutput() } else { service.closeRun() }
        #expect(service.results == nil)
        #expect(service.testOutcomes(for: "go") == outcomes, "Editor marker history must outlive the visible result")
        #expect(service.itemsByProviderID == discovered)
        run(.file(second))
        #expect(service.hasRun(providerID: "go", scope: .file(second)))
        run(.workspace)
        #expect(service.hasRun(providerID: "go", scope: .workspace))
    }

    @Test(arguments: [false, true])
    func closingTestRunPreservesDiscoveryAndAllowsNewRun(completed: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace/test-tab", isDirectory: true)
        let files = [root.appendingPathComponent("go.mod")]
        let process = TestStreamingProcess()
        let service = LanguageTestService(
            outcomeResolver: LinkedCoreTestRunOutcome(),
            executableResolver: TestExecutableResolver(),
            processFactory: { process }
        )
        defer { service.reset() }
        service.discover(workspaceURL: root, files: files)
        let discovered = service.itemsByProviderID
        #expect(!discovered.isEmpty)
        #expect(!service.hasRun(providerID: "go", scope: .workspace))
        #expect(service.run(providerID: "go", scope: .workspace,
                            workspaceURL: root, projectFiles: files))
        #expect(service.activePlan != nil)
        #expect(!service.output.isEmpty)
        #expect(service.hasRun(providerID: "go", scope: .workspace))
        #expect(!service.hasRun(providerID: "go", scope: .file(files[0])))
        #expect(!service.hasRun(providerID: "python", scope: .workspace))
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
        #expect(!service.hasRun(providerID: "go", scope: .workspace))
        #expect(service.itemsByProviderID == discovered)

        // Closing a result must leave the discovered scopes runnable.
        #expect(service.run(providerID: "go", scope: .workspace,
                            workspaceURL: root, projectFiles: files))
        #expect(service.activePlan != nil)
        #expect(service.isRunning)
    }

    @Test
    func stoppingTheGraphStopsServiceSessions() async throws {
        let moduleProcess = TestStreamingProcess()
        let configuration = RunConfiguration(
            id: "fixture:main", name: "Main", kind: .process(provider: "fixture"),
            execution: .service
        )
        let resolver = TestExecutableResolver()
        let service = RunService(
            process: TestStreamingProcess(),
            processFactory: { moduleProcess },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            runConfigurationOperations: FixedLaunchPlanRunConfigurationOperations(
                configuration: configuration,
                plan: SharedLaunchPlan(
                    executable: .toolchain("fixture-runtime"),
                    arguments: ["serve"],
                    workingDirectory: "."
                )
            ),
            executableResolver: resolver,
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let graph = ExecutionFeatureGraph(
            run: service,
            tests: LanguageTestService(
                outcomeResolver: LinkedCoreTestRunOutcome(),
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
        service.startConfiguration(configuration)

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

    @Test(arguments: [LanguageTestRunState.passed, .failed(exitCode: 7), .cancelled])
    func processLanguageTestsRemainIndependentFromProviderReports(expectedState: LanguageTestRunState) async throws {
        let root = URL(fileURLWithPath: "/workspace/go-tests", isDirectory: true)
        let source = root.appendingPathComponent("calc/calc_test.go")
        let buildFile = root.appendingPathComponent("go.mod")
        let process = TestStreamingProcess()
        let service = LanguageTestService(
            outcomeResolver: LinkedCoreTestRunOutcome(),
            executableResolver: TestExecutableResolver(),
            processFactory: { process }
        )

        #expect(service.run(
            providerID: "go",
            scope: .file(source),
            workspaceURL: root,
            projectFiles: [buildFile, source]
        ))
        #expect(service.activePlan?.frameworkID == "go")
        #expect(service.activePlan?.launchPlan.arguments == ["test", "./calc"])
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
    func inspect(at _: URL, checkFingerprint _: Bool, providerRuns _: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at _: URL, providerRuns _: [RunProviderConfiguration]?, lease _: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: configurations.count)
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: ([.currentFile] + configurations).map {
                EffectiveRunConfiguration(configuration: $0, options: RunOptions())
            }, diagnostics: [], defaultConfigurationID: configurations.first?.id
        )
    }
    func launchPlan(at _: URL, configurationID: String) throws -> SharedLaunchPlan {
        SharedLaunchPlan(executable: .toolchain("fixture-runtime"), arguments: [configurationID], workingDirectory: ".")
    }
}

/// Records how the service inspects: a full check reads every project input,
/// so only project loads may request it (issue #507). Provider staleness is
/// compared against the Provider snapshot the service hands over.
private final class FreshnessRecordingRunConfigurationOperations: RunConfigurationOperations, @unchecked Sendable {
    var inputsChanged = true
    var staleProviderModel = false
    var providerInspectionGate: InventoryInspectionGate?
    private(set) var providerInspections: [[RunProviderConfiguration]] = []
    var runInspections: [[RunProviderConfiguration]] { providerInspections }
    var providerConfiguration: RunConfiguration?
    var generationGate: InventoryInspectionGate?
    private(set) var generationLeases: [RunConfigurationGenerationLease] = []
    private(set) var fingerprintChecks: [Bool] = []
    private let custom = RunConfiguration(
        id: "Custom", name: "Custom", kind: .process(provider: "build.provider"),
        execution: .service,
        buildProvider: BuildProviderRunReference(pluginID: "dev.custom", buildSystemID: "engine", root: ".",
            run: "serve", projectID: "custom", targetID: "custom", execution: .service)
    )

    func inspect(at _: URL, checkFingerprint: Bool, providerRuns: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection {
        fingerprintChecks.append(checkFingerprint)
        var diagnostics: [RunConfigurationDiagnostic] = []
        if checkFingerprint && inputsChanged {
            diagnostics.append(RunConfigurationDiagnostic(
                configurationID: nil, code: "staleFingerprint",
                message: "Project inputs changed: 0 added, 0 removed, 1 modified"
            ))
        }
        if let providerRuns {
            providerInspections.append(providerRuns)
            if let gate = providerInspectionGate {
                gate.entered.continuation.yield(())
                // The synchronous port runs on RunService's utility queue; the
                // test releases it and every assertion path has cleanup/deadline.
                if gate.release.wait(timeout: .now() + 2) != .success { Issue.record("Provider inspection gate expired") }
            }
            if staleProviderModel {
                diagnostics.append(RunConfigurationDiagnostic(configurationID: nil, code: "staleProviderModel", message: "regenerate"))
            }
        }
        return ProjectRunConfigurationInspection(status: .ready, diagnostics: diagnostics)
    }
    func generate(at _: URL, providerRuns _: [RunProviderConfiguration]?, lease: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult {
        generationLeases.append(lease)
        try lease.check()
        if let gate = generationGate {
            gate.entered.continuation.yield(())
            if gate.release.wait(timeout: .now() + 2) != .success { Issue.record("Generation publication gate expired") }
        }
        try lease.check()
        return RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [.currentFile, providerConfiguration ?? custom].map {
                EffectiveRunConfiguration(configuration: $0, options: RunOptions())
            },
            diagnostics: [],
            defaultConfigurationID: nil
        )
    }
    func launchPlan(at _: URL, configurationID: String) throws -> SharedLaunchPlan {
        SharedLaunchPlan(executable: .toolchain("fixture-runtime"), arguments: [configurationID], workingDirectory: ".")
    }
}

/// Returns a fixed launch plan (optionally carrying pre-launch steps and a
/// classpath) so a test can drive the compile-then-run orchestration without a
/// real Rust core.
private struct FixedLaunchPlanRunConfigurationOperations: RunConfigurationOperations {
    let configuration: RunConfiguration
    let plan: SharedLaunchPlan
    var options = RunOptions()

    func inspect(at _: URL, checkFingerprint _: Bool, providerRuns _: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at _: URL, providerRuns _: [RunProviderConfiguration]?, lease _: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult {
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
    func launchPlan(at _: URL, configurationID _: String) throws -> SharedLaunchPlan {
        plan
    }
}

@MainActor
private func makeRunService(
    configuration: RunConfiguration,
    options: RunOptions,
    fileAccess: TestRunFileAccess
) -> RunService {
    RunService(
        process: TestStreamingProcess(),
        processFactory: { TestStreamingProcess() },
        fileAccess: fileAccess,
        preferences: TestRunPreferences(),
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
    let resolver = TestExecutableResolver()
    let run = RunService(
        process: TestStreamingProcess(),
        processFactory: { TestStreamingProcess() },
        fileAccess: TestRunFileAccess(),
        preferences: TestRunPreferences(),
        runConfigurationOperations: runOperations,
        executableResolver: resolver,
        languageProviderCatalog: .compatibilityFallback,
        languageRunProviders: .standard(catalog: .compatibilityFallback)
    )
    let tests = LanguageTestService(
        outcomeResolver: LinkedCoreTestRunOutcome(),
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

private struct SingleRunConfigurationOperations: RunConfigurationOperations {
    let configuration: RunConfiguration
    let options: RunOptions

    func inspect(at _: URL, checkFingerprint _: Bool, providerRuns _: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at _: URL, providerRuns _: [RunProviderConfiguration]?, lease _: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(configuration: configuration, options: options)],
            diagnostics: [],
            defaultConfigurationID: configuration.id
        )
    }
    func launchPlan(at _: URL, configurationID _: String) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Not required by the port resolution test")
    }
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
    var rejectsResolutionWithoutGeneratedDocument = false
    var savedProvider: BuildProviderRunReference? = nil
    func saveBuildProviderConfiguration(_ reference: BuildProviderRunReference, name: String, at projectURL: URL) throws -> String {
        guard reference == savedProvider else { throw RunFixtureError.failed }
        return "user:provider"
    }
    var inspectionGate: InventoryInspectionGate? = nil
    func inspect(at projectURL: URL, checkFingerprint _: Bool, providerRuns _: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection {
        if let inspectionGate {
            inspectionGate.entered.continuation.yield(())
            if inspectionGate.release.wait(timeout: .now() + 2) != .success {
                Issue.record("Run inspection was not released before its deadline")
            }
        }
        return ProjectRunConfigurationInspection(status: .missing, diagnostics: [])
    }
    func generate(at projectURL: URL, providerRuns _: [RunProviderConfiguration]?, lease _: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 0)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        if rejectsResolutionWithoutGeneratedDocument { throw RunFixtureError.failed }
        if let savedProvider {
            let configuration = RunConfiguration(id: "user:provider", name: "Main", kind: .process(provider: "build.provider"), buildProvider: savedProvider)
            return RunConfigurationResolution(configurations: [.init(configuration: configuration, options: RunOptions())],
                diagnostics: [], defaultConfigurationID: nil)
        }
        return RunConfigurationResolution(configurations: [], diagnostics: [], defaultConfigurationID: nil)
    }
    func launchPlan(at projectURL: URL, configurationID: String) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Unavailable in lifecycle test")
    }
}

/// Records the file inventory each generation attempt was given, so a test can
/// prove both that a pending workspace never reaches the store and that a ready
/// one is scanned with the complete inventory.
private final class RecordingRunConfigurationOperations: RunConfigurationOperations, @unchecked Sendable {
    private(set) var generateCallCount = 0

    func inspect(at projectURL: URL, checkFingerprint _: Bool, providerRuns _: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(
            status: generateCallCount == 0 ? .missing : .ready,
            diagnostics: []
        )
    }
    func generate(at projectURL: URL, providerRuns _: [RunProviderConfiguration]?, lease _: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult {
        generateCallCount += 1
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
    func launchPlan(at projectURL: URL, configurationID: String) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Unavailable in identification test")
    }
}

/// Reports an unreadable configuration so a test can observe the failed state.
private struct FailingInspectionRunConfigurationOperations: RunConfigurationOperations {
    func inspect(at projectURL: URL, checkFingerprint _: Bool, providerRuns _: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(
            status: .invalid("configurations.json is invalid"),
            diagnostics: [],
            recoveryAction: .editConfiguration
        )
    }
    func generate(at projectURL: URL, providerRuns _: [RunProviderConfiguration]?, lease _: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 0)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(configurations: [], diagnostics: [], defaultConfigurationID: nil)
    }
    func launchPlan(at projectURL: URL, configurationID: String) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Unavailable in inspection test")
    }
}

private struct TestReadyRunConfigurationOperations: RunConfigurationOperations {
    func inspect(at projectURL: URL, checkFingerprint _: Bool, providerRuns _: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at projectURL: URL, providerRuns _: [RunProviderConfiguration]?, lease _: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult {
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
    func launchPlan(at projectURL: URL, configurationID: String) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "The extension must supply this launch plan")
    }
}

private struct TestGoProjectRunConfigurationOperations: RunConfigurationOperations {
    private let configuration = RunConfiguration(
        id: "go:api",
        name: "Go API",
        kind: .process(provider: "go.main"),
        execution: .application
    )

    func inspect(at projectURL: URL, checkFingerprint _: Bool, providerRuns _: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at projectURL: URL, providerRuns _: [RunProviderConfiguration]?, lease _: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult {
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
    func launchPlan(at projectURL: URL, configurationID: String) throws -> SharedLaunchPlan {
        SharedLaunchPlan(
            executable: .toolchain("project-go"),
            arguments: ["run", "./cmd/api"],
            workingDirectory: "."
        )
    }
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


/// Two saved Provider services. Any legacy goal-planning call fails the test.
private struct ProviderChoicesRunOperations: RunConfigurationOperations {
    var withReference = true
    var configurations: [RunConfiguration] { ["first", "second"].map { id in RunConfiguration(id: id, name: id,
        kind: .process(provider: "build.provider"), execution: .service,
        buildProvider: .init(pluginID: "dev.first", buildSystemID: "maven", root: ".", run: "service", projectID: id, targetID: "service", execution: .service)) } }
    func inspect(at _: URL, checkFingerprint _: Bool, providerRuns _: [RunProviderConfiguration]?) -> ProjectRunConfigurationInspection { .init(status: .ready, diagnostics: []) }
    func generate(at _: URL, providerRuns _: [RunProviderConfiguration]?, lease _: RunConfigurationGenerationLease) throws -> RunConfigurationGenerationResult { .init(entryCount: 2) }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        .init(configurations: configurations.map { .init(configuration: $0, options: RunOptions()) }, diagnostics: [], defaultConfigurationID: configurations.first?.id)
    }
    func providerLaunchInputs(at _: URL, configurationID: String, providerRoot _: String) throws -> ProviderLaunchInputs {
        .init(buildSystemID: "maven", provider: "quarkus.maven", projectPath: configurationID,
              launchOptions: .init(execution: .service, arguments: ["a b", "雪"]),
              reference: withReference ? .init(pluginID: "dev.first", buildSystemID: "maven", root: ".", run: "service", projectID: configurationID, targetID: "service", execution: .service) : nil)
    }
    func launchPlan(at _: URL, configurationID _: String) throws -> SharedLaunchPlan {
        Issue.record("Provider-owned service reached the Core launch planner")
        throw RunFixtureError.failed
    }
}

@MainActor
private final class ProviderPreparationGate {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let finished = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    deinit { entered.continuation.finish(); release.continuation.finish(); finished.continuation.finish() }
}

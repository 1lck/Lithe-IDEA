import Combine
import Foundation
import LitheApplicationKernel
@testable import LitheExecutionModule
import LitheCoreContracts
import Testing

@MainActor
struct BuildSystemServiceTests {
    private static let workspace = URL(fileURLWithPath: "/workspace/demo")

    @Test
    func languageImportUsesEffectiveOptionsAndRefreshesAfterSelection() async throws {
        let planner = FakeBuildPlanner()
        planner.importEnabled = true
        planner.dynamicOptions = true
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = ["features": .array([.string("first")])]
        harness.service.reset(workspaceURL: Self.workspace)
        let first = try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        #expect(first.mavenContext?.profiles == ["first"])

        harness.service.setOption(Self.instanceID, optionID: "features", value: .array([.string("next")]))
        let next = try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        #expect(next.mavenContext?.profiles == ["next"])
        #expect(harness.service.languageImport == next)
    }

    @Test
    func languageImportWaiterCancellationDoesNotCancelSharedDetection() async throws {
        let planner = FakeBuildPlanner()
        planner.importEnabled = true
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let gate = GatedBuildDecode()
        planner.detectGate = gate
        let harness = Harness(planner: planner)
        defer { gate.releaseDecode(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await gate.entered.waitUntilOpen())
        let waiterStarted = BuildTestGate()
        let waiterFinished = BuildTestGate()
        let cancelled = Task { @MainActor in
            waiterStarted.open()
            defer { waiterFinished.open() }
            // No actor suspension before prepare registers its continuation.
            return try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        }
        defer { cancelled.cancel() }
        try #require(await waiterStarted.waitUntilOpen())
        cancelled.cancel()
        try #require(await waiterFinished.waitUntilOpen())
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        gate.releaseDecode()
        let shared = try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        #expect(shared.mavenContext?.reactorPath == "app")
    }

    @Test
    func stoppingServiceFinishesARegisteredLanguageImportWaiter() async throws {
        let planner = FakeBuildPlanner()
        planner.importEnabled = true
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let gate = GatedBuildDecode()
        planner.detectGate = gate
        let harness = Harness(planner: planner)
        defer { gate.releaseDecode(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await gate.entered.waitUntilOpen())
        let waiterStarted = BuildTestGate()
        let waiterFinished = BuildTestGate()
        let pending = Task { @MainActor in
            waiterStarted.open()
            defer { waiterFinished.open() }
            return try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        }
        defer { pending.cancel() }
        try #require(await waiterStarted.waitUntilOpen())

        harness.service.stop()

        try #require(await waiterFinished.waitUntilOpen())
        await #expect(throws: CancellationError.self) { try await pending.value }
        gate.releaseDecode()
        try #require(await gate.finished.waitUntilOpen())
        #expect(harness.service.languageImport == nil)
    }

    @Test
    func watchedFilesInvalidateLanguageImportBeforeDebouncedDetection() async throws {
        let planner = FakeBuildPlanner()
        planner.importEnabled = true
        planner.dynamicOptions = true
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let debounceStarted = BuildTestGate()
        let releaseDebounce = BuildTestGate()
        let debounceFinished = BuildTestGate()
        let harness = Harness(planner: planner, waitForRedetection: {
            debounceStarted.open()
            defer { debounceFinished.open() }
            guard await releaseDebounce.waitUntilOpen() else { throw GatedDecodeError.releaseTimedOut }
        })
        defer { releaseDebounce.open(); harness.service.stop() }
        harness.optionsStore.values["fixture"] = ["features": .array([.string("first")])]
        harness.service.reset(workspaceURL: Self.workspace)
        let first = try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        #expect(first.mavenContext?.profiles == ["first"])

        harness.service.workspaceFilesChanged([Self.workspace.appendingPathComponent("build.file")])
        #expect(harness.service.languageImport == nil)
        try #require(await debounceStarted.waitUntilOpen())
        harness.optionsStore.values["fixture"] = ["features": .array([.string("next")])]
        let waiterStarted = BuildTestGate()
        let pending = Task { @MainActor in
            waiterStarted.open()
            return try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        }
        defer { pending.cancel() }
        try #require(await waiterStarted.waitUntilOpen())
        #expect(harness.service.languageImport == nil)

        releaseDebounce.open()
        let next = try await pending.value
        try #require(await debounceFinished.waitUntilOpen())
        #expect(next.mavenContext?.profiles == ["next"])
        #expect(harness.service.languageImport == next)
    }

    @Test
    func commandModelRecomputesLanguageImportWithItsAcceptedOptions() async throws {
        let planner = FakeBuildPlanner()
        planner.importEnabled = true
        planner.dynamicOptions = true
        planner.modelOptionValues = ["features": ["cli"]]
        planner.modelOutput = .stdout
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: [], result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL"))
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = ["features": .array([.string("cli"), .string("removed")])]
        harness.service.reset(workspaceURL: Self.workspace)
        let initial = try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        #expect(initial.mavenContext?.profiles == ["cli", "removed"])

        harness.service.loadModel(Self.instanceID)
        try #require(await harness.waitForEntries { $0.first?.modelState == .loaded })
        let loaded = try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)

        #expect(loaded.mavenContext?.profiles == ["cli"])
        #expect(harness.service.languageImport == loaded)
        #expect(runner.requests.count == 1)
    }

    @Test
    func replacedWorkspaceDoesNotPublishItsPendingLanguageImport() async throws {
        let planner = FakeBuildPlanner()
        planner.importEnabled = true
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let gate = GatedBuildDecode()
        planner.detectGate = gate
        let harness = Harness(planner: planner)
        defer { gate.releaseDecode(); harness.service.stop() }
        var published: [URL] = []
        harness.service.onLanguageImportChanged = { published.append($0) }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await gate.entered.waitUntilOpen())
        harness.service.reset(workspaceURL: nil)
        gate.releaseDecode()
        try #require(await gate.finished.waitUntilOpen())
        #expect(harness.service.languageImport == nil)
        #expect(published.isEmpty)
    }

    @Test
    func detectionPublishesEntriesAndNamesRefusedPlugins() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = try decode(BuildDetection.self, """
        {"instances": [\(Self.instanceJSON(modelSource: "static", model: #"{"projects": [{"id": "p", "path": ".", "name": "demo"}]}"#))],
         "rejected": [{"index": 1, "error": {"code": "plugin.build.invalid", "message": "Broken manifest."}}],
         "shadowed": [{"pluginID": "dev.other", "buildSystemID": "fixture", "by": "dev.example"}]}
        """)
        let harness = Harness(planner: planner, sources: [fixtureSource(), fixtureSource(pluginID: "dev.broken")])
        defer { harness.service.stop() }

        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        let entry = try #require(harness.service.entries.first)
        #expect(entry.model?.projects.map(\.name) == ["demo"])
        #expect(entry.modelState == .loaded)
        #expect(entry.options.map(\.id) == ["release"])
        #expect(entry.sync?.watch == ["build.file"])
        #expect(harness.service.issues.contains("dev.broken: Broken manifest."))
        #expect(harness.service.issues.count == 2)
        #expect(!harness.service.isDetecting)
    }

    @Test
    func commandModelRunsWithCapturedStandardOutputAndRemovesItsOutputFile() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.modelOutput = .stdout
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: ["warming up\n"], result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL"))
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })

        let request = try #require(runner.requests.first)
        #expect(request.capturesStandardOutput)
        #expect(request.arguments == ["model"])
        #expect(request.workingDirectory.path == "/workspace/demo/app")
        #expect(request.environment == ["PATH": "/tool/bin", "FROM_PLAN": "1"])
        #expect(request.timeout == BuildSystemService.modelTimeout)
        #expect(planner.decodedModelOutputs == [.stdout("MODEL")])
        #expect(harness.service.entries.first?.model?.projects.map(\.name) == ["loaded"])
        #expect(harness.stateLocator.removed == harness.stateLocator.allocated)
        #expect(harness.service.output.contains("warming up"))
        #expect(!harness.service.hasActiveWork)
    }

    @Test
    func failedModelCommandReportsItsExitCode() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: ["no such task\n"], result: BuildCommandResult(termination: .exited(2)))
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries {
            if case .failed = $0.first?.modelState { return true }
            return false
        })
        guard case .failed(let message)? = harness.service.entries.first?.modelState else { return }
        #expect(message.contains("2"))
        #expect(message.contains("no such task"))
        #expect(planner.decodedModelOutputs.isEmpty)
    }

    @Test
    func taskStreamsOutputInOrderAndDecodesDiagnostics() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        planner.diagnostics = try decode([BuildDiagnostic].self, """
        [{"path": "src/a.rs", "line": 3, "severity": "error", "message": "bad"}]
        """)
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: ["one\n", "two\n", "three\n"], result: BuildCommandResult(termination: .exited(1)))
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        let runID = try #require(harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build"))
        #expect(harness.service.currentRunID == runID)
        #expect(harness.service.runState == .running)
        var ended: [BuildRunEnd] = []
        let observation = harness.service.runEnded.sink { ended.append($0) }
        defer { observation.cancel() }
        #expect(await harness.waitForRunState { $0 != .running })
        #expect(ended == [BuildRunEnd(runID: runID, entryID: Self.instanceID,
            state: harness.service.runState, exitCode: 1)])

        guard case .failed = harness.service.runState else {
            Issue.record("Expected a failed run, got \(harness.service.runState)")
            return
        }
        #expect(harness.service.output == "$ /tool/bin/fake build 'with space'\none\ntwo\nthree\n")
        #expect(harness.service.diagnostics.map(\.path) == ["src/a.rs"])
        #expect(planner.diagnosticOutputs == ["one\ntwo\nthree\n"])
        #expect(runner.requests.first?.capturesStandardOutput == false)
        #expect(runner.requests.first?.timeout == nil)
    }

    @Test
    func stopRunCancelsTheRunningCommand() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let runner = FakeBuildRunner()
        runner.blocksUntilCancelled = true
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        #expect(await runner.started.waitUntilOpen())
        #expect(harness.service.hasActiveWork)

        let runID = try #require(harness.service.currentRunID)
        #expect(harness.service.runTask("missing", request: BuildTaskRequest(task: "build"), title: "Missing") == nil)
        #expect(harness.service.currentRunID == runID)
        var ended: [BuildRunEnd] = []
        let observation = harness.service.runEnded.sink { ended.append($0) }
        defer { observation.cancel() }
        harness.service.stopRun()
        #expect(harness.service.runState == .cancelled)
        #expect(ended == [BuildRunEnd(runID: runID, entryID: Self.instanceID, state: .cancelled, exitCode: nil)])
        #expect(await runner.cancelled.waitUntilOpen())
        #expect(!harness.service.hasActiveWork)
    }

    @Test
    func disablingAPluginStopsItsRunAndRemovesItsInstances() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let runner = FakeBuildRunner()
        runner.blocksUntilCancelled = true
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })
        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        #expect(await runner.started.waitUntilOpen())

        harness.sources = []
        harness.service.pluginsChanged()

        #expect(harness.service.runState == .cancelled)
        #expect(await runner.cancelled.waitUntilOpen())
        #expect(harness.service.entries.isEmpty)
        #expect(!harness.service.hasBuildSystemPlugins)
    }

    @Test
    func refusedOptionValuesAreReplacedByTheirEffectiveValue() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        planner.optionsResolution = try decode(BuildOptionsResolution.self, """
        {"options": [{"id": "features", "displayName": "Features", "kind": "multiSelect",
                      "value": ["fast"], "source": "user"}],
         "dropped": ["features", "removed"], "fingerprint": "f"}
        """)
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = ["removed": .bool(true)]
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.setOption(Self.instanceID, optionID: "features", value: .array([.string("fast"), .string("gone")]))

        #expect(harness.optionsStore.values["fixture"] == ["features": .array([.string("fast")])])
        #expect(harness.service.entries.first?.options.first?.value == .array([.string("fast")]))
    }

    @Test
    func changedFingerprintMarksALoadedCommandModelStale() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: [], result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL"))
        planner.modelOutput = .stdout
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })
        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        #expect(harness.service.entries.first?.isReloadRequired == false)

        planner.fingerprint = "changed"
        harness.service.detect()
        #expect(await harness.waitForEntries { $0.first?.isReloadRequired == true })
        #expect(harness.service.entries.first?.model?.projects.map(\.name) == ["loaded"])
    }

    enum LoadKind: String, CaseIterable, Sendable {
        case model, dependencies

        @MainActor
        func start(_ service: BuildSystemService) {
            switch self {
            case .model: service.loadModel(BuildSystemServiceTests.instanceID)
            case .dependencies: service.loadDependencies(BuildSystemServiceTests.instanceID, project: nil)
            }
        }

        @MainActor
        func isLoading(_ service: BuildSystemService) -> Bool {
            switch self {
            case .model: service.isLoadingModel
            case .dependencies: service.isLoadingDependencies
            }
        }

        func isLoaded(_ entry: BuildSystemEntry?, name: String) -> Bool {
            switch self {
            case .model: return entry?.modelState == .loaded && entry?.model?.projects.first?.name == name
            case .dependencies:
                if case .loaded(let tree) = entry?.dependencies["app"] {
                    return tree.dependencies.first?.name == name
                }
                return false
            }
        }

        @MainActor
        func expectLoading(_ service: BuildSystemService) {
            #expect(isLoading(service))
            #expect(service.hasActiveWork)
            switch self {
            case .model: #expect(service.entry(BuildSystemServiceTests.instanceID)?.modelState == .loading)
            case .dependencies: #expect(service.entry(BuildSystemServiceTests.instanceID)?.dependencies["app"] == .loading)
            }
        }
    }

    enum LoadReplacement: String, CaseIterable, Sendable {
        case reload, stop, reset, disable
    }

    @Test(arguments: LoadKind.allCases, LoadReplacement.allCases)
    func oldCancellationCannotReleaseReplacementLoad(kind: LoadKind, replacement: LoadReplacement) async throws {
        try await verifyLoadOwnership(kind: kind, replacement: replacement, oldFinishesFirst: true)
    }

    @Test(arguments: LoadKind.allCases, LoadReplacement.allCases)
    func oldSuccessCannotOverwriteReplacementResult(kind: LoadKind, replacement: LoadReplacement) async throws {
        try await verifyLoadOwnership(kind: kind, replacement: replacement, oldFinishesFirst: false)
    }

    private func verifyLoadOwnership(
        kind: LoadKind, replacement: LoadReplacement, oldFinishesFirst: Bool
    ) async throws {
        let old = ControlledBuildLoad(output: "OLD", throwsCancellation: oldFinishesFirst)
        let new = ControlledBuildLoad(output: "NEW")
        let runner = ControlledBuildLoadRunner(loads: [old, new])
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.modelOutput = .stdout
        let harness = Harness(planner: planner, runner: runner)
        defer {
            harness.service.reset(workspaceURL: nil)
            old.release.open()
            new.release.open()
        }

        @MainActor
        func cleanUp() async {
            harness.service.reset(workspaceURL: nil)
            old.release.open()
            new.release.open()
            for url in harness.stateLocator.allocated {
                #expect(await harness.stateLocator.waitForRemoval(of: url))
            }
        }

        do {
            harness.service.reset(workspaceURL: Self.workspace)
            try #require(await harness.waitForEntries { !$0.isEmpty })
            kind.start(harness.service)
            try #require(await old.started.waitUntilOpen())
            let oldOutput = try #require(harness.stateLocator.allocated.last)

            switch replacement {
            case .reload: break
            case .stop: harness.service.stop()
            case .reset:
                harness.service.reset(workspaceURL: Self.workspace)
                try #require(await harness.waitForEntries { !$0.isEmpty })
            case .disable:
                harness.sources = []
                harness.service.pluginsChanged()
                try #require(await harness.waitForEntries { $0.isEmpty })
                #expect(!kind.isLoading(harness.service))
                harness.sources = [fixtureSource()]
                harness.service.pluginsChanged()
                try #require(await harness.waitForEntries { !$0.isEmpty })
            }
            kind.start(harness.service)
            try #require(await old.cancelled.waitUntilOpen())
            try #require(await new.started.waitUntilOpen())
            let newOutput = try #require(harness.stateLocator.allocated.last)
            #expect(oldOutput != newOutput)
            kind.expectLoading(harness.service)

            if oldFinishesFirst {
                old.release.open()
                try #require(await harness.stateLocator.waitForRemoval(of: oldOutput))
                // Removal occurs in the load's defer; its synchronous MainActor
                // completion runs before this MainActor waiter can resume.
                #expect(!harness.stateLocator.removed.contains(newOutput))
                kind.expectLoading(harness.service)
                // The replacement's retained handle must still cancel its command.
                harness.service.stop()
                try #require(await new.cancelled.waitUntilOpen())
                new.release.open()
                try #require(await harness.stateLocator.waitForRemoval(of: newOutput))
                #expect(harness.service.entry(Self.instanceID)?.modelState == .notLoaded)
                #expect(harness.service.entry(Self.instanceID)?.dependencies.isEmpty == true)
            } else {
                new.release.open()
                try #require(await harness.waitForEntries { kind.isLoaded($0.first, name: "NEW") })
                try #require(await harness.stateLocator.waitForRemoval(of: newOutput))
                let current = harness.service.entry(Self.instanceID)
                old.release.open()
                try #require(await harness.stateLocator.waitForRemoval(of: oldOutput))
                #expect(harness.service.entry(Self.instanceID) == current)
                #expect(kind.isLoaded(harness.service.entry(Self.instanceID), name: "NEW"))
            }
            #expect(!kind.isLoading(harness.service))
            #expect(!harness.service.hasActiveWork)
            #expect(Set(harness.stateLocator.removed) == Set(harness.stateLocator.allocated))
            #expect(harness.stateLocator.removed.count == 2)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    // MARK: Option and run identity regressions

    /// A value the current model dropped must leave both the stored options
    /// and the argv of the next task.
    @Test
    func taskPlansOnlyReceiveOptionValuesTheModelStillAccepts() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(
                modelSource: "static",
                model: #"{"projects": [{"id": "p", "path": ".", "name": "demo"}], "optionValues": {"features": ["cli"]}}"#
            )
        ])
        planner.loadedOptionsResolution = try Self.filteredOptions()
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = [
            "features": .array([.string("cli"), .string("removed")])
        ]

        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })
        // Detection stores the effective value, so the next plan starts from it.
        #expect(harness.optionsStore.values["fixture"]?["features"] == .array([.string("cli")]))

        harness.service.runTask(
            Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build"
        )
        #expect(await harness.waitForRunState { $0 == .succeeded })
        let context = try #require(planner.taskPlanContexts.last)
        #expect(context.options["features"] == .array([.string("cli")]))
    }

    /// Loading a command model can drop option values too; the stored value
    /// must be replaced even when the user does not touch the option.
    @Test
    func modelLoadStoresTheEffectiveOptionValues() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.dynamicOptions = true
        planner.modelOptionValues = ["features": ["cli"]]
        planner.modelOutput = .stdout
        let runner = FakeBuildRunner()
        runner.script = .init(
            chunks: ["loading\n"],
            result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL")
        )
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = [
            "features": .array([.string("cli"), .string("removed")])
        ]

        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })
        // Without a model the host cannot know which values are stale.
        #expect(
            harness.optionsStore.values["fixture"]?["features"]
                == .array([.string("cli"), .string("removed")])
        )

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        #expect(harness.optionsStore.values["fixture"]?["features"] == .array([.string("cli")]))

        harness.service.runTask(
            Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build"
        )
        #expect(await harness.waitForRunState { $0 == .succeeded })
        let context = try #require(planner.taskPlanContexts.last)
        #expect(context.options["features"] == .array([.string("cli")]))
    }

    /// A diagnostics decode that finishes after a new run started must not
    /// overwrite the new run's diagnostics.
    @Test
    func decodedDiagnosticsDoNotCrossIntoAReplacementRun() async throws {
        let old = try Self.diagnostic("old")
        let new = try Self.diagnostic("new")
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        planner.diagnostics = [old]
        let gate = GatedBuildDecode()
        planner.diagnosticsGate = gate
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.runTask(
            Self.instanceID, request: BuildTaskRequest(task: "build"), title: "First"
        )
        #expect(await gate.entered.waitUntilOpen())

        planner.diagnostics = [new]
        harness.service.runTask(
            Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Second"
        )
        #expect(await harness.waitForDiagnostics { $0 == [new] })

        gate.releaseDecode()
        #expect(await gate.finished.waitUntilOpen())
        // The released decode returns on the main actor promptly; this bounded
        // wait catches a regression without hanging.
        #expect(await harness.waitsForStaleDiagnostics([old]) == false)
        #expect(harness.service.diagnostics == [new])
    }

    /// A test-results decode that finishes after the workspace changed must
    /// not publish into the new workspace.
    @Test
    func decodedTestResultsDoNotCrossIntoAnotherWorkspace() async throws {
        let oldResults = try Self.testResults("old")
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "loaded"))
        ])
        planner.testPlanDeclaresResults = true
        planner.decodedTestResults = oldResults
        let gate = GatedBuildDecode()
        planner.testResultsGate = gate
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.runTests(
            Self.instanceID, request: BuildTestRequest(), title: "Tests"
        )
        #expect(await gate.entered.waitUntilOpen())

        harness.service.reset(workspaceURL: URL(fileURLWithPath: "/workspace/other"))
        #expect(await harness.waitForEntries { !$0.isEmpty })

        gate.releaseDecode()
        #expect(await gate.finished.waitUntilOpen())
        #expect(await harness.waitsForStaleTestResults(oldResults) == false)
        #expect(harness.service.testResults == nil)
    }

    // MARK: Multi-instance options and streamed output ownership

    /// Options are stored per workspace and build system, but a model value
    /// belongs to one instance. One instance must not delete a value another
    /// instance still accepts.
    @Test
    func multiInstanceOptionValuesSurviveForInstancesThatStillAcceptThem() async throws {
        let planner = FakeBuildPlanner()
        planner.dynamicOptions = true
        planner.detection = BuildDetection(instances: [
            try Self.nestedInstance(id: "fixture:a", root: "a", features: ["cli"]),
            try Self.nestedInstance(id: "fixture:b", root: "b", features: [])
        ])
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = [
            "features": .array([.string("cli"), .string("removed")])
        ]

        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.count == 2 })
        // `removed` is accepted by no instance; `cli` stays because `a` does.
        #expect(harness.optionsStore.values["fixture"]?["features"] == .array([.string("cli")]))
        let a = try #require(harness.service.entry("fixture:a"))
        let b = try #require(harness.service.entry("fixture:b"))
        #expect(a.options.first { $0.id == "features" }?.value == .array([.string("cli")]))
        #expect(b.options.first { $0.id == "features" }?.value == .array([]))
        #expect(b.options.first { $0.id == "features" }?.source == "unset")

        // Each plan filters the shared value against its own model. An
        // entirely rejected value is unset, not an explicit empty override.
        harness.service.runTask("fixture:a", request: BuildTaskRequest(task: "build"), title: "A")
        #expect(await harness.waitForRunState { $0 == .succeeded })
        #expect(planner.taskPlanContexts.last?.options["features"] == .array([.string("cli")]))
        harness.service.runTask("fixture:b", request: BuildTaskRequest(task: "build"), title: "B")
        #expect(await harness.waitForRunState { $0 == .succeeded })
        #expect(planner.taskPlanContexts.last?.options["features"] == nil)
    }

    @Test
    func instanceOptionEditsPreserveSiblingOnlySelections() async throws {
        let planner = FakeBuildPlanner()
        planner.dynamicOptions = true
        planner.detection = BuildDetection(instances: [
            try Self.nestedInstance(id: "fixture:a", root: "a", features: ["cli", "fast"]),
            try Self.nestedInstance(id: "fixture:b", root: "b", features: ["gui"])
        ])
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = ["features": .array([.string("cli"), .string("gui")])]
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { $0.count == 2 })

        harness.service.setInstanceOption("fixture:a", optionID: "features", value: .array([.string("fast")]))
        #expect(harness.optionsStore.values["fixture"]?["features"] == .array([.string("gui"), .string("fast")]))
        #expect(harness.service.entry("fixture:a")?.options.first?.value == .array([.string("fast")]))
        #expect(harness.service.entry("fixture:b")?.options.first?.value == .array([.string("gui")]))

        // Clearing B retains A's shared choice but records B's explicit empty
        // override. Redetection and task planning must keep that distinction.
        harness.service.setInstanceOption("fixture:b", optionID: "features", value: .array([]))
        try #require(await harness.waitForDetectionToFinish())
        #expect(harness.optionsStore.values["fixture"]?["features"] == .array([.string("fast")]))
        #expect(harness.optionsStore.emptyMultiSelectOptions(
            workspaceURL: Self.workspace, buildSystemID: "fixture"
        ) == ["b": Set(["features"])])
        #expect(harness.service.entry("fixture:a")?.options.first?.value == .array([.string("fast")]))
        #expect(harness.service.entry("fixture:b")?.options.first?.value == .array([]))
        #expect(harness.service.entry("fixture:b")?.options.first?.source == "user")
        harness.service.runTask("fixture:b", request: BuildTaskRequest(task: "build"), title: "B")
        try #require(await harness.waitForRunState { $0 == .succeeded })
        #expect(planner.taskPlanContexts.last?.options["features"] == .array([]))

        harness.service.setInstanceOption("fixture:b", optionID: "features", value: .array([.string("gui")]))
        #expect(harness.optionsStore.emptyMultiSelectOptions(
            workspaceURL: Self.workspace, buildSystemID: "fixture"
        ).isEmpty)
        #expect(harness.service.entry("fixture:b")?.options.first?.value == .array([.string("gui")]))
        #expect(harness.service.entry("fixture:a")?.options.first?.value == .array([.string("fast")]))

        harness.service.setInstanceOption("fixture:b", optionID: "features", value: .array([]))
        harness.service.setInstanceOption("fixture:a", optionID: "features", value: .array([]))
        #expect(harness.optionsStore.values["fixture"]?["features"] == .array([]))
        #expect(harness.optionsStore.emptyMultiSelectOptions(
            workspaceURL: Self.workspace, buildSystemID: "fixture"
        ) == ["a": Set(["features"]), "b": Set(["features"])])

        // A non-empty instance edit clears only its own marker; resetting the
        // shared option removes the override and every root's marker.
        harness.service.setInstanceOption("fixture:a", optionID: "features", value: .array([.string("cli")]))
        #expect(harness.optionsStore.values["fixture"]?["features"] == .array([.string("cli")]))
        #expect(harness.optionsStore.emptyMultiSelectOptions(
            workspaceURL: Self.workspace, buildSystemID: "fixture"
        ) == ["b": Set(["features"])])
        #expect(harness.service.entry("fixture:b")?.options.first?.value == .array([]))
        harness.service.setInstanceOption("fixture:a", optionID: "features", value: nil)
        #expect(harness.optionsStore.values["fixture"]?["features"] == nil)
        #expect(harness.optionsStore.emptyMultiSelectOptions(
            workspaceURL: Self.workspace, buildSystemID: "fixture"
        ).isEmpty)
        #expect(harness.service.entry("fixture:a")?.options.first?.source == "unset")
        #expect(harness.service.entry("fixture:b")?.options.first?.source == "unset")

        harness.service.setInstanceOption("fixture:a", optionID: "features", value: .array([]))
        harness.service.setInstanceOption("fixture:b", optionID: "features", value: .array([]))
        #expect(harness.optionsStore.emptyMultiSelectOptions(
            workspaceURL: Self.workspace, buildSystemID: "fixture"
        ) == ["a": Set(["features"]), "b": Set(["features"])])
        harness.service.setOption("fixture:a", optionID: "features", value: .array([.string("cli"), .string("gui")]))
        #expect(harness.optionsStore.emptyMultiSelectOptions(
            workspaceURL: Self.workspace, buildSystemID: "fixture"
        ).isEmpty)
        #expect(harness.service.entry("fixture:a")?.options.first?.value == .array([.string("cli")]))
        #expect(harness.service.entry("fixture:b")?.options.first?.value == .array([.string("gui")]))
    }

    @Test
    func languageImportPublishesTheSameEffectiveOptionsAsBuildPlansAndClearsDisabledPlugins() async throws {
        let planner = FakeBuildPlanner()
        planner.hasMavenLanguageImport = true
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        planner.optionsResolution = try decode(BuildOptionsResolution.self, """
        {"options": [
          {"id":"profiles", "displayName":"Profiles", "kind":"multiSelect", "value":["dev"], "source":"user"},
          {"id":"settingsFile", "displayName":"Settings", "kind":"file", "value":"/fixture/settings.xml", "source":"user"},
          {"id":"localRepository", "displayName":"Repository", "kind":"directory", "value":"/fixture/repository", "source":"user"}
         ], "dropped":["profiles"], "fingerprint":"first"}
        """)
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = [
            "profiles": .array([.string("dev"), .string("removed")]),
            "settingsFile": .string("/fixture/settings.xml"), "localRepository": .string("/fixture/repository")
        ]
        let published = BuildTestGate()
        var callbacks = 0
        harness.service.onLanguageImportChanged = { _ in callbacks += 1; published.open() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await published.waitUntilOpen())
        let context = try #require(harness.service.languageImport?.mavenContext)
        #expect(context.profiles == ["dev"])
        #expect(context.settingsPath == "/fixture/settings.xml")
        #expect(context.localRepositoryPath == "/fixture/repository")
        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        #expect(await harness.waitForRunState { $0 == .succeeded })
        #expect(planner.languageImportInputs.last == planner.taskPlanContexts.last?.options)

        let changed = BuildTestGate()
        harness.service.onLanguageImportChanged = { _ in callbacks += 1; changed.open() }
        planner.optionsResolution = try decode(BuildOptionsResolution.self, """
        {"options": [{"id":"profiles", "displayName":"Profiles", "kind":"multiSelect", "value":[], "source":"user"}],
         "dropped":[], "fingerprint":"second"}
        """)
        harness.service.setOption(Self.instanceID, optionID: "profiles", value: .array([]))
        #expect(await changed.waitUntilOpen())
        #expect(harness.service.languageImport?.mavenContext?.profiles == [])
        #expect(harness.service.languageImport?.mavenContext?.settingsPath == nil)
        harness.sources = []
        harness.service.pluginsChanged()
        let disabled = try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        #expect(disabled == JavaLanguageImportConfiguration())
        #expect(harness.service.languageImport == disabled)
        #expect(callbacks == 3)
        harness.service.reset(workspaceURL: nil)
        #expect(harness.service.languageImport == nil)
        await #expect(throws: CancellationError.self) {
            _ = try await harness.service.prepareLanguageImport(workspaceURL: Self.workspace)
        }
    }

    /// Output still draining from a cancelled command must not appear in the
    /// run that replaced it.
    @Test
    func lateCommandOutputDoesNotCrossIntoAReplacementRun() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let runner = ReplacedOutputRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "First")
        #expect(await runner.earlyWritten.waitUntilOpen())
        #expect(await harness.waitForOutput { $0.contains("early") })

        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Second")
        #expect(await harness.waitForRunState { $0 == .succeeded })
        #expect(await harness.waitForOutput { $0.contains("second") })

        runner.releaseLate.open()
        // The cancelled command now drains its tail; it must not be shown.
        #expect(await harness.waitsForLateOutput("late") == false)
        #expect(harness.service.output.contains("second"))
    }

    /// Output still draining from a cancelled command must not appear after a
    /// workspace switch either.
    @Test
    func lateCommandOutputDoesNotCrossIntoAnotherWorkspace() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "static")])
        let runner = ReplacedOutputRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "First")
        #expect(await runner.earlyWritten.waitUntilOpen())
        harness.service.reset(workspaceURL: URL(fileURLWithPath: "/workspace/other"))
        #expect(await harness.waitForEntries { !$0.isEmpty })

        runner.releaseLate.open()
        #expect(await harness.waitsForLateOutput("late") == false)
    }

    /// The model command's stderr/output goes through the same ownership check.
    @Test
    func lateModelCommandOutputDoesNotCrossIntoAnotherWorkspace() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        let runner = ReplacedOutputRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await runner.earlyWritten.waitUntilOpen())
        harness.service.reset(workspaceURL: URL(fileURLWithPath: "/workspace/other"))
        #expect(await harness.waitForEntries { !$0.isEmpty })

        runner.releaseLate.open()
        #expect(await harness.waitsForLateOutput("late") == false)
    }

    /// A detection that started before a model load must not replace the
    /// loaded model with its own older snapshot.
    @Test
    func detectionDoesNotOverwriteAModelLoadedWhileItRan() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.modelOutput = .stdout
        let runner = FakeBuildRunner()
        runner.script = .init(
            chunks: ["loading\n"],
            result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL")
        )
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        let gate = GatedBuildDecode()
        planner.detectGate = gate
        harness.service.detect()
        #expect(await gate.entered.waitUntilOpen())

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        let loaded = try #require(harness.service.entry(Self.instanceID)?.model)

        gate.releaseDecode()
        #expect(await gate.finished.waitUntilOpen())
        #expect(await harness.waitForDetectionToFinish())
        #expect(harness.service.entry(Self.instanceID)?.modelState == .loaded)
        #expect(harness.service.entry(Self.instanceID)?.model == loaded)
    }

    /// A dependency load that finished during detection must not replace the
    /// model detection just read.
    @Test
    func detectionKeepsANewModelAndADependencyLoadedWhileItRan() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "before"))
        ])
        let runner = FakeBuildRunner()
        runner.script = .init(
            chunks: [],
            result: BuildCommandResult(termination: .exited(0), standardOutput: "DEPS")
        )
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.model?.projects.first?.name == "before" })

        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "after"))
        ])
        let gate = GatedBuildDecode()
        planner.detectGate = gate
        harness.service.detect()
        #expect(await gate.entered.waitUntilOpen())

        harness.service.loadDependencies(Self.instanceID, project: nil)
        #expect(await harness.waitForEntries { entry in
            guard case .loaded = entry.first?.dependencies["app"] else { return false }
            return true
        })

        gate.releaseDecode()
        #expect(await gate.finished.waitUntilOpen())
        #expect(await harness.waitForDetectionToFinish())
        let entry = try #require(harness.service.entry(Self.instanceID))
        #expect(entry.model?.projects.first?.name == "after")
        guard case .loaded = entry.dependencies["app"] else {
            Issue.record("A dependency load that finished during detection was overwritten")
            return
        }
    }

    /// A normal re-detection with no concurrent load must publish the model it
    /// just read.
    @Test
    func redetectionPublishesANewStaticModel() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "before"))
        ])
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.model?.projects.first?.name == "before" })

        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "after"))
        ])
        harness.service.detect()
        #expect(await harness.waitForDetectionToFinish())
        #expect(harness.service.entry(Self.instanceID)?.model?.projects.first?.name == "after")
    }

    /// Clearing every choice of a multi-select is a value; a non-empty
    /// default must not come back after the next detection.
    @Test
    func explicitlyClearedMultiSelectKeepsItsEmptyValue() async throws {
        let planner = FakeBuildPlanner()
        planner.dynamicOptions = true
        planner.detection = BuildDetection(instances: [
            try Self.nestedInstance(id: "fixture:a", root: "a", features: ["cli"])
        ])
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = ["features": .array([])]

        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })
        #expect(harness.optionsStore.values["fixture"]?["features"] == .array([]))

        harness.service.runTask("fixture:a", request: BuildTaskRequest(task: "build"), title: "Build")
        #expect(await harness.waitForRunState { $0 == .succeeded })
        #expect(planner.taskPlanContexts.last?.options["features"] == .array([]))
    }

    /// An option changed while the model command runs makes its result stale.
    @Test
    func optionChangeDuringModelLoadMarksTheModelStale() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.modelOutput = .stdout
        let runner = ReplacedOutputRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await runner.earlyWritten.waitUntilOpen())

        // The command started with the old options; detection finishes before
        // its result returns.
        harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
        #expect(await harness.waitForDetectionToFinish())
        planner.fingerprint = "changed"

        runner.releaseLate.open()
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        #expect(harness.service.entry(Self.instanceID)?.isReloadRequired == true)
    }

    /// Another plugin can take over the same build-system ID and root; the
    /// old plugin's model and dependencies are not its data.
    @Test
    func pluginTakeoverDropsThePreviousPluginsModel() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "command", pluginID: "dev.a")
        ])
        planner.modelOutput = .stdout
        let runner = FakeBuildRunner()
        runner.script = .init(
            chunks: [],
            result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL")
        )
        let harness = Harness(
            planner: planner,
            runner: runner,
            sources: [fixtureSource(pluginID: "dev.a")]
        )
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })
        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })

        harness.sources = [fixtureSource(pluginID: "dev.b")]
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "command", pluginID: "dev.b")
        ])
        harness.service.pluginsChanged()
        #expect(await harness.waitForEntries { $0.first?.instance.pluginID == "dev.b" })
        let entry = try #require(harness.service.entry(Self.instanceID))
        #expect(entry.modelState == .notLoaded)
        #expect(entry.model == nil)
        #expect(entry.dependencies.isEmpty)
    }

    /// A watched file changed between the model command reading it and the
    /// result returning; the published model must stay marked stale.
    @Test
    func fileChangeDuringModelLoadMarksTheModelStale() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.modelOutput = .stdout
        let runner = ReplacedOutputRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await runner.earlyWritten.waitUntilOpen())
        harness.service.workspaceFilesChanged([
            Self.workspace.appendingPathComponent("build.file")
        ])

        runner.releaseLate.open()
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        #expect(harness.service.entry(Self.instanceID)?.isReloadRequired == true)
    }

    /// Report globs are relative to each project, so workspace tests without
    /// the model would miss every subproject report.
    @Test
    func workspaceTestsWithoutAModelAreRefused() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.testPlanDeclaresResults = true
        let runner = FakeBuildRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.runTests(Self.instanceID, request: BuildTestRequest(), title: "Tests")
        #expect(await harness.waitForRunState { state in
            if case .failed = state { return true }
            return false
        })
        guard case .failed(let message) = harness.service.runState else {
            Issue.record("Workspace tests without a model must be refused")
            return
        }
        #expect(message.contains("model"))
        #expect(runner.requests.isEmpty)
        #expect(harness.service.testResults == nil)
    }

    /// A cleared text option is an explicit empty value; the declaration
    /// default must not replace it after detection.
    @Test
    func explicitlyClearedTextOptionKeepsItsEmptyValue() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "loaded"))
        ])
        planner.optionsResolution = try decode(BuildOptionsResolution.self, """
        {"options": [{"id": "initScript", "displayName": "Init Script", "kind": "text",
         "value": "", "source": "user"}], "dropped": [], "fingerprint": "f"}
        """)
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.optionsStore.values["fixture"] = ["initScript": .string("")]

        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })
        #expect(harness.optionsStore.values["fixture"]?["initScript"] == .string(""))

        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        #expect(await harness.waitForRunState { $0 == .succeeded })
        #expect(planner.taskPlanContexts.last?.options["initScript"] == .string(""))
    }

    /// A plugin without a model and without report decoding can run workspace
    /// tests; the model is only required to discover subproject reports.
    @Test
    func modelLessPluginCanRunWorkspaceTests() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: nil)])
        let runner = FakeBuildRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.runTests(Self.instanceID, request: BuildTestRequest(), title: "Tests")
        #expect(await harness.waitForRunState { $0 == .succeeded })
        #expect(!runner.requests.isEmpty)
    }

    /// A model can read a subproject file before it lists that project in its
    /// watch paths; the change must still invalidate the load.
    @Test
    func subprojectFileChangeDuringFirstModelLoadMarksTheModelStale() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.modelOutput = .stdout
        let runner = ReplacedOutputRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await runner.earlyWritten.waitUntilOpen())
        harness.service.workspaceFilesChanged([
            Self.workspace.appendingPathComponent("app/build.gradle")
        ])

        runner.releaseLate.open()
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        #expect(harness.service.entry(Self.instanceID)?.isReloadRequired == true)
    }

    /// A dependency tree computed from an old profile must not be shown under
    /// the new option values.
    @Test
    func optionChangeDuringDependencyLoadMarksTheResultStale() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "loaded"))
        ])
        let runner = ReplacedOutputRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.loadDependencies(Self.instanceID, project: nil)
        #expect(await runner.earlyWritten.waitUntilOpen())
        harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
        #expect(await harness.waitForDetectionToFinish())
        planner.fingerprint = "changed"

        runner.releaseLate.open()
        #expect(await harness.waitForEntries { entry in
            guard case .failed = entry.first?.dependencies["app"] else { return false }
            return true
        })
    }

    /// A stale model's project list can miss a newly added subproject, so its
    /// reports would not be collected.
    @Test
    func staleModelCannotCollectWorkspaceReports() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.modelOutput = .stdout
        planner.testPlanDeclaresResults = true
        let runner = FakeBuildRunner()
        runner.script = .init(
            chunks: [],
            result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL")
        )
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })
        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        let commandsBefore = runner.requests.count

        planner.fingerprint = "changed"
        harness.service.detect()
        #expect(await harness.waitForEntries { $0.first?.isReloadRequired == true })

        // The view passes the stale model's non-empty project list; the guard
        // must not depend on an empty list.
        harness.service.runTests(
            Self.instanceID, request: BuildTestRequest(projects: ["app"]), title: "Tests"
        )
        #expect(await harness.waitForRunState { state in
            if case .failed = state { return true }
            return false
        })
        #expect(runner.requests.count == commandsBefore)
    }

    /// Relative source paths in the Build Output belong to the instance the
    /// last command ran in, not to the workspace root.
    @Test
    func outputLinksResolveRelativeToTheInstanceRoot() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.nestedInstance(id: "fixture:a", root: "a", features: [])
        ])
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })
        #expect(harness.service.outputRoots.isEmpty)

        harness.service.runTask("fixture:a", request: BuildTaskRequest(task: "build"), title: "Build")
        #expect(await harness.waitForRunState { $0 == .succeeded })
        #expect(
            harness.service.outputRoots
                == [Self.workspace.appendingPathComponent("a").standardizedFileURL]
        )
    }

    /// A task and a dependency load may run at the same time; each command's
    /// output keeps its own instance root for relative source links.
    @Test
    func outputRootsCoverEveryCommandThatWroteOutput() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.nestedInstance(id: "fixture:a", root: "a", features: []),
            try Self.nestedInstance(id: "fixture:b", root: "b", features: [])
        ])
        let runner = ReplacedOutputRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.count == 2 })

        harness.service.runTask("fixture:a", request: BuildTaskRequest(task: "build"), title: "A")
        #expect(await runner.earlyWritten.waitUntilOpen())
        harness.service.loadDependencies("fixture:b", project: nil)
        #expect(await harness.waitForEntries { entry in
            guard case .loaded = entry.first(where: { $0.id == "fixture:b" })?.dependencies["b"]
            else { return false }
            return true
        })

        runner.releaseLate.open()
        #expect(await harness.waitForRunState { $0 == .succeeded })
        #expect(
            harness.service.outputRoots
                == [
                    Self.workspace.appendingPathComponent("a").standardizedFileURL,
                    Self.workspace.appendingPathComponent("b").standardizedFileURL
                ]
        )
    }

    /// A dependency tree read from old build files must not be published as
    /// current when detection already saw the new files.
    @Test
    func fileChangeDuringDependencyLoadMarksTheResultStale() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "loaded"))
        ])
        let runner = ReplacedOutputRunner()
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.loadDependencies(Self.instanceID, project: nil)
        #expect(await runner.earlyWritten.waitUntilOpen())
        harness.service.workspaceFilesChanged([
            Self.workspace.appendingPathComponent("app/pom.xml")
        ])

        runner.releaseLate.open()
        #expect(await harness.waitForEntries { entry in
            guard case .failed = entry.first?.dependencies["app"] else { return false }
            return true
        })
    }

    // MARK: Provider

    @Test
    func providerModelSendsThePlannedRequestAndDecodesItsReply() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/model")
        let providers = FakeBuildProviders()
        providers.reply = .object(["projects": .array([.string("from provider")])])
        let runner = FakeBuildRunner()
        let harness = Harness(planner: planner, runner: runner, providers: providers)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })

        let sent = try #require(providers.sent.first)
        #expect(providers.sent.count == 1)
        #expect(sent.request == planner.providerRequest)
        #expect(sent.timeout == BuildSystemService.modelTimeout)
        #expect(sent.target == BuildProviderTarget(
            pluginID: "dev.example", manifest: Data("{}".utf8),
            packageURL: URL(fileURLWithPath: "/plugins/dev.example"),
            buildSystemID: "fixture", workspaceURL: Self.workspace
        ))
        #expect(planner.decodedModelOutputs == [.providerResult(providers.reply)])
        #expect(runner.requests.isEmpty)
        #expect(harness.service.output.contains("lithe/build/model"))
        #expect(!harness.service.hasActiveWork)
    }

    @Test
    func providerDependenciesDecodeTheProvidersReply() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "provider", model: Self.model(name: "loaded"))
        ])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/dependencies")
        let providers = FakeBuildProviders()
        let runner = FakeBuildRunner()
        let harness = Harness(planner: planner, runner: runner, providers: providers)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.loadDependencies(Self.instanceID, project: nil)
        #expect(await harness.waitForEntries { entry in
            guard case .loaded = entry.first?.dependencies["app"] else { return false }
            return true
        })

        #expect(providers.sent.map(\.request.method) == ["lithe/build/dependencies"])
        #expect(planner.decodedDependencyOutputs == [.providerResult(providers.reply)])
        #expect(runner.requests.isEmpty)
    }

    @Test
    func workspaceSwitchAndDisabledPluginStopTheirProviders() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/model")
        let providers = FakeBuildProviders()
        let harness = Harness(planner: planner, providers: providers)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })
        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        let first = try #require(providers.sent.first?.target)

        // An unchanged plugin list keeps the process.
        harness.service.pluginsChanged()
        #expect(providers.stopped.isEmpty)

        harness.sources = []
        harness.service.pluginsChanged()
        #expect(providers.stopped == [first])

        harness.sources = [fixtureSource()]
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })
        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        harness.service.reset(workspaceURL: URL(fileURLWithPath: "/workspace/other"))
        #expect(providers.stopped == [first, first])
        #expect(providers.running.isEmpty)
    }

    @Test(arguments: [false, true])
    func moduleShutdownStopsInitializingAndReadyProviders(ready: Bool) async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/model")
        let providers = FakeBuildProviders()
        if !ready { providers.replyGate = BuildTestGate() }
        let harness = Harness(planner: planner, providers: providers)
        let (runtime, graph) = try await makeBuildSystemTestRuntime(harness.service)
        defer {
            graph.stop()
            providers.replyGate?.open()
        }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { $0.first?.modelState == .notLoaded })
        harness.service.loadModel(Self.instanceID)
        try #require(await providers.requestStarted.waitUntilOpen())
        let target = try #require(providers.sent.first?.target)
        if ready {
            try #require(await harness.waitForEntries { $0.first?.modelState == .loaded })
        }
        #expect(providers.running == [target])

        try await runtime.shutdown(.execution)

        #expect(providers.stopped == [target])
        #expect(providers.running.isEmpty)
        #expect(!graph.isActive)
        #expect(runtime.capability(.executionWorkspace) == nil)
        try #require(await providers.requestFinished.waitUntilOpen())
        #expect(harness.service.entries.first?.modelState == (ready ? .loaded : .notLoaded))
        try await runtime.shutdown(.execution)
        #expect(providers.stopped == [target])
        await runtime.shutdownAll()
    }

    @Test
    func providerModelFailsWithoutAProviderHost() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/model")
        let harness = Harness(planner: planner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries {
            if case .failed = $0.first?.modelState { return true }
            return false
        })
        #expect(planner.decodedModelOutputs.isEmpty)
    }

    @Test
    func failedProviderRequestReportsItsMessage() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/model")
        let providers = FakeBuildProviders()
        providers.failure = BuildSystemServiceTestsError(message: "provider exploded")
        let harness = Harness(planner: planner, providers: providers)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries {
            if case .failed = $0.first?.modelState { return true }
            return false
        })
        guard case .failed(let message)? = harness.service.entries.first?.modelState else { return }
        #expect(message.contains("provider exploded"))
        #expect(planner.decodedModelOutputs.isEmpty)
    }

    private static func providerRequest(method: String) -> BuildProviderRequest {
        BuildProviderRequest(
            method: method, params: .object(["root": .string("app")]), optionFingerprint: "o",
            executesProjectCode: true, mayUseNetwork: true
        )
    }

    // MARK: Fixtures

    private static let instanceID = "fixture:app"

    private static func instanceJSON(
        modelSource: String?,
        model: String? = nil,
        pluginID: String = "dev.example"
    ) -> String {
        let source = modelSource.map { ", \"modelSource\": \"\($0)\"" } ?? ""
        return """
        {"id": "\(instanceID)", "pluginID": "\(pluginID)", "buildSystemID": "fixture",
         "displayName": "Fixture", "root": "app"\(source),
         "optionFingerprint": "o"\(model.map { ", \"model\": \($0)" } ?? "")}
        """
    }

    private static func instance(
        modelSource: String?,
        model: String? = nil,
        pluginID: String = "dev.example"
    ) throws -> BuildSystemInstance {
        try decode(
            BuildSystemInstance.self,
            instanceJSON(modelSource: modelSource, model: model, pluginID: pluginID)
        )
    }

    private static func model(name: String) -> String {
        #"{"projects": [{"id": "p", "path": ".", "name": "\#(name)"}]}"#
    }

    private static func nestedInstance(
        id: String,
        root: String,
        features: [String]
    ) throws -> BuildSystemInstance {
        let featureList = features.map { "\"\($0)\"" }.joined(separator: ", ")
        let model = """
        {"projects": [{"id": "\(id)", "path": ".", "name": "\(id)"}],
         "optionValues": {"features": [\(featureList)]}}
        """
        return try decode(BuildSystemInstance.self, """
        {"id": "\(id)", "pluginID": "dev.example", "buildSystemID": "fixture",
         "displayName": "\(id)", "root": "\(root)", "modelSource": "static",
         "optionFingerprint": "o", "model": \(model)}
        """)
    }

    private static func filteredOptions() throws -> BuildOptionsResolution {
        try decode(BuildOptionsResolution.self, """
        {"options": [{"id": "features", "displayName": "Features", "kind": "multiSelect",
         "value": ["cli"], "source": "user"}],
         "dropped": ["features"], "fingerprint": "f"}
        """)
    }

    private static func diagnostic(_ message: String) throws -> BuildDiagnostic {
        try decode(BuildDiagnostic.self, """
        {"path": "src/old.swift", "line": 1, "severity": "error", "message": "\(message)"}
        """)
    }

    private static func testResults(_ message: String) throws -> BuildTestResults {
        try decode(BuildTestResults.self, """
        {"tests": [{"suite": "Suite", "case": "case", "status": "failed", "message": "\(message)"}],
         "summary": {"total": 1, "passed": 0, "failed": 1, "errors": 0, "skipped": 0},
         "success": false}
        """)
    }
}

private func fixtureSource(pluginID: String = "dev.example") -> BuildSystemPluginSource {
    BuildSystemPluginSource(
        pluginID: pluginID,
        manifest: Data("{}".utf8),
        packageURL: URL(fileURLWithPath: "/plugins/\(pluginID)"),
        buildSystems: [DeclarativeBuildSystem(
            id: "fixture", displayName: "Fixture", modelSource: .command, tasks: [],
            testScopes: [], dependencyScopes: []
        )]
    )
}

private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@MainActor
private final class Harness {
    let service: BuildSystemService
    let optionsStore = FakeOptionsStore()
    let stateLocator = FakeStateLocator()
    private let enabledSources: SourceList

    /// The plugins the service sees as enabled.
    var sources: [BuildSystemPluginSource] {
        get { enabledSources.value }
        set { enabledSources.value = newValue }
    }

    init(
        planner: FakeBuildPlanner,
        runner: any BuildCommandRunning = FakeBuildRunner(),
        sources: [BuildSystemPluginSource] = [fixtureSource()],
        providers: (any BuildProviderRequesting)? = nil,
        waitForRedetection: @escaping @Sendable () async throws -> Void = {}
    ) {
        let enabledSources = SourceList(sources)
        self.enabledSources = enabledSources
        service = BuildSystemService(
            planner: planner,
            tools: FakeToolResolver(),
            optionsStore: optionsStore,
            stateLocator: stateLocator,
            runner: runner,
            providers: providers,
            waitForRedetection: waitForRedetection,
            sources: { enabledSources.value }
        )
    }

    func waitForEntries(_ predicate: @escaping ([BuildSystemEntry]) -> Bool) async -> Bool {
        await wait(for: service.$entries, predicate)
    }

    func waitForRunState(_ predicate: @escaping (BuildRunState) -> Bool) async -> Bool {
        await wait(for: service.$runState, predicate)
    }

    func waitForDiagnostics(_ predicate: @escaping ([BuildDiagnostic]) -> Bool) async -> Bool {
        await wait(for: service.$diagnostics, predicate)
    }

    /// Bounded wait for a publication a correct service never makes. Returns
    /// true when the stale value appears, so a regression fails locally
    /// instead of hanging.
    func waitsForStaleDiagnostics(_ diagnostics: [BuildDiagnostic]) async -> Bool {
        let gate = BuildTestGate()
        let observation = service.$diagnostics.sink { if $0 == diagnostics { gate.open() } }
        defer { observation.cancel() }
        return await gate.waitUntilOpen(timeout: .milliseconds(500))
    }

    func waitsForStaleTestResults(_ results: BuildTestResults?) async -> Bool {
        let gate = BuildTestGate()
        let observation = service.$testResults.sink { if $0 == results { gate.open() } }
        defer { observation.cancel() }
        return await gate.waitUntilOpen(timeout: .milliseconds(500))
    }

    func waitForDetectionToFinish() async -> Bool {
        await wait(for: service.$isDetecting) { !$0 }
    }

    func waitForOutput(_ predicate: @escaping (String) -> Bool) async -> Bool {
        await wait(for: service.$output, predicate)
    }

    /// Bounded wait for output a correct service never appends.
    func waitsForLateOutput(_ text: String) async -> Bool {
        let gate = BuildTestGate()
        let observation = service.$output.sink { if $0.contains(text) { gate.open() } }
        defer { observation.cancel() }
        return await gate.waitUntilOpen(timeout: .milliseconds(500))
    }

    /// `@Published` reports in `willSet`; the waiter resumes in a later main
    /// actor job, after the value is stored.
    private func wait<Value>(
        for publisher: Published<Value>.Publisher,
        _ predicate: @escaping (Value) -> Bool
    ) async -> Bool {
        let gate = BuildTestGate()
        let observation = publisher.sink { if predicate($0) { gate.open() } }
        defer { observation.cancel() }
        return await gate.waitUntilOpen()
    }
}

@MainActor
private final class SourceList {
    var value: [BuildSystemPluginSource]
    init(_ value: [BuildSystemPluginSource]) { self.value = value }
}

/// Opens once. Waiters give up at a local deadline, so a failed test does
/// not hang until the CI timeout; modelled on `LitheTests/TestGate`.
private final class BuildTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]

    func open() {
        let (resumed, cancelled) = lock.withLock {
            isOpen = true
            defer { waiters.removeAll(); deadlines.removeAll() }
            return (Array(waiters.values), Array(deadlines.values))
        }
        cancelled.forEach { $0.cancel() }
        resumed.forEach { $0.resume(returning: true) }
    }

    func waitUntilOpen(timeout: Duration = .seconds(5), ignoringCancellation: Bool = false) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let openAlready = lock.withLock {
                    if !isOpen { waiters[id] = continuation }
                    return isOpen
                }
                if openAlready {
                    continuation.resume(returning: true)
                    return
                }
                let deadline = Task { [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: the gate deadline bounds a failed asynchronous test while successful signaling remains continuation-driven.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(id, result: false)
                }
                let registered = lock.withLock {
                    guard waiters[id] != nil else { return false }
                    deadlines[id] = deadline
                    return true
                }
                if !registered { deadline.cancel() }
                if !ignoringCancellation && Task.isCancelled { finish(id, result: false) }
            }
        } onCancel: {
            if !ignoringCancellation { finish(id, result: false) }
        }
    }

    private func finish(_ id: UUID, result: Bool) {
        let (waiter, deadline) = lock.withLock {
            (waiters.removeValue(forKey: id), deadlines.removeValue(forKey: id))
        }
        deadline?.cancel()
        waiter?.resume(returning: result)
    }
}

/// A decode the test can pause after its command finished. The service
/// detaches decodes, so a stop, replacement run, or workspace switch can
/// happen while the result is still on its way back.
private final class GatedBuildDecode: Sendable {
    let entered = BuildTestGate()
    let finished = BuildTestGate()
    private let release = DispatchSemaphore(value: 0)

    func releaseDecode() { release.signal() }

    func waitForRelease() -> Bool {
        release.wait(timeout: .now() + 10) == .success
    }
}

private enum GatedDecodeError: Error {
    case releaseTimedOut
}

private final class FakeBuildPlanner: BuildSystemPlanning, @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var detection = BuildDetection(instances: [])
        var importEnabled = false
        var modelOutput: BuildProcessPlan.Output = .outputFile
        var providerRequest: BuildProviderRequest?
        var decodedDependencyOutputs: [BuildCommandOutput] = []
        var diagnostics: [BuildDiagnostic] = []
        var diagnosticsGate: GatedBuildDecode?
        var testResultsGate: GatedBuildDecode?
        var detectGate: GatedBuildDecode?
        var decodedTestResults: BuildTestResults?
        var testPlanDeclaresResults = false
        var optionsResolution: BuildOptionsResolution?
        var loadedOptionsResolution: BuildOptionsResolution?
        var dynamicOptions = false
        var hasMavenLanguageImport = false
        var languageImportInputs: [[String: ToolingJSONValue]] = []
        var modelOptionValues: [String: [String]]?
        var fingerprint = "initial"
        var decodedModelOutputs: [BuildCommandOutput] = []
        var diagnosticOutputs: [String] = []
        var taskPlanContexts: [BuildPlanContext] = []
    }

    private func access<Value>(_ body: (inout State) -> Value) -> Value { lock.withLock { body(&state) } }

    var detection: BuildDetection {
        get { access { $0.detection } }
        set { access { $0.detection = newValue } }
    }
    var importEnabled: Bool {
        get { access { $0.importEnabled } }
        set { access { $0.importEnabled = newValue } }
    }
    var modelOutput: BuildProcessPlan.Output {
        get { access { $0.modelOutput } }
        set { access { $0.modelOutput = newValue } }
    }
    /// When set, model and dependency plans ask the Provider instead of
    /// running a command.
    var providerRequest: BuildProviderRequest? {
        get { access { $0.providerRequest } }
        set { access { $0.providerRequest = newValue } }
    }
    var decodedDependencyOutputs: [BuildCommandOutput] { access { $0.decodedDependencyOutputs } }
    var diagnostics: [BuildDiagnostic] {
        get { access { $0.diagnostics } }
        set { access { $0.diagnostics = newValue } }
    }
    var optionsResolution: BuildOptionsResolution? {
        get { access { $0.optionsResolution } }
        set { access { $0.optionsResolution = newValue } }
    }
    /// The resolution Core reports once a model provides its option values.
    var loadedOptionsResolution: BuildOptionsResolution? {
        get { access { $0.loadedOptionsResolution } }
        set { access { $0.loadedOptionsResolution = newValue } }
    }
    /// Filters a stored `features` multi-select against the instance's model
    /// values, like Core's `choicesFromModel` resolution.
    var dynamicOptions: Bool {
        get { access { $0.dynamicOptions } }
        set { access { $0.dynamicOptions = newValue } }
    }
    var hasMavenLanguageImport: Bool {
        get { access { $0.hasMavenLanguageImport } }
        set { access { $0.hasMavenLanguageImport = newValue } }
    }
    var languageImportInputs: [[String: ToolingJSONValue]] { access { $0.languageImportInputs } }

    var modelOptionValues: [String: [String]]? {
        get { access { $0.modelOptionValues } }
        set { access { $0.modelOptionValues = newValue } }
    }
    var detectGate: GatedBuildDecode? {
        get { access { $0.detectGate } }
        set { access { $0.detectGate = newValue } }
    }
    var diagnosticsGate: GatedBuildDecode? {
        get { access { $0.diagnosticsGate } }
        set { access { $0.diagnosticsGate = newValue } }
    }
    var testResultsGate: GatedBuildDecode? {
        get { access { $0.testResultsGate } }
        set { access { $0.testResultsGate = newValue } }
    }
    var decodedTestResults: BuildTestResults? {
        get { access { $0.decodedTestResults } }
        set { access { $0.decodedTestResults = newValue } }
    }
    var testPlanDeclaresResults: Bool {
        get { access { $0.testPlanDeclaresResults } }
        set { access { $0.testPlanDeclaresResults = newValue } }
    }
    var taskPlanContexts: [BuildPlanContext] { access { $0.taskPlanContexts } }
    var fingerprint: String {
        get { access { $0.fingerprint } }
        set { access { $0.fingerprint = newValue } }
    }
    var decodedModelOutputs: [BuildCommandOutput] { access { $0.decodedModelOutputs } }
    var diagnosticOutputs: [String] { access { $0.diagnosticOutputs } }

    func detect(
        workspaceURL: URL,
        sources: [BuildSystemPluginSource],
        options: [String: [String: ToolingJSONValue]]
    ) throws -> BuildDetection {
        if let gate = access({ let gate = $0.detectGate; $0.detectGate = nil; return gate }) {
            gate.entered.open()
            guard gate.waitForRelease() else { throw GatedDecodeError.releaseTimedOut }
            gate.finished.open()
        }
        return detection
    }

    func languageImport(
        _ target: BuildSystemTarget, workspaceURL: URL, root: String,
        options: [String: ToolingJSONValue], executableURL: URL?
    ) throws -> BuildLanguageImport? {
        let profilesOptionID: String? = access {
            $0.languageImportInputs.append(options)
            if $0.importEnabled { return "features" }
            return $0.hasMavenLanguageImport ? "profiles" : nil
        }
        guard let profilesOptionID else { return nil }
        func text(_ id: String) -> String? {
            guard case .string(let value)? = options[id] else { return nil }
            return value
        }
        let profiles: [String]
        if case .array(let values)? = options[profilesOptionID] {
            profiles = values.compactMap { if case .string(let value) = $0 { value } else { nil } }
        } else { profiles = [] }
        return .maven(MavenLaunchContext(
            reactorPath: root, profiles: profiles, settingsPath: text("settingsFile"),
            localRepositoryPath: text("localRepository"), skipTests: false,
            mavenExecutablePath: executableURL?.path, javaHomePath: nil
        ))
    }

    func invocationPlan(_ target: BuildSystemTarget, root: String) throws -> BuildInvocation {
        BuildInvocation(executables: [.command("fake")])
    }

    func checkToolVersion(_ target: BuildSystemTarget, runtime: String?, output: String) throws -> BuildVersionCheck {
        BuildVersionCheck(satisfied: true, version: nil)
    }

    func resolveOptions(
        _ target: BuildSystemTarget,
        options: [String: ToolingJSONValue],
        modelValues: [String: [String]]?
    ) throws -> BuildOptionsResolution {
        if access({ $0.dynamicOptions }) {
            let stored = options["features"].flatMap { value -> [String]? in
                guard case .array(let items) = value else { return nil }
                return items.compactMap { item in
                    guard case .string(let text) = item else { return nil }
                    return text
                }
            } ?? []
            let kept = modelValues.map { values in
                stored.filter((values["features"] ?? []).contains)
            } ?? stored
            let dropped = kept.count != stored.count
            // Core rejects a non-empty stored selection when no item is valid.
            // This fixture has no default, so rejection is unset; only a stored
            // [] represents an explicit empty user override.
            let source = options["features"] != nil && !(dropped && kept.isEmpty) ? "user" : "unset"
            let fingerprint = access { $0.fingerprint }
            return try decode(BuildOptionsResolution.self, """
            {"options": [{"id": "features", "displayName": "Features", "kind": "multiSelect",
             "value": [\(kept.map { "\"\($0)\"" }.joined(separator: ", "))], "source": "\(source)"}],
             "dropped": \(dropped ? "[\"features\"]" : "[]"), "fingerprint": "\(fingerprint)"}
            """)
        }
        if modelValues != nil, let resolution = access({ $0.loadedOptionsResolution }) {
            return resolution
        }
        if let resolution = optionsResolution { return resolution }
        let fingerprint = access { $0.fingerprint }
        return try decode(BuildOptionsResolution.self, """
        {"options": [{"id": "release", "displayName": "Release", "kind": "boolean", "value": false}],
         "dropped": [], "fingerprint": "\(fingerprint)"}
        """)
    }

    func modelPlan(_ target: BuildSystemTarget, context: BuildPlanContext, outputFile: URL?) throws -> BuildOutputPlan {
        if let request = providerRequest { return .provider(request) }
        return .process(plan(["model"], output: modelOutput))
    }

    func taskPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTaskRequest) throws
        -> BuildProcessPlan {
        access { $0.taskPlanContexts.append(context) }
        return plan([request.task, "with space"], output: nil)
    }

    func testPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTestRequest) throws
        -> BuildTestPlan {
        let declaresResults = access { $0.testPlanDeclaresResults }
        return BuildTestPlan(
            process: plan(["test"], output: nil),
            results: declaresResults ? .reports(decoder: "junitXml", patterns: []) : nil
        )
    }

    func dependencyPlan(
        _ target: BuildSystemTarget,
        context: BuildPlanContext,
        project: BuildSelection?,
        outputFile: URL?
    ) throws -> BuildOutputPlan {
        if let request = providerRequest { return .provider(request) }
        return .process(plan(["dependencies"], output: .stdout))
    }

    func decodeModel(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        output: BuildCommandOutput,
        options: [String: ToolingJSONValue]
    ) throws -> BuildModel {
        access { $0.decodedModelOutputs.append(output) }
        let name: String
        if case .stdout(let text) = output, text == "OLD" || text == "NEW" {
            name = text
        } else {
            name = "loaded"
        }
        let optionValues = access { $0.modelOptionValues } ?? [:]
        return BuildModel(
            projects: [BuildModel.Project(id: "loaded", path: "app", name: name)],
            optionValues: optionValues
        )
    }

    func decodeTestResults(_ target: BuildSystemTarget, request: BuildTestResultsRequest) throws -> BuildTestResults {
        let results = access { $0.decodedTestResults }
        if let gate = access({ let gate = $0.testResultsGate; $0.testResultsGate = nil; return gate }) {
            gate.entered.open()
            guard gate.waitForRelease() else { throw GatedDecodeError.releaseTimedOut }
            gate.finished.open()
        }
        guard let results else {
            throw DeclarativePluginRejection(code: "plugin.build.unavailable", message: "No results.", field: nil)
        }
        return results
    }

    func decodeDiagnostics(_ target: BuildSystemTarget, workspaceURL: URL, root: String, output: String) throws
        -> [BuildDiagnostic] {
        let diagnostics = access { $0.diagnostics }
        if let gate = access({ let gate = $0.diagnosticsGate; $0.diagnosticsGate = nil; return gate }) {
            gate.entered.open()
            guard gate.waitForRelease() else { throw GatedDecodeError.releaseTimedOut }
            gate.finished.open()
        }
        access { $0.diagnosticOutputs.append(output) }
        return diagnostics
    }

    func decodeDependencies(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        project: String?,
        output: BuildCommandOutput
    ) throws -> BuildDependencyTree {
        access { $0.decodedDependencyOutputs.append(output) }
        if case .stdout(let name) = output, name == "OLD" || name == "NEW" {
            return try decode(BuildDependencyTree.self, """
            {"dependencies": [{"name": "\(name)"}], "truncated": false}
            """)
        }
        return try decode(BuildDependencyTree.self, #"{"dependencies": [], "truncated": false}"#)
    }

    func syncFingerprint(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        projects: [String],
        options: [String: ToolingJSONValue]
    ) throws -> BuildSyncState {
        BuildSyncState(fingerprint: fingerprint, watch: ["build.file"])
    }

    private func plan(_ arguments: [String], output: BuildProcessPlan.Output?) -> BuildProcessPlan {
        BuildProcessPlan(
            arguments: arguments,
            environment: ["FROM_PLAN": "1"],
            workingDirectory: "app",
            optionFingerprint: "o",
            output: output
        )
    }
}

@MainActor
private final class FakeToolResolver: BuildToolResolving {
    func resolve(
        _ invocation: BuildInvocation,
        displayName: String,
        workspaceURL: URL,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(
            executableURL: URL(fileURLWithPath: "/tool/bin/fake"),
            environment: ["PATH": "/tool/bin"],
            executesProjectCode: false,
            version: nil
        )
    }
}

@MainActor
private final class FakeOptionsStore: BuildOptionsStoring {
    var values: [String: [String: ToolingJSONValue]] = [:]
    var emptyValues: [String: [String: Set<String>]] = [:]

    func options(workspaceURL: URL, buildSystemID: String) -> [String: ToolingJSONValue] {
        values[buildSystemID] ?? [:]
    }

    func setOptions(_ options: [String: ToolingJSONValue], workspaceURL: URL, buildSystemID: String) {
        values[buildSystemID] = options.isEmpty ? nil : options
    }

    func emptyMultiSelectOptions(workspaceURL: URL, buildSystemID: String) -> [String: Set<String>] {
        emptyValues[buildSystemID] ?? [:]
    }

    func setEmptyMultiSelectOptions(_ options: [String: Set<String>], workspaceURL: URL, buildSystemID: String) {
        emptyValues[buildSystemID] = options.isEmpty ? nil : options
    }
}

private final class FakeStateLocator: BuildSystemStateLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var allocatedURLs: [URL] = []
    private var removedURLs: [URL] = []
    private var removalGates: [URL: BuildTestGate] = [:]

    var allocated: [URL] { lock.withLock { allocatedURLs } }
    var removed: [URL] { lock.withLock { removedURLs } }

    func workspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceURL: URL) throws -> URL {
        URL(fileURLWithPath: "/state/\(pluginID)/\(buildSystemID)")
    }

    func allocateOutputFile(in workspaceStateDirectory: URL) throws -> URL {
        let url = workspaceStateDirectory.appendingPathComponent("outputs/\(UUID().uuidString).json")
        lock.withLock {
            allocatedURLs.append(url)
            removalGates[url] = BuildTestGate()
        }
        return url
    }

    func removeOutputFile(_ url: URL) {
        let gate = lock.withLock {
            removedURLs.append(url)
            return removalGates[url]
        }
        gate?.open()
    }

    func waitForRemoval(of url: URL) async -> Bool {
        guard let gate = lock.withLock({ removalGates[url] }) else { return false }
        return await gate.waitUntilOpen()
    }
}

/// A runner may observe cancellation before its native process exits. Keep
/// those two events independently controllable, with a deadline on every wait.
private final class ControlledBuildLoad: Sendable {
    let output: String
    let throwsCancellation: Bool
    let started = BuildTestGate()
    let cancelled = BuildTestGate()
    let release = BuildTestGate()

    init(output: String, throwsCancellation: Bool = false) {
        self.output = output
        self.throwsCancellation = throwsCancellation
    }
}

private final class ControlledBuildLoadRunner: BuildCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let loads: [ControlledBuildLoad]
    private var nextLoad = 0

    init(loads: [ControlledBuildLoad]) { self.loads = loads }

    func run(
        _ request: BuildCommandRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> BuildCommandResult {
        let load: ControlledBuildLoad? = lock.withLock {
            guard nextLoad < loads.count else { return nil }
            defer { nextLoad += 1 }
            return loads[nextLoad]
        }
        guard let load else { throw ControlledLoadError.unexpectedCommand }
        load.started.open()
        return try await withTaskCancellationHandler {
            // Deliberately acknowledge cancellation without completing the old
            // command until the test has started or finished its replacement.
            guard await load.release.waitUntilOpen(ignoringCancellation: true) else {
                throw ControlledLoadError.releaseTimedOut
            }
            if load.throwsCancellation { throw CancellationError() }
            return BuildCommandResult(termination: .exited(0), standardOutput: load.output)
        } onCancel: {
            load.cancelled.open()
        }
    }
}

private enum ControlledLoadError: Error {
    case unexpectedCommand, releaseTimedOut
}

/// Emits one chunk, then waits so the test can replace the owner before the
/// command drains its remaining output.
private final class ReplacedOutputRunner: BuildCommandRunning, @unchecked Sendable {
    let earlyWritten = BuildTestGate()
    let releaseLate = BuildTestGate()
    private let lock = NSLock()
    private var calls = 0

    func run(
        _ request: BuildCommandRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> BuildCommandResult {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 {
            onOutput("early\n")
            earlyWritten.open()
            _ = await releaseLate.waitUntilOpen(ignoringCancellation: true)
            onOutput("late\n")
            return BuildCommandResult(termination: .exited(0), standardOutput: "MODEL")
        }
        onOutput("second\n")
        return BuildCommandResult(termination: .exited(0), standardOutput: "second")
    }
}

private final class FakeBuildRunner: BuildCommandRunning, @unchecked Sendable {
    struct Script {
        let chunks: [String]
        let result: BuildCommandResult
    }

    let started = BuildTestGate()
    let cancelled = BuildTestGate()
    private let lock = NSLock()
    private var recorded: [BuildCommandRequest] = []
    private var configuredScript = Script(chunks: [], result: BuildCommandResult(termination: .exited(0)))
    private var blocks = false

    var requests: [BuildCommandRequest] { lock.withLock { recorded } }
    var script: Script {
        get { lock.withLock { configuredScript } }
        set { lock.withLock { configuredScript = newValue } }
    }
    var blocksUntilCancelled: Bool {
        get { lock.withLock { blocks } }
        set { lock.withLock { blocks = newValue } }
    }

    func run(
        _ request: BuildCommandRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> BuildCommandResult {
        lock.withLock { recorded.append(request) }
        started.open()
        if blocksUntilCancelled {
            let cancelled = cancelled
            await withTaskCancellationHandler {
                _ = await cancelled.waitUntilOpen()
            } onCancel: {
                cancelled.open()
            }
            throw CancellationError()
        }
        let script = script
        script.chunks.forEach(onOutput)
        return script.result
    }
}

/// Records Provider requests and answers each with `reply`.
@MainActor
private final class FakeBuildProviders: BuildProviderRequesting {
    struct Sent: Equatable {
        let request: BuildProviderRequest
        let target: BuildProviderTarget
        let timeout: Duration
    }

    var reply: ToolingJSONValue = .object(["projects": .array([])])
    var failure: (any Error)?
    var replyGate: BuildTestGate?
    let requestStarted = BuildTestGate()
    let requestFinished = BuildTestGate()
    private(set) var sent: [Sent] = []
    private(set) var running: Set<BuildProviderTarget> = []
    private(set) var stopped: [BuildProviderTarget] = []

    func send(
        _ request: BuildProviderRequest,
        to target: BuildProviderTarget,
        timeout: Duration
    ) async throws -> ToolingJSONValue {
        sent.append(Sent(request: request, target: target, timeout: timeout))
        running.insert(target)
        requestStarted.open()
        defer { requestFinished.open() }
        if let replyGate, !(await replyGate.waitUntilOpen()) { throw CancellationError() }
        if let failure { throw failure }
        return reply
    }

    func retainProviders(_ keep: (BuildProviderTarget) -> Bool) {
        for target in running where !keep(target) {
            running.remove(target)
            stopped.append(target)
        }
    }
}

private struct BuildSystemServiceTestsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

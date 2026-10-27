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

    @Test
    func providerRunHandsValidatedPlanToNativeRunAndStopsOnDisable() async throws {
        let (planner, providers, launcher, harness) = try Self.runPreparationHarness()
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        try #require(harness.service.runApplication(Self.instanceID, request: Self.runRequest, title: "Main") != nil)
        try #require(await harness.waitForRunState { $0 == .succeeded })
        #expect(providers.sent.map(\.request.method) == ["lithe/build/prepareRun"])
        #expect(launcher.launched.count == 1)
        #expect(launcher.launched.first?.arguments == ["example.Main", "a b"])
        #expect(planner.diagnosticOutputs.isEmpty)
        harness.sources = []
        // Detection may already have removed the model before plugin disable
        // is delivered. Process ownership must survive that disappearance.
        harness.service.detect()
        try #require(await harness.waitForEntries { $0.isEmpty })
        harness.service.pluginsChanged()
        #expect(launcher.stopped == ["prepared-app"])
    }

    @Test
    func savedRunRoutesOnlyToItsEnabledWorkspaceInstance() async throws {
        let (_, providers, launcher, harness) = try Self.runPreparationHarness()
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        let reference = BuildProviderRunReference(pluginID: "dev.example", buildSystemID: "fixture", root: "app",
            run: "application", projectID: "p", targetID: "t", userArguments: ["a b"])
        let configuration = RunConfiguration(id: "user:main", name: "Saved Main", kind: .process(provider: "build.provider"),
            modulePath: nil, mainClass: nil, buildProvider: reference)
        #expect(harness.service.runProviderConfiguration(configuration, workspace: URL(fileURLWithPath: "/other")) == nil)
        try #require(harness.service.runProviderConfiguration(configuration, workspace: Self.workspace) != nil)
        try #require(await harness.waitForRunState { $0 == .succeeded })
        #expect(launcher.lastConfiguration == configuration)
        #expect(providers.sent.count == 1)
        harness.sources = []
        harness.service.pluginsChanged()
        try #require(await harness.waitForEntries { $0.isEmpty })
        #expect(harness.service.runProviderConfiguration(configuration, workspace: Self.workspace) == nil)
        #expect(providers.sent.count == 1)
    }

    /// A reply from a cancelled or outdated build must never start an application.
    @Test(arguments: ["stop", "workspace", "options", "disable", "source", "reload"])
    func providerRunLateReplyCannotLaunch(change: String) async throws {
        let (_, providers, launcher, harness) = try Self.runPreparationHarness()
        let release = BuildTestGate()
        providers.replyGate = release
        defer { release.open(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.runApplication(Self.instanceID, request: Self.runRequest, title: "Main")
        try #require(await providers.requestStarted.waitUntilOpen())
        switch change {
        case "workspace": harness.service.reset(workspaceURL: URL(fileURLWithPath: "/other"))
        case "options": harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
        case "disable": harness.sources = []; harness.service.pluginsChanged()
        case "source": harness.service.workspaceFilesChanged([Self.workspace.appendingPathComponent("app/Main.java")])
        case "reload": harness.service.loadModel(Self.instanceID, reason: .refresh)
        default: harness.service.stopRun()
        }
        providers.executionProgress?(BuildProviderProgress(output: "stale launch output"))
        release.open()
        try #require(await providers.requestFinished.waitUntilOpen())
        #expect(await launcher.didLaunch.waitUntilOpen(timeout: .milliseconds(200)) == false)
        #expect(launcher.launched.isEmpty)
        #expect(!harness.service.output.contains("stale launch output"))
    }

    @Test
    func providerRunCancellationDuringCoreDecodePreventsHandoff() async throws {
        let (planner, _, launcher, harness) = try Self.runPreparationHarness()
        let gate = GatedBuildDecode()
        planner.runPreparationGate = gate
        defer { gate.releaseDecode(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.runApplication(Self.instanceID, request: Self.runRequest, title: "Main")
        try #require(await gate.entered.waitUntilOpen())
        harness.service.stopRun()
        gate.releaseDecode()
        try #require(await gate.finished.waitUntilOpen())
        #expect(await launcher.didLaunch.waitUntilOpen(timeout: .milliseconds(200)) == false)
    }

    @Test
    func providerRunRejectsStaleTargetAndPreparationFailure() async throws {
        let (_, providers, launcher, harness) = try Self.runPreparationHarness()
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        #expect(harness.service.runApplication(Self.instanceID,
            request: BuildRunRequest(run: "application", projectID: "p", targetID: "gone"), title: "Main") == nil)
        providers.failure = BuildSystemServiceTestsError(message: "build failed")
        harness.service.runApplication(Self.instanceID, request: Self.runRequest, title: "Main")
        try #require(await harness.waitForRunState { if case .failed = $0 { true } else { false } })
        #expect(launcher.launched.isEmpty)
        #expect(harness.service.output.contains("build failed"))
    }

    @Test
    func providerDebugPreparationHandsOffOnlyValidatedCurrentFacts() async throws {
        let (planner, providers, launcher, harness) = try Self.debugPreparationHarness()
        defer { harness.service.stop() }
        var launched: [BuildDebugPreparation] = []
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        try #require(harness.service.debugApplication(Self.instanceID, request: Self.runRequest, title: "Debug") { source, plan in
            #expect(source.pluginID == "dev.example")
            launched.append(plan)
        } != nil)
        try #require(await harness.waitForRunState { $0 == .succeeded })
        #expect(providers.sent.map(\.request.method) == ["lithe/build/prepareDebug"])
        #expect(launched.first?.adapter == "native")
        #expect(launched.first?.arguments == ["a b", "x#y"])
        #expect(launcher.launched.isEmpty)
        #expect(planner.diagnosticOutputs.isEmpty)
    }

    @Test(arguments: ["stop", "debug-stop", "workspace", "options", "disable", "source", "reload"])
    func providerDebugLateReplyCannotLaunch(change: String) async throws {
        let (_, providers, _, harness) = try Self.debugPreparationHarness()
        let release = BuildTestGate()
        let launched = BuildTestGate()
        providers.replyGate = release
        defer { release.open(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.debugApplication(Self.instanceID, request: Self.runRequest, title: "Debug") { _, _ in launched.open() }
        try #require(await providers.requestStarted.waitUntilOpen())
        switch change {
        case "workspace": harness.service.reset(workspaceURL: URL(fileURLWithPath: "/other"))
        case "options": harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
        case "disable": harness.sources = []; harness.service.pluginsChanged()
        case "source": harness.service.workspaceFilesChanged([Self.workspace.appendingPathComponent("app/main.c")])
        case "reload": harness.service.loadModel(Self.instanceID, reason: .refresh)
        case "debug-stop": harness.service.cancelDebugPreparation()
        default: harness.service.stopRun()
        }
        providers.executionProgress?(BuildProviderProgress(output: "stale debug output"))
        release.open()
        try #require(await providers.requestFinished.waitUntilOpen())
        #expect(await launched.waitUntilOpen(timeout: .milliseconds(200)) == false)
        #expect(!harness.service.output.contains("stale debug output"))
    }

    @Test
    func providerDebugCancellationDuringDecodePreventsAdapterStart() async throws {
        let (planner, _, _, harness) = try Self.debugPreparationHarness()
        let gate = GatedBuildDecode()
        let launched = BuildTestGate()
        planner.runPreparationGate = gate
        defer { gate.releaseDecode(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.debugApplication(Self.instanceID, request: Self.runRequest, title: "Debug") { _, _ in launched.open() }
        try #require(await gate.entered.waitUntilOpen())
        harness.service.cancelDebugPreparation()
        gate.releaseDecode()
        try #require(await gate.finished.waitUntilOpen())
        #expect(await launched.waitUntilOpen(timeout: .milliseconds(200)) == false)
    }

    @Test
    func providerDebugRejectsMissingCapabilitiesAndReportsLaunchFailure() async throws {
        let (_, providers, _, noDebug) = try Self.runPreparationHarness()
        defer { noDebug.service.stop() }
        noDebug.service.reset(workspaceURL: Self.workspace)
        try #require(await noDebug.waitForEntries { !$0.isEmpty })
        #expect(noDebug.service.debugApplication(Self.instanceID, request: Self.runRequest, title: "Debug") { _, _ in
            Issue.record("No debug adapter was declared")
        } == nil)
        #expect(providers.sent.isEmpty)
        let (_, _, _, harness) = try Self.debugPreparationHarness()
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.debugApplication(Self.instanceID, request: Self.runRequest, title: "Debug") { _, _ in
            throw BuildSystemServiceTestsError(message: "adapter unavailable")
        }
        try #require(await harness.waitForRunState { if case .failed = $0 { true } else { false } })
        #expect(harness.service.output.contains("adapter unavailable"))
    }

    private static func debugPreparationHarness() throws -> (FakeBuildPlanner, FakeBuildProviders, FakeBuildRunLauncher, Harness) {
        let (planner, providers, launcher, harness) = try runPreparationHarness()
        planner.providerRequest = providerRequest(method: "lithe/build/prepareDebug")
        providers.reply = try decode(ToolingJSONValue.self,
            #"{"root":"app","adapter":"native","program":"app/bin/main","arguments":["a b","x#y"],"workingDirectory":"app","environment":{}}"#)
        harness.sources = [fixtureSource(providerRuns: [.init(id: "application", displayName: "Run",
            targetTags: ["application"], debugAdapter: "native")])]
        return (planner, providers, launcher, harness)
    }

    private static let runRequest = BuildRunRequest(run: "application", projectID: "p", targetID: "t")
    private static func runPreparationHarness() throws -> (FakeBuildPlanner, FakeBuildProviders, FakeBuildRunLauncher, Harness) {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try instance(modelSource: "provider", model:
            #"{"projects":[{"id":"p","name":"app","path":"app"}],"targets":[{"id":"t","projectID":"p","name":"Main","path":"app","tags":["application"]}]}"#)])
        planner.providerRequest = providerRequest(method: "lithe/build/prepareRun")
        let providers = FakeBuildProviders()
        providers.reply = try decode(ToolingJSONValue.self,
            #"{"executable":{"kind":"command","value":"java"},"arguments":["example.Main","a b"],"workingDirectory":"app","environment":{}}"#)
        let launcher = FakeBuildRunLauncher()
        let source = fixtureSource(providerRuns: [.init(id: "application", displayName: "Run", targetTags: ["application"])])
        return (planner, providers, launcher, Harness(planner: planner, sources: [source], providers: providers, runLauncher: launcher))
    }

    @Test(arguments: [Int32(0), Int32(7)])
    func providerTaskRunsWithoutPageOrHostCommand(exitCode: Int32) async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/execute")
        let providers = FakeBuildProviders()
        providers.executionResult = BuildProviderExecutionResult(exitCode: exitCode, output: "completed")
        let runner = FakeBuildRunner()
        let harness = Harness(planner: planner, runner: runner, providers: providers)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        try #require(harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build") != nil)
        try #require(await harness.waitForRunState { $0 != .running })
        #expect(providers.sent.map(\.request.method) == ["lithe/build/execute"])
        #expect(providers.sent.first?.target.workspaceURL == Self.workspace)
        #expect(runner.requests.isEmpty)
        #expect(harness.service.output.contains("completed"))
        if exitCode == 0 { #expect(harness.service.runState == .succeeded) }
        else { if case .failed = harness.service.runState {} else { Issue.record("Expected tool failure") } }
    }

    @Test(arguments: ["early\n", "a"])
    func providerTaskAppendsFinalSuffixAndDecodesTheCompleteOutput(prefix: String) async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/execute")
        let providers = FakeBuildProviders()
        // A progress chunk may end before a combining scalar in the next
        // chunk; compare byte prefixes rather than normalized Characters.
        let final = prefix == "a" ? "a\u{301}" : "early\nfinal\n"
        providers.executionResult = BuildProviderExecutionResult(exitCode: 0, output: final)
        let release = BuildTestGate()
        providers.replyGate = release
        let harness = Harness(planner: planner, providers: providers)
        defer { release.open(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        try #require(await providers.requestStarted.waitUntilOpen())
        providers.executionProgress?(BuildProviderProgress(output: prefix))
        release.open()
        try #require(await harness.waitForRunState { $0 == .succeeded })
        #expect(Array(harness.service.output.utf8) == Array(final.utf8))
        #expect(planner.diagnosticOutputs == [final])
    }

    /// Configuration may change while the final decode is off the main actor.
    @Test(arguments: [false, true])
    func providerTaskOptionsCancelDuringDiagnosticDecode(tests: Bool) async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: tests ? "lithe/build/test" : "lithe/build/execute")
        let stale = try Self.diagnostic("stale provider diagnostic")
        planner.diagnostics = [stale]
        let gate = GatedBuildDecode()
        planner.diagnosticsGate = gate
        let providers = FakeBuildProviders()
        let harness = Harness(planner: planner, providers: providers)
        defer { gate.releaseDecode(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        if tests { harness.service.runTests(Self.instanceID, request: BuildTestRequest(), title: "Tests") }
        else { harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build") }
        try #require(await gate.entered.waitUntilOpen())
        harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
        #expect(harness.service.runState == .cancelled)
        gate.releaseDecode()
        try #require(await gate.finished.waitUntilOpen())
        #expect(await harness.waitsForStaleDiagnostics([stale]) == false)
        #expect(harness.service.diagnostics.isEmpty)
    }

    /// A backend may drain after cancellation; no output or result may reach
    /// the replacement workspace or the new effective configuration.
    @Test(arguments: ["stop", "workspace", "options", "disable"], [false, true])
    func providerTaskLateOutputCannotCrossItsOwner(change: String, tests: Bool) async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: tests ? "lithe/build/test" : "lithe/build/execute")
        let providers = FakeBuildProviders()
        let release = BuildTestGate()
        providers.replyGate = release
        let harness = Harness(planner: planner, providers: providers)
        defer { release.open(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        if tests { harness.service.runTests(Self.instanceID, request: BuildTestRequest(), title: "Tests") }
        else { harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build") }
        try #require(await providers.requestStarted.waitUntilOpen())
        providers.executionProgress?(BuildProviderProgress(output: "early"))
        #expect(harness.service.output.contains("early"))
        switch change {
        case "workspace": harness.service.reset(workspaceURL: URL(fileURLWithPath: "/workspace/next"))
        case "options": harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
        case "disable": harness.sources = []; harness.service.pluginsChanged()
        default: harness.service.stopRun()
        }
        providers.executionProgress?(BuildProviderProgress(output: "late"))
        release.open()
        try #require(await providers.requestFinished.waitUntilOpen())
        #expect(!harness.service.output.contains("late"))
        #expect(!harness.service.output.contains("completed"))
        #expect(harness.service.runState != .succeeded)
    }

    @Test(arguments: [Int32(0), Int32(3)])
    func providerTestsDecodeReportsWithoutStartingAHostCommand(exitCode: Int32) async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "loaded"))
        ])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/test")
        planner.testPlanDeclaresResults = true
        let expected = try Self.testResults("assertion failed")
        planner.decodedTestResults = expected
        let providers = FakeBuildProviders()
        providers.executionResult = BuildProviderExecutionResult(exitCode: exitCode, output: "test output")
        let runner = FakeBuildRunner()
        let harness = Harness(planner: planner, runner: runner, providers: providers)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.runTests(Self.instanceID, request: BuildTestRequest(projects: ["app"]), title: "Tests")
        try #require(await harness.waitForRunState { $0 != .running })
        #expect(providers.sent.map(\.request.method) == ["lithe/build/test"])
        #expect(runner.requests.isEmpty)
        #expect(harness.service.testResults == expected)
        #expect(planner.diagnosticOutputs == ["test output"])
        if exitCode == 0 { #expect(harness.service.runState == .succeeded) }
        else { if case .failed = harness.service.runState {} else { Issue.record("Expected failed test exit") } }
    }

    /// The provider operation remains cancellable while its reports decode.
    @Test
    func providerTestOptionsCancelDuringReportDecode() async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "static", model: Self.model(name: "loaded"))
        ])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/test")
        planner.testPlanDeclaresResults = true
        let stale = try Self.testResults("stale")
        planner.decodedTestResults = stale
        let gate = GatedBuildDecode()
        planner.testResultsGate = gate
        let harness = Harness(planner: planner, providers: FakeBuildProviders())
        defer { gate.releaseDecode(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.runTests(Self.instanceID, request: BuildTestRequest(), title: "Tests")
        try #require(await gate.entered.waitUntilOpen())
        harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
        #expect(harness.service.runState == .cancelled)
        gate.releaseDecode()
        try #require(await gate.finished.waitUntilOpen())
        #expect(await harness.waitsForStaleTestResults(stale) == false)
        #expect(harness.service.testResults == nil)
    }

    @Test(arguments: ["source", "settings", "options"])
    func discoveredTestsRunExactSelectorsAndSourceEditsRevokeThem(change: String) async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/discoverTests")
        let discovered = try decode(BuildTestDiscovery.self, #"{"tests":[{"id":"exact","suite":"Suite","case":"case with spaces","project":{"name":"app","path":"app","tags":[],"properties":{}}}]}"#)
        planner.discovery = discovered
        let providers = FakeBuildProviders()
        let runner = FakeBuildRunner()
        var providerSettings: [String: ToolingJSONValue] = [:]
        let harness = Harness(planner: planner, runner: runner, sources: [fixtureSource(testDiscovery: true)], providers: providers,
                              settings: { _ in providerSettings })
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.discoverTests(Self.instanceID)
        try #require(await harness.waitForRunState { $0 == .succeeded })
        #expect(harness.service.testDiscovery(Self.instanceID) == .loaded(discovered))
        #expect(runner.requests.isEmpty)
        planner.providerRequest = Self.providerRequest(method: "lithe/build/test")
        try #require(harness.service.runDiscoveredTest(Self.instanceID, testID: "exact", title: "Test") != nil)
        try #require(await harness.waitForRunState { $0 == .succeeded })
        #expect(planner.testRequests == [discovered.tests[0].request])
        #expect(providers.sent.map(\.request.method) == ["lithe/build/discoverTests", "lithe/build/test"])
        // A source edit, not just a build-file edit, revokes the cached selector.
        if change == "source" {
            harness.service.workspaceFilesChanged([Self.workspace.appendingPathComponent("src/Test.java")])
        } else if change == "settings" { providerSettings = ["providerHeapMB": .integer(2048)] }
        else {
            harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
            harness.service.setOption(Self.instanceID, optionID: "release", value: nil)
        }
        #expect(harness.service.testDiscovery(Self.instanceID) == nil)
        #expect(harness.service.runDiscoveredTest(Self.instanceID, testID: "exact", title: "Test") == nil)
    }

    @Test
    func queuedDiscoveryCannotPublishAfterItWasReplaced() async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/discoverTests")
        planner.discovery = try decode(BuildTestDiscovery.self, #"{"tests":[]}"#)
        let providers = FakeBuildProviders()
        let harness = Harness(planner: planner, sources: [fixtureSource(testDiscovery: true)], providers: providers)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.discoverTests(Self.instanceID)
        // Both actions run on the main actor before the queued task can start.
        harness.service.stopRun()
        planner.providerRequest = Self.providerRequest(method: "lithe/build/execute")
        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        try #require(await harness.waitForRunState { $0 == .succeeded })
        #expect(providers.sent.map(\.request.method) == ["lithe/build/execute"])
        #expect(harness.service.testDiscovery(Self.instanceID) == nil)
    }

    @Test(arguments: [false, true])
    func discoveryFailureIsVisibleAndNeverStartsAHostCommand(hasProvider: Bool) async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/discoverTests")
        let providers = FakeBuildProviders()
        providers.failure = BuildSystemServiceTestsError(message: "discovery failed")
        let runner = FakeBuildRunner()
        let harness = Harness(planner: planner, runner: runner, sources: [fixtureSource(testDiscovery: true)],
                              providers: hasProvider ? providers : nil)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.discoverTests(Self.instanceID)
        try #require(await harness.waitForRunState { if case .failed = $0 { return true }; return false })
        guard case .failed(let message) = harness.service.testDiscovery(Self.instanceID) else {
            Issue.record("Discovery failure must be visible and retryable"); return
        }
        if hasProvider { #expect(message.contains("discovery failed")) }
        #expect(runner.requests.isEmpty)
    }

    @Test(arguments: ["stop", "workspace", "options", "source", "disable"])
    func discoveryDecodeCannotPublishAfterItsOwnerChanges(change: String) async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/discoverTests")
        planner.discovery = try decode(BuildTestDiscovery.self, #"{"tests":[]}"#)
        let gate = GatedBuildDecode()
        planner.discoveryGate = gate
        let harness = Harness(planner: planner, sources: [fixtureSource(testDiscovery: true)], providers: FakeBuildProviders())
        defer { gate.releaseDecode(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { !$0.isEmpty })
        harness.service.discoverTests(Self.instanceID)
        try #require(await gate.entered.waitUntilOpen())
        switch change {
        case "workspace": harness.service.reset(workspaceURL: URL(fileURLWithPath: "/workspace/next"))
        case "options": harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
        case "source": harness.service.workspaceFilesChanged([Self.workspace.appendingPathComponent("src/Test.java")])
        case "disable": harness.sources = []; harness.service.pluginsChanged()
        default: harness.service.stopRun()
        }
        gate.releaseDecode()
        try #require(await gate.finished.waitUntilOpen())
        // Observe publication rather than assuming the worker's return already
        // passed through the main actor. The bounded negative assertion covers it.
        let published = BuildTestGate()
        let observation = harness.service.objectWillChange.sink {
            if case .loaded = harness.service.testDiscovery(Self.instanceID) { published.open() }
        }
        defer { observation.cancel() }
        #expect(await published.waitUntilOpen(timeout: .milliseconds(500)) == false)
        #expect(harness.service.testDiscovery(Self.instanceID) == nil)
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

    /// A first load lets the provider answer from its snapshot; the request
    /// still names the build tool the host resolved, so the provider does
    /// not repeat wrapper, MAVEN_HOME, PATH, and override lookup.
    @Test
    func providerModelLoadCarriesTheResolvedToolWithoutRefresh() async throws {
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

        // Core decides the source; the tool is resolved only once it says
        // provider, and the request is planned again with it.
        #expect(planner.modelPlanHints == [
            BuildProviderHints(reason: .initial),
            BuildProviderHints(reason: .initial, toolExecutable: FakeToolResolver.executableURL),
        ])
        #expect(harness.tools.resolutions == 1)
        #expect(providers.sent.count == 1)
    }

    /// The user's Reload must reach the provider, or it would answer from a
    /// snapshot taken before the build files changed.
    @Test
    func providerReloadsAskForARefresh() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [
            try Self.instance(modelSource: "provider", model: Self.model(name: "loaded"))
        ])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/model")
        let providers = FakeBuildProviders()
        let harness = Harness(planner: planner, providers: providers)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { !$0.isEmpty })

        harness.service.loadModel(Self.instanceID, reason: .refresh)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })
        #expect(planner.modelPlanHints.last == BuildProviderHints(
            reason: .refresh, toolExecutable: FakeToolResolver.executableURL
        ))

        harness.service.loadDependencies(Self.instanceID, project: nil, reason: .refresh)
        #expect(await harness.waitForEntries { entry in
            guard case .loaded = entry.first?.dependencies["app"] else { return false }
            return true
        })
        #expect(planner.dependencyPlanHints == [
            BuildProviderHints(reason: .refresh),
            BuildProviderHints(reason: .refresh, toolExecutable: FakeToolResolver.executableURL),
        ])
    }

    /// A missing build tool is not a provider failure: the request goes out
    /// without the tool and the provider looks it up itself.
    @Test
    func providerLoadsWithoutTheToolWhenResolutionFails() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/model")
        let providers = FakeBuildProviders()
        let harness = Harness(planner: planner, providers: providers)
        harness.tools.failure = BuildToolResolutionError("Maven is not installed.")
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })

        #expect(planner.modelPlanHints == [BuildProviderHints(reason: .initial)])
        #expect(providers.sent.count == 1)
        #expect(harness.service.output.contains("Maven is not installed."))
    }

    @Test
    func providerDoesNotFallBackWhenAnExplicitExecutableFails() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/model")
        let providers = FakeBuildProviders()
        let harness = Harness(planner: planner, providers: providers, settings: { pluginID in
            #expect(pluginID == "dev.example")
            return ["toolPath": .string("/custom tools/build")]
        })
        harness.tools.failure = BuildToolResolutionError("Selected executable is unavailable.", terminal: true)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })
        harness.service.loadModel(Self.instanceID)
        #expect(await harness.waitForEntries { if case .failed = $0.first?.modelState { return true }; return false })
        #expect(providers.sent.isEmpty)
        guard case .failed(let message)? = harness.service.entries.first?.modelState else { return }
        #expect(message.contains("Selected executable is unavailable."))
    }

    /// Command sources resolve their tool when the command runs; planning
    /// never resolves it a second time for them.
    @Test
    func commandModelLoadsDoNotResolveAProviderTool() async throws {
        let planner = FakeBuildPlanner()
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "command")])
        planner.modelOutput = .stdout
        let runner = FakeBuildRunner()
        runner.script = .init(chunks: [], result: BuildCommandResult(termination: .exited(0), standardOutput: "MODEL"))
        let harness = Harness(planner: planner, runner: runner)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        #expect(await harness.waitForEntries { $0.first?.modelState == .notLoaded })

        harness.service.loadModel(Self.instanceID, reason: .refresh)
        #expect(await harness.waitForEntries { $0.first?.modelState == .loaded })

        #expect(planner.modelPlanHints == [BuildProviderHints(reason: .refresh)])
        #expect(harness.tools.resolutions == 1)
        #expect(runner.requests.count == 1)
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


    @Test(arguments: ["disable", "optionABA", "producerReload", "files", "workspace"])
    func sharedModelChangesCancelAnUncooperativeConsumer(change: String) async throws {
        // Producer facts are captured before the backend starts; changing the producer
        // revokes them while the reply is deliberately held, even across an option ABA.
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        let producer = try decode(BuildSystemInstance.self, """
        {"id":"source:app","pluginID":"dev.producer","buildSystemID":"source","displayName":"Source",
        "root":"app","modelSource":"provider","optionFingerprint":"o",
        "model":{"projects":[{"id":"p","path":"app","name":"source"}]}}
        """)
        planner.detection = BuildDetection(instances: [producer, try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/execute")
        let sources = [
            fixtureSource(pluginID: "dev.producer", buildSystemID: "source", sharesModel: true),
            fixtureSource(modelInputs: [.init(pluginID: "dev.producer", buildSystemID: "source")])
        ]
        let gate = BuildTestGate()
        let providers = FakeBuildProviders()
        providers.replyGate = gate
        providers.ignoresCancellation = true
        let harness = Harness(planner: planner, sources: sources, providers: providers)
        defer { gate.open(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { $0.count == 2 })
        let operation = try #require(harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build"))
        try #require(await providers.requestStarted.waitUntilOpen())
        let facts = try #require(planner.modelInputSources.last)
        #expect(facts.count == 1)
        #expect(facts.first?.instances.first?.buildSystemID == "source")
        if change == "disable" {
            harness.sources = [sources[1]]
            harness.service.pluginsChanged()
        } else if change == "optionABA" {
            harness.service.setOption("source:app", optionID: "release", value: .bool(true))
            harness.service.setOption("source:app", optionID: "release", value: nil)
        } else if change == "producerReload" {
            harness.service.loadModel("source:app")
        } else if change == "files" {
            harness.service.workspaceFilesChanged([Self.workspace.appendingPathComponent("build.file")])
        } else {
            harness.service.reset(workspaceURL: URL(fileURLWithPath: "/workspace/other"))
        }
        #expect(harness.service.currentRunID != operation)
        gate.open()
        try #require(await providers.requestFinished.waitUntilOpen())
        #expect(harness.service.runState != .succeeded)
    }

    @Test
    func aProducerModelLoadedAcrossOptionABARemainsStale() async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/model")
        let gate = BuildTestGate()
        let providers = FakeBuildProviders()
        providers.replyGate = gate
        let harness = Harness(planner: planner, sources: [fixtureSource(sharesModel: true)], providers: providers)
        defer { gate.open(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { $0.count == 1 })
        harness.service.loadModel(Self.instanceID)
        try #require(await providers.requestStarted.waitUntilOpen())
        harness.service.setOption(Self.instanceID, optionID: "release", value: .bool(true))
        harness.service.setOption(Self.instanceID, optionID: "release", value: nil)
        gate.open()
        try #require(await harness.waitForEntries { $0.first?.modelState == .loaded })
        #expect(harness.service.entry(Self.instanceID)?.isReloadRequired == true)
    }

    @Test(arguments: [false, true])
    func sharedInputsStayRevokedThroughBackgroundDecode(dependencies: Bool) async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        planner.detection = BuildDetection(instances: [try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: dependencies ? "lithe/build/dependencies" : "lithe/build/model")
        let consumer = fixtureSource(modelInputs: [.init(pluginID: "dev.producer", buildSystemID: "source")])
        let gate = GatedBuildDecode()
        planner.backgroundDecodeGate = gate
        let harness = Harness(planner: planner, sources: [consumer], providers: FakeBuildProviders())
        defer { gate.releaseDecode(); harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { $0.count == 1 })
        if dependencies { harness.service.loadDependencies(Self.instanceID, project: nil) }
        else { harness.service.loadModel(Self.instanceID) }
        try #require(await gate.entered.waitUntilOpen())
        // Availability changes revoke even the explicit unavailable slot snapshot.
        harness.service.pluginsChanged()
        gate.releaseDecode()
        try #require(await gate.finished.waitUntilOpen())
        #expect(!(await harness.waitsForStaleSharedInputResult()))
        #expect(harness.service.entry(Self.instanceID)?.model == nil)
        #expect(harness.service.entry(Self.instanceID)?.dependencies.isEmpty == true)
    }

    @Test
    func sharedModelHostIncludesOnlyEnabledExactPackageFacts() async throws {
        let planner = FakeBuildPlanner()
        planner.fingerprint = "o"
        let producer = try decode(BuildSystemInstance.self, """
        {"id":"source:app","pluginID":"dev.producer","buildSystemID":"source","displayName":"Source",
        "root":"app","modelSource":"provider","optionFingerprint":"o"}
        """)
        planner.detection = BuildDetection(instances: [producer, try Self.instance(modelSource: "provider")])
        planner.providerRequest = Self.providerRequest(method: "lithe/build/execute")
        let consumer = fixtureSource(modelInputs: [.init(pluginID: "dev.producer", buildSystemID: "source")])
        let producerSource = fixtureSource(pluginID: "dev.producer", buildSystemID: "source", sharesModel: true)
        let providers = FakeBuildProviders()
        let harness = Harness(planner: planner, sources: [producerSource, consumer], providers: providers)
        defer { harness.service.stop() }
        harness.service.reset(workspaceURL: Self.workspace)
        try #require(await harness.waitForEntries { $0.count == 2 })
        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        try #require(await harness.waitForRunState { $0 == .succeeded })
        let instance = try #require(planner.modelInputSources.last?.first?.instances.first)
        #expect(instance.state == "stale")
        #expect(instance.model == nil)
        harness.sources = [consumer]
        harness.service.pluginsChanged()
        try #require(await harness.waitForEntries { $0.count == 1 })
        harness.service.runTask(Self.instanceID, request: BuildTaskRequest(task: "build"), title: "Build")
        try #require(await harness.waitForRunState { $0 == .succeeded })
        #expect(planner.modelInputSources.last?.isEmpty == true)
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

private func fixtureSource(pluginID: String = "dev.example", testDiscovery: Bool = false, providerRuns: [DeclarativeBuildSystem.ProviderRun] = [], buildSystemID: String = "fixture", sharesModel: Bool = false, modelInputs: [DeclarativeBuildSystem.ModelInput] = []) -> BuildSystemPluginSource {
    BuildSystemPluginSource(
        pluginID: pluginID,
        manifest: Data("{}".utf8),
        packageURL: URL(fileURLWithPath: "/plugins/\(pluginID)"),
        buildSystems: [DeclarativeBuildSystem(
            id: buildSystemID, displayName: "Fixture", modelSource: .command, tasks: [],
            testScopes: [], dependencyScopes: [], testDiscovery: testDiscovery, providerRuns: providerRuns, sharesModel: sharesModel, modelInputs: modelInputs
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
    let tools = FakeToolResolver()
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
        runLauncher: (any BuildRunLaunching)? = nil,
        settings: @escaping @MainActor (String) -> [String: ToolingJSONValue] = { _ in [:] },
        waitForRedetection: @escaping @Sendable () async throws -> Void = {}
    ) {
        let enabledSources = SourceList(sources)
        self.enabledSources = enabledSources
        service = BuildSystemService(
            planner: planner,
            tools: tools,
            optionsStore: optionsStore,
            stateLocator: stateLocator,
            runner: runner,
            providers: providers,
            runLauncher: runLauncher,
            settings: settings,
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
    func waitsForStaleSharedInputResult() async -> Bool {
        let gate = BuildTestGate()
        let observation = service.$entries.sink { entries in
            if entries.contains(where: { $0.model != nil || $0.dependencies.values.contains(where: { if case .loaded = $0 { return true }; return false }) }) { gate.open() }
        }
        defer { observation.cancel() }
        return await gate.waitUntilOpen(timeout: .milliseconds(500))
    }

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
        var backgroundDecodeGate: GatedBuildDecode?
        var diagnosticsGate: GatedBuildDecode?
        var testResultsGate: GatedBuildDecode?
        var detectGate: GatedBuildDecode?
        var decodedTestResults: BuildTestResults?
        var testPlanDeclaresResults = false
        var discovery: BuildTestDiscovery?
        var discoveryGate: GatedBuildDecode?
        var runPreparationGate: GatedBuildDecode?
        var testRequests: [BuildTestRequest] = []
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
        var modelInputSources: [[BuildModelInputSource]] = []
        var modelPlanHints: [BuildProviderHints] = []
        var dependencyPlanHints: [BuildProviderHints] = []
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
    var runPreparationGate: GatedBuildDecode? {
        get { access { $0.runPreparationGate } }
        set { access { $0.runPreparationGate = newValue } }
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
    var discovery: BuildTestDiscovery? {
        get { access { $0.discovery } }
        set { access { $0.discovery = newValue } }
    }
    var discoveryGate: GatedBuildDecode? {
        get { access { $0.discoveryGate } }
        set { access { $0.discoveryGate = newValue } }
    }
    var testRequests: [BuildTestRequest] { access { $0.testRequests } }
    var testPlanDeclaresResults: Bool {
        get { access { $0.testPlanDeclaresResults } }
        set { access { $0.testPlanDeclaresResults = newValue } }
    }
    var taskPlanContexts: [BuildPlanContext] { access { $0.taskPlanContexts } }
    /// The provider hints of every model and dependency plan, in order.
    var modelPlanHints: [BuildProviderHints] { access { $0.modelPlanHints } }
    var dependencyPlanHints: [BuildProviderHints] { access { $0.dependencyPlanHints } }
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

    func invocationPlan(_ target: BuildSystemTarget, root: String, settings: [String: ToolingJSONValue]) throws -> BuildInvocation {
        let configured: String? = if case .string(let path)? = settings["toolPath"] { path } else { nil }
        return BuildInvocation(executables: [.setting(id: "toolPath", path: configured), .command("fake")])
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

    var backgroundDecodeGate: GatedBuildDecode? {
        get { access { $0.backgroundDecodeGate } }
        set { access { $0.backgroundDecodeGate = newValue } }
    }

    private func waitForBackgroundDecode() throws {
        if let gate = access({ let gate = $0.backgroundDecodeGate; $0.backgroundDecodeGate = nil; return gate }) {
            gate.entered.open()
            defer { gate.finished.open() }
            guard gate.waitForRelease() else { throw GatedDecodeError.releaseTimedOut }
        }
    }

    var modelInputSources: [[BuildModelInputSource]] { access { $0.modelInputSources } }

    func resolveModelInputs(_ target: BuildSystemTarget, revision: UInt64, sources: [BuildModelInputSource]) throws -> ToolingJSONValue {
        access { $0.modelInputSources.append(sources) }
        return .object(["version": .integer(1), "revision": .integer(Int(revision)), "inputs": .array([])])
    }

    private func withInputs(_ request: BuildProviderRequest, context: BuildPlanContext) -> BuildProviderRequest {
        guard let inputs = context.modelInputs, case .object(var params) = request.params else { return request }
        params["modelInputs"] = inputs
        return BuildProviderRequest(method: request.method, params: .object(params), optionFingerprint: request.optionFingerprint,
            executesProjectCode: request.executesProjectCode, mayUseNetwork: request.mayUseNetwork)
    }

    func modelPlan(
        _ target: BuildSystemTarget,
        context: BuildPlanContext,
        outputFile: URL?,
        providerHints: BuildProviderHints
    ) throws -> BuildOutputPlan {
        access { $0.modelPlanHints.append(providerHints) }
        if let request = providerRequest { return .provider(withInputs(request, context: context)) }
        return .process(plan(["model"], output: modelOutput))
    }

    func taskPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTaskRequest) throws
        -> BuildOutputPlan {
        access { $0.taskPlanContexts.append(context) }
        if let request = providerRequest { return .provider(withInputs(request, context: context)) }
        return .process(plan([request.task, "with space"], output: nil))
    }

    func testPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTestRequest) throws
        -> BuildTestPlan {
        access { $0.testRequests.append(request) }
        let declaresResults = access { $0.testPlanDeclaresResults }
        return BuildTestPlan(
            execution: providerRequest.map { .provider(withInputs($0, context: context)) } ?? .process(plan(["test"], output: nil)),
            results: declaresResults ? .reports(decoder: "junitXml", patterns: []) : nil
        )
    }

    func prepareRunPlan(_ target: BuildSystemTarget, context: BuildPlanContext, run: String,
                        project: BuildSelection, selectedTarget: BuildSelection, userArguments: [String]) throws -> BuildProviderRequest {
        guard let providerRequest else { throw CancellationError() }
        return withInputs(providerRequest, context: context)
    }

    func prepareDebugPlan(_ target: BuildSystemTarget, context: BuildPlanContext, run: String,
                          project: BuildSelection, selectedTarget: BuildSelection, userArguments: [String]) throws -> BuildProviderRequest {
        guard let providerRequest else { throw CancellationError() }
        return withInputs(providerRequest, context: context)
    }

    func decodeDebugPreparation(_ target: BuildSystemTarget, workspaceURL: URL, root: String, run: String,
                                result: ToolingJSONValue) throws -> BuildDebugPreparation {
        if let gate = access({ let gate = $0.runPreparationGate; $0.runPreparationGate = nil; return gate }) {
            gate.entered.open()
            guard gate.waitForRelease() else { throw GatedDecodeError.releaseTimedOut }
            gate.finished.open()
        }
        return try JSONDecoder().decode(BuildDebugPreparation.self, from: JSONEncoder().encode(result))
    }

    func decodeRunPreparation(_ target: BuildSystemTarget, workspaceURL: URL, root: String,
                              result: ToolingJSONValue) throws -> BuildRunPreparation {
        if let gate = access({ let gate = $0.runPreparationGate; $0.runPreparationGate = nil; return gate }) {
            gate.entered.open()
            guard gate.waitForRelease() else { throw GatedDecodeError.releaseTimedOut }
            gate.finished.open()
        }
        return try JSONDecoder().decode(BuildRunPreparation.self, from: JSONEncoder().encode(result))
    }

    func testDiscoveryPlan(_ target: BuildSystemTarget, context: BuildPlanContext) throws -> BuildProviderRequest {
        guard let providerRequest else { throw CancellationError() }
        return providerRequest
    }

    func decodeTestDiscovery(_ target: BuildSystemTarget, context: BuildPlanContext, result: ToolingJSONValue) throws -> BuildTestDiscovery {
        if let gate = access({ let gate = $0.discoveryGate; $0.discoveryGate = nil; return gate }) {
            gate.entered.open()
            guard gate.waitForRelease() else { throw GatedDecodeError.releaseTimedOut }
            gate.finished.open()
        }
        guard let discovery else { throw CancellationError() }
        return discovery
    }

    func dependencyPlan(
        _ target: BuildSystemTarget,
        context: BuildPlanContext,
        project: BuildSelection?,
        outputFile: URL?,
        providerHints: BuildProviderHints
    ) throws -> BuildOutputPlan {
        access { $0.dependencyPlanHints.append(providerHints) }
        if let request = providerRequest { return .provider(withInputs(request, context: context)) }
        return .process(plan(["dependencies"], output: .stdout))
    }

    func decodeModel(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        output: BuildCommandOutput,
        options: [String: ToolingJSONValue]
    ) throws -> BuildModel {
        try waitForBackgroundDecode()
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
        try waitForBackgroundDecode()
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
    static let executableURL = URL(fileURLWithPath: "/tool/bin/fake")
    /// When set, resolution fails like a build tool that is not installed.
    var failure: (any Error)?
    private(set) var resolutions = 0

    func resolve(
        _ invocation: BuildInvocation,
        displayName: String,
        workspaceURL: URL,
        checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        resolutions += 1
        if let failure { throw failure }
        return ResolvedBuildTool(
            executableURL: Self.executableURL,
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
        if let replyGate, !(await replyGate.waitUntilOpen(ignoringCancellation: ignoresCancellation)) { throw CancellationError() }
        if let failure { throw failure }
        return reply
    }

    var ignoresCancellation = false
    var executionResult = BuildProviderExecutionResult(exitCode: 0, output: "completed")
    var executionProgress: (@MainActor @Sendable (BuildProviderProgress) -> Void)?

    func execute(
        _ request: BuildProviderRequest, on target: BuildProviderTarget, timeout: Duration,
        progress: @escaping @MainActor @Sendable (BuildProviderProgress) -> Void
    ) async throws -> BuildProviderExecutionResult {
        executionProgress = progress
        _ = try await send(request, to: target, timeout: timeout)
        return executionResult
    }

    func prepareDebug(_ request: BuildProviderRequest, on target: BuildProviderTarget, timeout: Duration,
                      progress: @escaping @MainActor @Sendable (BuildProviderProgress) -> Void) async throws -> ToolingJSONValue {
        try await prepareRun(request, on: target, timeout: timeout, progress: progress)
    }

    func prepareRun(_ request: BuildProviderRequest, on target: BuildProviderTarget, timeout: Duration,
                    progress: @escaping @MainActor @Sendable (BuildProviderProgress) -> Void) async throws -> ToolingJSONValue {
        executionProgress = progress
        return try await send(request, to: target, timeout: timeout)
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

@MainActor
private final class FakeBuildRunLauncher: BuildRunLaunching {
    var lastConfiguration: RunConfiguration?
    var launched: [BuildRunPreparation] = []
    let didLaunch = BuildTestGate()
    var stopped: [String] = []
    func launchPreparedRun(_ plan: BuildRunPreparation, workspaceURL: URL, title: String, configuration: RunConfiguration?) throws -> String {
        lastConfiguration = configuration
        launched.append(plan)
        didLaunch.open()
        return "prepared-app"
    }
    func stopPreparedRun(_ operationID: String) { stopped.append(operationID) }
}

import Combine
import Foundation
import Testing
import WebKit
import LitheApplicationKernel
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI
@testable import Lithe

@MainActor
@Suite("Plugin web bridge", .serialized)
struct PluginWebBridgeTests {
    @Test func unknownMethodsAndMalformedRequestsAreRefused() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }

        #expect(try await harness.error("build.deleteEverything") == "plugin.web.unknownMethod")
        #expect(try await harness.errorCode(#"not json"#) == "plugin.web.invalidRequest")
        #expect(try await harness.errorCode(#"{"method":"ui.getState","extra":1}"#) == "plugin.web.invalidRequest")
        #expect(try await harness.error("ui.getState", ["unexpected": .bool(true)]) == "plugin.web.invalidRequest")
        #expect(try await harness.error("ui.setState") == "plugin.web.invalidRequest")
        #expect(try await harness.error("workspace.openFile", ["path": .integer(3)]) == "plugin.web.invalidRequest")
        #expect(try await harness.error("workspace.openFile", ["path": .string("a.txt"), "line": .integer(0)])
            == "plugin.web.invalidRequest")
        #expect(try await harness.error("build.cancel", ["run": .string("never-started")]) == "plugin.web.invalidRequest")
        #expect(try await harness.error("build.setOptions", [
            "instance": .string("own"), "values": .object(["undeclared": .bool(true)])
        ]) == "plugin.web.invalidRequest")
        #expect(harness.build.tasks.isEmpty)
    }

    @Test func pageReachesOnlyItsPluginAndWorkspace() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }

        #expect(try await harness.error("build.refresh", ["instance": .string("foreign")]) == "plugin.web.forbidden")
        #expect(try await harness.error("build.runTask", ["instance": .string("foreign"), "task": .string("build")])
            == "plugin.web.forbidden")
        #expect(try await harness.error("workspace.openFile", ["path": .string("../outside.txt")]) == "plugin.web.forbidden")
        #expect(try await harness.error("workspace.openFile", ["path": .string(harness.outside.path)])
            == "plugin.web.forbidden")
        #expect(try await harness.error("workspace.openFile", ["path": .string("link/secret.txt")])
            == "plugin.web.forbidden")
        #expect(try await harness.error("build.runTask", [
            "instance": .string("own"), "task": .string("build"), "project": .object(["path": .string("../other")])
        ]) == "plugin.web.forbidden")
        #expect(harness.host.opened.isEmpty)

        let instances = try await harness.ok("build.instances")
        guard case .object(let result) = instances, case .array(let listed)? = result["instances"] else {
            Issue.record("Unexpected instances \(instances)")
            return
        }
        #expect(listed.count == 1)
        #expect(listed.first.flatMap { if case .object(let value) = $0 { value["id"] } else { nil } } == .string("own"))

        harness.host.pluginWebWorkspaceURL = harness.outside.deletingLastPathComponent()
        #expect(try await harness.error("ui.getState") == "plugin.web.forbidden")
    }

    @Test func functionsAreReachedOnlyThroughThePluginsOwnInstancesWithConsent() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }

        #expect(try await harness.error("functions.list", ["instance": .string("foreign")]) == "plugin.web.forbidden")
        #expect(try await harness.error("functions.invoke", [
            "instance": .string("foreign"), "function": .string("snapshot.read")
        ]) == "plugin.web.forbidden")
        #expect(try await harness.error("functions.invoke", [
            "instance": .string("own"), "function": .string("snapshot.read"), "params": .array([])
        ]) == "plugin.web.invalidRequest")
        #expect(harness.host.consents.isEmpty)

        harness.host.allowsProcesses = false
        #expect(try await harness.error("functions.list", ["instance": .string("own")]) == "plugin.web.forbidden")
        #expect(try await harness.error("functions.invoke", [
            "instance": .string("own"), "function": .string("snapshot.read")
        ]) == "plugin.web.forbidden")
        #expect(harness.build.functionListings == 0)
        #expect(harness.build.invocations.isEmpty)

        harness.host.allowsProcesses = true
        #expect(try await harness.ok("functions.list", ["instance": .string("own")])
            == .object(["functions": .array([.string("snapshot.read"), .string("workspace.build")])]))
        #expect(harness.build.functionListings == 1)
        #expect(harness.host.consents.allSatisfy { $0.pluginID == "dev.example.web" })
    }

    @Test func functionResultsProgressAndPluginFailuresReachThePage() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        var events: [(String, ToolingJSONValue)] = []
        harness.bridge.emit = { events.append(($0, $1)) }
        harness.build.invoke = { functionID, params, progress in
            progress(PluginFunctionProgress(message: "Building app", percentage: 40))
            guard functionID == "workspace.build" else {
                throw PluginFunctionFailure(
                    code: "plugin.function.failed", message: "broken failed", pluginErrorCode: "sample.buildFailed"
                )
            }
            return .object(["echo": params])
        }

        let value = try await harness.ok("functions.invoke", [
            "instance": .string("own"), "function": .string("workspace.build"),
            "params": .object(["project": .string("app")]), "call": .string("call-1")
        ])
        #expect(value == .object(["value": .object(["echo": .object(["project": .string("app")])])]))
        #expect(harness.build.invocations.map(\.entryID) == ["own"])
        #expect(events.count == 1)
        #expect(events.first?.0 == "functions.progress")
        #expect(events.first?.1 == .object([
            "call": .string("call-1"), "instance": .string("own"), "function": .string("workspace.build"),
            "message": .string("Building app"), "percentage": .integer(40)
        ]))

        // Without a call ID nothing can be correlated, so no progress is sent.
        let failure = try await harness.failure("functions.invoke", [
            "instance": .string("own"), "function": .string("snapshot.clear")
        ])
        #expect(failure == .object([
            "code": .string("plugin.function.failed"), "message": .string("broken failed"),
            "pluginErrorCode": .string("sample.buildFailed")
        ]))
        #expect(events.count == 1)
    }

    @Test func cancellingACallOrClosingThePageCancelsTheFunction() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let entered = TestGate()
        harness.build.invoke = { _, _, _ in
            entered.open()
            // Ends through cancellation; the gate's bound keeps a broken test finite.
            _ = await TestGate().waitUntilOpen(timeout: .seconds(10))
            try Task.checkCancellation()
            return .null
        }

        let pending = Task { try await harness.error("functions.invoke", [
            "instance": .string("own"), "function": .string("workspace.build"), "call": .string("slow")
        ]) }
        defer { pending.cancel() }
        #expect(await entered.waitUntilOpen(), "The function never started")
        #expect(try await harness.error("functions.invoke", [
            "instance": .string("own"), "function": .string("workspace.build"), "call": .string("slow")
        ]) == "plugin.web.invalidRequest")
        #expect(try await harness.ok("functions.cancel", ["call": .string("slow")]) == .object([:]))
        #expect(try await pending.value == "requestCancelled")
        // A finished call is cancelled as a no-op.
        #expect(try await harness.ok("functions.cancel", ["call": .string("slow")]) == .object([:]))

        let second = TestGate()
        harness.build.invoke = { _, _, _ in
            second.open()
            _ = await TestGate().waitUntilOpen(timeout: .seconds(10))
            try Task.checkCancellation()
            return .null
        }
        let closing = Task { try await harness.error("functions.invoke", [
            "instance": .string("own"), "function": .string("workspace.build")
        ]) }
        defer { closing.cancel() }
        #expect(await second.waitUntilOpen(), "The second function never started")
        harness.bridge.close()
        #expect(try await closing.value == "requestCancelled")
    }

    @Test func callCancelledWhileAwaitingConsentNeverStarts() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let confirmationRequested = TestGate()
        let confirm = TestGate()
        harness.host.confirmProcessStart = {
            confirmationRequested.open()
            return await confirm.waitUntilOpen()
        }
        let pending = Task { try await harness.error("functions.invoke", [
            "instance": .string("own"), "function": .string("workspace.build"), "call": .string("c1")
        ]) }
        defer { confirm.open(); pending.cancel() }
        #expect(await confirmationRequested.waitUntilOpen(), "The call never reached consent")

        // invoke -> cancel -> the user approves: the function must not start.
        #expect(try await harness.ok("functions.cancel", ["call": .string("c1")]) == .object([:]))
        confirm.open()
        #expect(try await pending.value == "requestCancelled")
        #expect(harness.build.invocations.isEmpty)
    }

    @Test func callsAwaitingConsentCountAgainstTheLimit() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let limit = PluginWebBridge.functionCallLimit
        let allAwaitConsent = TestGate()
        let confirm = TestGate()
        var awaiting = 0
        harness.host.confirmProcessStart = {
            awaiting += 1
            if awaiting == limit { allAwaitConsent.open() }
            return await confirm.waitUntilOpen()
        }
        let pending = (0..<limit).map { index in
            Task { try await harness.error("functions.invoke", [
                "instance": .string("own"), "function": .string("workspace.build"), "call": .string("call-\(index)")
            ]) }
        }
        defer { confirm.open(); pending.forEach { $0.cancel() } }
        #expect(await allAwaitConsent.waitUntilOpen(), "Not every call reached consent")

        // One more call is refused at once, before the user answers.
        #expect(try await harness.error("functions.invoke", [
            "instance": .string("own"), "function": .string("workspace.build"), "call": .string("extra")
        ]) == "plugin.build.unavailable")
        confirm.open()
        for call in pending { #expect(try await call.value == nil) }
        #expect(harness.build.invocations.count == limit)
    }

    @Test func aCallIDIsNeverAcceptedTwice() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let parameters: [String: ToolingJSONValue] = [
            "instance": .string("own"), "function": .string("workspace.build"), "call": .string("c1")
        ]

        #expect(try await harness.ok("functions.invoke", parameters) == .object(["value": .null]))
        #expect(try await harness.error("functions.invoke", parameters) == "plugin.web.invalidRequest")
        #expect(harness.build.invocations.count == 1)
    }

    @Test func decodedModelTaskCategoriesAndRunEntriesReachThePage() throws {
        let data = Data(#"""
        {"projects":[{"id":"app","path":"app","name":"app"}],"tasks":[
          {"id":"app:test","projectID":"app","name":"test","path":"app","template":"model-task",
           "group":"test","execution":"test","category":["verification","unit"]}
        ],"run":[{"id":"run-app","name":"app","provider":"fixture.run","command":"tool",
                  "args":["run"],"cwd":"app","env":{},"source":null,
                  "buildSystem":{"id":"fixture","root":"","projectID":"app","taskID":"app:test",
                                 "optionFingerprint":"o"}}]}
        """#.utf8)
        let model = try JSONDecoder().decode(BuildModel.self, from: data)
        let decoded = try JSONDecoder().decode([String: ToolingJSONValue].self, from: data)
        guard case .object(let object) = PluginWebBridge.json(model),
              case .array(let tasks)? = object["tasks"], case .object(let task)? = tasks.first else {
            Issue.record("The decoded model lost its tasks")
            return
        }
        #expect(task["category"] == .array([.string("verification"), .string("unit")]))
        #expect(object["run"] == decoded["run"])
        #expect(BuildModel(projects: []).run.isEmpty)
    }

    @Test func processRequestsAskFirstAndRebuildTheSelectionFromTheModel() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }

        harness.host.allowsProcesses = false
        #expect(try await harness.error("build.runTask", [
            "instance": .string("own"), "task": .string("build"), "project": .object(["name": .string("app")])
        ]) == "plugin.web.forbidden")
        #expect(harness.build.tasks.isEmpty)

        harness.host.allowsProcesses = true
        #expect(try await harness.error("build.runTask", [
            "instance": .string("own"), "task": .string("build"), "userArguments": .array([.string("--evil")])
        ]) == "plugin.build.invalidSelection")
        #expect(try await harness.error("build.runTask", [
            "instance": .string("own"), "task": .string("build"), "project": .object(["name": .string("missing")])
        ]) == "plugin.build.invalidSelection")
        let started = try await harness.ok("build.runTask", [
            "instance": .string("own"), "task": .string("build"),
            "project": .object(["name": .string("app"), "properties": .object(["injected": .string("x")])])
        ])
        #expect(harness.build.tasks.count == 1)
        #expect(harness.build.tasks.first?.project == BuildSelection(name: "app", path: "app"))
        #expect(harness.host.consents.count == 2)
        #expect(harness.host.outputShown == 1)
        guard case .object(let result) = started, case .string(let run)? = result["run"] else {
            Issue.record("Unexpected run \(started)")
            return
        }
        #expect(try await harness.ok("build.cancel", ["run": .string(run)]) == .object([:]))
        #expect(harness.build.stopCount == 1)
    }

    @Test func rejectedStartCannotClaimOrCancelAnotherHostsRun() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let otherRun = UUID()
        harness.build.acceptsRuns = false
        #expect(try await harness.error("build.runTask", ["instance": .string("own"), "task": .string("build")])
            == "plugin.build.unavailable")
        harness.build.currentRunID = otherRun
        #expect(try await harness.error("build.cancel", ["run": .string(otherRun.uuidString.lowercased())])
            == "plugin.web.invalidRequest")
        #expect(harness.build.stopCount == 0)
        #expect(harness.host.outputShown == 0)
    }

    @Test(arguments: ["build.runTask", "build.runTests"])
    func busyBuildIsNotReplacedOrItsOutputCleared(method: String) async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let otherRun = UUID()
        harness.build.currentRunID = otherRun
        harness.build.output = "Native build output\n"

        #expect(try await harness.error(method, BridgeHarness.runParameters(method)) == "plugin.build.unavailable")
        #expect(harness.build.currentRunID == otherRun)
        #expect(harness.build.tasks.isEmpty)
        #expect(harness.build.tests.isEmpty)
        #expect(harness.build.stopCount == 0)
        #expect(harness.build.outputClearCount == 0)
        #expect(harness.build.output == "Native build output\n")
        #expect(harness.host.outputShown == 0)
        #expect(try await harness.error("build.cancel", ["run": .string(otherRun.uuidString.lowercased())])
            == "plugin.web.invalidRequest")
        #expect(harness.build.stopCount == 0)
    }

    @Test(arguments: ["build.runTask", "build.runTests"])
    func runStartedWhileAwaitingConsentIsNotReplaced(method: String) async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let confirmationRequested = TestGate()
        let confirm = TestGate()
        harness.host.confirmProcessStart = {
            confirmationRequested.open()
            return await confirm.waitUntilOpen()
        }
        let pending = Task { try await harness.error(method, BridgeHarness.runParameters(method)) }
        defer { confirm.open(); pending.cancel() }
        #expect(await confirmationRequested.waitUntilOpen(), "The request never reached process confirmation")

        // A native control or another page starts a run while this page's
        // confirmation is suspended. Only then does the user allow this request.
        let otherRun = UUID()
        harness.build.currentRunID = otherRun
        harness.build.output = "Another page's build output\n"
        confirm.open()
        #expect(try await pending.value == "plugin.build.unavailable")
        #expect(harness.host.consents.count == 1)
        #expect(harness.build.currentRunID == otherRun)
        #expect(harness.build.tasks.isEmpty)
        #expect(harness.build.tests.isEmpty)
        #expect(harness.build.stopCount == 0)
        #expect(harness.build.outputClearCount == 0)
        #expect(harness.build.output == "Another page's build output\n")
        #expect(harness.host.outputShown == 0)
        #expect(try await harness.error("build.cancel", ["run": .string(otherRun.uuidString.lowercased())])
            == "plugin.web.invalidRequest")
        #expect(harness.build.stopCount == 0)
    }

    @Test(arguments: ["build.runTask", "build.runTests"], ["application", "example"])
    func sameNameTargetsAreSelectedByTheirModelTags(method: String, kind: String) async throws {
        let model = try BridgeHarness.sameNameTargets()
        let harness = try BridgeHarness(model: model)
        defer { harness.cleanUp() }
        let selected = try #require(model.targets.first { $0.tags.contains(kind) })
        let project = try #require(model.projects.first { $0.id == selected.projectID })
        var params = BridgeHarness.runParameters(method)
        params["project"] = .object(["name": .string(project.name), "path": .string(project.path)])
        params["target"] = .object([
            "name": .string("demo"), "path": .string("app"),
            "tags": .array(selected.tags.reversed().map(ToolingJSONValue.string)),
            "execution": .string("service"), "properties": .object(["source": .string("injected")])
        ])

        _ = try await harness.ok(method, params)
        let requestTarget = method == "build.runTask" ? harness.build.tasks.first?.target : harness.build.tests.first?.target
        let requestProject = method == "build.runTask" ? harness.build.tasks.first?.project : harness.build.tests.first?.project
        #expect(requestProject == BuildSelection(project: project))
        #expect(requestTarget == BuildSelection(target: selected))
        #expect(requestTarget?.properties == ["source": kind])
        #expect(requestTarget?.execution == nil)
        #expect(harness.host.outputShown == 1)
    }

    @Test func cargoExampleSelectionReachesTheRealCorePlan() async throws {
        let manifest = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/cargo-build.plugin.json"))
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: manifest)
        let source = BuildSystemPluginSource(
            pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: DeclarativePluginTestSupport.repositoryRoot, buildSystems: descriptor.buildSystems
        )
        let harness = try BridgeHarness(source: source)
        defer { harness.cleanUp() }
        try Data("""
        [package]
        name = "demo"
        version = "0.1.0"
        [[example]]
        name = "demo"
        """.utf8).write(to: harness.workspace.appendingPathComponent("Cargo.toml"))
        try FileManager.default.createDirectory(at: harness.workspace.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("fn main() {}\n".utf8).write(to: harness.workspace.appendingPathComponent("src/main.rs"))
        let planner = RustBuildSystemOperations(core: RustCoreBridge())
        let detection = try planner.detect(workspaceURL: harness.workspace, sources: [source], options: [:])
        let instance = try #require(detection.instances.first)
        let model = try #require(instance.model)
        let example = try #require(model.targets.first { $0.name == "demo" && $0.tags == ["example"] })
        let project = try #require(model.projects.first { $0.id == example.projectID })
        #expect(model.targets.contains { $0.name == "demo" && $0.path == example.path && $0.tags == ["application"] })
        let declaration = try #require(source.buildSystems.first)
        harness.build.entries = [BuildSystemEntry(
            instance: instance, declaration: declaration, source: source, model: model, modelState: .loaded
        )]

        // Core's target scope requires the owning project, just as the native
        // target controls submit it; tags then distinguish the two demo targets.
        _ = try await harness.ok("build.runTask", [
            "instance": .string(instance.id), "task": .string("example"),
            "project": .object(["name": .string(project.name), "path": .string(project.path)]),
            "target": .object(["name": .string("demo"), "path": .string(example.path), "tags": .array([.string("example")])])
        ])
        let request = try #require(harness.build.tasks.first)
        let plan = try planner.taskPlan(
            BuildSystemTarget(manifest: source.manifest, buildSystemID: instance.buildSystemID),
            context: BuildPlanContext(root: instance.root, options: [:]), request: request
        )
        #expect(request.project == BuildSelection(project: project))
        #expect(request.target == BuildSelection(target: example))
        #expect(plan.arguments == ["run", "--example", "demo"])
        #expect(plan.workingDirectory == instance.root)
        #expect(plan.execution == .application)
    }

    @Test(arguments: ["build.runTask", "build.runTests"])
    func ambiguousOrUnknownTargetTagsDoNotStartARun(method: String) async throws {
        let harness = try BridgeHarness(model: BridgeHarness.sameNameTargets())
        defer { harness.cleanUp() }
        var params = BridgeHarness.runParameters(method)
        let target: [String: ToolingJSONValue] = ["name": .string("demo"), "path": .string("app")]
        params["target"] = .object(target)
        #expect(try await harness.error(method, params) == "plugin.build.invalidSelection")
        let invalidTags: [[String]] = [[], ["missing"], ["example"], ["example", "runnable", "forged"]]
        for tags in invalidTags {
            params["target"] = .object(target.merging(["tags": .array(tags.map(ToolingJSONValue.string))]) { _, new in new })
            #expect(try await harness.error(method, params) == "plugin.build.invalidSelection")
        }
        #expect(harness.build.tasks.isEmpty)
        #expect(harness.build.tests.isEmpty)
        #expect(harness.host.consents.isEmpty)
    }

    @Test(arguments: ["build.runTask", "build.runTests"])
    func malformedTargetTagsAreRefused(method: String) async throws {
        let harness = try BridgeHarness(model: BridgeHarness.sameNameTargets())
        defer { harness.cleanUp() }
        let malformed: [ToolingJSONValue] = [
            .string("example"), .array([.integer(1)]), .array([.string("")]), .array([.string("example\n")]),
            .array([.string(String(repeating: "x", count: 65))]), .array(Array(repeating: .string("example"), count: 65))
        ]
        for tags in malformed {
            var params = BridgeHarness.runParameters(method)
            params["target"] = .object(["name": .string("demo"), "path": .string("app"), "tags": tags])
            #expect(try await harness.error(method, params) == "plugin.web.invalidRequest")
        }
        #expect(harness.build.tasks.isEmpty)
        #expect(harness.build.tests.isEmpty)
        #expect(harness.host.consents.isEmpty)
    }

    @Test func workspaceChangeDuringActivationCannotStartOrReturnBuildWork() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        harness.host.onAccess = {
            harness.host.pluginWebWorkspaceURL = harness.outside.deletingLastPathComponent()
        }
        #expect(try await harness.error("build.refresh", ["instance": .string("own")]) == "plugin.web.forbidden")
        #expect(harness.build.modelLoads.isEmpty)
        #expect(harness.host.consents.isEmpty)
    }

    @Test func closingPageReleasesDetectionWaitAndRefusesItsResult() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let entered = TestGate()
        let detecting = TestGate()
        harness.host.onAccess = { entered.open() }
        harness.build.isDetecting = true
        harness.build.onDetectionRead = { detecting.open() }
        let request = Task { try await harness.error("build.instances") }
        defer { request.cancel() }
        #expect(await entered.waitUntilOpen())
        #expect(await detecting.waitUntilOpen())
        harness.bridge.close()
        #expect(try await request.value == "plugin.web.forbidden")
    }

    @Test func stalledDetectionHasItsOwnDeadline() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        harness.build.isDetecting = true
        let bridge = PluginWebBridge(
            window: harness.window, host: harness.host, stateStore: MemoryPluginWebStateStore(), requestTimeout: .zero
        )
        defer { bridge.close() }
        do {
            _ = try await bridge.handle(method: "build.instances", params: .null)
            Issue.record("A stalled detection returned success")
        } catch let error as PluginWebBridgeFailure {
            #expect(error.code == "plugin.build.unavailable")
        }
    }

    @Test func stateIsKeptByTheHostWithinItsLimit() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }

        #expect(try await harness.ok("ui.getState") == .object(["state": .null]))
        let state: ToolingJSONValue = .object(["tab": .string("tasks")])
        #expect(try await harness.ok("ui.setState", ["state": state]) == .object([:]))
        #expect(try await harness.ok("ui.getState") == .object(["state": state]))
        let large = ToolingJSONValue.string(String(repeating: "x", count: PluginWebBridge.stateLimit))
        #expect(try await harness.error("ui.setState", ["state": large]) == "plugin.web.invalidRequest")
        #expect(try await harness.ok("ui.getState") == .object(["state": state]))
        #expect(try await harness.ok("ui.setState", ["state": .null]) == .object([:]))
        #expect(try await harness.ok("ui.getState") == .object(["state": .null]))
    }

    @Test func workspaceClosureReleasesPagesWithoutDisablingTheirPlugins() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let pages = PluginWebPages(windows: [harness.window])
        defer { pages.closeAll() }
        let old = pages.page(for: harness.window.windowID) { _ in FakePage() }
        pages.closeAll()
        #expect(old?.isClosed == true)
        let reopened = pages.page(for: harness.window.windowID) { _ in FakePage() }
        #expect(reopened != nil)
        #expect(reopened !== old)
    }

    @Test func closingDedicatedProjectRevokesHiddenPageWhileSettingsRetainsItsModel() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let suite = "lithe-web-window-close-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        var containers: [MacServiceContainer] = []
        let pages = PluginWebPages(windows: [harness.window])
        let manager = ProjectSessionManager(settings: settings, modelFactory: {
            let container = MacServiceContainer(
                store: store, settings: settings, javaMavenOperations: NoProjectJavaOperations(),
                pluginWebPageLifecycle: PluginWebPageLifecycle()
            )
            containers.append(container)
            return AppModel(settings: settings, services: Self.services(container.services, pages: pages))
        })
        defer { containers.forEach { $0.moduleLifecycleCoordinator.stop() } }
        let shutdownStarted = TestGate(), releaseShutdown = TestGate()
        var pendingRequest: Task<String, Never>?
        var closingWindow: Task<Void, Never>?
        defer { releaseShutdown.open() }
        try await WorkbenchTestScope.withCleanup({
            releaseShutdown.open()
            pages.closeAll()
            pendingRequest?.cancel()
            _ = await pendingRequest?.value
            await closingWindow?.value
            await manager.stopAllSessions()
            if let model = manager.settingsModel { manager.releaseSettings(for: model.id) }
        }) { scope in
            // Give the primary session a workspace without starting project discovery.
            manager.activeModel.workspaceSessionCoordinator.beginWorkspace(at: harness.root.appendingPathComponent("primary"))
            manager.requestOpenProject(harness.workspace, from: manager.activeSessionID, placement: .newWindow)
            let model = manager.activeModel
            // Retain the real workspace URL, but isolate this lifecycle test from
            // discovery and finish the module teardown started by opening it.
            model.workspaceSessionCoordinator.stopSessionResources()
            model.workspaceSessionCoordinator.resetWorkspaceFeature()
            try await scope.run("initial workspace teardown") { await model.awaitModuleRuntimeShutdown() }
            manager.bindSettings(to: model.id)
            let host = RetainedProjectWebHost(model: model, detectingBuild: harness.build)
            harness.build.isDetecting = true
            let detecting = TestGate()
            harness.build.onDetectionRead = { detecting.open() }
            let page = try #require(pages.page(for: harness.window.windowID) { window in
                MacPluginWebPage(
                    window: window, host: host, stateStore: pages.stateStore,
                    theme: MacPluginWebTheme(colorTheme: .lithe, isDark: false, codeFontFamily: "Menlo", codeFontSize: 13)
                )
            })
            // Keep the page registered after hiding its tool window; no WebView
            // is needed to exercise the real page and bridge cleanup.
            let toolWindow = WorkbenchFeatureModel.ToolWindow(rawValue: harness.window.windowID)
            model.workbenchFeature.setVisibility(toolWindow, isVisible: true)
            model.workbenchFeature.setVisibility(toolWindow, isVisible: false)
            #expect(!model.workbenchFeature.isVisible(toolWindow))
            #expect(pages.openWindowIDs.contains(harness.window.windowID))
            let pending = Task { await page.bridge.handle(#"{"method":"build.instances"}"#) }
            pendingRequest = pending
            defer { pending.cancel() }
            try #require(await detecting.waitUntilOpen(), "The page never reached the detection wait")
            #expect(host.activationAttempts == 1)

            let shutdownModule = WebPageShutdownTestModule(started: shutdownStarted, release: releaseShutdown)
            try model.services.moduleRuntime.register(ModuleFactory(manifest: shutdownModule.manifest) { shutdownModule })
            try await scope.run("shutdown module activation") {
                _ = try await model.services.moduleRuntime.activate(shutdownModule.manifest.id)
            }
            let closing = Task { await manager.resetDedicatedWindowSession(windowID: model.id) }
            closingWindow = closing
            defer { closing.cancel(); releaseShutdown.open() }
            try #require(await shutdownStarted.waitUntilOpen(), "Project teardown never reached the shutdown gate")
            // Assert before module teardown finishes, with both the model and Settings alive.
            #expect(manager.settingsModel === model)
            #expect(model.workspaceURL == harness.workspace)
            #expect(page.isClosed)
            #expect(pages.openWindowIDs.isEmpty)
            try await scope.run("closed page detection reply") {
                let reply = await pending.value
                #expect(reply.contains("plugin.web.forbidden"))
            }
            host.detectingBuild = nil
            try await scope.run("closed page cannot reactivate execution") {
                let reply = await page.bridge.handle(#"{"method":"build.instances"}"#)
                #expect(reply.contains("plugin.web.forbidden"))
            }
            #expect(host.activationAttempts == 1)
            releaseShutdown.open()
            try await scope.run("dedicated project shutdown") { await closing.value }
            #expect(manager.sessions(in: .dedicated(model.id)).isEmpty)
            #expect(manager.settingsModel === model)
            #expect(page.isClosed)
            #expect(model.executionCapability == nil)
            try await scope.run("retained closed model cannot reactivate execution") {
                let reply = await page.bridge.handle(#"{"method":"build.instances"}"#)
                #expect(reply.contains("plugin.web.forbidden"))
            }
            #expect(host.activationAttempts == 1)
            #expect(model.executionCapability == nil)
        }
    }

    /// Reuses platform dependencies but gives this session its isolated page registry.
    private static func services(_ base: AppServices, pages: PluginWebPages) -> AppServices {
        AppServices(
            moduleRuntime: base.moduleRuntime, pluginManager: base.pluginManager,
            pluginMarketplace: base.pluginMarketplace, pluginCatalog: base.pluginCatalog,
            pluginUIIconResources: base.pluginUIIconResources, pluginWebPages: pages,
            languageProviderCatalogSource: base.languageProviderCatalogSource,
            workspaceLanguageServerPreferences: base.workspaceLanguageServerPreferences,
            languageProviderCatalogSnapshot: base.languageProviderCatalogSnapshot,
            debugLaunchConfigurationResolver: base.debugLaunchConfigurationResolver,
            debugPortAvailabilityChecker: base.debugPortAvailabilityChecker,
            javaTestResultServerFactory: { MacJavaTestResultServer() },
            workspaceOperations: base.workspaceOperations, documentLifecycleDecider: base.documentLifecycleDecider,
            lineEditing: base.lineEditing, javaMavenOperations: base.javaMavenOperations,
            markdownRenderer: base.markdownRenderer, markdownImageImporter: base.markdownImageImporter,
            store: base.store, fileStorage: base.fileStorage, fileOperations: base.fileOperations,
            agentEditRestorer: base.agentEditRestorer, binaryFileViewerRegistry: base.binaryFileViewerRegistry,
            projectRuntimeService: base.projectRuntimeService, gitWatchContextProvider: base.gitWatchContextProvider,
            githubService: base.githubService, secureStore: base.secureStore, databaseSecureStore: base.databaseSecureStore,
            diagnosticsExportService: base.diagnosticsExportService, credentialResolver: base.credentialResolver,
            aiConfigurationSources: base.aiConfigurationSources, recentProjectsStore: base.recentProjectsStore,
            recentProjectBranchReader: base.recentProjectBranchReader, workspaceSessionStore: base.workspaceSessionStore,
            directoryMarkStore: base.directoryMarkStore, workbenchLayoutStore: base.workbenchLayoutStore,
            workbenchBackgroundPlatform: base.workbenchBackgroundPlatform, directoryWatcherFactory: base.directoryWatcherFactory,
            platformUI: base.platformUI, shortcutDetectorFactory: base.shortcutDetectorFactory
        )
    }

    @Test func disablingPluginClosesPagesAndForgetsConsentInEveryProject() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let lifecycle = PluginWebPageLifecycle()
        var prompts = 0
        let first = PluginWebPages(windows: [harness.window]) { _ in prompts += 1; return true }
        let second = PluginWebPages(windows: [harness.window]) { _ in prompts += 1; return true }
        defer { first.closeAll(); second.closeAll() }
        lifecycle.register(first)
        lifecycle.register(second)
        let firstPage = first.page(for: harness.window.windowID) { _ in FakePage() }
        // A detached (hidden) page remains in its project registry.
        let hiddenPage = second.page(for: harness.window.windowID) { _ in FakePage() }
        let consent = PluginWebProcessConsent(
            pluginID: harness.window.pluginID, pluginName: "Fixture", workspaceURL: harness.workspace,
            action: "Build", userArguments: []
        )
        #expect(await first.confirmProcessStart(consent))
        #expect(await second.confirmProcessStart(consent))
        #expect(prompts == 2)

        lifecycle.disable(harness.window.pluginID)
        #expect(firstPage?.isClosed == true)
        #expect(hiddenPage?.isClosed == true)
        #expect(first.openWindowIDs.isEmpty)
        #expect(second.openWindowIDs.isEmpty)
        #expect(first.page(for: harness.window.windowID) { _ in FakePage() } == nil)
        #expect(second.page(for: harness.window.windowID) { _ in FakePage() } == nil)
        #expect(await second.confirmProcessStart(consent) == false)

        let later = PluginWebPages(windows: [harness.window])
        defer { later.closeAll() }
        lifecycle.register(later)
        later.closeAll()
        #expect(later.page(for: harness.window.windowID) { _ in FakePage() } == nil)
        lifecycle.enable(harness.window.pluginID)
        #expect(first.page(for: harness.window.windowID) { _ in FakePage() } !== firstPage)
        #expect(second.page(for: harness.window.windowID) { _ in FakePage() } !== hiddenPage)
        #expect(later.page(for: harness.window.windowID) { _ in FakePage() } != nil)
        #expect(await first.confirmProcessStart(consent))
        #expect(await second.confirmProcessStart(consent))
        #expect(prompts == 4)
    }

    @Test func replacingPackageBlocksEveryProjectUntilProcessRestart() throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let lifecycle = PluginWebPageLifecycle()
        let first = PluginWebPages(windows: [harness.window])
        let second = PluginWebPages(windows: [harness.window])
        defer { first.closeAll(); second.closeAll() }
        lifecycle.register(first)
        lifecycle.register(second)
        let firstPage = first.page(for: harness.window.windowID) { _ in FakePage() }
        let secondPage = second.page(for: harness.window.windowID) { _ in FakePage() }
        lifecycle.packageWillChange(harness.window.pluginID)
        #expect(firstPage?.isClosed == true)
        #expect(secondPage?.isClosed == true)

        let later = PluginWebPages(windows: [harness.window])
        defer { later.closeAll() }
        lifecycle.register(later)
        // A stale manager in another project may still think live enablement is valid.
        lifecycle.disable(harness.window.pluginID)
        lifecycle.enable(harness.window.pluginID)
        for pages in [first, second, later] {
            pages.closeAll()
            #expect(pages.page(for: harness.window.windowID) { _ in FakePage() } == nil)
        }
    }

    @Test func lifecycleRegistrationDoesNotRetainClosedProjectWindows() throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }
        let lifecycle = PluginWebPageLifecycle()
        var pages: PluginWebPages? = PluginWebPages(windows: [harness.window])
        weak var released = pages
        lifecycle.register(try #require(pages))
        pages?.closeAll()
        pages = nil
        #expect(released == nil)
        lifecycle.disable(harness.window.pluginID)
        lifecycle.enable(harness.window.pluginID)
    }

    @Test func closedPageIsForbiddenAndRegistryForgetsConsent() async throws {
        let harness = try BridgeHarness()
        defer { harness.cleanUp() }

        var prompts = 0
        let pages = PluginWebPages(windows: [harness.window]) { _ in prompts += 1; return true }
        let page = pages.page(for: harness.window.windowID) { _ in FakePage() }
        #expect(page != nil)
        #expect(pages.page(for: harness.window.windowID) { _ in FakePage() } === page)
        #expect(pages.page(for: "unknown") { _ in FakePage() } == nil)

        let consent = PluginWebProcessConsent(
            pluginID: harness.window.pluginID, pluginName: "Fixture", workspaceURL: harness.workspace,
            action: "Build", userArguments: []
        )
        #expect(await pages.confirmProcessStart(consent))
        #expect(await pages.confirmProcessStart(consent))
        #expect(prompts == 1)

        pages.closePages(of: [harness.window.pluginID])
        #expect(page?.isClosed == true)
        #expect(pages.openWindowIDs.isEmpty)
        #expect(pages.page(for: harness.window.windowID) { _ in FakePage() } == nil)
        #expect(await pages.confirmProcessStart(consent) == false)
        pages.closeAll()
        #expect(pages.page(for: harness.window.windowID) { _ in FakePage() } == nil)
        #expect(await pages.confirmProcessStart(consent) == false)
        pages.allowPages(of: harness.window.pluginID)
        #expect(pages.page(for: harness.window.windowID) { _ in FakePage() } !== page)
        defer { pages.closeAll() }
        #expect(await pages.confirmProcessStart(consent))
        #expect(prompts == 2)

        harness.bridge.close()
        #expect(try await harness.error("ui.getState") == "plugin.web.forbidden")
    }
}

@MainActor
@Suite("Plugin web content", .serialized)
struct PluginWebContentTests {
    @Test func servesOnlyRegularFilesInsideThePackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-web-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("ui"), withIntermediateDirectories: true)
        try Data("<p>ok</p>".utf8).write(to: package.appendingPathComponent("ui/index.html"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("ui/link.txt"), withDestinationURL: root.appendingPathComponent("secret.txt")
        )
        let pluginID = "dev.example.web"
        let policy = MacPluginWebContent.contentSecurityPolicy(pluginID: pluginID)
        func status(_ url: String, method: String = "GET") -> Int {
            MacPluginWebSchemeHandler.response(
                for: URL(string: url)!, method: method, pluginID: pluginID, packageURL: package, policy: policy
            ).head.statusCode
        }

        let served = MacPluginWebSchemeHandler.response(
            for: URL(string: "lithe-plugin://dev.example.web/ui/index.html")!, method: "GET",
            pluginID: pluginID, packageURL: package, policy: policy
        )
        #expect(served.head.statusCode == 200)
        #expect(served.body == Data("<p>ok</p>".utf8))
        #expect(served.head.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
        let csp = served.head.value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
        #expect(csp.contains("default-src 'none'"))
        #expect(!csp.contains("unsafe-eval"))
        #expect(!csp.contains("script-src 'self' lithe-plugin://dev.example.web 'unsafe-inline'"))

        #expect(status("lithe-plugin://dev.example.web/ui/%2e%2e/%2e%2e/secret.txt") == 403)
        #expect(status("lithe-plugin://dev.example.web/ui%2F..%2F..%2Fsecret.txt") == 403)
        #expect(status("lithe-plugin://dev.example.web/ui/link.txt") == 403)
        #expect(status("lithe-plugin://dev.example.web/ui/") == 403)
        #expect(status("lithe-plugin://dev.example.web/ui/missing.html") == 404)
        #expect(status("lithe-plugin://dev.example.other/ui/index.html") == 403)
        #expect(status("lithe-plugin://dev.example.web/ui/index.html", method: "POST") == 405)
    }
}

@MainActor
@Suite("Plugin web packages", .serialized)
struct PluginWebPackageTests {
    @Test func webStateStaysInItsOwningWindowAndWorkspaceOutsideThePackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-web-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = MacPluginStateDirectories(rootURL: root.appendingPathComponent("support/PluginState"))
        let store = MacPluginWebStateStore(directories: directories, fileStorage: MacFileStorage())
        let workspace = root.appendingPathComponent("workspace")
        let value = Data(#"{"tab":"tasks"}"#.utf8)
        try store.setState(value, pluginID: "dev.example.web", windowID: "dev.example.web.window", workspaceURL: workspace)
        #expect(store.state(pluginID: "dev.example.web", windowID: "dev.example.web.window", workspaceURL: workspace) == value)
        #expect(store.state(pluginID: "dev.example.web", windowID: "dev.example.web.other", workspaceURL: workspace) == nil)
        #expect(store.state(pluginID: "dev.example.web", windowID: "dev.example.web.window",
                            workspaceURL: root.appendingPathComponent("other")) == nil)
        #expect(throws: (any Error).self) {
            try store.setState(value, pluginID: "../escape", windowID: "window", workspaceURL: workspace)
        }
        #expect(throws: (any Error).self) {
            try store.setState(Data(repeating: 1, count: PluginWebBridge.stateLimit + 1),
                               pluginID: "dev.example.web", windowID: "window", workspaceURL: workspace)
        }
        try store.setState(nil, pluginID: "dev.example.web", windowID: "dev.example.web.window", workspaceURL: workspace)
        #expect(store.state(pluginID: "dev.example.web", windowID: "dev.example.web.window", workspaceURL: workspace) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("package").path))
    }

    @Test func webPanelFixtureInstallsWithItsEntryAndIsRefusedWithoutIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-web-package-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("ui"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/web-panel.plugin.json"))
            .write(to: package.appendingPathComponent("plugin.json"))
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16"/></svg>"#.utf8)
            .write(to: package.appendingPathComponent("icons/panel.svg"))
        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed"), validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(allowsLocalDevelopmentPackages: true)
        )
        #expect(throws: (any Error).self) { try store.installPackage(from: package, origin: .localDevelopment) }

        try Data("<!doctype html><title>Panel</title>".utf8).write(to: package.appendingPathComponent("ui/index.html"))
        let installed = try store.installPackage(from: package, origin: .localDevelopment)
        let contributions = installed.manifest.modules.flatMap(\.contributions)
        #expect(contributions.first { $0.id == "dev.lithe.fixture.web-panel.window" }?.webEntry == "ui/index.html")
        #expect(contributions.first { $0.id == "dev.lithe.fixture.web-panel.notes" }?.hasDeclarativeContent == true)
        let windows = MacPluginWebContent.windows([installed])
        #expect(windows.map(\.windowID) == ["dev.lithe.fixture.web-panel.window"])
        #expect(windows.first?.isInspectable == true)
    }
}

// MARK: Test doubles

/// Keeps the real workspace identity; after detection, a missed close would
/// reach the real execution activation instead of being hidden by the fake.
@MainActor
private final class RetainedProjectWebHost: PluginWebBridgeHost {
    private let model: AppModel
    var detectingBuild: FakeBuildAccess?
    private(set) var activationAttempts = 0

    init(model: AppModel, detectingBuild: FakeBuildAccess) {
        self.model = model
        self.detectingBuild = detectingBuild
    }

    var pluginWebWorkspaceURL: URL? { model.pluginWebWorkspaceURL }
    func pluginWebBuildSystems(activate: Bool) async -> (any PluginWebBuildAccess)? {
        if activate { activationAttempts += 1 }
        if let detectingBuild { return detectingBuild }
        return await model.pluginWebBuildSystems(activate: activate)
    }
    func pluginWebShowBuildOutput() { model.pluginWebShowBuildOutput() }
    func pluginWebOpenFile(_ url: URL, line: Int?, column: Int?) -> Bool {
        model.pluginWebOpenFile(url, line: line, column: column)
    }
    func pluginWebConfirmProcessStart(_ consent: PluginWebProcessConsent) async -> Bool {
        await model.pluginWebConfirmProcessStart(consent)
    }
}

/// Suspends the real manager's teardown so revocation is checked before shutdown ends.
@MainActor
private final class WebPageShutdownTestModule: LitheModule {
    let manifest = ModuleManifest(
        id: ModuleID("dev.lithe.tests.web-window-shutdown"), displayName: "Web Window Shutdown Test",
        scope: .application, defaultState: .enabled, activationPolicy: .onDemand
    )
    private let started: TestGate
    private let release: TestGate

    init(started: TestGate, release: TestGate) { self.started = started; self.release = release }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {
        started.open()
        #expect(await release.waitUntilOpen(), "The test did not release project shutdown")
    }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

@MainActor
private final class FakePage: PluginWebPageHandle {
    private(set) var isClosed = false
    func close() { isClosed = true }
}

@MainActor
private final class FakeHost: PluginWebBridgeHost {
    var pluginWebWorkspaceURL: URL?
    let build: FakeBuildAccess
    var allowsProcesses = true
    var consents: [PluginWebProcessConsent] = []
    var opened: [URL] = []
    var outputShown = 0
    var onAccess: (() -> Void)?
    var confirmProcessStart: (@MainActor () async -> Bool)?

    init(workspaceURL: URL, build: FakeBuildAccess) {
        pluginWebWorkspaceURL = workspaceURL
        self.build = build
    }

    func pluginWebBuildSystems(activate: Bool) async -> (any PluginWebBuildAccess)? { onAccess?(); return build }
    func pluginWebShowBuildOutput() { outputShown += 1 }
    func pluginWebOpenFile(_ url: URL, line: Int?, column: Int?) -> Bool {
        opened.append(url)
        return FileManager.default.fileExists(atPath: url.path)
    }
    func pluginWebConfirmProcessStart(_ consent: PluginWebProcessConsent) async -> Bool {
        consents.append(consent)
        if let confirmProcessStart { return await confirmProcessStart() }
        return allowsProcesses
    }
}

@MainActor
private final class FakeBuildAccess: PluginWebBuildAccess {
    var entries: [BuildSystemEntry]
    private var detecting = false
    var isDetecting: Bool {
        get { onDetectionRead?(); return detecting }
        set { changeSubject.send(); detecting = newValue }
    }
    var onDetectionRead: (() -> Void)?
    var currentRunID: UUID?
    var modelLoads: [String] = []
    var tasks: [BuildTaskRequest] = []
    var tests: [BuildTestRequest] = []
    var stopCount = 0
    var output = ""
    private(set) var outputClearCount = 0
    private let changeSubject = PassthroughSubject<Void, Never>()
    private let endSubject = PassthroughSubject<BuildRunEnd, Never>()

    init(entries: [BuildSystemEntry]) { self.entries = entries }

    var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }
    var runEnded: AnyPublisher<BuildRunEnd, Never> { endSubject.eraseToAnyPublisher() }
    func loadModel(_ entryID: String) { modelLoads.append(entryID) }
    var acceptsRuns = true
    func runTask(_ entryID: String, request: BuildTaskRequest, title: String) -> UUID? {
        guard acceptsRuns else { return nil }
        tasks.append(request)
        return startRun()
    }
    func runTests(_ entryID: String, request: BuildTestRequest, title: String) -> UUID? {
        guard acceptsRuns else { return nil }
        tests.append(request)
        return startRun()
    }
    /// Match BuildSystemService's replacement semantics so a missed bridge
    /// busy check observably cancels the existing run and clears its output.
    private func startRun() -> UUID {
        if currentRunID != nil { stopRun() }
        outputClearCount += 1
        output = ""
        let id = UUID()
        currentRunID = id
        return id
    }
    func loadDependencies(_ entryID: String, project: BuildModel.Project?) {}
    func setOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) {}

    var functionListings = 0
    var invocations: [(entryID: String, functionID: String)] = []
    var invoke: (@MainActor (String, ToolingJSONValue, @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void) async throws
        -> ToolingJSONValue)?
    func pluginFunctions(_ entryID: String) async throws -> [String] {
        functionListings += 1
        return ["snapshot.read", "workspace.build"]
    }
    func invokePluginFunction(
        _ entryID: String, functionID: String, params: ToolingJSONValue, timeout: Duration,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        invocations.append((entryID, functionID))
        return try await invoke?(functionID, params, progress) ?? .null
    }

    func stopRun() {
        stopCount += 1
        if let currentRunID, let entryID = entries.first?.id {
            endSubject.send(BuildRunEnd(runID: currentRunID, entryID: entryID, state: .cancelled, exitCode: nil))
        }
        currentRunID = nil
    }
}

@MainActor
private final class BridgeHarness {
    let root: URL
    let workspace: URL
    let outside: URL
    let window: PluginWebWindow
    let build: FakeBuildAccess
    let host: FakeHost
    let bridge: PluginWebBridge

    init(model: BuildModel? = nil, source: BuildSystemPluginSource? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-bridge-\(UUID().uuidString)")
        // The directory does not exist yet, so Foundation cannot infer its URL
        // directory hint. Keep the fixture equal to the opened workspace URL.
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        outside = root.appendingPathComponent("outside/secret.txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("link"), withDestinationURL: outside.deletingLastPathComponent()
        )
        window = PluginWebWindow(
            pluginID: source?.pluginID ?? "dev.example.web", pluginName: "Fixture", windowID: "dev.example.web.window",
            entry: "ui/index.html", packageURL: root,
            buildSystemIDs: source.map { Set($0.buildSystems.map(\.id)) } ?? ["fixture"], isInspectable: false
        )
        build = FakeBuildAccess(entries: [
            Self.entry(id: "own", pluginID: "dev.example.web", model: model),
            Self.entry(id: "foreign", pluginID: "dev.example.other")
        ])
        host = FakeHost(workspaceURL: workspace, build: build)
        bridge = PluginWebBridge(window: window, host: host, stateStore: MemoryPluginWebStateStore())
    }

    func cleanUp() {
        bridge.close()
        try? FileManager.default.removeItem(at: root)
    }

    func ok(_ method: String, _ params: [String: ToolingJSONValue] = [:]) async throws -> ToolingJSONValue {
        let reply = try await send(method, params)
        guard let value = reply["ok"] else {
            Issue.record("\(method) failed: \(reply)")
            return .null
        }
        return value
    }

    func error(_ method: String, _ params: [String: ToolingJSONValue] = [:]) async throws -> String? {
        let reply = try await send(method, params)
        guard case .object(let error)? = reply["error"], case .string(let code)? = error["code"] else { return nil }
        return code
    }

    /// The whole error object of a refused request.
    func failure(_ method: String, _ params: [String: ToolingJSONValue] = [:]) async throws -> ToolingJSONValue? {
        try await send(method, params)["error"]
    }

    func errorCode(_ message: String) async throws -> String? {
        let reply = try JSONDecoder().decode([String: ToolingJSONValue].self, from: Data(await bridge.handle(message).utf8))
        guard case .object(let error)? = reply["error"], case .string(let code)? = error["code"] else { return nil }
        return code
    }

    private func send(_ method: String, _ params: [String: ToolingJSONValue]) async throws -> [String: ToolingJSONValue] {
        let message = String(decoding: try JSONEncoder().encode(
            ToolingJSONValue.object(["method": .string(method), "params": .object(params)])
        ), as: UTF8.self)
        return try JSONDecoder().decode([String: ToolingJSONValue].self, from: Data(await bridge.handle(message).utf8))
    }

    static func runParameters(_ method: String) -> [String: ToolingJSONValue] {
        var params: [String: ToolingJSONValue] = ["instance": .string("own")]
        if method == "build.runTask" { params["task"] = .string("build") }
        return params
    }

    /// Cargo permits an application and an example called `demo` in the same
    /// project directory. Tags distinguish them; properties still come from the model.
    static func sameNameTargets() throws -> BuildModel {
        try JSONDecoder().decode(BuildModel.self, from: Data(#"""
        {"projects":[{"id":"app","path":"app","name":"app"}],"targets":[
          {"id":"app:application:demo","projectID":"app","name":"demo","path":"app",
           "tags":["application","runnable"],"properties":{"source":"application"}},
          {"id":"app:example:demo","projectID":"app","name":"demo","path":"app",
           "tags":["example","runnable"],"properties":{"source":"example"}}
        ]}
        """#.utf8))
    }

    private static func entry(id: String, pluginID: String, model: BuildModel? = nil) -> BuildSystemEntry {
        let declaration = DeclarativeBuildSystem(
            id: "fixture", displayName: "Fixture", modelSource: .static,
            tasks: [DeclarativeBuildSystem.Task(
                id: "build", displayName: "Build", group: .build, scopes: [.workspace, .project, .target],
                fromModel: false, targetTags: [], requiresUserArguments: false, description: nil
            )],
            testScopes: [.workspace, .project, .target], dependencyScopes: []
        )
        let model = model ?? BuildModel(projects: [BuildModel.Project(id: "app", path: "app", name: "app")])
        return BuildSystemEntry(
            instance: BuildSystemInstance(
                id: id, pluginID: pluginID, buildSystemID: "fixture", displayName: "Fixture", root: "",
                markers: [], modelSource: .static, optionFingerprint: "o", model: model, modelError: nil
            ),
            declaration: declaration,
            source: BuildSystemPluginSource(
                pluginID: pluginID, manifest: Data("{}".utf8), packageURL: URL(fileURLWithPath: "/plugins/\(pluginID)"),
                buildSystems: [declaration]
            ),
            model: model,
            modelState: .loaded
        )
    }
}

/// Loads a real page through the package scheme and the injected bridge. The
/// page reports what it observed through `ui.setState`, which opens a gate.
@MainActor
@Suite("Plugin web page", .serialized)
struct PluginWebPageTests {
    @Test func pageRunsOnlyPackagedScriptsAndTalksThroughTheBridge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-web-page-\(UUID().uuidString)")
        let ui = root.appendingPathComponent("ui")
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        <!doctype html><html><head><meta charset="utf-8"><script src="app.js"></script></head>
        <body><script>window.inlineRan = true;</script></body></html>
        """.utf8).write(to: ui.appendingPathComponent("index.html"))
        try Data(#"""
        window.addEventListener('DOMContentLoaded', async () => {
          const code = async (method, params) => {
            try { await lithe.request(method, params); return 'ok'; } catch (error) { return error.code; }
          };
          let fetched = 'blocked';
          try { await fetch('https://example.invalid/'); fetched = 'allowed'; } catch (error) {}
          let replaced = false;
          try { window.lithe = {}; replaced = window.lithe.version !== 1; } catch (error) {}
          lithe.on('ui.themeChanged', (event) => lithe.request('ui.setState', { state: { themeChanged: event.theme } }));
          await lithe.request('ui.setState', { state: {
            version: lithe.version,
            pluginID: lithe.context.pluginID,
            theme: document.documentElement.dataset.theme,
            background: document.documentElement.style.getPropertyValue('--lithe-background'),
            inlineRan: window.inlineRan === true,
            fetched, replaced,
            unknown: await code('build.deleteEverything'),
            invalid: await code('ui.getState', { extra: 1 }),
            outside: await code('workspace.openFile', { path: '../secret.txt' })
          } });
        });
        """#.utf8).write(to: ui.appendingPathComponent("app.js"))
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))

        let window = PluginWebWindow(
            pluginID: "dev.example.web", pluginName: "Fixture", windowID: "dev.example.web.window",
            entry: "ui/index.html", packageURL: root, buildSystemIDs: [], isInspectable: false
        )
        let baseline = try packageFiles(in: root)
        let store = ReportingStateStore()
        let host = FakeHost(workspaceURL: workspace, build: FakeBuildAccess(entries: []))
        let page = MacPluginWebPage(window: window, host: host, stateStore: store, theme: Self.theme(dark: false))
        defer { page.close() }

        let webView = try #require(page.webView)
        #expect(!webView.configuration.websiteDataStore.isPersistent)
        let report = try #require(await store.next(timeout: .seconds(10)), "The page never reported its state")
        #expect(report["version"] == .integer(1))
        #expect(report["pluginID"] == .string("dev.example.web"))
        #expect(report["theme"] == .string("light"))
        #expect(report["background"].map { $0 != .string("") } == true)
        #expect(report["inlineRan"] == .bool(false))
        #expect(report["fetched"] == .string("blocked"))
        #expect(report["replaced"] == .bool(false))
        #expect(report["unknown"] == .string("plugin.web.unknownMethod"))
        #expect(report["invalid"] == .string("plugin.web.invalidRequest"))
        #expect(report["outside"] == .string("plugin.web.forbidden"))
        #expect(host.opened.isEmpty)

        page.update(theme: Self.theme(dark: true))
        let changed = try #require(await store.next(timeout: .seconds(10)), "ui.themeChanged never reached the page")
        #expect(changed["themeChanged"] == .string("dark"))

        page.close()
        #expect(page.webView == nil)
        #expect(try packageFiles(in: root) == baseline)
    }

    /// Snapshot the read-only package input, including added/removed files.
    private func packageFiles(in root: URL) throws -> [String: Data] {
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var snapshot: [String: Data] = [:]
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                snapshot[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
            }
        }
        return snapshot
    }

    private static func theme(dark: Bool) -> MacPluginWebTheme {
        MacPluginWebTheme(colorTheme: .lithe, isDark: dark, codeFontFamily: "Menlo", codeFontSize: 13)
    }
}

/// Hands each state the page writes to the test, in order.
@MainActor
private final class ReportingStateStore: PluginWebStateStoring {
    private var reports: [[String: ToolingJSONValue]] = []
    private var gate = TestGate()

    func state(pluginID: String, windowID: String, workspaceURL: URL) -> Data? { nil }

    func setState(_ data: Data?, pluginID: String, windowID: String, workspaceURL: URL) throws {
        guard let data, case .object(let report)? = try? JSONDecoder().decode(ToolingJSONValue.self, from: data) else { return }
        reports.append(report)
        gate.open()
    }

    func next(timeout: Duration) async -> [String: ToolingJSONValue]? {
        if reports.isEmpty, await !gate.waitUntilOpen(timeout: timeout) { return nil }
        gate = TestGate()
        return reports.isEmpty ? nil : reports.removeFirst()
    }
}

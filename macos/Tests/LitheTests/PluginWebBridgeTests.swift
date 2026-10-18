import Combine
import Foundation
import Testing
import WebKit
import LitheCoreContracts
import LitheExecutionModule
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
        harness.build.currentRunID = otherRun
        harness.build.acceptsRuns = false
        #expect(try await harness.error("build.runTask", ["instance": .string("own"), "task": .string("build")])
            == "plugin.build.unavailable")
        #expect(try await harness.error("build.cancel", ["run": .string(otherRun.uuidString.lowercased())])
            == "plugin.web.invalidRequest")
        #expect(harness.build.stopCount == 0)
        #expect(harness.host.outputShown == 0)
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
    var stopCount = 0
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
        currentRunID = UUID()
        return currentRunID
    }
    func runTests(_ entryID: String, request: BuildTestRequest, title: String) -> UUID? {
        guard acceptsRuns else { return nil }
        currentRunID = UUID()
        return currentRunID
    }
    func loadDependencies(_ entryID: String, project: BuildModel.Project?) {}
    func setOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) {}
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

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-bridge-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        outside = root.appendingPathComponent("outside/secret.txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("link"), withDestinationURL: outside.deletingLastPathComponent()
        )
        window = PluginWebWindow(
            pluginID: "dev.example.web", pluginName: "Fixture", windowID: "dev.example.web.window",
            entry: "ui/index.html", packageURL: root, buildSystemIDs: ["fixture"], isInspectable: false
        )
        build = FakeBuildAccess(entries: [
            Self.entry(id: "own", pluginID: "dev.example.web"),
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

    private static func entry(id: String, pluginID: String) -> BuildSystemEntry {
        let declaration = DeclarativeBuildSystem(
            id: "fixture", displayName: "Fixture", modelSource: .static,
            tasks: [DeclarativeBuildSystem.Task(
                id: "build", displayName: "Build", group: .build, scopes: [.workspace, .project],
                fromModel: false, targetTags: [], requiresUserArguments: false, description: nil
            )],
            testScopes: [], dependencyScopes: []
        )
        let model = BuildModel(projects: [BuildModel.Project(id: "app", path: "app", name: "app")])
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

import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@MainActor
struct PluginTerminalHostServiceTests {
    @Test
    func createsDirectArgvPublishesExitAndIsolatesOwnership() async throws {
        let fixture = Fixture()
        defer { fixture.end() }
        let created = try await fixture.call("create", [
            "executable": .string("docker"), "arguments": .array([.string("exec"), .string("$(literal)")]),
            "environment": .object(["DOCKER_HOST": .string("unix:///fixture/docker.sock"), "DOCKER_CONTEXT": .null]),
        ]).get()
        let id = try terminalID(created)
        #expect(fixture.window.launch?.arguments == ["exec", "$(literal)"])
        #expect(fixture.window.launch?.environment.keys.contains("DOCKER_CONTEXT") == true)
        #expect(fixture.window.launch?.environment["DOCKER_CONTEXT"] == .some(nil))
        #expect(fixture.window.launch?.workingDirectory == PluginHostFixture.workspaceURL)
        _ = try await fixture.call("show", ["terminalID": .string(id)]).get()
        #expect(fixture.window.access.shown == 1)
        fixture.dispatcher.beginSession(pluginID: "other", hostServices: Array(fixture.service.methods))
        let foreign = await fixture.dispatcher.dispatch(fixture.request("show", ["terminalID": .string(id)]), pluginID: "other")
        #expect(code(foreign) == "plugin.host.notFound")
        _ = try await fixture.call("onExit", ["terminalID": .string(id)]).get()
        fixture.window.exit?(.init(code: 7, reason: "exited"))
        fixture.window.exit?(.init(code: 8, reason: "exited"))
        #expect(fixture.events.count == 1)
        guard case .object(let event) = fixture.events.first,
              case .object(let data)? = event["event"] else { Issue.record("exit missing"); return }
        #expect(data["exitCode"] == .integer(7))
        _ = try await fixture.call("close", ["terminalID": .string(id)]).get()
        #expect(fixture.window.access.closed)
    }

    @Test
    func rejectsUnknownOptionsBadLaunchAndRemoteBeforeCreatingAnything() async {
        let fixture = Fixture()
        defer { fixture.end() }
        for params: [String: ToolingJSONValue] in [
            ["executable": .string("docker"), "sendText": .string("bad")],
            ["executable": .string("./docker")],
            ["executable": .string("docker"), "environment": .object(["LITHE_PROCESS_SCOPE": .string("override")])],
            ["executable": .string("docker"), "cwd": .object(["rootID": .string("unknown"), "path": .string("")])],
        ] {
            #expect(code(await fixture.call("create", params)) != nil)
        }
        #expect(fixture.window.launch == nil)
        fixture.context = fixture.contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL,
            remote: (connectionID: "connection", remoteRoot: "/workspace"))
        #expect(code(await fixture.call("create", ["executable": .string("docker")])) == "plugin.host.authorityUnsupported")
        #expect(fixture.window.launch == nil)
    }

    @Test
    func contextCloseStopsOnlyOwnedTerminalAndPendingLaunchCannotSurviveReplacement() async throws {
        let fixture = Fixture()
        defer { fixture.end() }
        let started = TestGate(), release = TestGate(), finished = TestGate()
        fixture.window.duringLaunch = { started.open(); _ = await release.waitUntilOpen() }
        let pending = Task { @MainActor in
            defer { finished.open() }
            return await fixture.call("create", ["executable": .string("docker")])
        }
        defer { release.open(); pending.cancel() }
        try #require(await started.waitUntilOpen())
        fixture.contexts.close(owner: fixture.window)
        release.open()
        try #require(await finished.waitUntilOpen())
        #expect(code(await pending.value) != nil)
        #expect(fixture.window.access.closed)
        #expect(code(await fixture.call("show", ["terminalID": .string("unknown")])) == "plugin.host.contextExpired")
    }

    @Test
    func sessionEndClosesNativeAccessWithoutTouchingOtherPlugins() async throws {
        let fixture = Fixture()
        defer { fixture.end() }
        _ = try await fixture.call("create", ["executable": .string("docker")]).get()
        fixture.dispatcher.endSession(pluginID: "other")
        #expect(!fixture.window.access.closed)
        fixture.dispatcher.endSession(pluginID: "plugin")
        try #require(await fixture.window.access.didClose.waitUntilOpen())
        #expect(fixture.window.access.closed)
    }

    @Test
    func reopenRestoresOnlyTheChosenDisplaySuffixAndRejectsStaleExit() async throws {
        let fixture = Fixture()
        defer { fixture.end() }
        let created = try await fixture.call("create", ["executable": .string("example-client"), "retainedContextBytes": .integer(8)]).get()
        let id = try terminalID(created)
        let oldExit = fixture.window.exit
        fixture.window.access.history = "older\nrecent\n"
        _ = try await fixture.call("onExit", ["terminalID": .string(id)]).get()
        _ = try await fixture.call("close", ["terminalID": .string(id)]).get()
        #expect(code(await fixture.call("show", ["terminalID": .string(id)])) == "plugin.host.preconditionFailed")
        let reopened = try await fixture.call("reopen", ["terminalID": .string(id)]).get()
        #expect(fixture.window.launch?.displayHistory == "\nrecent\n")
        #expect(fixture.window.launch?.arguments == [])
        guard case .object(let result) = reopened else { Issue.record("reopen missing"); return }
        #expect(result["terminalID"] == .string(id))
        #expect(result["generation"] == .integer(2))
        oldExit?(.init(code: 9, reason: "exited"))
        #expect(fixture.events.count == 1)
        fixture.window.exit?(.init(code: 0, reason: "exited"))
        #expect(fixture.events.count == 2)
        _ = try await fixture.call("dispose", ["terminalID": .string(id)]).get()
        #expect(code(await fixture.call("reopen", ["terminalID": .string(id)])) == "plugin.host.notFound")
    }

    @Test
    func cancelledReopenDoesNotPublishAnExitOrConsumeTheNextGeneration() async throws {
        let fixture = Fixture()
        defer { fixture.end() }
        let id = try terminalID(await fixture.call("create", ["executable": .string("example-client")]).get())
        _ = try await fixture.call("onExit", ["terminalID": .string(id)]).get()
        _ = try await fixture.call("close", ["terminalID": .string(id)]).get()
        let entered = TestGate(), release = TestGate(), finished = TestGate()
        fixture.window.duringLaunch = { entered.open(); _ = await release.waitUntilOpen() }
        let reopen = Task { @MainActor in
            defer { finished.open() }
            return await fixture.call("reopen", ["terminalID": .string(id)])
        }
        defer { reopen.cancel(); release.open() }
        try #require(await entered.waitUntilOpen())
        reopen.cancel(); release.open()
        try #require(await finished.waitUntilOpen())
        #expect(code(await reopen.value) == "plugin.host.cancelled")
        #expect(fixture.events.count == 1)
        fixture.window.duringLaunch = nil
        let result = try await fixture.call("reopen", ["terminalID": .string(id)]).get()
        guard case .object(let object) = result else { Issue.record("reopen missing"); return }
        #expect(object["generation"] == .integer(2))
    }

    private func terminalID(_ value: ToolingJSONValue) throws -> String {
        guard case .object(let object) = value, case .string(let id)? = object["terminalID"] else {
            throw PluginHostArguments.invalid
        }
        return id
    }

    private func code(_ result: Result<ToolingJSONValue, PluginHostRequestFailure>) -> String? {
        if case .failure(let failure) = result { return failure.code }; return nil
    }

    @MainActor
    private final class Access: PluginTerminalSessionAccess {
        var exit: PluginTerminalExit?
        var shown = 0
        var closed = false
        var history = ""
        let didClose = TestGate()
        func show() throws { shown += 1 }
        func displayText(maximumBytes: Int) -> String { String(decoding: history.utf8.suffix(maximumBytes), as: UTF8.self) }
        func close() async { closed = true; didClose.open() }
    }

    @MainActor
    private final class Window: PluginHostWindowPort, PluginTerminalWindowPort {
        var hostSnapshot: PluginHostWindowSnapshot? = PluginHostFixture.snapshot(windowID: UUID())
        let hostMessages = PluginHostMessageFeatureModel()
        let access = Access()
        var launch: PluginTerminalLaunch?
        var exit: (@MainActor @Sendable (PluginTerminalExit) -> Void)?
        var duringLaunch: (@MainActor () async -> Void)?
        func hostCreatePluginTerminal(_ launch: PluginTerminalLaunch, onExit: @escaping @MainActor @Sendable (PluginTerminalExit) -> Void) async throws -> any PluginTerminalSessionAccess {
            self.launch = launch; exit = onExit
            access.closed = false
            await duringLaunch?()
            return access
        }
        func hostDocumentState(at url: URL, flushingEditor: Bool) async -> PluginHostDocumentState? { nil }
        func hostOpenDocument(at url: URL, activation: PluginHostEditorActivation) async -> PluginHostDocumentState? { nil }
        func hostPlaceCaret(in url: URL, at position: PluginHostPosition) {}
        func hostNoteMessageLimit(pluginName: String) {}
    }

    @MainActor
    private final class Fixture {
        let contexts = PluginWorkspaceContexts()
        let window = Window()
        var context: PluginWorkspaceContext!
        let dispatcher: PluginHostServiceDispatcher
        let service: PluginTerminalHostService
        var events: [ToolingJSONValue] = []
        init() {
            dispatcher = PluginHostServiceDispatcher(contexts: contexts)
            let metadata = PluginWorkspaceHostService(contexts: contexts,
                backendStateDirectory: { _ in URL(fileURLWithPath: "/fixture/state") }, rootIDSecret: { Data("fixture".utf8) })
            service = PluginTerminalHostService(contexts: contexts, metadata: metadata)
            context = contexts.open(owner: window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
            dispatcher.register(service)
            dispatcher.beginSession(pluginID: "plugin", hostServices: Array(service.methods))
            dispatcher.subscriptions.deliver = { [weak self] _, value in self?.events.append(value) }
        }
        func end() {
            window.duringLaunch = nil; window.exit = nil
            dispatcher.endSession(pluginID: "plugin"); dispatcher.endSession(pluginID: "other")
            contexts.close(owner: window)
        }
        func request(_ method: String, _ params: [String: ToolingJSONValue]) -> PluginHostRequest {
            var params = params
            params["context"] = .object(["contextID": .string(context.contextID), "generation": .integer(context.generation)])
            return PluginHostRequest(id: UUID().uuidString, method: "lithe/host/terminal/" + method, service: "terminal", params: .object(params))
        }
        func call(_ method: String, _ params: [String: ToolingJSONValue]) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
            await dispatcher.dispatch(request(method, params), pluginID: "plugin")
        }
    }
}

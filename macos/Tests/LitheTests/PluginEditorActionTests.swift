import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct PluginEditorActionTests {
    @Test
    func registrationsAreIndependentScopedAndDisposable() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let contexts = PluginWorkspaceContexts()
        let context = contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
        let service = PluginEditorActionHostService(contexts: contexts, decoder: DeclarativePluginTestSupport.operations)
        let dispatcher = PluginHostServiceDispatcher(contexts: contexts)
        dispatcher.register(service)
        let session = dispatcher.beginSession(pluginID: "tool", hostServices: ["lithe/host/editor/registerActions"])
        defer { dispatcher.endSession(pluginID: "tool") }
        service.updateFunctions(pluginID: "tool", sessionID: session, ids: ["actions.collect", "requests.send", "queries.execute"])
        let result = try await dispatcher.dispatch(request(context: context, function: "actions.collect"), pluginID: "tool").get()
        let registration = try #require(service.registrations(context: context.reference, filename: "a.HTTP").first)
        #expect(service.contains(registration, functionID: "requests.send"))
        #expect(service.contains(registration, functionID: "queries.execute"))
        #expect(!service.contains(registration, functionID: "anotherPlugin.execute"))
        #expect(service.registrations(context: context.reference, filename: "a.txt").isEmpty)
        service.updateFunctions(pluginID: "tool", sessionID: session, ids: ["actions.collect", "requests.send", "queries.execute", "extra.function"])
        #expect(service.contains(registration), "adding a function must not withdraw unrelated bindings")
        guard case .object(let value) = result, case .string(let subscription)? = value["subscriptionID"] else {
            Issue.record("missing subscription"); return
        }
        dispatcher.subscriptions.dispose(pluginID: "tool", subscriptionID: subscription)
        #expect(!service.contains(registration))
    }

    @Test
    func withdrawalAndSessionReplacementNeverResurrectOldLeases() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let contexts = PluginWorkspaceContexts()
        let context = contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
        let service = PluginEditorActionHostService(contexts: contexts, decoder: DeclarativePluginTestSupport.operations)
        let dispatcher = PluginHostServiceDispatcher(contexts: contexts)
        dispatcher.register(service)
        let session = dispatcher.beginSession(pluginID: "tool", hostServices: ["lithe/host/editor/registerActions"])
        defer { dispatcher.endSession(pluginID: "tool") }
        service.updateFunctions(pluginID: "tool", sessionID: session, ids: ["actions.collect"])
        _ = try await dispatcher.dispatch(request(context: context, function: "actions.collect"), pluginID: "tool").get()
        let old = try #require(service.registrations(context: context.reference, filename: "a.http").first)
        service.updateFunctions(pluginID: "tool", sessionID: session, ids: [])
        service.updateFunctions(pluginID: "tool", sessionID: session, ids: ["actions.collect"])
        #expect(!service.contains(old))
        _ = try await dispatcher.dispatch(request(context: context, function: "actions.collect"), pluginID: "tool").get()
        let current = try #require(service.registrations(context: context.reference, filename: "a.http").first)
        #expect(current.lease != old.lease)
        contexts.close(owner: fixture.window)
        #expect(!service.contains(current))
        #expect(dispatcher.subscriptions.count(pluginID: "tool") == 0)
    }

    @Test
    func missingPermissionAndUnknownFunctionDoNotCreateBindings() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let contexts = PluginWorkspaceContexts()
        let context = contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
        let service = PluginEditorActionHostService(contexts: contexts, decoder: DeclarativePluginTestSupport.operations)
        let dispatcher = PluginHostServiceDispatcher(contexts: contexts)
        dispatcher.register(service)
        dispatcher.beginSession(pluginID: "tool", hostServices: [])
        defer { dispatcher.endSession(pluginID: "tool") }
        if case .failure(let error) = await dispatcher.dispatch(request(context: context, function: "actions.collect"), pluginID: "tool") {
            #expect(error.code == "plugin.host.permissionDenied")
        } else { Issue.record("permission must be denied") }
        let session = dispatcher.beginSession(pluginID: "tool", hostServices: ["lithe/host/editor/registerActions"])
        service.updateFunctions(pluginID: "tool", sessionID: session, ids: [])
        if case .failure(let error) = await dispatcher.dispatch(request(context: context, function: "actions.collect"), pluginID: "tool") {
            #expect(error.code == "plugin.host.invalidParams")
        } else { Issue.record("unknown function must be denied") }
        #expect(service.registrations(context: context.reference, filename: "a.http").isEmpty)
    }

    private func request(context: PluginWorkspaceContext, function: String) -> PluginHostRequest {
        PluginHostRequest(id: "registration", method: "lithe/host/editor/registerActions", service: "editor", params: .object([
            "context": .object(["contextID": .string(context.contextID), "generation": .integer(context.generation)]),
            "id": .string("actions"), "function": .string(function),
            "selector": .object(["fileExtensions": .array([.string("http")])]),
        ]))
    }
}

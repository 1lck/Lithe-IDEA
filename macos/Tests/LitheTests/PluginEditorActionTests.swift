import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct PluginEditorActionTests {
    @Test
    func collectionUsesOneTotalBudgetRatherThanRestartingItForEachRegistration() {
        #expect(PluginEditorActionCollectionBudget.remaining(after: .zero) == .seconds(8))
        #expect(PluginEditorActionCollectionBudget.remaining(after: .seconds(6)) == .seconds(2))
        #expect(PluginEditorActionCollectionBudget.remaining(after: .seconds(8)) == nil)
        #expect(PluginEditorActionCollectionBudget.remaining(after: .seconds(12)) == nil)
    }

    @Test
    func registrationsAreIndependentScopedAndDisposable() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let contexts = PluginWorkspaceContexts()
        let context = contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
        let service = PluginEditorActionHostService(contexts: contexts, decoder: DeclarativePluginTestSupport.operations, host: .macOS)
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
        let service = PluginEditorActionHostService(contexts: contexts, decoder: DeclarativePluginTestSupport.operations, host: .macOS)
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
        let service = PluginEditorActionHostService(contexts: contexts, decoder: DeclarativePluginTestSupport.operations, host: .macOS)
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

    // MARK: Version 2: alternatives and reveal

    @Test
    func aMarkerOffersItsAlternativesAndTheClickedFunctionsAreAllKnown() throws {
        let service = PluginEditorActionHostService(
            contexts: PluginWorkspaceContexts(), decoder: DeclarativePluginTestSupport.operations, host: .macOS)
        let fixture = try contractFixture("editor/editor-actions-v2.json")
        let marker = try #require(fixture.member("cases")?.elements.first)

        let actions = try service.decode(
            try #require(marker.member("value")), text: try #require(marker.member("text")?.textValue))

        let main = try #require(actions.first)
        #expect(actions.count == 1)
        #expect(main.icon == "run")
        #expect(main.alternatives.map(\.id) == ["debug", "test"])
        #expect(main.alternatives.map(\.icon) == ["debug", "test"])
        #expect(main.alternatives.last?.invoke.params == .object([:]), "an alternative without params is still a call")
        #expect(main.functionIDs == ["go.markers.invoke", "go.markers.invoke", "go.markers.invoke"])
        #expect(main.range.start.line == 3)
        #expect(main.range.start.column == 1)
    }

    @Test
    func aClickedActionMayRevealLocationsAndNothingElseIsInterpreted() throws {
        let service = PluginEditorActionHostService(
            contexts: PluginWorkspaceContexts(), decoder: DeclarativePluginTestSupport.operations, host: .macOS)
        let cases = try #require(contractFixture("editor/editor-actions-v2.json").member("cases")).elements
        func result(_ name: String) throws -> ToolingJSONValue {
            try #require(cases.first { $0.member("name")?.textValue?.hasPrefix(name) == true }?.member("value"))
        }

        let reveal = try #require(try service.decodeReveal(result("a click reveals")))
        #expect(reveal.locations.map(\.uri) == ["file:///workspace/messages.properties", "file:///workspace/messages_zh.properties"])
        #expect(reveal.locations.first?.range.start.line == 4)
        #expect(reveal.locations.first?.range.end.character == 9)

        #expect(try service.decodeReveal(result("other result members")) == nil, "the plugin's own members are not the host's business")
        #expect(throws: (any Error).self) { try service.decodeReveal(result("a reveal location needs")) }
    }

    @Test
    func contractFixtureCasesMatchCore() throws {
        let fixture = try contractFixture("editor/editor-actions-v2.json")
        let host = try #require(fixture.member("host"))
        let options = PluginEditorHostOptions(
            actionIcons: try #require(host.member("actionIcons")).elements.compactMap(\.textValue),
            actionSourceBytes: try #require(host.member("actionSourceBytes")?.integerValue),
            providerTypes: PluginEditorHostOptions.macOS.providerTypes)
        #expect(options == .macOS, "the fixture describes the host the macOS app declares")
        let operations = DeclarativePluginTestSupport.operations

        for entry in try #require(fixture.member("cases")).elements {
            let name = entry.member("name")?.textValue ?? "case"
            let kind = try #require(entry.member("kind")?.textValue)
            let expected = try #require(entry.member("expected"))
            do {
                let decoded = try operations.decodeEditorActions(
                    kind: kind, value: try #require(entry.member("value")),
                    text: entry.member("text")?.textValue ?? "", host: options)
                #expect(expected.member("status")?.textValue == "accepted", "\(name)")
                let value = kind == "actions" ? decoded.member("actions") : decoded
                #expect(value == expected.member("value"), "\(name)")
            } catch {
                #expect(expected.member("status")?.textValue == "rejected", "\(name)")
            }
        }
    }

    private func request(context: PluginWorkspaceContext, function: String) -> PluginHostRequest {
        PluginHostRequest(id: "registration", method: "lithe/host/editor/registerActions", service: "editor", params: .object([
            "context": .object(["contextID": .string(context.contextID), "generation": .integer(context.generation)]),
            "id": .string("actions"), "function": .string(function),
            "selector": .object(["fileExtensions": .array([.string("http")])]),
        ]))
    }
}

private func contractFixture(_ name: String) throws -> ToolingJSONValue {
    let url = DeclarativePluginTestSupport.repositoryRoot
        .appendingPathComponent("shared/contracts/plugins/v1/fixtures/\(name)")
    return try JSONDecoder().decode(ToolingJSONValue.self, from: Data(contentsOf: url))
}

private extension ToolingJSONValue {
    func member(_ key: String) -> ToolingJSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var elements: [ToolingJSONValue] {
        if case .array(let array) = self { return array }
        return []
    }

    var textValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var integerValue: Int? {
        if case .integer(let number) = self { return number }
        return nil
    }
}

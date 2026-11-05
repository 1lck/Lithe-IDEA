import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

/// Content providers of plugin backends (plan API-12): the binding, its
/// lifecycle, and Core's check of the answer.
@MainActor
struct PluginContentProviderTests {
    private static let method = "lithe/host/documents/registerContentProvider"

    @MainActor
    private struct Harness {
        let fixture = PluginHostFixture()
        let contexts = PluginWorkspaceContexts()
        let context: PluginWorkspaceContext
        let service: PluginContentProviderHostService
        let dispatcher: PluginHostServiceDispatcher
        let session: String

        init(grants: [String] = [PluginContentProviderTests.method]) {
            context = contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
            service = PluginContentProviderHostService(contexts: contexts, decoder: DeclarativePluginTestSupport.operations)
            dispatcher = PluginHostServiceDispatcher(contexts: contexts)
            dispatcher.register(service)
            session = dispatcher.beginSession(pluginID: "tool", hostServices: grants)
            service.updateFunctions(pluginID: "tool", sessionID: session, ids: ["documents.read"])
        }

        func tearDown() {
            dispatcher.endSession(pluginID: "tool")
            fixture.tearDown()
        }

        func register(scheme: String, function: String = "documents.read") async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
            await dispatcher.dispatch(
                PluginHostRequest(id: "registration", method: PluginContentProviderTests.method, service: "documents", params: .object([
                    "context": .object(["contextID": .string(context.contextID), "generation": .integer(context.generation)]),
                    "scheme": .string(scheme),
                    "function": .string(function),
                ])),
                pluginID: "tool"
            )
        }
    }

    @Test
    func aRegisteredSchemeIsServedByItsFunctionInThisWindowOnly() async throws {
        let harness = Harness()
        defer { harness.tearDown() }

        _ = try await harness.register(scheme: "metals-library").get()

        let provider = try #require(harness.service.provider(forScheme: "metals-library", context: harness.context.reference))
        #expect(provider.pluginID == "tool")
        #expect(provider.functionID == "documents.read")
        #expect(harness.service.provider(forScheme: "other", context: harness.context.reference) == nil)
        let elsewhere = PluginWorkspaceContextReference(contextID: "another", generation: 1)
        #expect(harness.service.provider(forScheme: "metals-library", context: elsewhere) == nil)
    }

    @Test
    func aSchemeHasOneProviderPerWindow() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        _ = try await harness.register(scheme: "metals-library").get()

        guard case .failure(let error) = await harness.register(scheme: "metals-library") else {
            Issue.record("a second provider for the scheme must be refused"); return
        }
        #expect(error.code == "plugin.host.preconditionFailed")
    }

    @Test
    func aFunctionTheSessionDidNotRegisterCreatesNoProvider() async {
        let harness = Harness()
        defer { harness.tearDown() }

        guard case .failure(let error) = await harness.register(scheme: "metals-library", function: "unknown.function") else {
            Issue.record("an unknown function must be refused"); return
        }
        #expect(error.code == "plugin.host.invalidParams")
        #expect(harness.service.provider(forScheme: "metals-library", context: harness.context.reference) == nil)
    }

    @Test
    func withoutTheGrantNothingIsRegistered() async {
        let harness = Harness(grants: [])
        defer { harness.tearDown() }

        guard case .failure(let error) = await harness.register(scheme: "metals-library") else {
            Issue.record("the grant is required"); return
        }
        #expect(error.code == "plugin.host.permissionDenied")
    }

    @Test
    func disposingWithdrawingAndClosingTheContextRemoveTheProvider() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let context = harness.context.reference

        // Disposing the subscription.
        let result = try await harness.register(scheme: "metals-library").get()
        guard case .object(let value) = result, case .string(let subscription)? = value["subscriptionID"] else {
            Issue.record("missing subscription"); return
        }
        harness.dispatcher.subscriptions.dispose(pluginID: "tool", subscriptionID: subscription)
        #expect(harness.service.provider(forScheme: "metals-library", context: context) == nil)

        // Withdrawing the function; a reused function ID must not revive it.
        _ = try await harness.register(scheme: "metals-library").get()
        harness.service.updateFunctions(pluginID: "tool", sessionID: harness.session, ids: [])
        #expect(harness.service.provider(forScheme: "metals-library", context: context) == nil)
        harness.service.updateFunctions(pluginID: "tool", sessionID: harness.session, ids: ["documents.read"])
        #expect(harness.service.provider(forScheme: "metals-library", context: context) == nil)

        // Closing the window's context.
        _ = try await harness.register(scheme: "metals-library").get()
        harness.contexts.close(owner: harness.fixture.window)
        #expect(harness.service.provider(forScheme: "metals-library", context: context) == nil)
        #expect(harness.dispatcher.subscriptions.count(pluginID: "tool") == 0)
    }

    @Test
    func coreAcceptsAStringOrAContentObjectAndRefusesTheRest() throws {
        let service = PluginContentProviderHostService(contexts: PluginWorkspaceContexts(), decoder: DeclarativePluginTestSupport.operations)

        #expect(try service.content(of: .string("class A {}")) == "class A {}")
        #expect(try service.content(of: .object(["content": .string("class A {}")])) == "class A {}")
        #expect(throws: (any Error).self) { try service.content(of: .integer(7)) }
        #expect(throws: (any Error).self) { try service.content(of: .object(["content": .integer(7)])) }
        #expect(throws: (any Error).self) { try service.content(of: .string(String(repeating: "a", count: 1024 * 1024 + 1))) }
    }
}

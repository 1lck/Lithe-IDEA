import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing

/// `lithe/host/languageServer/request`, `notify` and `setStatus` (plan
/// API-25) as a backend reaches them: the params that cross into the
/// session, and the failures that come back in the backend's shape. Rust
/// Core decides what a server may be asked; these tests use a recording
/// session and check only what the host adds.
@MainActor
struct PluginLanguageServerHostServiceTests {
    private static let methods = [
        "lithe/host/languageServer/request",
        "lithe/host/languageServer/notify",
        "lithe/host/languageServer/setStatus",
    ]

    @MainActor
    private struct Harness {
        let fixture = PluginHostFixture()
        let contexts = PluginWorkspaceContexts()
        let context: PluginWorkspaceContext
        let dispatcher: PluginHostServiceDispatcher
        let servers = RecordingServers()

        init(grants: [String] = PluginLanguageServerHostServiceTests.methods, withSessions: Bool = true) {
            context = contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
            fixture.window.hostLanguageServers = withSessions ? servers : nil
            dispatcher = PluginHostServiceDispatcher(contexts: contexts)
            dispatcher.register(PluginLanguageServerHostService(contexts: contexts))
            _ = dispatcher.beginSession(pluginID: "tool", hostServices: grants)
        }

        func tearDown() {
            dispatcher.endSession(pluginID: "tool")
            fixture.tearDown()
        }

        func call(
            _ method: String, _ params: [String: ToolingJSONValue]
        ) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
            var withContext = params
            withContext["context"] = .object([
                "contextID": .string(context.contextID), "generation": .integer(context.generation),
            ])
            return await dispatcher.dispatch(
                PluginHostRequest(id: "call", method: method, service: "languageServer", params: .object(withContext)),
                pluginID: "tool"
            )
        }

        func request(_ params: [String: ToolingJSONValue] = [:]) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
            await call(PluginLanguageServerHostServiceTests.methods[0], base(params))
        }

        func notify(_ params: [String: ToolingJSONValue] = [:]) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
            await call(PluginLanguageServerHostServiceTests.methods[1], base(params))
        }

        func setStatus(_ params: [String: ToolingJSONValue]) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
            await call(PluginLanguageServerHostServiceTests.methods[2], ["serverID": .string("scala")].merging(params) { $1 })
        }

        private func base(_ params: [String: ToolingJSONValue]) -> [String: ToolingJSONValue] {
            ["serverID": .string("scala"), "method": .string("textDocument/definition")].merging(params) { $1 }
        }
    }

    // MARK: request

    @Test
    func aRequestReachesTheSessionAndItsValueComesBack() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.servers.requestOutcome = .success(.array([.string("Main.scala")]))

        let answer = try await harness.request([
            "params": .object(["position": .integer(3)]), "timeoutMilliseconds": .integer(2_500),
        ]).get()

        #expect(answer == .object(["value": .array([.string("Main.scala")])]))
        #expect(harness.servers.requests == [.init(
            pluginID: "tool", serverID: "scala", method: "textDocument/definition",
            params: .object(["position": .integer(3)]), timeout: 2.5
        )])
    }

    @Test
    func aRequestWithoutParamsOrTimeoutLeavesBothToTheEngine() async throws {
        let harness = Harness()
        defer { harness.tearDown() }

        _ = try await harness.request().get()

        #expect(harness.servers.requests.first?.params == .object([:]))
        #expect(harness.servers.requests.first?.timeout == nil)
    }

    @Test
    func aTimeoutOutsideTheContractedRangeNeverReachesTheSession() async {
        let harness = Harness()
        defer { harness.tearDown() }

        for milliseconds in [0, -1, 300_001] {
            guard case .failure(let failure) = await harness.request(["timeoutMilliseconds": .integer(milliseconds)]) else {
                Issue.record("\(milliseconds) ms must be refused"); continue
            }
            #expect(failure.code == "plugin.host.invalidParams")
        }
        #expect(harness.servers.requests.isEmpty)
    }

    @Test
    func aParameterTheContractDoesNotDefineIsRefused() async {
        let harness = Harness()
        defer { harness.tearDown() }

        guard case .failure(let failure) = await harness.request(["workspaceFolder": .string("/x")]) else {
            Issue.record("an unknown parameter must be refused"); return
        }

        #expect(failure.code == "plugin.host.unsupportedOption")
        #expect(harness.servers.requests.isEmpty)
    }

    // MARK: notify

    @Test
    func aNotificationReportsWhetherTheServerGotIt() async throws {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.servers.notifyOutcome = .success(true)
        #expect(try await harness.notify().get() == .object(["delivered": .bool(true)]))
        harness.servers.notifyOutcome = .success(false)
        #expect(try await harness.notify().get() == .object(["delivered": .bool(false)]))
    }

    // MARK: setStatus

    @Test
    func aStatusIsRecordedForTheServerAndAnswersEmpty() async throws {
        let harness = Harness()
        defer { harness.tearDown() }

        let answer = try await harness.setStatus([
            "state": .string("preparing"), "message": .string("Importing build"), "percentage": .integer(40),
        ]).get()

        #expect(answer == .object([:]))
        #expect(harness.servers.statuses == [.init(
            status: PluginServerStatus(state: .preparing, message: "Importing build", percentage: 40),
            serverID: "scala", pluginID: "tool"
        )])
    }

    @Test
    func aStatusOutsideTheContractIsRefused() async {
        let harness = Harness()
        defer { harness.tearDown() }

        for params: [String: ToolingJSONValue] in [
            ["state": .string("booting")],
            ["state": .string("preparing"), "percentage": .integer(101)],
            ["state": .string("preparing"), "percentage": .integer(-1)],
            [:],
        ] {
            guard case .failure(let failure) = await harness.setStatus(params) else {
                Issue.record("\(params) must be refused"); continue
            }
            #expect(failure.code == "plugin.host.invalidParams")
        }
        // The first version of the contract has no status actions.
        guard case .failure(let option) = await harness.setStatus(["state": .string("preparing"), "actions": .array([])]) else {
            Issue.record("status actions must be refused"); return
        }
        #expect(option.code == "plugin.host.unsupportedOption")
        #expect(harness.servers.statuses.isEmpty)
    }

    // MARK: failures

    @Test
    func theSessionsFailuresReachTheBackendWithTheirStableCodes() async {
        let harness = Harness()
        defer { harness.tearDown() }
        let serverError = PluginHostRequestFailure(
            message: "Server refused", code: "plugin.host.languageServerError",
            details: .object(["code": .integer(-32_001), "message": .string("no build")])
        )
        let outcomes: [PluginHostRequestFailure] = [
            .languageServerUnavailable, .foreignContribution, serverError,
        ]

        for outcome in outcomes {
            harness.servers.requestOutcome = .failure(outcome)
            guard case .failure(let failure) = await harness.request() else {
                Issue.record("\(outcome.code ?? "") must fail"); continue
            }
            #expect(failure.code == outcome.code)
            #expect(failure.message == outcome.message)
            #expect(failure.details == outcome.details)
        }
    }

    @Test
    func aCodeTheHostDoesNotKnowReachesTheBackendAsFailed() async {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.servers.requestOutcome = .failure(PluginHostRequestFailure(message: "?", code: "plugin.host.somethingNew"))

        guard case .failure(let failure) = await harness.request() else {
            Issue.record("the outcome must fail"); return
        }

        #expect(failure.code == "plugin.host.failed")
    }

    @Test
    func aWindowWithoutLanguageSessionsHasNoServerToAsk() async {
        let harness = Harness(withSessions: false)
        defer { harness.tearDown() }

        for result in [await harness.request(), await harness.notify(), await harness.setStatus(["state": .string("ready")])] {
            guard case .failure(let failure) = result else {
                Issue.record("a window without sessions must refuse"); continue
            }
            #expect(failure.code == "plugin.host.languageServerUnavailable")
        }
    }

    @Test
    func aMethodTheManifestDidNotGrantIsDeniedBeforeTheSessionIsAsked() async {
        let harness = Harness(grants: [Self.methods[0]])
        defer { harness.tearDown() }

        guard case .failure(let failure) = await harness.setStatus(["state": .string("ready")]) else {
            Issue.record("setStatus without a grant must be denied"); return
        }

        #expect(failure.code == "plugin.host.permissionDenied")
        #expect(harness.servers.statuses.isEmpty)
    }
}

/// The window's language sessions, recording what the host passed on.
@MainActor
private final class RecordingServers: PluginLanguageServerRouting {
    struct Request: Equatable {
        let pluginID: String
        let serverID: String
        let method: String
        let params: ToolingJSONValue
        let timeout: TimeInterval?
    }

    struct StatusCall: Equatable {
        let status: PluginServerStatus
        let serverID: String
        let pluginID: String
    }

    var requestOutcome: Result<ToolingJSONValue, PluginHostRequestFailure> = .success(.null)
    var notifyOutcome: Result<Bool, PluginHostRequestFailure> = .success(true)
    private(set) var requests: [Request] = []
    private(set) var statuses: [StatusCall] = []

    func requestPluginServer(
        pluginID: String, serverID: String, method: String, params: ToolingJSONValue, timeout: TimeInterval?
    ) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
        requests.append(Request(pluginID: pluginID, serverID: serverID, method: method, params: params, timeout: timeout))
        return requestOutcome
    }

    func notifyPluginServer(
        pluginID: String, serverID: String, method: String, params: ToolingJSONValue
    ) async -> Result<Bool, PluginHostRequestFailure> {
        notifyOutcome
    }

    func setPluginServerStatus(
        _ status: PluginServerStatus, serverID: String, pluginID: String
    ) -> Result<Void, PluginHostRequestFailure> {
        statuses.append(StatusCall(status: status, serverID: serverID, pluginID: pluginID))
        return .success(())
    }
}

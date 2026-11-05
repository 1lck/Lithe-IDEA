import Combine
import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

// 这些测试用第二种工具（resource key 在模板与 .properties 之间跳转）验证 Provider 通道：
// 宿主不认识任何语言，只按注册的选择器和类型路由，并把 Core 规范化后的结果交给编辑器。
@MainActor
struct PluginEditorProviderTests {
    private static let properties = PluginEditorProviderDocument(
        documentID: "doc-1", version: 3, filename: "app.properties", language: "properties")

    // MARK: Registration

    @Test
    func registrationsAreScopedBySelectorAndTypeAndRevokedWithTheirFunctions() async throws {
        let harness = ProviderHarness(functions: ["keys.hover", "keys.complete", "keys.usages"])
        defer { harness.tearDown() }
        let selector = #"{"languages":["HTML"],"fileExtensions":[".Properties"],"fileNames":["Messages"]}"#
        let providers = #"{"hover":{"function":"keys.hover"},"completion":{"function":"keys.complete","triggerCharacters":["."]}}"#
        _ = try await harness.register(selector: selector, providers: providers).get()

        #expect(harness.registrations("App.PROPERTIES", "plaintext", "hover").count == 1, "extension, any case")
        #expect(harness.registrations("Messages", "plaintext", "hover").count == 1, "file name")
        #expect(harness.registrations("index.htm", "html", "completion").count == 1, "language")
        #expect(harness.registrations("notes.txt", "plaintext", "hover").isEmpty)
        #expect(harness.registrations("app.properties", "properties", "codeLens").isEmpty, "type not provided")

        let registration = try #require(harness.registrations("a.properties", "properties", "completion").first)
        #expect(registration.providers["completion"]?.triggerCharacters == ["."])
        #expect(registration.providers["completion"]?.budget == .milliseconds(400))
        #expect(registration.providers["hover"]?.budget == .milliseconds(400))
        #expect(harness.service.contains(registration, functionID: "keys.hover"))
        #expect(!harness.service.contains(registration, functionID: "anotherPlugin.hover"))

        harness.setFunctions(["keys.hover", "keys.complete", "keys.usages", "keys.extra"])
        #expect(harness.service.contains(registration, functionID: "keys.hover"), "adding a function must not withdraw bindings")
        harness.setFunctions(["keys.hover", "keys.complete"])
        #expect(!harness.service.contains(registration, functionID: "keys.hover"), "withdrawing a function revokes the plugin's bindings")
        #expect(harness.registrations("a.properties", "properties", "hover").isEmpty)
    }

    @Test
    func disposingTheSubscriptionOrClosingTheContextWithdrawsRegistrations() async throws {
        let harness = ProviderHarness(functions: ["keys.hover"])
        defer { harness.tearDown() }
        let changes = ChangeCounter()
        let observation = harness.service.changes.sink { _ in changes.count += 1 }
        defer { observation.cancel() }
        let providers = #"{"hover":{"function":"keys.hover"}}"#

        let first = try await harness.register(id: "first", providers: providers).get()
        _ = try await harness.register(id: "second", providers: providers).get()
        #expect(harness.registrations("a.properties", "properties", "hover").count == 2)
        #expect(changes.count == 2)

        guard case .object(let value) = first, case .string(let subscription)? = value["subscriptionID"] else {
            Issue.record("missing subscription"); return
        }
        harness.dispatcher.subscriptions.dispose(pluginID: ProviderHarness.pluginID, subscriptionID: subscription)
        #expect(harness.registrations("a.properties", "properties", "hover").map(\.id) == ["second"])
        #expect(changes.count == 3, "disposing a registration tells the editor to ask again")

        harness.contexts.close(owner: harness.fixture.window)
        #expect(harness.registrations("a.properties", "properties", "hover").isEmpty)
        #expect(harness.dispatcher.subscriptions.count(pluginID: ProviderHarness.pluginID) == 0)
    }

    @Test
    func endingTheSessionWithdrawsEveryRegistration() async throws {
        let harness = ProviderHarness(functions: ["keys.hover"])
        defer { harness.tearDown() }
        _ = try await harness.register(providers: #"{"hover":{"function":"keys.hover"}}"#).get()
        let registration = try #require(harness.registrations("a.properties", "properties", "hover").first)

        harness.dispatcher.endSession(pluginID: ProviderHarness.pluginID)
        #expect(!harness.service.contains(registration, functionID: "keys.hover"))
        #expect(harness.registrations("a.properties", "properties", "hover").isEmpty)
    }

    @Test
    func everyProviderTypeTheMacOSHostRoutesIsAccepted() async throws {
        let harness = ProviderHarness(functions: ["f.definition", "f.hover", "f.complete", "f.lens", "f.fold", "f.tokens", "f.links"])
        defer { harness.tearDown() }
        let providers = """
        {"definition":{"function":"f.definition"},"hover":{"function":"f.hover"},
         "completion":{"function":"f.complete"},"codeLens":{"function":"f.lens"},
         "foldingRange":{"function":"f.fold"},
         "semanticTokens":{"function":"f.tokens","legend":{"tokenTypes":["property"],"tokenModifiers":[]}},
         "documentLink":{"function":"f.links"}}
        """
        _ = try await harness.register(providers: providers).get()

        let registration = try #require(harness.registrations("a.properties", "properties", "definition").first)
        #expect(Set(registration.providers.keys) == Set(PluginEditorHostOptions.macOS.providerTypes))
        #expect(registration.providers["definition"]?.budget == .milliseconds(1500))
        #expect(registration.providers["codeLens"]?.budget == .milliseconds(2000))
        #expect(registration.providers["semanticTokens"]?.legend != nil)
    }

    @Test
    func aTypeTheHostDoesNotRouteIsAnUnsupportedOption() async throws {
        let harness = ProviderHarness(functions: ["keys.hover", "keys.signature"])
        defer { harness.tearDown() }

        // The contract names a type the macOS host does not route.
        let signature = await harness.register(providers: #"{"signatureHelp":{"function":"keys.signature"}}"#)
        guard case .failure(let failure) = signature else { Issue.record("signatureHelp must be refused"); return }
        #expect(failure.code == "plugin.host.unsupportedOption")
        #expect(failure.details == .object(["option": .string("providers.signatureHelp")]))

        // A host that declared fewer types refuses the others with the same code.
        let limited = ProviderHarness(
            host: PluginEditorHostOptions(actionIcons: [], actionSourceBytes: 1024, providerTypes: ["hover"]),
            functions: ["keys.definition"])
        defer { limited.tearDown() }
        let definition = await limited.register(providers: #"{"definition":{"function":"keys.definition"}}"#)
        guard case .failure(let refused) = definition else { Issue.record("definition must be refused"); return }
        #expect(refused.code == "plugin.host.unsupportedOption")
        #expect(refused.details == .object(["option": .string("providers.definition")]))
        #expect(limited.registrations("a.properties", "properties", "definition").isEmpty)
    }

    @Test
    func malformedRegistrationsAreInvalidParamsAndCreateNoBinding() async throws {
        let harness = ProviderHarness(functions: ["keys.hover", "keys.tokens"])
        defer { harness.tearDown() }
        let cases: [(name: String, selector: String, providers: String)] = [
            ("a selector must name something", "{}", #"{"hover":{"function":"keys.hover"}}"#),
            ("semantic tokens declare their legend", #"{"fileExtensions":["properties"]}"#, #"{"semanticTokens":{"function":"keys.tokens"}}"#),
            ("budgets are the host's", #"{"fileExtensions":["properties"]}"#, #"{"hover":{"function":"keys.hover","budgetMs":5000}}"#),
            ("the function must be one the backend announced", #"{"fileExtensions":["properties"]}"#, #"{"hover":{"function":"keys.missing"}}"#),
        ]
        for item in cases {
            let outcome = await harness.register(selector: item.selector, providers: item.providers)
            guard case .failure(let failure) = outcome else { Issue.record("\(item.name) must be refused"); continue }
            #expect(failure.code == "plugin.host.invalidParams", "\(item.name)")
        }
        #expect(harness.registrations("a.properties", "properties", "hover").isEmpty)
        #expect(harness.dispatcher.subscriptions.count(pluginID: ProviderHarness.pluginID) == 0)
    }

    @Test
    func aDuplicateIDIsAPreconditionFailureAndEachPluginHasABoundedNumberOfRegistrations() async throws {
        let harness = ProviderHarness(functions: ["keys.hover"])
        defer { harness.tearDown() }
        let providers = #"{"hover":{"function":"keys.hover"}}"#
        _ = try await harness.register(id: "same", providers: providers).get()
        guard case .failure(let duplicate) = await harness.register(id: "same", providers: providers) else {
            Issue.record("a second registration with the same id must be refused"); return
        }
        #expect(duplicate.code == "plugin.host.preconditionFailed")

        for number in 1..<32 { _ = try await harness.register(id: "r\(number)", providers: providers).get() }
        guard case .failure(let overflow) = await harness.register(id: "one-too-many", providers: providers) else {
            Issue.record("the 33rd registration must be refused"); return
        }
        #expect(overflow.code == "plugin.host.limitExceeded")
    }

    // MARK: Queries

    @Test
    func aQueryKeepsValidAnswersAndDropsFailedAndMalformedOnes() async throws {
        let harness = ProviderHarness(functions: ["a.hover", "b.hover", "c.hover"])
        defer { harness.tearDown() }
        for (id, function) in [("a-keys", "a.hover"), ("b-keys", "b.hover"), ("c-keys", "c.hover")] {
            _ = try await harness.register(id: id, providers: #"{"hover":{"function":"\#(function)"}}"#).get()
        }
        let backends = RecordingProviderBackends()
        backends.answers["a.hover"] = try json(#"{"contents":[{"language":"properties","value":"app.title=Lithe"},"Defined in messages.properties"]}"#)
        backends.answers["b.hover"] = .string("not a hover")
        backends.failing = ["c.hover"]

        let answers = await harness.query("hover", Self.properties, position: (0, 7), backends: backends)

        #expect(answers.map(\.registration.id) == ["a-keys"])
        let expected = try json(#"{"contents":[{"kind":"markdown","value":"```properties\napp.title=Lithe\n```"},{"kind":"markdown","value":"Defined in messages.properties"}]}"#)
        #expect(answers.first?.result == expected, "Core's normalized shape, not the plugin's raw answer")
        #expect(backends.calls.count == 3, "every matching registration is asked")
        #expect(backends.calls.allSatisfy { $0.plugin == ProviderHarness.pluginID && $0.context == harness.context.reference })
        let first = try #require(backends.calls.first { $0.function == "a.hover" })
        let expectedParams = try json(#"{"documentID":"doc-1","version":3,"position":{"line":0,"character":7}}"#)
        #expect(first.params == expectedParams)
    }

    @Test
    func eachTypeIsAskedWithinTheBudgetCoreAssignedIt() async throws {
        let harness = ProviderHarness(functions: ["f.definition", "f.hover", "f.complete", "f.lens", "f.fold", "f.links"])
        defer { harness.tearDown() }
        let providers = """
        {"definition":{"function":"f.definition"},"hover":{"function":"f.hover"},
         "completion":{"function":"f.complete"},"codeLens":{"function":"f.lens"},
         "foldingRange":{"function":"f.fold"},"documentLink":{"function":"f.links"}}
        """
        _ = try await harness.register(providers: providers).get()
        let backends = RecordingProviderBackends()

        for type in ["definition", "hover", "completion", "codeLens", "foldingRange", "documentLink"] {
            _ = await harness.query(type, Self.properties, position: (0, 0), backends: backends)
        }

        let budgets = Dictionary(uniqueKeysWithValues: backends.calls.map { ($0.function, $0.timeout) })
        #expect(budgets["f.hover"] == .milliseconds(400))
        #expect(budgets["f.complete"] == .milliseconds(400))
        #expect(budgets["f.definition"] == .milliseconds(1500))
        #expect(budgets["f.lens"] == .milliseconds(2000))
        #expect(budgets["f.fold"] == .milliseconds(2000))
        #expect(budgets["f.links"] == .milliseconds(2000))
    }

    @Test
    func anAnswerForADocumentThatMovedOnIsDropped() async throws {
        let harness = ProviderHarness(functions: ["keys.hover"])
        defer { harness.tearDown() }
        _ = try await harness.register(providers: #"{"hover":{"function":"keys.hover"}}"#).get()
        let backends = RecordingProviderBackends()
        backends.answers["keys.hover"] = try json(#"{"contents":["late"]}"#)

        let alreadyStale = await harness.query("hover", Self.properties, position: (0, 0), backends: backends, isCurrent: { false })
        #expect(alreadyStale.isEmpty)

        // The version changes while the plugin is still working.
        let current = CurrentFlag()
        backends.whileCalled = { current.value = false }
        let movedOn = await harness.query("hover", Self.properties, position: (0, 0), backends: backends, isCurrent: { current.value })
        #expect(movedOn.isEmpty)
        #expect(backends.calls.count == 2, "the plugin was asked both times")

        // The plugin's functions are withdrawn while it is still working.
        backends.whileCalled = { harness.setFunctions([]) }
        let withdrawn = await harness.query("hover", Self.properties, position: (0, 0), backends: backends)
        #expect(withdrawn.isEmpty)
    }

    @Test
    func aTriggerCharacterOnlyReachesRegistrationsThatAskedForIt() async throws {
        let harness = ProviderHarness(functions: ["dot.complete", "any.complete"])
        defer { harness.tearDown() }
        _ = try await harness.register(id: "dot", providers: #"{"completion":{"function":"dot.complete","triggerCharacters":["."]}}"#).get()
        _ = try await harness.register(id: "any", providers: #"{"completion":{"function":"any.complete"}}"#).get()
        let backends = RecordingProviderBackends()

        _ = await harness.query("completion", Self.properties, position: (0, 4), trigger: ".", backends: backends)
        let expectedParams = try json(#"{"documentID":"doc-1","version":3,"position":{"line":0,"character":4},"triggerCharacter":"."}"#)
        #expect(backends.calls.map(\.function) == ["dot.complete"])
        #expect(backends.calls.first?.params == expectedParams)

        backends.calls.removeAll()
        _ = await harness.query("completion", Self.properties, position: (0, 4), trigger: ",", backends: backends)
        #expect(backends.calls.isEmpty, "nobody asked for a comma")

        backends.calls.removeAll()
        _ = await harness.query("completion", Self.properties, position: (0, 4), backends: backends)
        #expect(Set(backends.calls.map(\.function)) == ["dot.complete", "any.complete"], "typing a letter asks everyone")
    }

    @Test
    func aQueryOnlyReachesRegistrationsForTheFileAndTheType() async throws {
        let harness = ProviderHarness(functions: ["keys.hover"])
        defer { harness.tearDown() }
        _ = try await harness.register(providers: #"{"hover":{"function":"keys.hover"}}"#).get()
        let backends = RecordingProviderBackends()
        let other = PluginEditorProviderDocument(documentID: "doc-2", version: 1, filename: "main.go", language: "go")

        let otherFile = await harness.query("hover", other, position: (0, 0), backends: backends)
        let otherType = await harness.query("documentLink", Self.properties, backends: backends)
        #expect(otherFile.isEmpty)
        #expect(otherType.isEmpty)
        #expect(backends.calls.isEmpty)
    }

    // MARK: Definition merge

    @Test
    func coreKeepsTheServersDefinitionsAndOnlySupplementsThem() throws {
        let harness = ProviderHarness(functions: [])
        defer { harness.tearDown() }
        let document = URL(fileURLWithPath: "/work/app.go")
        func place(_ path: String, _ line: Int, _ from: Int, _ to: Int) throws -> ToolingJSONValue {
            try json(#"{"uri":"file://\#(path)","range":{"start":{"line":\#(line),"character":\#(from)},"end":{"line":\#(line),"character":\#(to)}}}"#)
        }

        // The same place from both sides is shown once.
        let duplicate = try harness.service.mergeDefinitions(
            documentURL: document, line: 9, character: 9,
            server: [place("/work/a.go", 1, 0, 3)],
            plugin: [place("/work/a.go", 1, 0, 3), place("/work/b.go", 2, 0, 3)])
        #expect(duplicate.server == [0])
        #expect(duplicate.plugin == [1])

        // A server answer that only points at the symbol itself yields to the plugin.
        let own = try place("/work/app.go", 4, 2, 8)
        let other = try place("/work/b.go", 2, 0, 3)
        let yielded = try harness.service.mergeDefinitions(
            documentURL: document, line: 4, character: 5, server: [own], plugin: [other])
        #expect(yielded.server.isEmpty)
        #expect(yielded.plugin == [0])

        // Without a plugin answer the server's own location stands, and the end bound is exclusive.
        let alone = try harness.service.mergeDefinitions(
            documentURL: document, line: 4, character: 5, server: [own], plugin: [])
        #expect(alone.server == [0])
        let atTheEnd = try harness.service.mergeDefinitions(
            documentURL: document, line: 4, character: 8, server: [own], plugin: [other])
        #expect(atTheEnd.server == [0])
        #expect(atTheEnd.plugin == [0])
    }

    @Test
    func aMalformedLocationFailsTheMerge() throws {
        let harness = ProviderHarness(functions: [])
        defer { harness.tearDown() }
        let empty = try json(#"{"uri":"","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}"#)
        #expect(throws: (any Error).self) {
            try harness.service.mergeDefinitions(
                documentURL: URL(fileURLWithPath: "/work/app.go"), line: 0, character: 0, server: [empty], plugin: [])
        }
    }

    // MARK: Modifier hover

    @Test
    func aNewerHoverCancelsTheRunningDefinitionQueryAndRetiresTheOlderTicket() async {
        let hover = PluginDefinitionHover()
        let first = hover.begin()
        // Stands in for providers still inside their budget; cancellation ends the sleep at once.
        let slow = Task<[LanguageServerLocation], Never> {
            try? await Task.sleep(for: .seconds(30))
            return []
        }
        hover.run(slow)

        let second = hover.begin()

        #expect(slow.isCancelled)
        #expect(!hover.isLatest(first), "the older hover's server reply can no longer start providers")
        #expect(hover.isLatest(second))
        _ = await slow.value
    }

    @Test
    func aFinishedDefinitionQueryIsNotCancelledByTheNextHover() async {
        let hover = PluginDefinitionHover()
        _ = hover.begin()
        let done = Task<[LanguageServerLocation], Never> { [] }
        hover.run(done)
        _ = await done.value
        hover.finished(done)

        _ = hover.begin()

        #expect(!done.isCancelled)
    }

    // MARK: Contract

    @Test
    func theMacOSHostDeclaresTheOptionsTheContractFixtureAssumes() throws {
        let fixture = try contractFixture("editor-providers.json")
        let types = try #require(fixture.member("host")?.member("providerTypes"))
        #expect(types == .array(PluginEditorHostOptions.macOS.providerTypes.map { .string($0) }))

        let encoded = try JSONEncoder().encode(PluginEditorHostOptions.macOS)
        let options = try JSONDecoder().decode(ToolingJSONValue.self, from: encoded)
        #expect(options.member("providerTypes") == types)
        #expect(options.member("actionSourceBytes") == .integer(1024 * 1024))
        #expect(options.member("actionIcons")?.elements.count == 9)
    }

    @Test
    func contractFixtureRegistrationsAndResultsMatchCore() throws {
        let fixture = try contractFixture("editor-providers.json")
        let operations = DeclarativePluginTestSupport.operations
        let types = try #require(fixture.member("host")?.member("providerTypes")).elements.compactMap(\.textValue)

        for entry in try #require(fixture.member("registrations")).elements {
            let name = entry.member("name")?.textValue ?? "registration"
            let expected = try #require(entry.member("expected"))
            do {
                let decoded = try operations.decodeEditorProviderRegistration(
                    value: try #require(entry.member("params")), types: types)
                #expect(expected.member("status")?.textValue == "accepted", "\(name)")
                #expect(decoded.member("registration") == expected.member("registration"), "\(name)")
            } catch let unsupported as PluginEditorProviderUnsupported {
                #expect(expected.member("code")?.textValue == "plugin.host.unsupportedOption", "\(name)")
                #expect(expected.member("details")?.member("option")?.textValue == unsupported.option, "\(name)")
            } catch {
                #expect(expected.member("code")?.textValue == "plugin.host.invalidParams", "\(name)")
            }
        }

        for entry in try #require(fixture.member("results")).elements {
            let name = entry.member("name")?.textValue ?? "result"
            let expected = try #require(entry.member("expected"))
            do {
                let decoded = try operations.decodeEditorProviderResult(
                    type: try #require(entry.member("type")?.textValue),
                    value: entry.member("value") ?? .null, legend: entry.member("legend"))
                #expect(expected.member("status")?.textValue == "accepted", "\(name)")
                #expect(decoded.member("result") == expected.member("value"), "\(name)")
            } catch {
                #expect(expected.member("status")?.textValue == "rejected", "\(name)")
            }
        }
    }
}

// MARK: - Test doubles and helpers

private func json(_ text: String) throws -> ToolingJSONValue {
    try JSONDecoder().decode(ToolingJSONValue.self, from: Data(text.utf8))
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
}

private final class ChangeCounter {
    var count = 0
}

private final class CurrentFlag {
    var value = true
}

/// One local window with a workspace and a plugin session that announced `functions`,
/// wired to the real provider service and dispatcher.
@MainActor
private final class ProviderHarness {
    static let pluginID = "tool"

    let fixture = PluginHostFixture()
    let contexts = PluginWorkspaceContexts()
    let context: PluginWorkspaceContext
    let service: PluginEditorProviderHostService
    let dispatcher: PluginHostServiceDispatcher
    let session: String

    init(host: PluginEditorHostOptions = .macOS, functions: [String]) {
        context = contexts.open(owner: fixture.window, rootURL: PluginHostFixture.workspaceURL, remote: nil)
        service = PluginEditorProviderHostService(
            contexts: contexts, decoder: DeclarativePluginTestSupport.operations, host: host)
        dispatcher = PluginHostServiceDispatcher(contexts: contexts)
        dispatcher.register(service)
        session = dispatcher.beginSession(
            pluginID: Self.pluginID, hostServices: ["lithe/host/editor/registerProviders"])
        service.updateFunctions(pluginID: Self.pluginID, sessionID: session, ids: functions)
    }

    func tearDown() {
        dispatcher.endSession(pluginID: Self.pluginID)
        fixture.tearDown()
    }

    func setFunctions(_ ids: [String]) {
        service.updateFunctions(pluginID: Self.pluginID, sessionID: session, ids: ids)
    }

    func registrations(_ filename: String, _ language: String, _ type: String) -> [PluginEditorProviderRegistration] {
        service.registrations(context: context.reference, filename: filename, language: language, type: type)
    }

    func register(
        id: String = "message-keys", selector: String = #"{"fileExtensions":["properties"]}"#, providers: String
    ) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
        guard let selector = try? json(selector), let providers = try? json(providers) else {
            preconditionFailure("the test's registration is not JSON")
        }
        let request = PluginHostRequest(
            id: "registration", method: "lithe/host/editor/registerProviders", service: "editor",
            params: .object([
                "context": .object([
                    "contextID": .string(context.contextID), "generation": .integer(context.generation),
                ]),
                "id": .string(id), "selector": selector, "providers": providers,
            ]))
        return await dispatcher.dispatch(request, pluginID: Self.pluginID)
    }

    func query(
        _ type: String, _ document: PluginEditorProviderDocument, position: (line: Int, character: Int)? = nil,
        trigger: String? = nil, backends: RecordingProviderBackends,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> [PluginEditorProviderAnswer] {
        await service.query(
            type: type, document: document, context: context.reference, position: position,
            triggerCharacter: trigger, backends: backends, isCurrent: isCurrent)
    }
}

/// Answers provider functions from a table and records how the host called them.
@MainActor
private final class RecordingProviderBackends: PluginBackendRequesting {
    struct Call {
        let function: String
        let params: ToolingJSONValue
        let plugin: String
        let context: PluginWorkspaceContextReference?
        let timeout: Duration
    }

    struct Failure: Error {}

    var answers: [String: ToolingJSONValue] = [:]
    var failing: Set<String> = []
    /// Runs inside each call, before it answers: the world changing while a plugin works.
    var whileCalled: (() -> Void)?
    var calls: [Call] = []

    func declaresBackend(_: String) -> Bool { true }
    func pluginFunctions(ofPlugin _: String) async throws -> [String] { [] }

    func invokePluginFunction(
        _ functionID: String, params: ToolingJSONValue, ofPlugin pluginID: String, timeout: Duration,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        try await invokePluginFunction(
            functionID, params: params, ofPlugin: pluginID, context: nil, timeout: timeout, progress: progress)
    }

    func invokePluginFunction(
        _ functionID: String, params: ToolingJSONValue, ofPlugin pluginID: String,
        context: PluginWorkspaceContextReference?, timeout: Duration,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        calls.append(Call(function: functionID, params: params, plugin: pluginID, context: context, timeout: timeout))
        whileCalled?()
        if failing.contains(functionID) { throw Failure() }
        return answers[functionID] ?? .null
    }
}

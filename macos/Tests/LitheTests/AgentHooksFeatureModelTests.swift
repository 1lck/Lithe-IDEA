import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Agent Hook settings")
@MainActor
struct AgentHooksFeatureModelTests {
    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func validatesDraftsThroughCoreWithoutExecutingOrSavingThem() async {
        let stub = HookTestService()
        let feature = AgentHooksFeatureModel(service: stub)
        await feature.load()
        feature.beginEditing(AgentHook(name: "remind", description: "结束提醒", command: "printf done"))
        #expect(feature.canSave)
        for name in ["", "../escape", "spaces here", String(repeating: "a", count: 81), "NOTIFY"] {
            feature.draft?.name = name
            #expect(!feature.canSave)
        }
        feature.draft?.name = "valid_1"
        feature.timeoutText = "0"
        #expect(!feature.canSave)
        #expect(feature.draftValidation?.issues == [AgentHookDraftIssue(field: "timeout", code: "out_of_range")])
        feature.timeoutText = "86400"
        #expect(feature.canSave)
        // Swift used to accept these; the host rejected them only when saving.
        feature.draft?.agents = ["codex-acp", "codex-acp"]
        #expect(!feature.canSave)
        feature.draft?.agents = ["codex-acp"]
        feature.draft?.matcher = .shell
        #expect(feature.draftValidation?.issues == [AgentHookDraftIssue(field: "matcher", code: "incompatible_event")])
        feature.draft?.matcher = .all
        feature.draft?.agents = []
        #expect(!feature.canSave)
        #expect(await stub.writes == 0)
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func savingStoresTheTimeoutCoreParsed() async {
        let stub = HookTestService()
        let feature = AgentHooksFeatureModel(service: stub)
        await feature.load()
        feature.beginEditing(AgentHook(name: "timed", command: "printf done"))
        feature.timeoutText = "30"
        await feature.save()
        #expect(await stub.lastSaved?.timeoutSeconds == 30)
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func bridgeReturnsTheSharedFixtureVerdicts() throws {
        struct Fixture: Decodable {
            struct Case: Decodable {
                struct Request: Decodable {
                    struct Draft: Decodable {
                        let id, name, description: String
                        let event: AgentHookEvent
                        let matcher: AgentHookMatcher
                        let command, timeoutText: String
                        let agents: [String]
                    }
                    struct Existing: Decodable { let id, name: String }
                    let hook: Draft
                    let existingHooks: [Existing]
                }
                let name: String
                let request: Request
                let expected: AgentHookDraftValidation
            }
            let cases: [Case]
        }
        let url = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/agent/hook-draft-validation-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let service = RustAgentHooksService(core: RustCoreBridge(), directory: URL(fileURLWithPath: "/fixture/library"))
        for item in fixture.cases {
            let draft = item.request.hook
            let hook = AgentHook(id: draft.id, name: draft.name, description: draft.description, event: draft.event,
                                 matcher: draft.matcher, command: draft.command, agents: draft.agents)
            let library = AgentHookLibrary(revision: "fixture", hooks: item.request.existingHooks.map {
                AgentHookEntry(hook: AgentHook(id: $0.id, name: $0.name, command: "printf done"), configuredAgents: [], needsSync: false)
            }, targets: [])
            let result = try service.validateDraft(hook, timeoutText: draft.timeoutText, library: library)
            #expect(result == item.expected, "\(item.name)")
        }
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func failedSaveRetainsTheDraftAndExplicitReloadRefreshesGuards() async {
        let stub = HookTestService()
        let feature = AgentHooksFeatureModel(service: stub)
        await feature.load()
        let draft = AgentHook(name: "new-hook", command: "printf new")
        feature.beginEditing(draft)
        await stub.setFailure(true)
        await feature.save()
        #expect(feature.draft == draft)
        #expect(feature.phase == .failed("Fixture conflict"))
        await stub.setFailure(false)
        await feature.load()
        #expect(feature.draft == draft)
        await feature.save()
        #expect(feature.draft == nil)
        #expect(feature.library?.hooks.last?.id == draft.id)
    }

    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func mutationsDoNotOverlapAndPartialSynchronizationRemainsVisible() async {
        let stub = HookTestService()
        let feature = AgentHooksFeatureModel(service: stub)
        await feature.load()
        feature.beginEditing(AgentHook(name: "new-hook", command: "printf new"))
        await stub.onSave {
            await MainActor.run { #expect(feature.isBusy && !feature.canSave) }
            await feature.load()
            await feature.sync()
            await feature.save()
        }
        await feature.save()
        #expect(await stub.writes == 1)
        #expect(feature.library?.hooks.last?.needsSync == true)
        #expect(feature.library?.targets.last?.issue != nil)
        #expect(feature.phase == .ready)
    }

    @Test func togglingKeepsIdentityAndRemovalUsesTheSnapshotRevision() async throws {
        let stub = HookTestService()
        let feature = AgentHooksFeatureModel(service: stub)
        await feature.load()
        let entry = try #require(feature.entries.first)
        await feature.setEnabled(false, entry: entry)
        #expect(await stub.lastSaved?.id == entry.id)
        #expect(await stub.lastSaved?.enabled == false)
        #expect(await stub.lastRevision == "fixture-library-revision")
        await feature.remove(entry)
        #expect(await stub.removed == entry.id)
    }

    @Test func sharedFixtureDecodesNativeStateAndSearchFindsDescriptions() async throws {
        let stub = HookTestService()
        let feature = AgentHooksFeatureModel(service: stub)
        await feature.load()
        #expect(feature.entries.first?.hook.event == .turnEnd)
        #expect(feature.entries.first?.configuredAgents == ["codex-acp"])
        feature.query = "结束"
        #expect(feature.entries.count == 1)
        feature.query = "nonexistent"
        #expect(feature.entries.isEmpty)
        #expect(SettingsCategory.hooks.group == .ai)
        #expect(SettingsSearchVocabulary.matches(query: "Timeout", category: .hooks))
    }
}

actor HookTestService: AgentHooksService {
    private var failure = false
    private var saving: (@Sendable () async -> Void)?
    private(set) var writes = 0
    private(set) var reads = 0
    private(set) var lastSaved: AgentHook?
    private(set) var lastRevision: String?
    private(set) var removed: String?
    func setFailure(_ value: Bool) { failure = value }
    func onSave(_ action: @escaping @Sendable () async -> Void) { saving = action }
    struct Failure: LocalizedError { var errorDescription: String? { "Fixture conflict" } }
    /// Draft rules are Core's; the stub only replaces file-backed operations.
    nonisolated func validateDraft(_ hook: AgentHook, timeoutText: String, library: AgentHookLibrary) throws -> AgentHookDraftValidation {
        try RustAgentHooksService(core: RustCoreBridge(), directory: URL(fileURLWithPath: "/fixture/library"))
            .validateDraft(hook, timeoutText: timeoutText, library: library)
    }
    func load() throws -> AgentHookLibrary {
        reads += 1
        if failure { throw Failure() }
        struct Fixture: Decodable { let library: AgentHookLibrary }
        let url = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/agent/hooks-management-v1.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).library
    }
    func save(_ hook: AgentHook, library: AgentHookLibrary) async throws -> AgentHookLibrary {
        if failure { throw Failure() }
        writes += 1; lastSaved = hook; lastRevision = library.revision
        await saving?()
        return AgentHookLibrary(revision: "saved", hooks: library.hooks.filter { $0.id != hook.id }
            + [AgentHookEntry(hook: hook, configuredAgents: [], needsSync: true)], targets: library.targets)
    }
    func remove(id: String, library: AgentHookLibrary) -> AgentHookLibrary {
        removed = id; lastRevision = library.revision
        return AgentHookLibrary(revision: "removed", hooks: library.hooks.filter { $0.id != id }, targets: library.targets)
    }
    func sync(library: AgentHookLibrary) -> AgentHookLibrary { library }
}

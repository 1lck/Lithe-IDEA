import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Agent Hook settings")
@MainActor
struct AgentHooksFeatureModelTests {
    @Test func validatesDraftsWithoutExecutingOrSavingThem() async {
        let stub = HookTestService()
        let feature = AgentHooksFeatureModel(service: stub)
        await feature.load()
        feature.draft = AgentHook(name: "remind", description: "结束提醒", command: "printf done")
        #expect(feature.canSave)
        for name in ["", "../escape", "spaces here", String(repeating: "a", count: 81)] {
            feature.draft?.name = name
            #expect(!feature.canSave)
        }
        feature.draft?.name = "valid_1"
        feature.draft?.timeoutSeconds = 0
        #expect(!feature.canSave)
        feature.draft?.timeoutSeconds = 86400
        #expect(feature.canSave)
        feature.draft?.agents = []
        #expect(!feature.canSave)
        #expect(await stub.writes == 0)
    }

    @Test func failedSaveRetainsTheDraftAndExplicitReloadRefreshesGuards() async {
        let stub = HookTestService()
        let feature = AgentHooksFeatureModel(service: stub)
        await feature.load()
        let draft = AgentHook(name: "new-hook", command: "printf new")
        feature.draft = draft
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

    @Test func mutationsDoNotOverlapAndPartialSynchronizationRemainsVisible() async {
        let stub = HookTestService()
        let feature = AgentHooksFeatureModel(service: stub)
        await feature.load()
        feature.draft = AgentHook(name: "new-hook", command: "printf new")
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

import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Shared instruction synchronization")
@MainActor
struct SharedInstructionsFeatureTests {
    @Test func loadingAndExpandingIsReadOnlyAndKeepsIndependentDrafts() async throws {
        let service = SharedInstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        await feature.loadShared()
        #expect(feature.sharedDraft == "Shared original")
        #expect(feature.files.count == 2)
        feature.toggleEditor(.codex)
        feature.edit("Unsaved native draft")
        feature.toggleEditor(.codex)
        #expect(!feature.isEditorExpanded)
        feature.toggleEditor(.claude)
        feature.toggleEditor(.codex)
        #expect(feature.draft == "Unsaved native draft")
        #expect(!feature.canToggleShared(.codex))
        feature.editShared("New shared text")
        #expect(feature.canSaveShared)
        #expect(!feature.canToggleShared(.claude), "save source changes before switching targets")
        await feature.saveShared()
        #expect(feature.sharedLibrary?.file.content == "New shared text")
        #expect(feature.draft == "Unsaved native draft")
        #expect(await service.operations == ["save"])
    }

    @Test func rapidAgentChoicesUseFreshSnapshotsAndOneFailureDoesNotClearAnotherChoice() async {
        let service = SharedInstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        await feature.loadShared()
        await service.setFailsCodex(true)
        await service.onToggle {
            await MainActor.run {
                #expect(!feature.canToggleShared(.codex))
                #expect(feature.canToggleShared(.claude), "another row stays enabled and retains its native colors")
            }
            await feature.setSharedEnabled(true, agent: .claude)
        }
        await feature.setSharedEnabled(true, agent: .codex)
        #expect(feature.sharedState(.codex)?.enabled == false)
        #expect(feature.sharedState(.claude)?.enabled == true)
        #expect(feature.sharedSyncErrors[.codex] == "External file changed")
        #expect(feature.pendingSharedAgents.isEmpty)
        #expect(await service.operations == ["codex-acp", "claude-acp"])
        await service.setFailsCodex(false)
        await feature.setSharedEnabled(true, agent: .codex)
        #expect(feature.sharedState(.codex)?.enabled == true)
        #expect(feature.sharedSyncErrors[.codex] == nil)
    }

    @Test func sourceConflictsKeepDraftAndFailedReloadDoesNotDiscardIt() async {
        let service = SharedInstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        await feature.loadShared()
        feature.editShared("Keep this shared draft")
        await service.setFailsSource(true)
        await feature.saveShared()
        #expect(feature.sharedPhase == .failed("External file changed"))
        #expect(feature.sharedDraft == "Keep this shared draft")
        await feature.loadShared(reload: true)
        #expect(feature.sharedDraft == "Keep this shared draft")
        await service.setFailsSource(false)
        await feature.loadShared(reload: true)
        #expect(feature.sharedDraft == "Shared original")
        #expect(!feature.isSharedDirty)
    }

    @Test func cancellingTheOwnerDropsQueuedSwitchesAndDoesNotWriteThemLater() async {
        let service = SharedInstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        let started = TestGate(), released = TestGate()
        await service.onToggle {
            started.open()
            let wasReleased = await released.waitUntilOpen()
            if !Task.isCancelled { #expect(wasReleased) }
        }
        await feature.loadShared()
        let task = Task { await feature.setSharedEnabled(true, agent: .codex) }
        defer { released.open(); task.cancel() }
        #expect(await started.waitUntilOpen())
        await feature.setSharedEnabled(true, agent: .claude)
        task.cancel()
        released.open()
        await task.value
        #expect(feature.pendingSharedAgents.isEmpty)
        #expect(feature.sharedState(.claude)?.enabled == false)
        #expect(await service.operations == ["codex-acp"])
    }
}

private actor SharedInstructionsStub: AgentInstructionsService {
    struct Conflict: LocalizedError { var errorDescription: String? { "External file changed" } }
    var operations: [String] = []
    private var text = "Shared original"
    private var enabled: Set<AgentInstructionKind> = []
    private var failsCodex = false, failsSource = false
    private var callback: (@Sendable () async -> Void)?
    func onToggle(_ value: @escaping @Sendable () async -> Void) { callback = value }
    func setFailsCodex(_ value: Bool) { failsCodex = value }
    func setFailsSource(_ value: Bool) { failsSource = value }
    func read(agent: AgentInstructionKind) async throws -> AgentInstructionFile { native(agent) }
    func save(file: AgentInstructionFile, content: String) async throws -> AgentInstructionFile { file }
    func readShared() async throws -> SharedInstructionLibrary {
        if failsSource { throw Conflict() }
        return library()
    }
    func saveShared(content: String, library: SharedInstructionLibrary) async throws -> SharedInstructionLibrary {
        operations.append("save")
        if failsSource { throw Conflict() }
        text = content
        return self.library()
    }
    func setSharedEnabled(_ value: Bool, agent: AgentInstructionKind, library: SharedInstructionLibrary) async throws -> SharedInstructionLibrary {
        operations.append(agent.rawValue)
        let called = callback; callback = nil
        await called?()
        try Task.checkCancellation()
        if failsCodex && agent == .codex { throw Conflict() }
        if value { enabled.insert(agent) } else { enabled.remove(agent) }
        return self.library()
    }
    private func native(_ agent: AgentInstructionKind) -> AgentInstructionFile {
        .init(agentId: agent.rawValue, path: "/fixture/\(agent.rawValue)/instructions.md",
              content: "Own \(agent.title)", exists: true, revision: "native-\(agent.rawValue)")
    }
    private func library() -> SharedInstructionLibrary {
        .init(file: .init(agentId: "shared", path: "/fixture/library/Shared.md", content: text,
                         exists: true, revision: "source-\(text)"),
              agents: AgentInstructionKind.allCases.map { agent in
                SharedInstructionAgent(agentId: agent.rawValue, file: native(agent), enabled: enabled.contains(agent),
                                       needsSync: false, ownLineCount: 1, issue: nil)
              })
    }
}

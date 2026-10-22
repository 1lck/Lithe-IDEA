import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Global Agent instructions")
@MainActor
struct AgentInstructionsFeatureModelTests {
    @Test func draftsAreIndependentAndSurviveNavigation() async {
        let service = InstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        await feature.load()
        feature.edit("Codex draft 中文")
        feature.selectedAgent = .claude
        await feature.load()
        feature.edit("Claude draft")
        feature.selectedAgent = .codex
        await feature.load()
        #expect(feature.draft == "Codex draft 中文")
        #expect(feature.isDirty && feature.canSave)
        #expect(await service.reads == [.codex, .claude])
    }

    @Test func successfulSaveConfirmsNativeResultAndDoesNotOverwriteAnotherAgentDraft() async {
        let service = InstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        await feature.load()
        feature.edit("new global instructions")
        await service.onSave {
            await MainActor.run {
                #expect(feature.phase == .saving)
                #expect(!feature.canSave)
            }
            // A duplicate save and reload must not race the pending write.
            await feature.save()
            await feature.load(reload: true)
            await MainActor.run { feature.selectedAgent = .claude }
            await feature.load()
            await MainActor.run { feature.edit("other draft") }
        }
        await feature.save()
        #expect(feature.selectedAgent == .claude)
        #expect(feature.draft == "other draft")
        #expect(feature.files[.codex]?.content == "new global instructions")
        #expect(feature.saved.contains(.codex))
        #expect(await service.writes == 1)
        feature.selectedAgent = .codex
        #expect(!feature.isDirty)
    }

    @Test func failedSaveKeepsDraftAndExplicitReloadUsesExternalContents() async {
        let service = InstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        await feature.load()
        feature.edit("keep this draft")
        await service.setFailure(.conflict)
        await feature.save()
        #expect(feature.phase == .failed("External file changed"))
        #expect(feature.draft == "keep this draft")
        #expect(feature.file?.content == "Codex original")
        #expect(feature.saved.isEmpty)
        await service.setFailure(nil)
        await service.replaceCodex("External text")
        await feature.load(reload: true)
        #expect(feature.draft == "External text")
        #expect(!feature.isDirty)
    }

    @Test func failedReloadAndFailedInitialLoadAreRetryable() async {
        let service = InstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        await service.setFailure(.read)
        await feature.load()
        #expect(feature.file == nil)
        #expect(!feature.canSave)
        #expect(feature.phase == .failed("Cannot read"))
        await service.setFailure(nil)
        await feature.load()
        feature.edit("draft")
        await service.setFailure(.read)
        await feature.load(reload: true)
        #expect(feature.draft == "draft")
        #expect(feature.file?.content == "Codex original")
    }

    @Test func emptyTextIsSavedAndOversizedTextIsRejectedBeforeNativeWrite() async {
        let service = InstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        await feature.load()
        feature.edit(String(repeating: "文", count: 350_000))
        #expect(!feature.canSave, "the limit counts UTF-8 bytes")
        await feature.save()
        #expect(await service.writes == 0)
        feature.edit("")
        await feature.save()
        #expect(feature.file?.content == "")
        #expect(feature.saved.contains(.codex))
    }

    @Test func nativeReadbackCanSwitchBackFromAnEmptyOverride() async {
        let service = InstructionsStub()
        let feature = AgentInstructionsFeatureModel(service: service)
        await feature.load()
        feature.edit("")
        await service.returnEffectiveBaseAfterSave()
        await feature.save()
        #expect(feature.file?.path == "/fixture/codex/AGENTS.md")
        #expect(feature.draft == "Effective base")
        #expect(!feature.isDirty)
    }
}

private actor InstructionsStub: AgentInstructionsService {
    enum Failure: LocalizedError {
        case read, conflict
        var errorDescription: String? { self == .read ? "Cannot read" : "External file changed" }
    }
    var reads: [AgentInstructionKind] = []
    var writes = 0
    private var failure: Failure?
    private var saveCallback: (@Sendable () async -> Void)?
    private var effectiveBase = false
    private var codexContent = "Codex original"

    func onSave(_ callback: @escaping @Sendable () async -> Void) { saveCallback = callback }
    func setFailure(_ value: Failure?) { failure = value }
    func replaceCodex(_ content: String) { codexContent = content }
    func returnEffectiveBaseAfterSave() { effectiveBase = true }
    func read(agent: AgentInstructionKind) async throws -> AgentInstructionFile {
        reads.append(agent)
        if failure == .read { throw Failure.read }
        return AgentInstructionFile(agentId: agent.rawValue, path: "/fixture/\(agent.id)/instructions.md",
                                    content: agent == .codex ? codexContent : "Claude original", exists: true, revision: "snapshot")
    }
    func save(file: AgentInstructionFile, content: String) async throws -> AgentInstructionFile {
        writes += 1
        let callback = saveCallback
        saveCallback = nil
        await callback?()
        if let failure { throw failure }
        return AgentInstructionFile(agentId: file.agentId,
                                    path: effectiveBase ? "/fixture/codex/AGENTS.md" : file.path,
                                    content: effectiveBase ? "Effective base" : content, exists: true, revision: "saved")
    }
}

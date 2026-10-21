import Foundation
import LitheCoreContracts

/// Settings edits the upstream files directly; drafts survive navigation and failures.
@MainActor
final class AgentInstructionsFeatureModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, saving, failed(String) }

    @Published var selectedAgent: AgentInstructionKind = .codex
    @Published private(set) var files: [AgentInstructionKind: AgentInstructionFile] = [:]
    @Published private(set) var drafts: [AgentInstructionKind: String] = [:]
    @Published private(set) var phases: [AgentInstructionKind: Phase] = [:]
    @Published private(set) var saved: Set<AgentInstructionKind> = []
    private let service: any AgentInstructionsService

    init(service: any AgentInstructionsService) { self.service = service }

    var file: AgentInstructionFile? { files[selectedAgent] }
    var draft: String { drafts[selectedAgent] ?? "" }
    var phase: Phase { phases[selectedAgent] ?? .idle }
    var isBusy: Bool { phase == .loading || phase == .saving }
    var isDirty: Bool { file.map { draft != $0.content } ?? false }
    var canSave: Bool { isDirty && !isBusy && draft.utf8.count <= 1024 * 1024 }

    func edit(_ text: String) {
        guard !isBusy else { return }
        drafts[selectedAgent] = text
        saved.remove(selectedAgent)
    }

    /// Initial loads retain cached drafts. Explicit reload replaces a draft only after success.
    func load(reload: Bool = false) async {
        let agent = selectedAgent
        guard !isBusy, reload || files[agent] == nil else { return }
        phases[agent] = .loading
        do {
            let file = try await service.read(agent: agent)
            files[agent] = file
            drafts[agent] = file.content
            saved.remove(agent)
            phases[agent] = .ready
        } catch is CancellationError {
            phases[agent] = files[agent] == nil ? .idle : .ready
        } catch {
            phases[agent] = .failed(error.localizedDescription)
        }
    }

    func save() async {
        let agent = selectedAgent
        guard canSave, let file = files[agent] else { return }
        let content = drafts[agent] ?? ""
        phases[agent] = .saving
        do {
            let updated = try await service.save(file: file, content: content)
            files[agent] = updated
            // Text controls are disabled during save; selection may still change.
            drafts[agent] = updated.content
            saved.insert(agent)
            phases[agent] = .ready
        } catch {
            phases[agent] = .failed(error.localizedDescription)
        }
    }
}

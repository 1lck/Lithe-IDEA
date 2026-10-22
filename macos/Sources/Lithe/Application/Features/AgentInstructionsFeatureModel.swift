import Foundation
import LitheCoreContracts

/// Settings edits the upstream files directly; drafts survive navigation and failures.
@MainActor
final class AgentInstructionsFeatureModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, saving, failed(String) }

    @Published var selectedAgent: AgentInstructionKind = .codex
    @Published private(set) var isEditorExpanded = false
    @Published private(set) var files: [AgentInstructionKind: AgentInstructionFile] = [:]
    @Published private(set) var drafts: [AgentInstructionKind: String] = [:]
    @Published private(set) var phases: [AgentInstructionKind: Phase] = [:]
    @Published private(set) var saved: Set<AgentInstructionKind> = []
    @Published private(set) var sharedLibrary: SharedInstructionLibrary?
    @Published private(set) var sharedDraft = ""
    @Published private(set) var sharedPhase: Phase = .idle
    @Published private(set) var sharedSaved = false
    @Published private(set) var pendingSharedAgents: Set<AgentInstructionKind> = []
    @Published private(set) var sharedSyncErrors: [AgentInstructionKind: String] = [:]
    private var sharedSwitches: [(AgentInstructionKind, Bool)] = []
    private var drainsSharedSwitches = false
    private let service: any AgentInstructionsService

    init(service: any AgentInstructionsService) { self.service = service }

    var file: AgentInstructionFile? { files[selectedAgent] }
    var draft: String { drafts[selectedAgent] ?? "" }
    var phase: Phase { phases[selectedAgent] ?? .idle }
    var isBusy: Bool { phase == .loading || phase == .saving }
    var isDirty: Bool { file.map { draft != $0.content } ?? false }
    var canSave: Bool { isDirty && !isBusy && !isSharedBusy && draft.utf8.count <= 1024 * 1024 }

    var isSharedBusy: Bool { sharedPhase == .loading || sharedPhase == .saving }
    var isSharedDirty: Bool { sharedLibrary.map { sharedDraft != $0.file.content } ?? false }
    var canSaveShared: Bool { sharedLibrary != nil && isSharedDirty && !isSharedBusy
        && !phases.values.contains(.saving) && sharedDraft.utf8.count <= 1024 * 1024 }

    func sharedState(_ agent: AgentInstructionKind) -> SharedInstructionAgent? {
        sharedLibrary?.agents.first { $0.agentId == agent.rawValue }
    }

    func canToggleShared(_ agent: AgentInstructionKind) -> Bool {
        (!isSharedBusy || drainsSharedSwitches) && !pendingSharedAgents.contains(agent)
            && !isSharedDirty && phases[agent] != .saving
            && drafts[agent] == files[agent]?.content && sharedState(agent)?.enabled != nil
    }

    func editShared(_ text: String) {
        guard !isSharedBusy else { return }
        sharedDraft = text
        sharedSaved = false
    }

    func loadShared(reload: Bool = false) async {
        guard !isSharedBusy, !phases.values.contains(.saving) else { return }
        let retainedFile = !reload && isSharedDirty ? sharedLibrary?.file : nil
        sharedPhase = .loading
        do {
            let library = try await service.readShared()
            // Navigation refreshes real switch state, but only explicit reload
            // replaces an unsaved shared draft and its original conflict guard.
            applyShared(retainedFile.map { SharedInstructionLibrary(file: $0, agents: library.agents) } ?? library)
            if retainedFile == nil { sharedDraft = library.file.content }
            sharedSaved = false
            sharedSyncErrors.removeAll()
            sharedPhase = .ready
        } catch is CancellationError { sharedPhase = .idle }
        catch { sharedPhase = .failed(error.localizedDescription) }
    }

    func saveShared() async {
        guard canSaveShared, let library = sharedLibrary else { return }
        sharedPhase = .saving
        do {
            applyShared(try await service.saveShared(content: sharedDraft, library: library))
            sharedSaved = true
            sharedPhase = .ready
        } catch { sharedPhase = .failed(error.localizedDescription) }
    }

    func setSharedEnabled(_ enabled: Bool, agent: AgentInstructionKind) async {
        guard canToggleShared(agent), sharedLibrary != nil else { return }
        pendingSharedAgents.insert(agent)
        sharedSwitches.append((agent, enabled))
        guard !drainsSharedSwitches else { return }
        drainsSharedSwitches = true
        defer {
            drainsSharedSwitches = false
            pendingSharedAgents.removeAll()
            sharedSwitches.removeAll()
        }
        // The first view-owned task drains the queue. Later rows stay interactive
        // and use the preceding operation's fresh native/source revisions.
        while !sharedSwitches.isEmpty, !Task.isCancelled {
            let (target, value) = sharedSwitches.removeFirst()
            guard let library = sharedLibrary else { break }
            sharedPhase = .saving
            do {
                applyShared(try await service.setSharedEnabled(value, agent: target, library: library))
                sharedSyncErrors.removeValue(forKey: target)
            } catch { sharedSyncErrors[target] = error.localizedDescription }
            pendingSharedAgents.remove(target)
            sharedPhase = .ready
        }
    }

    private func applyShared(_ library: SharedInstructionLibrary) {
        sharedLibrary = library
        for agent in AgentInstructionKind.allCases {
            guard let updated = sharedState(agent)?.file else { continue }
            // A shared update never overwrites an independent native-file draft.
            guard files[agent] == nil || drafts[agent] == files[agent]?.content else { continue }
            files[agent] = updated
            drafts[agent] = updated.content
            phases[agent] = .ready
        }
    }

    func edit(_ text: String) {
        guard !isBusy, !isSharedBusy else { return }
        drafts[selectedAgent] = text
        saved.remove(selectedAgent)
    }

    func toggleEditor(_ agent: AgentInstructionKind) {
        isEditorExpanded = selectedAgent == agent ? !isEditorExpanded : true
        selectedAgent = agent
    }

    /// Listing both files is read-only. One unavailable Agent must not hide the other.
    func loadAll() async {
        for agent in AgentInstructionKind.allCases {
            guard !Task.isCancelled else { return }
            await load(agent: agent)
        }
    }

    /// Initial loads retain cached drafts. Explicit reload replaces a draft only after success.
    func load(reload: Bool = false) async {
        await load(agent: selectedAgent, reload: reload)
    }

    private func load(agent: AgentInstructionKind, reload: Bool = false) async {
        let phase = phases[agent] ?? .idle
        guard phase != .loading, phase != .saving, reload || files[agent] == nil else { return }
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
            if sharedLibrary != nil {
                do { applyShared(try await service.readShared()) }
                catch { sharedPhase = .failed(error.localizedDescription) }
            }
        } catch {
            phases[agent] = .failed(error.localizedDescription)
        }
    }
}

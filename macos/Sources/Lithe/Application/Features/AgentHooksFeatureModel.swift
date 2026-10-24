import Foundation
import LitheCoreContracts

/// Owns drafts and observable synchronization outcomes; native execution stays upstream.
@MainActor
final class AgentHooksFeatureModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, saving, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var library: AgentHookLibrary?
    @Published var draft: AgentHook?
    @Published var query = ""
    private let service: any AgentHooksService

    init(service: any AgentHooksService) { self.service = service }
    var isBusy: Bool { phase == .loading || phase == .saving }
    var entries: [AgentHookEntry] {
        (library?.hooks ?? []).filter { entry in
            query.isEmpty || [entry.hook.name, entry.hook.description, entry.hook.command].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    var canSave: Bool {
        guard let draft, library != nil, !isBusy else { return false }
        return !draft.name.isEmpty && draft.name.utf8.count <= 80
            && draft.name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
            && draft.description.unicodeScalars.count <= 200 && !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.command.utf8.count <= 32768 && !draft.command.contains("\0") && !draft.agents.isEmpty
            && (draft.timeoutSeconds == nil || (1...86400).contains(draft.timeoutSeconds!))
            && !(library?.hooks.contains { $0.id != draft.id && $0.hook.name.caseInsensitiveCompare(draft.name) == .orderedSame } ?? false)
    }

    func load() async {
        guard !isBusy else { return }
        phase = .loading
        do { library = try await service.load(); phase = .ready }
        catch is CancellationError { phase = .idle }
        catch { phase = .failed(error.localizedDescription) }
    }
    func save() async {
        guard canSave, let draft, let library else { return }
        phase = .saving
        do {
            self.library = try await service.save(draft, library: library)
            self.draft = nil
            phase = .ready
        } catch is CancellationError { phase = .idle }
        catch { phase = .failed(error.localizedDescription) }
    }
    func setEnabled(_ enabled: Bool, entry: AgentHookEntry) async {
        guard !isBusy, let library, !entry.hook.pendingRemoval else { return }
        var hook = entry.hook
        hook.enabled = enabled
        phase = .saving
        do { self.library = try await service.save(hook, library: library); phase = .ready }
        catch is CancellationError { phase = .idle }
        catch { phase = .failed(error.localizedDescription) }
    }
    func remove(_ entry: AgentHookEntry) async {
        guard !isBusy, let library else { return }
        phase = .saving
        do { self.library = try await service.remove(id: entry.id, library: library); phase = .ready }
        catch is CancellationError { phase = .idle }
        catch { phase = .failed(error.localizedDescription) }
    }
    func sync() async {
        guard !isBusy, let library else { return }
        phase = .saving
        do { self.library = try await service.sync(library: library); phase = .ready }
        catch is CancellationError { phase = .idle }
        catch { phase = .failed(error.localizedDescription) }
    }
}

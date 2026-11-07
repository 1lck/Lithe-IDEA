import Foundation
import LitheCoreContracts

/// Owns drafts and observable synchronization outcomes; native execution stays upstream.
@MainActor
final class AgentHooksFeatureModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, saving, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var library: AgentHookLibrary? { didSet { revalidate() } }
    @Published var draft: AgentHook? { didSet { revalidate() } }
    /// Raw timeout text; Core parses it so the integer and range rules have one owner.
    @Published var timeoutText = "" { didSet { revalidate() } }
    /// Core's field-level verdict for the current draft; `nil` without a draft or library.
    @Published private(set) var draftValidation: AgentHookDraftValidation?
    @Published var query = ""
    private let service: any AgentHooksService

    init(service: any AgentHooksService) { self.service = service }
    var isBusy: Bool { phase == .loading || phase == .saving }
    var entries: [AgentHookEntry] {
        (library?.hooks ?? []).filter { entry in
            query.isEmpty || [entry.hook.name, entry.hook.description, entry.hook.command].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    var canSave: Bool { draft != nil && library != nil && !isBusy && draftValidation?.valid == true }

    /// Starts editing `hook`, seeding the timeout field from its stored value.
    func beginEditing(_ hook: AgentHook) {
        timeoutText = hook.timeoutSeconds.map(String.init) ?? ""
        draft = hook
    }

    private func revalidate() {
        guard let draft, let library else { draftValidation = nil; return }
        do { draftValidation = try service.validateDraft(draft, timeoutText: timeoutText, library: library) }
        catch {
            // log-exempt: 同一次失败已经记录过：Core 请求轨迹已记录 agent.hooks.validateDraft 的失败，保存按钮保持禁用
            draftValidation = nil
        }
    }

    func load() async {
        guard !isBusy else { return }
        phase = .loading
        do { library = try await service.load(); phase = .ready }
        catch is CancellationError { phase = .idle }
        catch { phase = .failed(error.localizedDescription) }
    }
    func save() async {
        guard canSave, var draft, let library, let validation = draftValidation else { return }
        draft.timeoutSeconds = validation.timeoutSeconds
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

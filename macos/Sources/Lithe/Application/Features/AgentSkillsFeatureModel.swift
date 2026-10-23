import Foundation
import LitheCoreContracts

/// Settings-only state. Discovery and file management never start a conversation.
@MainActor
final class AgentSkillsFeatureModel: ObservableObject {
    struct Context: Equatable { let workspace: URL? }
    struct Item: Identifiable, Equatable {
        let agentID: String
        let source: String
        let skill: AgentSkill
        var id: String { agentID + ":" + skill.id }
        var agentName: String { agentID == "codex-acp" ? "Codex" : "Claude" }
    }
    enum Phase: Equatable { case idle, loading, ready, failed }
    struct PendingEnablement {
        let item: Item
        let enabled: Bool
        var itemID: String { item.id }
    }
    static let agents = ["codex-acp", "claude-acp"]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var listings: [String: AgentSkillListing] = [:]
    @Published private(set) var directories: [String: [String: String]] = [:]
    @Published private(set) var discoveryErrors: [String: String] = [:]
    @Published private(set) var error: String?
    @Published private(set) var savedURL: URL?
    @Published private(set) var isWriting = false
    @Published private(set) var pendingEnablements: [PendingEnablement] = []
    @Published private(set) var didChangeEnablement = false
    @Published var query = ""
    @Published var scope = "user"
    @Published var agentFilter = "all"
    private let service: any AgentManagementService
    private var context: Context?
    private var revision = UUID()
    private var writeTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(service: any AgentManagementService) { self.service = service }

    private var matchingItems: [Item] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.agents.filter { agentFilter == "all" || agentFilter == $0 }.flatMap { agentID -> [Item] in
            guard let listing = listings[agentID] else { return [Item]() }
            return listing.skills.map { Item(agentID: agentID, source: listing.source, skill: $0) }
        }.filter { item in
            query.isEmpty || [item.skill.name, item.skill.description, item.skill.path]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted {
            ($0.skill.name.lowercased(), $0.agentID, $0.skill.path) < ($1.skill.name.lowercased(), $1.agentID, $1.skill.path)
        }
    }

    func count(in scope: String) -> Int { matchingItems.filter { belongs($0, to: scope) }.count }
    var visibleItems: [Item] { matchingItems.filter { belongs($0, to: scope) } }
    /// Display the user's choice immediately without replacing confirmed native state.
    func displayedEnablement(for item: Item) -> Bool? {
        if let pending = pendingEnablements.first(where: { $0.itemID == item.id }) { return pending.enabled }
        return item.skill.enabled
    }
    func canChangeEnablement(for item: Item) -> Bool {
        phase != .loading && (!isWriting || !pendingEnablements.isEmpty)
            && !pendingEnablements.contains(where: { $0.itemID == item.id })
    }
    private func belongs(_ item: Item, to scope: String) -> Bool {
        scope == "repo" ? (context?.workspace != nil && item.skill.scope == "repo") : ["user", "system", "admin"].contains(item.skill.scope)
    }

    func directory(agentID: String, scope: String) -> String? { directories[agentID]?[scope] }

    func read(_ item: Item) async throws -> String {
        try await service.readSkill(at: URL(fileURLWithPath: item.skill.path), agentID: item.agentID)
    }

    func reload(_ next: Context) {
        guard !isWriting else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh(next) }
    }

    func refresh(_ next: Context) async {
        // A manual refresh must not invalidate a write in the same context.
        guard !isWriting || context != next else { return }
        if context != next {
            writeTask?.cancel(); writeTask = nil; isWriting = false
            pendingEnablements = []; didChangeEnablement = false
            listings = [:]; directories = [:]; discoveryErrors = [:]; savedURL = nil
        }
        context = next
        let token = UUID(); revision = token
        error = nil; phase = .loading
        let service = service
        // A missing Codex CLI must not suppress the independently available Claude inventory.
        async let codex = Self.load(service, agentID: "codex-acp", workspace: next.workspace)
        async let claude = Self.load(service, agentID: "claude-acp", workspace: next.workspace)
        async let codexDirectories = Self.loadDirectories(service, agentID: "codex-acp", workspace: next.workspace)
        async let claudeDirectories = Self.loadDirectories(service, agentID: "claude-acp", workspace: next.workspace)
        let results = await [codex, claude]
        let paths = await [codexDirectories, claudeDirectories]
        guard !Task.isCancelled, revision == token else { return }
        for (index, agentID) in Self.agents.enumerated() {
            let result = results[index]
            switch result {
            case .success(let listing): listings[agentID] = listing; discoveryErrors[agentID] = nil
            case .failure(let reason): discoveryErrors[agentID] = reason.message
            }
            switch paths[index] {
            case .success(let paths): directories[agentID] = paths
            case .failure(let reason):
                directories[agentID] = listings[agentID]?.directories ?? [:]
                discoveryErrors[agentID] = [discoveryErrors[agentID], reason.message].compactMap { $0 }.joined(separator: "\n")
            }
        }
        phase = discoveryErrors.count == Self.agents.count ? .failed : .ready
    }

    private nonisolated static func loadDirectories(_ service: any AgentManagementService, agentID: String, workspace: URL?) async -> Result<[String: String], Failure> {
        // Destination lookup creates no files and needs no CLI.
        do { return .success(try await service.skillDirectories(agentID: agentID, workspace: workspace)) }
        catch { return .failure(Failure(message: error.localizedDescription)) }
    }

    private struct Failure: Error { let message: String }
    private nonisolated static func load(_ service: any AgentManagementService, agentID: String, workspace: URL?) async -> Result<AgentSkillListing, Failure> {
        do { return .success(try await service.listSkills(agentID: agentID, workspace: workspace)) }
        catch { return .failure(Failure(message: error.localizedDescription)) }
    }

    /// Capture the project before awaiting; switching projects invalidates delayed results.
    func setEnabled(_ enabled: Bool, for item: Item, context expected: Context) {
        guard canChangeEnablement(for: item), context == expected,
              item.skill.enabled != nil, item.skill.enabled != enabled,
              listings[item.agentID]?.skills.contains(item.skill) == true else { return }
        pendingEnablements.append(.init(item: item, enabled: enabled))
        guard !isWriting else { return }
        isWriting = true; error = nil; didChangeEnablement = false
        let token = UUID(); revision = token
        let service = service
        writeTask = Task { [weak self] in
            // Serialize native read/write/read exchanges while only locking the rows awaiting confirmation.
            while let pending = self?.pendingEnablements.first {
                guard !Task.isCancelled, self?.revision == token else { return }
                let item = pending.item
                let request = AgentSkillEnablement(agentID: item.agentID, workspace: expected.workspace,
                                                  skill: item.skill, enabled: pending.enabled)
                do {
                    let listing = try await service.setSkillEnabled(request)
                    guard let self, !Task.isCancelled, self.revision == token else { return }
                    self.listings[item.agentID] = listing
                    self.discoveryErrors[item.agentID] = nil
                } catch {
                    guard let self, !Task.isCancelled, self.revision == token else { return }
                    self.error = error.localizedDescription
                }
                self?.pendingEnablements.removeFirst()
            }
            guard let self, !Task.isCancelled, self.revision == token else { return }
            self.isWriting = false; self.didChangeEnablement = self.error == nil; self.writeTask = nil
        }
    }

    func write(_ request: AgentSkillWrite, context expected: Context) {
        guard !isWriting, context == expected, phase != .loading else { return }
        isWriting = true; error = nil; savedURL = nil
        let token = UUID(); revision = token
        let service = service
        writeTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let url = try await service.writeSkill(request)
                guard let self, !Task.isCancelled, self.revision == token else { return }
                self.savedURL = url; self.isWriting = false
                await self.refresh(expected)
                if self.context == expected { self.writeTask = nil }
            } catch {
                guard let self, !Task.isCancelled, self.revision == token else { return }
                self.error = error.localizedDescription; self.isWriting = false; self.writeTask = nil
            }
        }
    }

    func dismissResult() { savedURL = nil; error = nil; didChangeEnablement = false }
    func cancel() {
        revision = UUID(); writeTask?.cancel(); writeTask = nil; refreshTask?.cancel(); refreshTask = nil; isWriting = false
        pendingEnablements = []; didChangeEnablement = false
        if phase == .loading { phase = .idle }
    }
}

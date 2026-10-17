import Combine
import Foundation

/// One discovered definition in one Agent configuration file.
struct McpServerSource: Hashable, Identifiable {
    let file: McpConfigurationFile
    let definitionHash: String
    /// True when the ledger records Lithe as the writer of this exact entry.
    let isOwnedByLithe: Bool

    var id: String { McpServerLibraryFeatureModel.identity(of: file) }
}

/// A server definition merged across the Agent configuration files.
///
/// Entries are grouped by name and definition hash: the same server registered
/// with both Agents becomes one row, while a same-name entry with a different
/// definition stays a separate row so editing one never silently rewrites the
/// other.
struct McpServerRow: Identifiable, Equatable {
    let id: String
    let definition: McpServerDefinition
    let sources: [McpServerSource]
    /// Another global entry with the same name has a different definition.
    let hasDefinitionConflict: Bool

    var name: String { definition.name }

    var globalSources: [McpServerSource] {
        sources.filter { $0.file.scope == .global }
    }

    var enabledGlobalAgents: Set<McpAgent> {
        Set(globalSources.map(\.file.agent))
    }

    var ownedGlobalAgents: Set<McpAgent> {
        Set(globalSources.filter(\.isOwnedByLithe).map(\.file.agent))
    }

    /// Project entries are owned by the project grant and are not edited here.
    var isProjectOnly: Bool { globalSources.isEmpty }

    var isLitheRegistration: Bool {
        definition.name == "lithe" && sources.contains { $0.file.scope == .project }
    }

    /// Compact one-line description for the list.
    var summary: String {
        switch definition.transport {
        case .stdio:
            let parts = [definition.command ?? ""] + definition.args
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        case .http, .sse:
            return definition.url ?? ""
        }
    }
}

/// Editable copy of one row.
struct McpServerDraft: Equatable {
    /// Row being edited; `nil` while adding a server.
    var originalRowID: String?
    var originalName: String?
    var name: String = ""
    var transport: McpTransport = .stdio
    var command: String = ""
    var url: String = ""
    /// One argument per line preserves arguments that contain spaces.
    var argumentsText: String = ""
    var env: [McpKeyValue] = []
    var headers: [McpKeyValue] = []
    var enabledAgents: Set<McpAgent> = []

    var isNew: Bool { originalRowID == nil }

    var arguments: [String] {
        argumentsText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    init() {}

    init(row: McpServerRow) {
        originalRowID = row.id
        originalName = row.name
        name = row.definition.name
        transport = row.definition.transport
        command = row.definition.command ?? ""
        url = row.definition.url ?? ""
        argumentsText = row.definition.args.joined(separator: "\n")
        env = row.definition.env
        headers = row.definition.headers
        enabledAgents = row.enabledGlobalAgents
    }
}

/// Project-level Lithe registration outcome, shown next to the access section.
enum LitheProjectRegistrationState: Equatable {
    case inactive
    case registered
    /// Some Agent configuration was left untouched; carries the reason.
    case needsAttention(String)
}

/// Errors surfaced by library actions. Messages never include secret values.
enum McpLibraryError: LocalizedError {
    case unavailable
    case agentHasNoGlobalConfiguration
    case notOwned(String)
    case externallyModified(String)
    case invalidDraft(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "MCP configuration management is unavailable.")
        case .agentHasNoGlobalConfiguration:
            String(localized: "This Agent has no global MCP configuration file.")
        case .notOwned(let name):
            String(
                format: String(localized: "“%@” was created outside Lithe. Take ownership before changing it."),
                name
            )
        case .externallyModified(let name):
            String(
                format: String(localized: "“%@” changed outside Lithe. Refresh and try again."),
                name
            )
        case .invalidDraft(let message):
            message
        }
    }
}

/// Application dependencies used by the MCP library.
@MainActor
protocol McpServerLibraryActions: AnyObject {
    var mcpConfigurationStore: (any McpConfigurationStore)? { get }
    var mcpWorkspaceURL: URL? { get }
    var mcpLedgerStore: any KeyValueStore { get }
}

/// Discovers, edits and removes MCP servers registered with Codex and Claude Code.
///
/// Core plans every write against the ownership ledger; this model stages all
/// plans before touching disk so a conflict on the second Agent never leaves the
/// first Agent half written. Secrets are held only in memory and are never
/// included in errors.
@MainActor
final class McpServerLibraryFeatureModel: ObservableObject {
    @Published private(set) var rows: [McpServerRow] = []
    @Published private(set) var isAvailable = false
    @Published private(set) var loadErrors: [String] = []
    @Published private(set) var litheRegistration: LitheProjectRegistrationState = .inactive
    @Published private(set) var litheRegisteredAgents: Set<McpAgent> = []
    /// Most recent successful write, so the page can point at the backup.
    @Published private(set) var lastBackupURL: URL?
    @Published var error: String?

    private weak var model: (any McpServerLibraryActions)?
    private var ledger: [String: [McpOwnedEntry]] = [:]
    private var hasLoaded = false
    private static let ledgerKey = "settings.mcpServerRegistrations"

    init(model: any McpServerLibraryActions) {
        self.model = model
        loadLedger()
    }

    // MARK: - Discovery

    nonisolated static func identity(of file: McpConfigurationFile) -> String {
        "\(file.agent.rawValue)|\(file.scope.rawValue)|\(file.projectPath ?? "")"
    }

    func refreshIfNeeded() {
        guard !hasLoaded else { return }
        refresh()
    }

    func refresh() {
        guard let store = model?.mcpConfigurationStore else {
            isAvailable = false
            rows = []
            return
        }
        isAvailable = true
        let files = store.configurationFiles(workspace: model?.mcpWorkspaceURL)
        var grouped: [String: (definition: McpServerDefinition, sources: [McpServerSource])] = [:]
        var globalHashesByName: [String: Set<String>] = [:]
        var errors: [String] = []

        for file in files {
            do {
                let content = try store.read(file) ?? ""
                for server in try store.parse(file, content: content) {
                    let key = "\(server.name)#\(server.definitionHash)"
                    let source = McpServerSource(
                        file: file,
                        definitionHash: server.definitionHash,
                        isOwnedByLithe: isOwned(server, in: file)
                    )
                    if var entry = grouped[key] {
                        entry.sources.append(source)
                        grouped[key] = entry
                    } else {
                        grouped[key] = (server, [source])
                    }
                    if file.scope == .global {
                        globalHashesByName[server.name, default: []].insert(server.definitionHash)
                    }
                }
            } catch {
                errors.append(String(
                    format: String(localized: "Could not read %@: %@"),
                    file.url.path,
                    error.localizedDescription
                ))
            }
        }

        loadErrors = errors
        rows = grouped.values.map { entry in
            McpServerRow(
                id: "\(entry.definition.name)#\(entry.definition.definitionHash)",
                definition: entry.definition,
                sources: entry.sources,
                hasDefinitionConflict: (globalHashesByName[entry.definition.name]?.count ?? 0) > 1
            )
        }
        .sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            if order != .orderedSame { return order == .orderedAscending }
            if left.isProjectOnly != right.isProjectOnly { return !left.isProjectOnly }
            return left.definition.definitionHash < right.definition.definitionHash
        }
        hasLoaded = true
    }

    /// Files a save writes to, shown in the editor before committing.
    func destinationURLs(for draft: McpServerDraft) -> [URL] {
        guard let store = model?.mcpConfigurationStore else { return [] }
        return store.configurationFiles(workspace: model?.mcpWorkspaceURL)
            .filter { $0.scope == .global && draft.enabledAgents.contains($0.agent) }
            .map(\.url)
    }

    // MARK: - Drafts

    func makeDraft() -> McpServerDraft { McpServerDraft() }

    func draft(for row: McpServerRow) -> McpServerDraft { McpServerDraft(row: row) }

    /// Returns a user-facing reason when the draft cannot be saved.
    func validationMessage(for draft: McpServerDraft) -> String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return String(localized: "Enter a server name.")
        }
        if name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) == nil {
            return String(localized: "Use letters, digits, dots, dashes or underscores. The name must start with a letter or digit.")
        }
        if draft.enabledAgents.isEmpty {
            return String(localized: "Choose at least one Agent.")
        }
        switch draft.transport {
        case .stdio:
            if draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(localized: "Enter the command that starts this server.")
            }
        case .http, .sse:
            let url = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
                return String(localized: "Enter a complete server URL.")
            }
        }
        return nil
    }

    // MARK: - Mutations

    /// Creates or updates a server in every global configuration it is enabled in.
    @discardableResult
    func save(_ draft: McpServerDraft) -> Bool {
        guard let store = model?.mcpConfigurationStore else {
            error = McpLibraryError.unavailable.localizedDescription
            return false
        }
        if let message = validationMessage(for: draft) {
            error = message
            return false
        }
        error = nil
        let files = store.configurationFiles(workspace: model?.mcpWorkspaceURL)
            .filter { $0.scope == .global }
        let targetFiles = files.filter { draft.enabledAgents.contains($0.agent) }
        let original = draft.originalRowID.flatMap { id in rows.first { $0.id == id } }

        var definition = McpServerDefinition(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: draft.transport,
            command: nil,
            args: draft.arguments,
            env: sorted(draft.env),
            url: nil,
            headers: []
        )
        switch draft.transport {
        case .stdio:
            definition.command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        case .http, .sse:
            definition.url = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
            definition.headers = sorted(draft.headers)
        }

        var operations: [McpConfigurationFile: [Operation]] = [:]
        if let original {
            // Renaming or turning an Agent off removes the entry Lithe wrote
            // there; a same-name entry edited outside Lithe refuses the plan.
            for source in original.globalSources
            where !draft.enabledAgents.contains(source.file.agent)
                || original.name != definition.name {
                operations[source.file, default: []].append(.remove(original.name))
            }
        }
        for file in targetFiles {
            // An explicit edit of the entry the user opened may replace a
            // definition Lithe did not write, but only while the on-disk hash
            // still matches the row that was shown. A stale row refuses.
            let expected = original?.globalSources.first { $0.file == file }?.definitionHash
            operations[file, default: []].append(.set(definition, expectedHash: expected))
        }

        do {
            try commit(operations, store: store)
        } catch {
            self.error = error.localizedDescription
            refresh()
            return false
        }
        refresh()
        return true
    }

    /// Adds or removes one definition in a single Agent's global configuration.
    @discardableResult
    func setAgent(_ agent: McpAgent, enabled: Bool, for row: McpServerRow) -> Bool {
        guard let store = model?.mcpConfigurationStore else {
            error = McpLibraryError.unavailable.localizedDescription
            return false
        }
        guard let file = store.configurationFiles(workspace: model?.mcpWorkspaceURL)
            .first(where: { $0.scope == .global && $0.agent == agent }) else {
            error = McpLibraryError.agentHasNoGlobalConfiguration.localizedDescription
            return false
        }
        error = nil
        let operation: Operation = enabled
            ? .set(row.definition, expectedHash: nil)
            : .remove(row.name)
        do {
            try commit([file: [operation]], store: store)
        } catch {
            self.error = error.localizedDescription
            refresh()
            return false
        }
        refresh()
        return true
    }

    /// Removes a server from every global configuration that Lithe owns it in.
    @discardableResult
    func delete(_ row: McpServerRow) -> Bool {
        guard let store = model?.mcpConfigurationStore else {
            error = McpLibraryError.unavailable.localizedDescription
            return false
        }
        error = nil
        guard !row.globalSources.isEmpty else {
            error = McpLibraryError.notOwned(row.name).localizedDescription
            return false
        }
        var operations: [McpConfigurationFile: [Operation]] = [:]
        for source in row.globalSources {
            operations[source.file, default: []].append(.remove(row.name))
        }
        do {
            try commit(operations, store: store)
        } catch {
            self.error = error.localizedDescription
            refresh()
            return false
        }
        refresh()
        return true
    }

    /// Records an externally created entry as Lithe-managed without touching the
    /// file, after which the per-Agent switch can remove or replace it.
    func takeOwnership(of row: McpServerRow, agent: McpAgent) {
        guard let source = row.globalSources.first(where: { $0.file.agent == agent }),
              !source.isOwnedByLithe else { return }
        error = nil
        var entries = ledgerEntries(for: source.file)
        entries.removeAll { $0.name == row.name }
        entries.append(McpOwnedEntry(name: row.name, definitionHash: source.definitionHash))
        setLedger(entries, for: source.file)
        refresh()
    }

    // MARK: - Lithe project registration

    /// Writes Lithe's own MCP server into the open project's Codex and Claude
    /// configuration. Called when the project grant is enabled.
    func registerLitheServer(_ server: McpServerDefinition) {
        guard let store = model?.mcpConfigurationStore,
              let workspace = model?.mcpWorkspaceURL else { return }
        let files = store.configurationFiles(workspace: workspace)
            .filter { $0.scope == .project }
        var registered: Set<McpAgent> = []
        var messages: [String] = []

        for file in files {
            do {
                let existing = try store.read(file)
                let content = existing ?? ""
                let entries = ledgerEntries(for: file)
                let plan = try store.planWrite(
                    request(
                        for: file,
                        content: content,
                        operation: "set",
                        server: server,
                        name: nil,
                        owned: entries
                    ),
                    for: file
                )
                if let conflict = plan.conflict {
                    messages.append(conflictMessage(conflict, name: server.name, file: file))
                    continue
                }
                if plan.changed {
                    lastBackupURL = try store.write(plan.content, to: file).backupURL
                    // Lithe created the project Codex file; keep it out of the
                    // repository without editing the tracked .gitignore.
                    if file.agent == .codex, existing == nil {
                        try store.excludeFromVersionControl(".codex/config.toml", workspace: workspace)
                    }
                }
                if let hash = plan.definitionHash {
                    var updated = entries
                    updated.removeAll { $0.name == server.name }
                    updated.append(McpOwnedEntry(name: server.name, definitionHash: hash))
                    setLedger(updated, for: file)
                }
                registered.insert(file.agent)
            } catch {
                messages.append(String(
                    format: String(localized: "Could not register Lithe MCP in %@: %@"),
                    file.url.path,
                    error.localizedDescription
                ))
            }
        }

        litheRegisteredAgents = registered
        if let message = messages.first {
            litheRegistration = .needsAttention(message)
        } else {
            litheRegistration = registered.isEmpty ? .inactive : .registered
        }
        refresh()
    }

    /// Removes the project-level Lithe entry when the grant is disabled or the
    /// project closes. Entries edited outside Lithe are kept and reported.
    func unregisterLitheServer() {
        guard let store = model?.mcpConfigurationStore,
              let workspace = model?.mcpWorkspaceURL else {
            litheRegisteredAgents = []
            litheRegistration = .inactive
            return
        }
        let files = store.configurationFiles(workspace: workspace)
            .filter { $0.scope == .project }
        var messages: [String] = []

        for file in files {
            let entries = ledgerEntries(for: file)
            guard entries.contains(where: { $0.name == "lithe" }) else { continue }
            do {
                let content = try store.read(file) ?? ""
                let plan = try store.planWrite(
                    request(
                        for: file,
                        content: content,
                        operation: "remove",
                        server: nil,
                        name: "lithe",
                        owned: entries
                    ),
                    for: file
                )
                if let conflict = plan.conflict {
                    messages.append(conflictMessage(conflict, name: "lithe", file: file))
                    continue
                }
                if plan.changed {
                    lastBackupURL = try store.write(plan.content, to: file).backupURL
                }
                var updated = entries
                updated.removeAll { $0.name == "lithe" }
                setLedger(updated, for: file)
            } catch {
                messages.append(String(
                    format: String(localized: "Could not remove Lithe MCP from %@: %@"),
                    file.url.path,
                    error.localizedDescription
                ))
            }
        }

        litheRegisteredAgents = []
        litheRegistration = messages.first.map { .needsAttention($0) } ?? .inactive
        refresh()
    }

    // MARK: - Planning and writing

    private enum Operation {
        /// `expectedHash` is the definition the user was shown for an explicit
        /// edit; it authorizes replacing an entry Lithe did not write.
        case set(McpServerDefinition, expectedHash: String?)
        case remove(String)
    }

    private func request(
        for file: McpConfigurationFile,
        content: String,
        operation: String,
        server: McpServerDefinition?,
        name: String?,
        owned: [McpOwnedEntry]
    ) -> McpWriteRequest {
        McpWriteRequest(
            source: file.agent.sourceName,
            scope: file.scope.rawValue,
            projectPath: file.projectPath,
            content: content,
            operation: operation,
            server: server,
            name: name,
            owned: owned
        )
    }

    /// Plans every operation against the current bytes first, then writes the
    /// changed files. A conflict anywhere aborts before disk is touched.
    private func commit(
        _ operations: [McpConfigurationFile: [Operation]],
        store: any McpConfigurationStore
    ) throws {
        var planned: [(file: McpConfigurationFile, content: String, entries: [McpOwnedEntry], changed: Bool)] = []
        for (file, fileOperations) in operations {
            var content = try store.read(file) ?? ""
            var entries = ledgerEntries(for: file)
            var changed = false
            for operation in fileOperations {
                let plan: McpWritePlan
                switch operation {
                case .set(let server, let expectedHash):
                    var planningEntries = entries
                    if let expectedHash {
                        planningEntries.append(McpOwnedEntry(
                            name: server.name, definitionHash: expectedHash
                        ))
                    }
                    plan = try store.planWrite(
                        request(
                            for: file,
                            content: content,
                            operation: "set",
                            server: server,
                            name: nil,
                            owned: planningEntries
                        ),
                        for: file
                    )
                    if let conflict = plan.conflict {
                        throw conflictError(conflict, name: server.name, file: file)
                    }
                    content = plan.content
                    changed = changed || plan.changed
                    if let hash = plan.definitionHash {
                        entries.removeAll { $0.name == server.name }
                        entries.append(McpOwnedEntry(name: server.name, definitionHash: hash))
                    }
                case .remove(let name):
                    plan = try store.planWrite(
                        request(
                            for: file,
                            content: content,
                            operation: "remove",
                            server: nil,
                            name: name,
                            owned: entries
                        ),
                        for: file
                    )
                    if let conflict = plan.conflict {
                        throw conflictError(conflict, name: name, file: file)
                    }
                    content = plan.content
                    changed = changed || plan.changed
                    entries.removeAll { $0.name == name }
                }
            }
            planned.append((file, content, entries, changed))
        }

        for entry in planned where entry.changed {
            lastBackupURL = try store.write(entry.content, to: entry.file).backupURL
            setLedger(entry.entries, for: entry.file)
        }
    }

    private func conflictError(
        _ conflict: String,
        name: String,
        file: McpConfigurationFile
    ) -> McpLibraryError {
        switch conflict {
        case "externallyModified":
            return .externallyModified("\(name) (\(file.agent.displayName))")
        default:
            return .notOwned(name)
        }
    }

    private func conflictMessage(_ conflict: String, name: String, file: McpConfigurationFile) -> String {
        conflictError(conflict, name: name, file: file).localizedDescription
    }

    // MARK: - Ownership ledger

    private func isOwned(_ server: McpServerDefinition, in file: McpConfigurationFile) -> Bool {
        ledgerEntries(for: file).contains {
            $0.name == server.name && $0.definitionHash == server.definitionHash
        }
    }

    private func ledgerEntries(for file: McpConfigurationFile) -> [McpOwnedEntry] {
        ledger[Self.identity(of: file)] ?? []
    }

    private func setLedger(_ entries: [McpOwnedEntry], for file: McpConfigurationFile) {
        let key = Self.identity(of: file)
        if entries.isEmpty {
            ledger[key] = nil
        } else {
            ledger[key] = entries
        }
        saveLedger()
    }

    private func loadLedger() {
        guard let data = model?.mcpLedgerStore.data(forKey: Self.ledgerKey) else { return }
        ledger = (try? JSONDecoder().decode([String: [McpOwnedEntry]].self, from: data)) ?? [:]
    }

    private func saveLedger() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        model?.mcpLedgerStore.set(data, forKey: Self.ledgerKey)
    }

    private func sorted(_ entries: [McpKeyValue]) -> [McpKeyValue] {
        entries
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
}

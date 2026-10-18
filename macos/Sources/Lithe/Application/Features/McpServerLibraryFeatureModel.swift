import Combine
import Foundation

/// One discovered definition in one Agent configuration file.
struct McpServerSource: Hashable, Identifiable {
    let file: McpConfigurationFile
    let definitionHash: String
    /// Full entry version for this file; merged Agents can have distinct versions.
    var sourceHash: String? = nil
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

    /// List and accessibility text must never include arguments or URL credentials.
    var summary: String {
        let fallback = definition.transport.title
        switch definition.transport {
        case .stdio:
            // Commands may contain inline scripts or assignments; show only a safe executable name.
            guard let executable = definition.command?.split(whereSeparator: { $0.isWhitespace }).first,
                  executable.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+/").contains($0)
                  }),
                  let name = executable.split(separator: "/", omittingEmptySubsequences: false).last,
                  !name.isEmpty, name != ".", name != "..", !name.hasPrefix("-") else {
                return fallback
            }
            return String(name)
        case .http, .sse:
            // Reject ambiguous input rather than echoing the original, potentially secret URL.
            guard let raw = definition.url,
                  !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
                  var components = URLComponents(string: raw),
                  components.string == raw,
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = components.host, !host.isEmpty,
                  host.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]").contains($0)
                  }) else {
                return fallback
            }
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            guard components.url != nil, let summary = components.string else { return fallback }
            return summary
        }
    }
}

/// Editable copy of one row.
struct McpServerDraft: Equatable {
    /// Row being edited; `nil` while adding a server.
    var originalRowID: String?
    var originalName: String?
    /// Immutable source snapshots captured when the editor opens, even after refresh.
    private(set) var originalSources: [McpServerSource] = []
    var name: String = ""
    var transport: McpTransport = .stdio
    var command: String = ""
    var url: String = ""
    /// One argument per line; spaces and blank lines are significant.
    var argumentsText: String = ""
    /// Keep the exact array while its text projection is unchanged: joining is
    /// ambiguous for no arguments vs one empty argument, and embedded newlines.
    private var originalArguments: [String] = []
    var env: [McpKeyValue] = []
    var headers: [McpKeyValue] = []
    var enabledAgents: Set<McpAgent> = []

    var isNew: Bool { originalRowID == nil }

    var arguments: [String] {
        if argumentsText == originalArguments.joined(separator: "\n") {
            return originalArguments
        }
        // When text differs, an empty field clears argv; every other line is an argument.
        // The line editor cannot create a lone empty argument or distinguish an
        // embedded newline from an argument boundary after the text is changed.
        guard !argumentsText.isEmpty else { return [] }
        return argumentsText.components(separatedBy: "\n")
    }

    init() {}

    init(row: McpServerRow) {
        originalRowID = row.id
        originalName = row.name
        originalSources = row.globalSources
        name = row.definition.name
        transport = row.definition.transport
        command = row.definition.command ?? ""
        url = row.definition.url ?? ""
        originalArguments = row.definition.args
        argumentsText = originalArguments.joined(separator: "\n")
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
    private var hasLoaded = false
    /// Workspaces whose project-level Lithe entry is registered. Kept because
    /// the coordinator clears the workspace URL before the close callback runs,
    /// so cleanup can no longer rely on the current session. A project switch
    /// can register the new workspace before the old one is cleaned up, so
    /// every registration is tracked until an unregistration pass removes it.
    private var litheRegistrationWorkspaces: Set<URL> = []
    private static let ledgerKey = "settings.mcpServerRegistrations"

    init(model: any McpServerLibraryActions) {
        self.model = model
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
                        sourceHash: server.sourceHash,
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
        // Core writes the active transport's entries into an object or table,
        // which cannot repeat a key. Rejecting duplicates here gives the user a
        // fixable message instead of a generic invalid-request error.
        let duplicateEntries = switch draft.transport {
        case .stdio: hasDuplicateEntryNames(draft.env)
        case .http, .sse: hasDuplicateEntryNames(draft.headers)
        }
        if duplicateEntries {
            return String(localized: "Environment variable and header names must be unique.")
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
        let originalName = draft.originalName
        let originalSources = draft.originalSources

        var definition = McpServerDefinition(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: draft.transport,
            command: nil,
            args: [],
            env: [],
            url: nil,
            headers: []
        )
        // Fields belong to exactly one transport. The editor keeps hidden
        // values when the transport changes (arguments for stdio, URL for
        // HTTP), and the write path drops the inactive ones; hashing them
        // would make the fresh entry look externally modified on refresh.
        switch draft.transport {
        case .stdio:
            definition.command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
            definition.args = draft.arguments
            definition.env = sorted(draft.env)
        case .http, .sse:
            definition.url = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
            definition.headers = sorted(draft.headers)
        }

        var operations: [McpConfigurationFile: [Operation]] = [:]
        let renaming = originalName.map { $0 != definition.name } ?? false
        if let originalName {
            // Disabling an Agent still requires explicit ownership; the captured
            // version also prevents a stale editor removing a newer owned entry.
            for source in originalSources
            where !draft.enabledAgents.contains(source.file.agent) {
                // Ownership can be taken in this same editor after the draft
                // was captured, so consult the shared ledger at save time.
                // The captured source version stays a required precondition:
                // a newer ledger entry alone must not authorize a stale removal.
                guard let expected = source.sourceHash else {
                    error = McpLibraryError.notOwned(originalName).localizedDescription
                    return false
                }
                guard ledgerOwns(name: originalName, sourceHash: expected, in: source.file) else {
                    // A newer complete version, or a record this draft saw as
                    // owned that is now gone, means the entry changed after
                    // this draft was captured; refresh is the accurate remedy.
                    // A legacy record without a sourceHash cannot be refreshed
                    // into ownership, so it keeps the take-ownership message.
                    let changedSinceDraft = source.isOwnedByLithe
                        || ledgerEntries(for: source.file).contains {
                            $0.name == originalName && $0.sourceHash != nil
                        }
                    error = (changedSinceDraft
                        ? McpLibraryError.externallyModified(originalName)
                        : McpLibraryError.notOwned(originalName)
                    ).localizedDescription
                    return false
                }
                operations[source.file, default: []].append(
                    .remove(originalName, expectedHash: expected)
                )
            }
        }
        for file in targetFiles {
            let source = originalSources.first { $0.file == file }
            // A source version must remain the one captured when the editor
            // opened, independent of refreshes and another window's ledger.
            if source != nil && source?.sourceHash == nil {
                error = McpLibraryError.externallyModified(originalName ?? definition.name).localizedDescription
                return false
            }
            let expected = source?.sourceHash
            let previousName = renaming && source != nil ? originalName : nil
            operations[file, default: []].append(.set(
                definition, expectedHash: expected, previousName: previousName
            ))
            // Removing the old name after the set lets Core copy the old table
            // (including Codex-specific fields) before the entry disappears.
            // The rename remove carries the displayed hash too: without it an
            // explicit rename of an entry Lithe did not create could update
            // the new name but never delete the old one.
            if let previousName {
                operations[file, default: []].append(
                    .remove(previousName, expectedHash: expected)
                )
            }
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
            ? .set(row.definition, expectedHash: nil, previousName: nil)
            : .remove(row.name, expectedHash: nil)
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
            operations[source.file, default: []].append(
                .remove(row.name, expectedHash: nil)
            )
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
        entries.append(McpOwnedEntry(
            name: row.name, definitionHash: source.definitionHash, sourceHash: source.sourceHash
        ))
        setLedger(entries, for: source.file)
        refresh()
    }

    // MARK: - Lithe project registration

    /// Writes Lithe's own MCP server into the open project's Codex and Claude
    /// configuration. Called when the project grant is enabled.
    func registerLitheServer(_ server: McpServerDefinition) {
        guard let store = model?.mcpConfigurationStore,
              let workspace = model?.mcpWorkspaceURL else { return }
        litheRegistrationWorkspaces.insert(workspace)
        let files = store.configurationFiles(workspace: workspace)
            .filter { $0.scope == .project }
        var registered = litheRegisteredAgents
        var messages: [String] = []
        var planned: [(
            change: McpConfigurationChange,
            entries: [McpOwnedEntry],
            changed: Bool
        )] = []

        do {
            // Plan both Agents before touching either file. A conflict or stale
            // snapshot anywhere rolls the registration back as one operation.
            for file in files {
                let existing = try store.read(file)
                let entries = ledgerEntries(for: file)
                let plan = try store.planWrite(
                    request(
                        for: file, content: existing ?? "", operation: "set",
                        server: server, name: nil, owned: entries
                    ),
                    for: file
                )
                if let conflict = plan.conflict {
                    throw conflictError(conflict, name: server.name, file: file)
                }
                var updated = entries
                if let hash = plan.definitionHash {
                    updated.removeAll { $0.name == server.name }
                    updated.append(McpOwnedEntry(
                        name: server.name, definitionHash: hash, sourceHash: plan.sourceHash
                    ))
                }
                planned.append((
                    McpConfigurationChange(file: file, source: existing, content: plan.content),
                    updated, plan.changed
                ))
            }
            let receipts = try store.writeBatch(planned.filter { $0.changed }.map { $0.change })
            lastBackupURL = receipts.last?.backupURL ?? lastBackupURL
            for entry in planned {
                setLedger(entry.entries, for: entry.change.file)
            }
            registered = Set(files.map { $0.agent })

            // Exclude is a post-commit warning: registration and ownership are
            // already durable, so cleanup must still know about both Agents.
            for entry in planned
            where entry.change.file.agent == .codex && entry.change.source == nil && entry.changed {
                do {
                    try store.excludeFromVersionControl(".codex/config.toml", workspace: workspace)
                } catch {
                    messages.append(String(
                        format: String(
                            localized: "Lithe MCP was registered, but .codex/config.toml could not be added to Git’s local exclude list: %@"
                        ),
                        error.localizedDescription
                    ))
                }
            }
        } catch {
            messages.append(String(
                format: String(localized: "Could not register Lithe MCP in %@: %@"),
                workspace.path, error.localizedDescription
            ))
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
    ///
    /// The close flow clears the session URL before this runs, so the workspace
    /// recorded at registration time is the fallback that keeps cleanup
    /// pointed at the project Lithe actually wrote to.
    func unregisterLitheServer() {
        guard let store = model?.mcpConfigurationStore else {
            litheRegisteredAgents = []
            litheRegistration = .inactive
            litheRegistrationWorkspaces.removeAll()
            return
        }
        // Clean every workspace this model registered, plus the current one in
        // case a switch already cleared the tracked identity. Using only one
        // URL would strand the previous project's entry after an A→B switch.
        var workspaces = litheRegistrationWorkspaces
        if let current = model?.mcpWorkspaceURL { workspaces.insert(current) }
        guard !workspaces.isEmpty else {
            litheRegisteredAgents = []
            litheRegistration = .inactive
            return
        }
        var files: [McpConfigurationFile] = []
        for workspace in workspaces {
            for file in store.configurationFiles(workspace: workspace)
            where file.scope == .project && !files.contains(file) {
                files.append(file)
            }
        }
        var messages: [String] = []

        for file in files {
            let entries = ledgerEntries(for: file)
            guard entries.contains(where: { $0.name == "lithe" }) else { continue }
            do {
                let existing = try store.read(file)
                let content = existing ?? ""
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
                    lastBackupURL = try store.write(
                        plan.content, to: file, replacing: existing
                    ).backupURL
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
        litheRegistrationWorkspaces.removeAll()
        if let message = messages.first {
            // The project section hides its registration line once MCP is off,
            // so a cleanup conflict must also reach the library's error banner
            // or the user would never learn that an entry was left behind.
            error = message
            litheRegistration = .needsAttention(message)
        } else {
            // A later successful cleanup also dismisses an older conflict
            // banner left by a previous unregister.
            error = nil
            litheRegistration = .inactive
        }
        refresh()
    }

    // MARK: - Planning and writing

    private enum Operation {
        /// `expectedHash` is the complete source version shown when editing.
        /// Core requires it to match even when the shared ledger is newer.
        /// `previousName` is set when the edit renames the entry, so Core can
        /// carry unmodeled configuration over to the new name.
        case set(McpServerDefinition, expectedHash: String?, previousName: String?)
        /// `expectedHash` authorizes removing the displayed definition during
        /// a rename of an entry Lithe did not create.
        case remove(String, expectedHash: String?)
    }

    private func request(
        for file: McpConfigurationFile,
        content: String,
        operation: String,
        server: McpServerDefinition?,
        name: String?,
        previousName: String? = nil,
        owned: [McpOwnedEntry],
        expectedHash: String? = nil
    ) -> McpWriteRequest {
        McpWriteRequest(
            source: file.agent.sourceName,
            scope: file.scope.rawValue,
            projectPath: file.projectPath,
            content: content,
            operation: operation,
            server: server,
            name: name,
            previousName: previousName,
            owned: owned,
            expectedHash: expectedHash
        )
    }

    /// Plans every operation against the current bytes first, then writes the
    /// changed files. A conflict anywhere aborts before disk is touched.
    private func commit(
        _ operations: [McpConfigurationFile: [Operation]],
        store: any McpConfigurationStore
    ) throws {
        var planned: [(
            file: McpConfigurationFile,
            source: String?,
            content: String,
            entries: [McpOwnedEntry],
            changed: Bool
        )] = []
        for (file, fileOperations) in operations {
            let source = try store.read(file)
            var content = source ?? ""
            var entries = ledgerEntries(for: file)
            var completedRenames: [String: String] = [:]
            var changed = false
            for operation in fileOperations {
                let plan: McpWritePlan
                switch operation {
                case .set(let server, let expectedHash, let previousName):
                    plan = try store.planWrite(
                        request(
                            for: file,
                            content: content,
                            operation: "set",
                            server: server,
                            name: nil,
                            previousName: previousName,
                            owned: entries,
                            expectedHash: expectedHash
                        ),
                        for: file
                    )
                    if let conflict = plan.conflict {
                        throw conflictError(conflict, name: server.name, file: file)
                    }
                    content = plan.content
                    changed = changed || plan.changed
                    if let previousName, let expectedHash,
                       try !store.parse(file, content: content).contains(where: { $0.name == previousName }) {
                        completedRenames[previousName] = expectedHash
                    }
                    if let hash = plan.definitionHash {
                        entries.removeAll { $0.name == server.name }
                        entries.append(McpOwnedEntry(
                            name: server.name, definitionHash: hash, sourceHash: plan.sourceHash
                        ))
                    }
                case .remove(let name, let expectedHash):
                    // Codex can move the original while planning the set. Only
                    // that already-authenticated move satisfies this removal;
                    // an original missing before planning still conflicts.
                    if let expectedHash, completedRenames[name] == expectedHash {
                        entries.removeAll { $0.name == name }
                        continue
                    }
                    plan = try store.planWrite(
                        request(
                            for: file,
                            content: content,
                            operation: "remove",
                            server: nil,
                            name: name,
                            owned: entries,
                            expectedHash: expectedHash
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
            planned.append((file, source, content, entries, changed))
        }

        let changes = planned.filter { $0.changed }.map {
            McpConfigurationChange(file: $0.file, source: $0.source, content: $0.content)
        }
        let receipts = try store.writeBatch(changes)
        lastBackupURL = receipts.last?.backupURL ?? lastBackupURL
        // A later failure must not publish ownership for an earlier write.
        for entry in planned where entry.changed {
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
        guard let sourceHash = server.sourceHash else { return false }
        return ledgerOwns(name: server.name, sourceHash: sourceHash, in: file)
    }

    /// Whether the latest shared ledger recorded this exact complete entry.
    private func ledgerOwns(
        name: String, sourceHash: String, in file: McpConfigurationFile
    ) -> Bool {
        ledgerEntries(for: file).contains {
            $0.name == name && $0.sourceHash == sourceHash
        }
    }

    private func ledgerEntries(for file: McpConfigurationFile) -> [McpOwnedEntry] {
        ledgerSnapshot()[Self.identity(of: file)] ?? []
    }

    /// Reads the shared ledger every time instead of caching it per window.
    /// Multiple windows share one store; a stale copy would rewrite the whole
    /// map and silently drop entries another window just recorded.
    private func ledgerSnapshot() -> [String: [McpOwnedEntry]] {
        guard let data = model?.mcpLedgerStore.data(forKey: Self.ledgerKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [McpOwnedEntry]].self, from: data)) ?? [:]
    }

    private func setLedger(_ entries: [McpOwnedEntry], for file: McpConfigurationFile) {
        var snapshot = ledgerSnapshot()
        let key = Self.identity(of: file)
        if entries.isEmpty {
            snapshot[key] = nil
        } else {
            snapshot[key] = entries
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        model?.mcpLedgerStore.set(data, forKey: Self.ledgerKey)
    }

    private func sorted(_ entries: [McpKeyValue]) -> [McpKeyValue] {
        entries
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    /// Empty rows are dropped on save, so only written names can collide.
    private func hasDuplicateEntryNames(_ entries: [McpKeyValue]) -> Bool {
        var names = Set<String>()
        for entry in entries
        where !entry.key.trimmingCharacters(in: .whitespaces).isEmpty {
            if !names.insert(entry.key).inserted { return true }
        }
        return false
    }
}

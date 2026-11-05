import Combine
import Foundation
import LitheModuleAPI

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
    /// Present only while reviewing an incomplete featured template.
    var setup: McpRegistrySetup?

    var setupMessage: String? {
        switch setup {
        case .bearerToken:
            L10n.string("GitHub requires a personal access token. Set the Authorization header to Bearer followed by your token. It is stored in the Agent configuration file.")
        case .allowedDirectories:
            L10n.string("Add at least one absolute folder path after the package argument, one per line. Filesystem can read and write only in the folders you allow. Requires Node.js 24 or later.")
        case nil: nil
        }
    }

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

    init(definition: McpServerDefinition) {
        name = definition.name
        transport = definition.transport
        command = definition.command ?? ""
        url = definition.url ?? ""
        originalArguments = definition.args
        argumentsText = definition.args.joined(separator: "\n")
        env = definition.env
        headers = definition.headers
    }

    mutating func setCommand(_ value: String, arguments: [String]) {
        command = value
        originalArguments = arguments
        argumentsText = arguments.joined(separator: "\n")
    }

    init?(entry: McpRegistryEntry) {
        guard let definition = entry.draft else { return nil }
        self.init(definition: definition)
        if entry.source == .featured {
            setup = entry.setup
            if setup == .bearerToken { headers = [McpKeyValue(key: "Authorization", value: "")] }
        }
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
            L10n.string("MCP configuration management is unavailable.")
        case .agentHasNoGlobalConfiguration:
            L10n.string("This Agent has no global MCP configuration file.")
        case .notOwned(let name):
            String(
                format: L10n.string("“%@” was created outside Lithe. Take ownership before changing it."),
                name
            )
        case .externallyModified(let name):
            String(
                format: L10n.string("“%@” changed outside Lithe. Refresh and try again."),
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
    var mcpTools: (any McpToolsManaging)? { get }
    var mcpRegistry: (any McpRegistryProviding)? { get }
    var mcpConfigurationStore: (any McpConfigurationStore)? { get }
    var mcpWorkspaceURL: URL? { get }
    var mcpLedgerStore: any KeyValueStore { get }
}

extension McpServerLibraryActions {
    var mcpTools: (any McpToolsManaging)? { nil }
    var mcpRegistry: (any McpRegistryProviding)? { nil }
}

/// Discovers, edits and removes MCP servers registered with Codex and Claude Code.
///
/// Core plans every write against the ownership ledger; this model stages all
/// plans before touching disk so a conflict on the second Agent never leaves the
/// first Agent half written. Secrets are held only in memory and are never
/// included in errors.
@MainActor
final class McpServerLibraryFeatureModel: ObservableObject {
    let tools: McpToolsFeatureModel
    let discovery: McpRegistryFeatureModel
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
        tools = McpToolsFeatureModel(service: model.mcpTools)
        discovery = McpRegistryFeatureModel(registry: model.mcpRegistry)
        tools.didChangePolicy = { [weak self] row, snapshot in
            self?.recordToolPolicy(row: row, snapshot: snapshot)
        }
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
        // Core merges by name and definition hash, flags same-name conflicts,
        // decides ledger ownership and orders the rows; this model only reads
        // files and maps Core's file identities back to native files.
        let files = store.configurationFiles(workspace: model?.mcpWorkspaceURL)
        var readErrors: [String: String] = [:]
        var inputs: [McpLibraryFileInput] = []
        for file in files {
            do {
                inputs.append(libraryInput(for: file, content: try store.read(file)))
            } catch {
                readErrors[Self.identity(of: file)] = error.localizedDescription
            }
        }
        let snapshot: McpLibrarySnapshot
        do {
            snapshot = try store.librarySnapshot(inputs)
        } catch {
            loadErrors = [error.localizedDescription]
            rows = []
            hasLoaded = true
            tools.reconcile(rows)
            return
        }
        let failures = Dictionary(
            snapshot.failures.map { ($0.file, $0.message) }, uniquingKeysWith: { first, _ in first }
        )
        loadErrors = files.compactMap { file in
            let id = Self.identity(of: file)
            guard let reason = readErrors[id] ?? failures[id] else { return nil }
            return String(format: L10n.string("Could not read %@: %@"), file.url.path, reason)
        }
        let filesByID = Dictionary(
            files.map { (Self.identity(of: $0), $0) }, uniquingKeysWith: { first, _ in first }
        )
        rows = snapshot.rows.map { row in
            McpServerRow(
                id: row.id,
                definition: row.definition,
                sources: row.sources.compactMap { source in
                    filesByID[source.file].map { file in
                        McpServerSource(
                            file: file,
                            definitionHash: source.definitionHash,
                            sourceHash: source.sourceHash,
                            isOwnedByLithe: source.ownedByLithe
                        )
                    }
                },
                hasDefinitionConflict: row.hasDefinitionConflict
            )
        }
        hasLoaded = true
        tools.reconcile(rows)
    }

    func catalogEntry(for definition: McpServerDefinition) -> McpRegistryEntry? {
        discovery.entries.first { entry in
            guard entry.source == .featured, let draft = entry.draft else { return false }
            if definition.transport != .stdio { return draft.transport == definition.transport && draft.url == definition.url }
            return draft.transport == .stdio && draft.command == definition.command && draft.args == Array(definition.args.prefix(draft.args.count))
        }
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

    /// Import is a preview only. Existing Core parsing validates the JSON;
    /// no configuration or ownership record changes until the editor saves.
    func importedDrafts(_ json: String) throws -> [McpServerDraft] {
        guard let store = model?.mcpConfigurationStore,
              let file = store.configurationFiles(workspace: nil).first(where: { $0.agent == .claudeCode && $0.scope == .global })
        else { throw McpLibraryError.unavailable }
        let servers = try store.parse(file, content: json)
        guard !servers.isEmpty else { throw McpLibraryError.invalidDraft(L10n.string("Paste a JSON object containing mcpServers.")) }
        return servers.map(McpServerDraft.init(definition:))
    }

    func draft(for row: McpServerRow) -> McpServerDraft { McpServerDraft(row: row) }

    /// Returns a user-facing reason when the draft cannot be saved.
    func validationMessage(for draft: McpServerDraft) -> String? {
        switch validate(draft) {
        case .success(let validation):
            return validation.issues.first.map(Self.message(for:))
        case .failure(let error):
            return error.localizedDescription
        }
    }

    private func validate(_ draft: McpServerDraft) -> Result<McpDraftValidation, Error> {
        guard let store = model?.mcpConfigurationStore else { return .failure(McpLibraryError.unavailable) }
        return Result { try store.validateDraft(Self.payload(for: draft)) }
    }

    static func payload(for draft: McpServerDraft) -> McpDraftPayload {
        McpDraftPayload(
            name: draft.name,
            transport: draft.transport,
            command: draft.command,
            url: draft.url,
            arguments: draft.arguments,
            env: draft.env,
            headers: draft.headers,
            enabledAgents: McpAgent.allCases.filter(draft.enabledAgents.contains).map(\.sourceName),
            setup: draft.setup?.rawValue
        )
    }

    /// Localizes Core's stable draft issue codes.
    static func message(for issue: McpDraftIssue) -> String {
        switch issue.code {
        case "nameRequired":
            L10n.string("Enter a server name.")
        case "nameInvalid":
            L10n.string("Use letters, digits, dots, dashes or underscores. The name must start with a letter or digit.")
        case "agentsRequired":
            L10n.string("Choose at least one Agent.")
        case "duplicateKeys":
            L10n.string("Environment variable and header names must be unique.")
        case "commandRequired":
            L10n.string("Enter the command that starts this server.")
        case "urlInvalid":
            L10n.string("Enter a complete server URL.")
        case "bearerTokenRequired":
            L10n.string("Enter an Authorization header with Bearer and your GitHub token.")
        case "allowedDirectoriesRequired":
            L10n.string("Add at least one absolute allowed folder path after the Filesystem package argument.")
        default:
            L10n.string("MCP configuration management is unavailable.")
        }
    }

    // MARK: - Mutations

    /// Creates or updates a server in every global configuration it is enabled in.
    @discardableResult
    func save(_ draft: McpServerDraft) -> Bool {
        guard let store = model?.mcpConfigurationStore else {
            error = McpLibraryError.unavailable.localizedDescription
            return false
        }
        let definition: McpServerDefinition
        switch validate(draft) {
        case .success(let validation):
            if let issue = validation.issues.first {
                error = Self.message(for: issue)
                return false
            }
            guard let normalized = validation.definition else {
                error = McpLibraryError.unavailable.localizedDescription
                return false
            }
            definition = normalized
        case .failure(let failure):
            error = failure.localizedDescription
            return false
        }
        error = nil
        let originalSources = draft.originalSources
        if let originalName = draft.originalName, originalName != definition.name,
           let original = rows.first(where: { $0.id == draft.originalRowID }) {
            do {
                try model?.mcpTools?.validateRename(McpToolTarget(definition: original.definition, files: originalSources.map(\.file)))
            } catch { self.error = error.localizedDescription; return false }
        }
        // The captured sources stay the save's precondition, independent of
        // later refreshes; Core also consults the ledger read at save time,
        // so ownership taken in this editor after capture still applies.
        let original = draft.originalName.map { name in
            McpBatchIntent.Original(name: name, sources: originalSources.map {
                McpBatchIntent.OriginalSource(
                    file: Self.identity(of: $0.file), sourceHash: $0.sourceHash, ownedByLithe: $0.isOwnedByLithe
                )
            })
        }
        return perform(.save(draft: Self.payload(for: draft), original: original), store: store)
    }

    /// Adds or removes one definition in a single Agent's global configuration.
    @discardableResult
    func setAgent(_ agent: McpAgent, enabled: Bool, for row: McpServerRow) -> Bool {
        guard let store = model?.mcpConfigurationStore else {
            error = McpLibraryError.unavailable.localizedDescription
            return false
        }
        error = nil
        return perform(
            .setAgent(definition: row.definition, agent: agent.sourceName, enabled: enabled), store: store
        )
    }

    /// Removes a server from every global configuration that Lithe owns it in.
    @discardableResult
    func delete(_ row: McpServerRow) -> Bool {
        guard let store = model?.mcpConfigurationStore else {
            error = McpLibraryError.unavailable.localizedDescription
            return false
        }
        error = nil
        return perform(
            .delete(name: row.name, files: row.globalSources.map { Self.identity(of: $0.file) }), store: store
        )
    }

    /// Records an externally created entry as Lithe-managed without touching the
    /// file, after which the per-Agent switch can remove or replace it.
    func takeOwnership(of row: McpServerRow, agent: McpAgent) {
        guard let source = row.globalSources.first(where: { $0.file.agent == agent }),
              !source.isOwnedByLithe else { return }
        error = nil
        var entries = ledgerEntries(for: source.file)
        let filters = entries.first { $0.name == row.name }?.toolFilters
        entries.removeAll { $0.name == row.name }
        entries.append(McpOwnedEntry(
            name: row.name, definitionHash: source.definitionHash, sourceHash: source.sourceHash, toolFilters: filters
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
                format: L10n.string("Could not register Lithe MCP in %@: %@"),
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
                    format: L10n.string("Could not remove Lithe MCP from %@: %@"),
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
            expectedHash: expectedHash,
            toolFilters: server.flatMap { server in owned.first(where: { $0.name == server.name })?.toolFilters?[file.url.path] }
        )
    }

    private func libraryInput(for file: McpConfigurationFile, content: String?) -> McpLibraryFileInput {
        McpLibraryFileInput(
            id: Self.identity(of: file),
            source: file.agent.sourceName,
            scope: file.scope.rawValue,
            projectPath: file.projectPath,
            path: file.url.path,
            content: content,
            owned: ledgerEntries(for: file)
        )
    }

    /// Lets Core plan the edit across every global file against the current
    /// bytes and ledger, then writes the changed files as one batch. A
    /// conflict anywhere aborts before disk is touched, and ownership is
    /// published only after every write succeeded.
    private func perform(_ intent: McpBatchIntent, store: any McpConfigurationStore) -> Bool {
        let files = store.configurationFiles(workspace: model?.mcpWorkspaceURL)
            .filter { $0.scope == .global }
        let filesByID = Dictionary(
            files.map { (Self.identity(of: $0), $0) }, uniquingKeysWith: { first, _ in first }
        )
        do {
            var inputs: [McpLibraryFileInput] = []
            for file in files {
                inputs.append(libraryInput(for: file, content: try store.read(file)))
            }
            let outcome = try store.batchPlan(files: inputs, intent: intent)
            switch outcome.status {
            case "ready":
                break
            case "invalid":
                error = outcome.issues?.first.map(Self.message(for:))
                    ?? McpLibraryError.unavailable.localizedDescription
                return false
            default:
                guard let rejection = outcome.rejection else { throw McpLibraryError.unavailable }
                error = rejectionError(rejection, file: rejection.file.flatMap { filesByID[$0] })
                    .localizedDescription
                // Plan conflicts mean the files moved on; refresh shows them.
                if rejection.file != nil { refresh() }
                return false
            }
            let sources = Dictionary(
                inputs.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first }
            )
            let changes = (outcome.changes ?? []).filter(\.changed)
            let batch = try changes.map { change in
                guard let file = filesByID[change.file], let content = change.content else {
                    throw McpLibraryError.unavailable
                }
                return McpConfigurationChange(file: file, source: sources[change.file] ?? nil, content: content)
            }
            let receipts = try store.writeBatch(batch)
            lastBackupURL = receipts.last?.backupURL ?? lastBackupURL
            // A later failure must not publish ownership for an earlier write.
            for change in changes {
                guard let file = filesByID[change.file] else { continue }
                for rename in change.renames {
                    model?.mcpTools?.serverRenamed(from: rename.from, to: rename.to, in: file)
                }
                setLedger(change.owned, for: file)
            }
        } catch {
            self.error = error.localizedDescription
            refresh()
            return false
        }
        refresh()
        return true
    }

    private func rejectionError(
        _ rejection: McpBatchOutcome.Rejection, file: McpConfigurationFile?
    ) -> McpLibraryError {
        switch rejection.code {
        case "externallyModified":
            let name = file.map { "\(rejection.name) (\($0.agent.displayName))" } ?? rejection.name
            return .externallyModified(name)
        case "agentHasNoGlobalConfiguration":
            return .agentHasNoGlobalConfiguration
        default:
            return .notOwned(rejection.name)
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

    private func ledgerEntries(for file: McpConfigurationFile) -> [McpOwnedEntry] {
        ledgerSnapshot()[Self.identity(of: file)] ?? []
    }

    private func recordToolPolicy(row: McpServerRow, snapshot: McpToolPolicySnapshot) {
        // Tool filters change Codex's full source hash, but not the connection
        // identity. Advance only ownership that matched before our guarded edit.
        if snapshot.agent == .codex, let previous = snapshot.previousSourceHash,
           let next = snapshot.sourceHash, let source = row.globalSources.first(where: { $0.file.agent == .codex }) {
            var entries = ledgerEntries(for: source.file)
            if let index = entries.firstIndex(where: { $0.name == row.name && $0.sourceHash == previous }) {
                entries[index] = McpOwnedEntry(name: row.name, definitionHash: row.definition.definitionHash,
                    sourceHash: next, toolFilters: entries[index].toolFilters)
                setLedger(entries, for: source.file)
            }
        }
        refresh()
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
}

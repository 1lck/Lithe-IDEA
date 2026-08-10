import Combine
import Foundation

enum DatabaseConnectionStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed

    var title: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }
}

@MainActor
final class DatabaseFeatureModel: ObservableObject {
    @Published private(set) var profiles: [DatabaseProfile]
    @Published private(set) var folders: [DatabaseConnectionFolder]
    @Published var selectedProfileID: UUID?
    @Published private(set) var tables: [String] = []
    @Published private(set) var databaseOptions: [String] = []
    @Published var selectedTable: String?
    @Published private(set) var openTableTabs: [String] = []
    @Published private(set) var columns: [String] = []
    @Published private(set) var columnTypes: [String: String] = [:]
    @Published private(set) var rows: [DatabaseRow] = []
    @Published private(set) var totalRows: Int64 = 0
    @Published private(set) var currentOffset = 0
    let pageSize = 200
    @Published private(set) var primaryKeyColumns: [String] = []
    @Published private(set) var indexes: [DatabaseRow] = []
    @Published private(set) var foreignKeys: [DatabaseRow] = []
    @Published private(set) var objects: [DatabaseObjectKind: [DatabaseRow]] = [:]
    @Published private(set) var lastExplainResult: DatabaseQueryResult?
    @Published private(set) var lastDiagnostics: DatabaseQueryResult?
    @Published private(set) var recoveryPoints: [DatabaseRecoveryPoint]
    @Published private(set) var auditEntries: [DatabaseAuditEntry]
    @Published private(set) var executionEvents: [DatabaseExecutionEvent]
    @Published private(set) var backupSchedules: [DatabaseBackupSchedule]
    @Published private(set) var sqlTabs: [DatabaseSQLTab]
    @Published var selectedSQLTabID: UUID?
    @Published var workspaceSection: DatabaseWorkspaceSection = .data
    @Published private(set) var sqlHistory: [DatabaseSQLHistoryEntry]
    @Published private(set) var connectionStatuses: [UUID: DatabaseConnectionStatus] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var backupProgress: Double?
    @Published var errorMessage: String?
    @Published private(set) var redisKeys: [RedisKeySummary] = []
    @Published private(set) var redisNextCursor = "0"
    @Published private(set) var redisSelectedKey: RedisKeyDetail?
    @Published var redisIncludeSize = true
    @Published private(set) var nacosConfigs: [NacosConfigSummary] = []
    @Published private(set) var nacosConfigTotalCount = 0
    @Published var nacosSelectedConfig: NacosConfigDetail?
    @Published private(set) var nacosServices: [NacosServiceSummary] = []
    @Published private(set) var nacosServiceTotalCount = 0
    @Published private(set) var nacosInstances: [NacosInstanceSummary] = []

    private let operations: any DatabaseOperations
    private let connectionStore: DatabaseConnectionStore
    private let recoveryStore: DatabaseRecoveryStore
    private var backupTimer: Timer?
    private var profileGeneration: UInt64 = 0
    private var tableRequestID: UUID?
    // Keep the unmasked page separate so primary-key mutations and exports never
    // accidentally persist the display placeholder.
    private var sourceRows: [DatabaseRow] = []

    init(operations: any DatabaseOperations, connectionStore: DatabaseConnectionStore, recoveryStore: DatabaseRecoveryStore = DatabaseRecoveryStore()) {
        self.operations = operations
        self.connectionStore = connectionStore
        self.recoveryStore = recoveryStore
        profiles = connectionStore.load()
        folders = connectionStore.loadFolders()
        let firstSQLTab = DatabaseSQLTab(title: "Query 1")
        sqlTabs = [firstSQLTab]
        selectedSQLTabID = firstSQLTab.id
        sqlHistory = connectionStore.loadSQLHistory()
        recoveryPoints = recoveryStore.recoveryPoints()
        auditEntries = recoveryStore.auditEntries()
        executionEvents = recoveryStore.executionEvents()
        backupSchedules = connectionStore.loadBackupSchedules()
        migrateLegacyGroupsIfNeeded()
        refreshBackupTimer()
    }

    deinit { backupTimer?.invalidate() }

    func add(_ profile: DatabaseProfile, password: String) async -> Bool {
        await save(profile, password: password)
    }

    func update(_ profile: DatabaseProfile, password: String?) async -> Bool {
        await save(profile, password: password)
    }

    func hasSavedPassword(for profile: DatabaseProfile) -> Bool {
        connectionStore.hasPassword(for: profile.id)
    }

    private func save(_ profile: DatabaseProfile, password: String?) async -> Bool {
        let generation = profileGeneration
        isLoading = true; errorMessage = nil
        setConnectionStatus(.connecting, for: profile.id)
        do {
            var profile = profile
            if profile.folderID != nil { profile.group = "" }
            let previousPassword = connectionStore.password(for: profile.id)
            let hadPreviousPassword = connectionStore.hasPassword(for: profile.id)
            let connection = connection(profile, password: password ?? previousPassword)
            try await Task.detached { [operations] in try operations.testConnection(connection) }.value
            let previousProfiles = profiles
            var updated = previousProfiles.filter { $0.id != profile.id }; updated.append(profile)
            if let password { try connectionStore.savePassword(password, for: profile.id) }
            do {
                try connectionStore.save(updated)
            } catch {
                if password != nil {
                    if hadPreviousPassword {
                        try? connectionStore.savePassword(previousPassword, for: profile.id)
                    } else {
                        try? connectionStore.deletePassword(for: profile.id)
                    }
                }
                throw error
            }
            profiles = sortedProfiles(updated)
            setConnectionStatus(.connected, for: profile.id)
            guard profileGeneration == generation else { return true }
            activateProfile(profile)
            if profile.kind.supportsDataGrid {
                await refreshTables()
            } else {
                isLoading = false
            }
            return true
        } catch {
            setConnectionStatus(.failed, for: profile.id)
            if profileGeneration == generation {
                errorMessage = executionError(error)
                isLoading = false
            }
            return false
        }
    }

    func remove(_ profile: DatabaseProfile) {
        do {
            let updated = profiles.filter { $0.id != profile.id }
            try connectionStore.save(updated); try connectionStore.deletePassword(for: profile.id); try connectionStore.deleteSQLHistory(for: profile.id); try connectionStore.deleteBackupSchedule(for: profile.id); try recoveryStore.deleteExecutionEvents(for: profile.id)
            profiles = updated
            connectionStatuses.removeValue(forKey: profile.id)
            sqlHistory.removeAll { $0.profileID == profile.id }
            executionEvents.removeAll { $0.profileID == profile.id }
            backupSchedules.removeAll { $0.profileID == profile.id }
            refreshBackupTimer()
            if selectedProfileID == profile.id {
                clearProfileScopedState()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func createFolder(name: String, parentID: UUID? = nil) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            errorMessage = "Folder name is required."
            return false
        }
        guard parentID == nil || folders.contains(where: { $0.id == parentID }),
              !folders.contains(where: { $0.parentID == parentID && $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            errorMessage = "A folder with this name already exists."
            return false
        }
        do {
            var updated = folders
            updated.append(DatabaseConnectionFolder(name: normalized, parentID: parentID))
            try connectionStore.saveFolders(updated)
            folders = sortedFolders(updated)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameFolder(_ folder: DatabaseConnectionFolder, to name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            errorMessage = "Folder name is required."
            return false
        }
        guard !folders.contains(where: { $0.id != folder.id && $0.parentID == folder.parentID && $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            errorMessage = "A folder with this name already exists."
            return false
        }
        do {
            var updated = folders
            guard let index = updated.firstIndex(where: { $0.id == folder.id }) else { return false }
            updated[index].name = normalized
            try connectionStore.saveFolders(updated)
            folders = sortedFolders(updated)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Removing a folder never removes a saved connection. Its connections are
    /// moved to the root so credentials and history remain intact.
    func removeFolder(_ folder: DatabaseConnectionFolder) {
        do {
            let updatedProfiles = profiles.map { profile -> DatabaseProfile in
                guard profile.folderID == folder.id else { return profile }
                var profile = profile
                profile.folderID = folder.parentID
                return profile
            }
            let updatedFolders = folders.compactMap { current -> DatabaseConnectionFolder? in
                guard current.id != folder.id else { return nil }
                var current = current
                if current.parentID == folder.id { current.parentID = folder.parentID }
                return current
            }
            try connectionStore.save(updatedProfiles)
            try connectionStore.saveFolders(updatedFolders)
            profiles = sortedProfiles(updatedProfiles)
            folders = sortedFolders(updatedFolders)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func move(_ profile: DatabaseProfile, toFolder folderID: UUID?) {
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else {
            errorMessage = "The selected connection folder no longer exists."
            return
        }
        do {
            var updated = profiles
            guard let index = updated.firstIndex(where: { $0.id == profile.id }) else { return }
            updated[index].folderID = folderID
            updated[index].group = ""
            try connectionStore.save(updated)
            profiles = sortedProfiles(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func importDBXConnections(plan: DatabaseDBXImportPlan, selectedIDs: Set<UUID>) -> Int {
        errorMessage = nil
        var updatedFolders = folders
        var folderIDMap: [UUID: UUID] = [:]
        for importedFolder in plan.folders {
            let targetParentID = importedFolder.parentID.flatMap { folderIDMap[$0] }
            if let existing = updatedFolders.first(where: {
                $0.parentID == targetParentID && $0.name.caseInsensitiveCompare(importedFolder.name) == .orderedSame
            }) {
                folderIDMap[importedFolder.id] = existing.id
            } else {
                let folder = DatabaseConnectionFolder(name: importedFolder.name, parentID: targetParentID)
                updatedFolders.append(folder)
                folderIDMap[importedFolder.id] = folder.id
            }
        }

        var updatedProfiles = profiles
        var imported: [(profile: DatabaseProfile, password: String)] = []
        for candidate in plan.candidates where selectedIDs.contains(candidate.id) && !candidate.isDuplicate {
            var profile = candidate.profile
            profile.folderID = profile.folderID.flatMap { folderIDMap[$0] }
            let duplicate = updatedProfiles.contains {
                $0.name == profile.name && $0.host == profile.host && $0.port == profile.port && $0.path == profile.path
            }
            guard !duplicate else { continue }
            updatedProfiles.append(profile)
            imported.append((profile, candidate.password))
        }
        guard !imported.isEmpty else { return 0 }

        var writtenPasswordIDs: [UUID] = []
        do {
            for item in imported where !item.password.isEmpty {
                try connectionStore.savePassword(item.password, for: item.profile.id)
                writtenPasswordIDs.append(item.profile.id)
            }
            try connectionStore.saveFolders(updatedFolders)
            try connectionStore.save(updatedProfiles)
            folders = sortedFolders(updatedFolders)
            profiles = sortedProfiles(updatedProfiles)
            return imported.count
        } catch {
            for id in writtenPasswordIDs { try? connectionStore.deletePassword(for: id) }
            try? connectionStore.saveFolders(folders)
            try? connectionStore.save(profiles)
            errorMessage = error.localizedDescription
            return 0
        }
    }

    func disconnect(_ profile: DatabaseProfile) {
        setConnectionStatus(.idle, for: profile.id)
        if selectedProfileID == profile.id {
            clearProfileScopedState()
        }
    }

    func duplicate(_ profile: DatabaseProfile) -> DatabaseProfile? {
        var copy = profile
        copy = DatabaseProfile(
            name: "\(profile.name) Copy", kind: profile.kind, host: profile.host, port: profile.port,
            username: profile.username, database: profile.database, path: profile.path, ssl: profile.ssl,
            folderID: profile.folderID, colorHex: profile.colorHex, readOnly: profile.readOnly,
            productionProtection: profile.productionProtection, maskSensitiveFields: profile.maskSensitiveFields,
            sensitiveColumnPatterns: profile.sensitiveColumnPatterns, caCertificatePath: profile.caCertificatePath,
            serverName: profile.serverName, sshHost: profile.sshHost, sshPort: profile.sshPort,
            sshUsername: profile.sshUsername, sshKeyPath: profile.sshKeyPath, sshLocalPort: profile.sshLocalPort,
            proxyURL: profile.proxyURL
        )
        do {
            var updated = profiles
            updated.append(copy)
            try connectionStore.save(updated)
            let password = connectionStore.password(for: profile.id)
            if !password.isEmpty {
                try connectionStore.savePassword(password, for: copy.id)
            }
            profiles = sortedProfiles(updated)
            return copy
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func select(_ profile: DatabaseProfile) async {
        activateProfile(profile)
        if profile.kind.supportsDataGrid {
            await refreshTables()
        } else {
            setConnectionStatus(.connected, for: profile.id)
            isLoading = false
        }
    }

    func refreshTables() async {
        guard let profile = selectedProfile else {
            tables = []
            databaseOptions = []
            return
        }
        guard profile.kind.supportsDataGrid else {
            tables = []
            databaseOptions = []
            return
        }
        let generation = profileGeneration
        isLoading = true; errorMessage = nil
        tables = []; objects = [:]
        setConnectionStatus(.connecting, for: profile.id)
        do {
            let connection = connection(profile)
            if profile.kind == .mysql || profile.kind == .mariadb {
                let databaseRows = try await Task.detached { [operations] in
                    try operations.listDatabases(connection: connection)
                }.value
                guard isCurrent(profileID: profile.id, generation: generation) else { return }
                databaseOptions = databaseRows
            } else {
                databaseOptions = []
            }
            let result = try await Task.detached { [operations] in try operations.listTables(connection: connection, schema: "") }.value
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            setConnectionStatus(.connected, for: profile.id)
            tables = result.compactMap { row in
                row["table_name"]?.text ?? row["TABLE_NAME"]?.text ?? row["name"]?.text
            }
            if profile.kind.isSQLDatabase { await refreshObjects(profileID: profile.id, generation: generation) }
        } catch {
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            tables = []; objects = [:]; databaseOptions = []
            errorMessage = executionError(error)
            setConnectionStatus(.failed, for: profile.id)
        }
        if isCurrent(profileID: profile.id, generation: generation) { isLoading = false }
    }

    func refreshDatabases() async {
        guard let profile = selectedProfile, profile.kind == .mysql || profile.kind == .mariadb else { return }
        let generation = profileGeneration
        isLoading = true
        errorMessage = nil
        do {
            let connection = connection(profile)
            let rows = try await Task.detached { [operations] in
                try operations.listDatabases(connection: connection)
            }.value
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            databaseOptions = rows
            isLoading = false
        } catch {
            if isCurrent(profileID: profile.id, generation: generation) {
                databaseOptions = []
                errorMessage = executionError(error)
                isLoading = false
            }
        }
    }

    func selectDatabase(_ database: String, for profile: DatabaseProfile) async {
        guard selectedProfileID == profile.id,
              (profile.kind == .mysql || profile.kind == .mariadb),
              databaseOptions.contains(database) else { return }
        var updated = profiles
        guard let index = updated.firstIndex(where: { $0.id == profile.id }) else { return }
        var updatedProfile = updated[index]
        updatedProfile.database = database
        updated[index] = updatedProfile
        do {
            try connectionStore.save(updated)
            profiles = sortedProfiles(updated)
            activateProfile(updatedProfile)
            await refreshTables()
        } catch {
            errorMessage = executionError(error)
        }
    }

    private func refreshObjects(profileID: UUID, generation: UInt64) async {
        guard isCurrent(profileID: profileID, generation: generation),
              let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let connection = connection(profile)
        do {
            let loaded = try await withThrowingTaskGroup(of: (DatabaseObjectKind, [DatabaseRow]).self) { group in
                for kind in DatabaseObjectKind.allCases {
                    group.addTask { [operations] in
                        (kind, try operations.listObjects(connection: connection, schema: "", kind: kind))
                    }
                }
                var result: [DatabaseObjectKind: [DatabaseRow]] = [:]
                for try await (kind, rows) in group { result[kind] = rows }
                return result
            }
            guard isCurrent(profileID: profileID, generation: generation) else { return }
            objects = loaded
        } catch {
            if isCurrent(profileID: profileID, generation: generation) {
                objects = [:]
                errorMessage = executionError(error)
            }
        }
    }

    func loadSchemaSnapshot(profileID: UUID) async -> DatabaseSchemaSnapshot? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            errorMessage = "The selected database connection no longer exists."
            return nil
        }
        let generation = profileGeneration
        let tracksUI = selectedProfileID == profileID
        if tracksUI {
            isLoading = true
            errorMessage = nil
        }
        do {
            let connection = connection(profile)
            let tableRows = try await Task.detached { [operations] in
                try operations.listTables(connection: connection, schema: "")
            }.value
            let tableNames = tableRows.compactMap { row -> String? in
                let type = row["table_type"]?.text ?? row["TABLE_TYPE"]?.text ?? ""
                guard type.isEmpty || type.caseInsensitiveCompare("BASE TABLE") == .orderedSame || type.caseInsensitiveCompare("table") == .orderedSame else { return nil }
                return row["table_name"]?.text ?? row["TABLE_NAME"]?.text ?? row["name"]?.text
            }
            let tables = try await withThrowingTaskGroup(of: DatabaseSchemaTableSnapshot.self) { group in
                for table in tableNames {
                    group.addTask { [operations] in
                        let description = try operations.describeTable(connection: connection, schema: "", table: table)
                        let indexes = try operations.listIndexes(connection: connection, schema: "", table: table)
                        let foreignKeys = try operations.listForeignKeys(connection: connection, schema: "", table: table)
                        return DatabaseSchemaTableSnapshot(
                            name: table,
                            columns: description.compactMap { row in
                                guard let name = row["column_name"]?.text ?? row["COLUMN_NAME"]?.text ?? row["name"]?.text else { return nil }
                                let dataType = row["data_type"]?.text ?? row["DATA_TYPE"]?.text ?? row["type"]?.text ?? ""
                                let nullable = if let value = row["is_nullable"]?.text ?? row["IS_NULLABLE"]?.text {
                                    value.caseInsensitiveCompare("NO") != .orderedSame
                                } else if let notNull = row["notnull"]?.integerValue {
                                    notNull == 0
                                } else {
                                    true
                                }
                                let defaultValue = row["column_default"]?.text ?? row["COLUMN_DEFAULT"]?.text ?? row["dflt_value"]?.text
                                let isPrimary = row["column_key"]?.text == "PRI" || row["COLUMN_KEY"]?.text == "PRI" || (row["pk"]?.integerValue ?? 0) > 0
                                return DatabaseSchemaColumnSnapshot(name: name, dataType: dataType, isNullable: nullable, defaultValue: defaultValue, isPrimaryKey: isPrimary)
                            },
                            indexes: indexes.compactMap { row in
                                guard let name = row["index_name"]?.text ?? row["INDEX_NAME"]?.text ?? row["name"]?.text else { return nil }
                                let definition = row["definition"]?.text ?? row["index_definition"]?.text ?? ""
                                return DatabaseSchemaIndexSnapshot(name: name, definition: definition)
                            },
                            foreignKeys: foreignKeys.compactMap { row in
                                guard let name = row["constraint_name"]?.text ?? row["CONSTRAINT_NAME"]?.text ?? row["id"]?.text else { return nil }
                                guard let column = row["column_name"]?.text ?? row["COLUMN_NAME"]?.text ?? row["from"]?.text else { return nil }
                                guard let referencedTable = row["referenced_table_name"]?.text ?? row["REFERENCED_TABLE_NAME"]?.text ?? row["table"]?.text else { return nil }
                                guard let referencedColumn = row["referenced_column_name"]?.text ?? row["REFERENCED_COLUMN_NAME"]?.text ?? row["to"]?.text else { return nil }
                                return DatabaseSchemaForeignKeySnapshot(name: name, column: column, referencedTable: referencedTable, referencedColumn: referencedColumn)
                            }
                        )
                    }
                }
                var snapshots: [DatabaseSchemaTableSnapshot] = []
                for try await table in group { snapshots.append(table) }
                return snapshots.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            if tracksUI && !isCurrent(profileID: profileID, generation: generation) { return nil }
            if tracksUI { isLoading = false }
            return DatabaseSchemaSnapshot(profileID: profile.id, profileName: profile.name, kind: profile.kind, schema: "", tables: tables)
        } catch {
            if tracksUI && isCurrent(profileID: profileID, generation: generation) {
                errorMessage = executionError(error)
                isLoading = false
            }
            return nil
        }
    }

    func applySchemaMigration(_ diff: DatabaseSchemaDiffResult, targetProfileID: UUID, confirmed: Bool = false) async -> Bool {
        guard let profile = profiles.first(where: { $0.id == targetProfileID }) else {
            errorMessage = "The target database connection no longer exists."
            return false
        }
        guard diff.target.profileID == targetProfileID else {
            errorMessage = "The migration target does not match the selected connection."
            return false
        }
        guard diff.source.kind == diff.target.kind else {
            errorMessage = "Automatic migration requires source and target connections to use the same database engine."
            return false
        }
        guard !diff.items.isEmpty else { return true }
        guard !diff.requiresConfirmation || confirmed else {
            errorMessage = "The schema migration contains destructive changes and needs confirmation."
            return false
        }
        if diff.items.contains(where: { $0.sql.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("--") }) {
            errorMessage = "This migration contains a review-only SQL step and cannot be applied automatically."
            return false
        }
        let generation = profileGeneration
        let tracksUI = selectedProfileID == targetProfileID
        if tracksUI {
            isLoading = true
            errorMessage = nil
        }
        do {
            let recoveryPoint = try await createRecoveryPoint(profile: profile, reason: "Before schema migration")
            let connection = connection(profile)
            for item in diff.items {
                for statement in DatabaseSchemaDiffEngine.statements(in: item.sql) where !statement.hasPrefix("--") {
                    _ = try await Task.detached { [operations] in
                        try operations.execute(connection: connection, sql: statement, values: [], confirmed: confirmed, allowWrite: false)
                    }.value
                }
            }
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "schemaMigration", summary: "Applied schema migration from \(diff.source.profileName)", createdAt: Date(), recoveryPointID: recoveryPoint.id, rowsAffected: nil, succeeded: true, errorMessage: nil))
            if tracksUI && isCurrent(profileID: targetProfileID, generation: generation) {
                await refreshTables()
                if let table = selectedTable { await openTable(table) }
                isLoading = false
            }
            return true
        } catch {
            let sanitizedError = executionError(error)
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "schemaMigration", summary: "Schema migration failed", createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: false, errorMessage: sanitizedError))
            if tracksUI && isCurrent(profileID: targetProfileID, generation: generation) {
                errorMessage = sanitizedError
                isLoading = false
            }
            return false
        }
    }

    func applySchemaChange(_ change: DatabaseSchemaChange, confirmed: Bool = false) async -> Bool {
        guard let profile = selectedProfile else { errorMessage = "Select a database connection first."; return false }
        let generation = profileGeneration
        isLoading = true; errorMessage = nil
        do {
            let connection = connection(profile)
            let recoveryPoint = try await createRecoveryPoint(profile: profile, reason: "Before schema change")
            _ = try await Task.detached { [operations] in
                try operations.applySchemaChange(connection: connection, schema: "", change: change, confirmed: confirmed, allowWrite: false)
            }.value
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "schemaChange", summary: "Applied \(change.operation)", createdAt: Date(), recoveryPointID: recoveryPoint.id, rowsAffected: nil, succeeded: true, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return true }
            await refreshTables()
            if let table = selectedTable { await openTable(table) }
            return true
        } catch {
            let sanitizedError = executionError(error)
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "schemaChange", summary: "Schema change failed", createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: false, errorMessage: sanitizedError))
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = sanitizedError
                isLoading = false
            }
            return false
        }
    }

    func explainSQL(_ sql: String, format: String = "json") async -> DatabaseQueryResult? {
        guard let profile = selectedProfile else { errorMessage = "Select a database connection first."; return nil }
        let generation = profileGeneration
        do {
            let connection = connection(profile)
            let result = try await Task.detached { [operations] in
                try operations.explain(connection: connection, sql: sql, format: format)
            }.value
            guard isCurrent(profileID: profile.id, generation: generation) else { return nil }
            let displayResult = masked(result)
            lastExplainResult = displayResult
            return displayResult
        } catch {
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = executionError(error)
            }
            return nil
        }
    }

    func loadDiagnostics(_ request: DatabaseDiagnosticsRequest) async -> DatabaseQueryResult? {
        guard let profile = selectedProfile else { errorMessage = "Select a database connection first."; return nil }
        let generation = profileGeneration
        do {
            let connection = connection(profile)
            let result = try await Task.detached { [operations] in
                try operations.diagnostics(connection: connection, request: request)
            }.value
            guard isCurrent(profileID: profile.id, generation: generation) else { return nil }
            let displayResult = masked(result)
            lastDiagnostics = displayResult
            return displayResult
        } catch {
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = executionError(error)
            }
            return nil
        }
    }

    func openTable(_ table: String) async {
        guard let profile = selectedProfile else { return }
        let generation = profileGeneration
        let requestID = UUID()
        tableRequestID = requestID
        if !openTableTabs.contains(table) { openTableTabs.append(table) }
        selectedTable = table; isLoading = true; errorMessage = nil
        do {
            let connection = connection(profile)
            async let metadata = Task.detached { [operations] in try operations.describeTable(connection: connection, schema: "", table: table) }.value
            async let page = Task.detached { [operations, pageSize] in try operations.pageTable(connection: connection, schema: "", table: table, limit: pageSize, offset: 0, filters: [], sort: []) }.value
            async let tableIndexes = Task.detached { [operations] in try operations.listIndexes(connection: connection, schema: "", table: table) }.value
            async let tableForeignKeys = Task.detached { [operations] in try operations.listForeignKeys(connection: connection, schema: "", table: table) }.value
            let (description, result, loadedIndexes, loadedForeignKeys) = try await (metadata, page, tableIndexes, tableForeignKeys)
            guard isCurrent(profileID: profile.id, generation: generation),
                  selectedTable == table,
                  tableRequestID == requestID else { return }
            columns = description.compactMap { $0["column_name"]?.text ?? $0["COLUMN_NAME"]?.text ?? $0["name"]?.text }
            columnTypes = Dictionary(uniqueKeysWithValues: description.compactMap { row in
                guard let name = row["column_name"]?.text ?? row["COLUMN_NAME"]?.text ?? row["name"]?.text else { return nil }
                let type = row["data_type"]?.text ?? row["DATA_TYPE"]?.text ?? row["type"]?.text ?? ""
                return (name, type.lowercased())
            })
            primaryKeyColumns = description.compactMap { row in
                let name = row["column_name"]?.text ?? row["COLUMN_NAME"]?.text ?? row["name"]?.text
                let mysqlPrimary = row["column_key"]?.text == "PRI" || row["COLUMN_KEY"]?.text == "PRI"
                let sqlitePrimary = row["pk"]?.integerValue ?? 0 > 0
                return mysqlPrimary || sqlitePrimary ? name : nil
            }
            if columns.isEmpty { columns = result.rows.first.map { Array($0.keys).sorted() } ?? [] }
            sourceRows = result.rows
            rows = masked(result.rows)
            totalRows = result.totalRows ?? Int64(result.rows.count)
            indexes = loadedIndexes; foreignKeys = loadedForeignKeys
            currentOffset = 0
        } catch {
            if isCurrent(profileID: profile.id, generation: generation), selectedTable == table, tableRequestID == requestID {
                errorMessage = executionError(error)
                rows = []; sourceRows = []; columns = []; columnTypes = [:]; indexes = []; foreignKeys = []; totalRows = 0
            }
        }
        if isCurrent(profileID: profile.id, generation: generation), tableRequestID == requestID { isLoading = false }
    }

    @discardableResult
    func closeTableTab(_ table: String) -> String? {
        openTableTabs.removeAll { $0 == table }
        guard selectedTable == table else { return selectedTable }
        selectedTable = openTableTabs.last
        if selectedTable == nil {
            rows = []; sourceRows = []; columns = []; columnTypes = [:]
            indexes = []; foreignKeys = []; totalRows = 0; currentOffset = 0
        }
        return selectedTable
    }

    func loadPage(filters: [DatabaseFilter], sort: [DatabaseSort], offset: Int) async {
        guard let profile = selectedProfile, let table = selectedTable else { return }
        let generation = profileGeneration
        let requestID = UUID()
        tableRequestID = requestID
        isLoading = true; errorMessage = nil
        do {
            let connection = connection(profile)
            let result = try await Task.detached { [operations, pageSize] in
                try operations.pageTable(connection: connection, schema: "", table: table, limit: pageSize, offset: max(0, offset), filters: filters, sort: sort)
            }.value
            guard isCurrent(profileID: profile.id, generation: generation), selectedTable == table, tableRequestID == requestID else { return }
            sourceRows = result.rows
            rows = masked(result.rows)
            totalRows = result.totalRows ?? Int64(result.rows.count); currentOffset = max(0, offset)
        } catch {
            if isCurrent(profileID: profile.id, generation: generation), selectedTable == table, tableRequestID == requestID {
                errorMessage = executionError(error)
            }
        }
        if isCurrent(profileID: profile.id, generation: generation), tableRequestID == requestID { isLoading = false }
    }

    func apply(drafts: [DatabaseCellDraft], insertedRows: [DatabaseRow], deletedIndexes: Set<Int>, confirmed: Bool = false) async -> Bool {
        guard let profile = selectedProfile, let table = selectedTable else { return false }
        let generation = profileGeneration
        var changesByRow: [Int: DatabaseRow] = [:]
        for draft in drafts { changesByRow[draft.rowIndex, default: [:]][draft.column] = typedValue(draft.value, for: draft.column) }
        var mutations = insertedRows.map { row in
            DatabaseMutation(action: .insert, table: table, values: row.mapValuesWithKeys { column, value in typedValue(value, for: column) })
        }
        for (index, values) in changesByRow where !deletedIndexes.contains(index) {
            guard sourceRows.indices.contains(index), let key = keyValues(sourceRows[index]) else { errorMessage = "This table needs a primary key before rows can be edited."; return false }
            mutations.append(DatabaseMutation(action: .update, table: table, values: values, key: key))
        }
        for index in deletedIndexes {
            guard sourceRows.indices.contains(index), let key = keyValues(sourceRows[index]) else { errorMessage = "This table needs a primary key before rows can be deleted."; return false }
            mutations.append(DatabaseMutation(action: .delete, table: table, key: key))
        }
        isLoading = true; errorMessage = nil
        do {
            let connection = connection(profile)
            let recoveryPoint = profile.kind == .mongodb ? nil : try await createRecoveryPoint(profile: profile, reason: "Before table edit")
            _ = try await Task.detached { [operations] in try operations.applyChanges(connection: connection, schema: "", mutations: mutations, confirmed: confirmed, allowWrite: false) }.value
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "tableEdit", summary: "Applied table cell changes", createdAt: Date(), recoveryPointID: recoveryPoint?.id, rowsAffected: nil, succeeded: true, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return true }
            await openTable(table); return true
        } catch {
            let sanitizedError = executionError(error)
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "tableEdit", summary: "Table cell changes failed", createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: false, errorMessage: sanitizedError))
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = sanitizedError
                isLoading = false
            }
            return false
        }
    }

    func exportData(format: DatabaseTransferFormat) async -> Data? {
        guard let profile = selectedProfile else { return nil }
        let connection = connection(profile)
        let table = selectedTable
        let generation = profileGeneration
        do {
            let data = try await Task.detached { [operations, table] in
                switch format {
                case .csv, .json:
                    guard let table else { throw DatabaseTransferError.tableRequired }
                    let sql = "SELECT * FROM \(Self.quotedIdentifier(table, for: connection.kind))"
                    return format == .csv
                        ? try operations.exportCSV(connection: connection, sql: sql, values: [], limit: 100_000)
                        : try operations.exportJSON(connection: connection, sql: sql, values: [], limit: 100_000)
                case .sql:
                    return try operations.exportSQL(connection: connection, options: DatabaseSQLExportOptions())
                }
            }.value
            return data
        } catch {
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = executionError(error)
            }
            return nil
        }
    }

    func exportDataFile(format: DatabaseTransferFormat) async -> URL? {
        guard format == .sql, let profile = selectedProfile else { return nil }
        let generation = profileGeneration
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-database-\(UUID().uuidString).sql")
        do {
            let connection = connection(profile)
            let result = try await Task.detached { [operations] in
                try operations.exportSQLToFile(
                    connection: connection,
                    options: DatabaseSQLExportOptions(schema: "", selectedTables: [], includeStructure: true, includeData: true, limit: 0),
                    outputURL: outputURL
                )
            }.value
            guard result.path == outputURL.path, FileManager.default.fileExists(atPath: outputURL.path) else {
                throw DatabaseSidecarError.invalidResponse("Database backup file was not created")
            }
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = executionError(error)
            }
            return nil
        }
    }

    func importData(_ data: Data, format: DatabaseTransferFormat, confirmed: Bool = false) async -> Bool {
        guard let profile = selectedProfile else { return false }
        let generation = profileGeneration
        let table = selectedTable
        isLoading = true; errorMessage = nil
        do {
            let connection = connection(profile)
            let recoveryPoint = try await createRecoveryPoint(profile: profile, reason: "Before import")
            _ = try await Task.detached { [operations, table] in
                switch format {
                case .csv:
                    guard let table else { throw DatabaseTransferError.tableRequired }
                    return try operations.importCSV(connection: connection, schema: "", table: table, data: data)
                case .json:
                    guard let table else { throw DatabaseTransferError.tableRequired }
                    return try operations.importJSON(connection: connection, schema: "", table: table, data: data)
                case .sql:
                    return try operations.restoreSQL(connection: connection, data: data, confirmed: confirmed, allowWrite: false)
                }
            }.value
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "import", summary: "Imported \(format.rawValue) data", createdAt: Date(), recoveryPointID: recoveryPoint.id, rowsAffected: nil, succeeded: true, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return true }
            if let table { await openTable(table) } else { await refreshTables() }
            return true
        } catch {
            let sanitizedError = executionError(error)
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "import", summary: "Import failed", createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: false, errorMessage: sanitizedError))
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = sanitizedError
                isLoading = false
            }
            return false
        }
    }

    func importDataFile(_ fileURL: URL, format: DatabaseTransferFormat, confirmed: Bool = false) async -> Bool {
        guard format == .sql, let profile = selectedProfile else { return false }
        let generation = profileGeneration
        let table = selectedTable
        isLoading = true
        errorMessage = nil
        do {
            let connection = connection(profile)
            let recoveryPoint = try await createRecoveryPoint(profile: profile, reason: "Before SQL import")
            _ = try await Task.detached { [operations] in
                try operations.restoreSQLFile(connection: connection, fileURL: fileURL, confirmed: confirmed, allowWrite: false)
            }.value
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "import", summary: "Imported SQL backup", createdAt: Date(), recoveryPointID: recoveryPoint.id, rowsAffected: nil, succeeded: true, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return true }
            if let table { await openTable(table) } else { await refreshTables() }
            return true
        } catch {
            let sanitizedError = executionError(error)
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "import", summary: "SQL import failed", createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: false, errorMessage: sanitizedError))
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = sanitizedError
                isLoading = false
            }
            return false
        }
    }

    var selectedSQLTab: DatabaseSQLTab? { sqlTabs.first { $0.id == selectedSQLTabID } }

    var sqlCompletionItems: [String] {
        let keywords = [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP",
            "JOIN", "LEFT JOIN", "ORDER BY", "GROUP BY", "LIMIT", "EXPLAIN", "SHOW", "DESCRIBE", "BEGIN", "COMMIT", "ROLLBACK"
        ]
        var seen = Set<String>()
        return (keywords + tables + columns).filter { seen.insert($0.lowercased()).inserted }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func addSQLTab(sql: String = "") {
        let tab = DatabaseSQLTab(title: "Query \(sqlTabs.count + 1)", sql: sql)
        sqlTabs.append(tab)
        selectedSQLTabID = tab.id
    }

    func closeSQLTab(_ id: UUID) {
        guard sqlTabs.count > 1 else {
            updateSQLTab(id) { tab in
                tab.sql = ""; tab.result = nil; tab.resultColumns = []; tab.rowsAffected = nil; tab.execution = nil; tab.errorMessage = nil
            }
            return
        }
        guard let index = sqlTabs.firstIndex(where: { $0.id == id }) else { return }
        sqlTabs.remove(at: index)
        if selectedSQLTabID == id { selectedSQLTabID = sqlTabs[max(0, index - 1)].id }
    }

    func updateSQL(_ sql: String, in tabID: UUID) {
        updateSQLTab(tabID) { tab in
            tab.sql = sql
            tab.errorMessage = nil
        }
    }

    func formatSQL(in tabID: UUID) {
        guard let tab = sqlTabs.first(where: { $0.id == tabID }) else { return }
        updateSQL(DatabaseSQLFormatter.format(tab.sql), in: tabID)
    }

    func analysis(forSQLTab tabID: UUID) -> DatabaseSQLAnalysis {
        DatabaseSQLAnalyzer.analyze(sqlTabs.first(where: { $0.id == tabID })?.sql ?? "")
    }

    func restoreSQLHistory(_ entry: DatabaseSQLHistoryEntry) {
        if let selected = selectedSQLTab, selected.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateSQL(entry.sql, in: selected.id)
        } else {
            addSQLTab(sql: entry.sql)
        }
    }

    func runSQL(in tabID: UUID, confirmedRisk: Bool = false) async {
        guard let profile = selectedProfile, let tab = sqlTabs.first(where: { $0.id == tabID }) else {
            errorMessage = "Select a database connection first."
            return
        }
        let analysis = DatabaseSQLAnalyzer.analyze(tab.sql)
        updateSQLTab(tabID) { tab in
            tab.errorMessage = nil
            tab.result = nil
            tab.resultColumns = []
            tab.rowsAffected = nil
            tab.execution = nil
        }
        guard analysis.canExecute else {
            updateSQLTab(tabID) { $0.errorMessage = analysis.warning }
            return
        }
        guard !analysis.requiresConfirmation || confirmedRisk else {
            updateSQLTab(tabID) { $0.errorMessage = analysis.warning }
            return
        }

        let sql = tab.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = connection(profile)
        let generation = profileGeneration
        let startedAt = Date()
        updateSQLTab(tabID) { tab in
            tab.isRunning = true; tab.errorMessage = nil; tab.result = nil; tab.resultColumns = []; tab.rowsAffected = nil; tab.execution = nil
        }

        do {
            let recoveryPoint: DatabaseRecoveryPoint? = analysis.kind.usesQueryEndpoint ? nil : try await createRecoveryPoint(profile: profile, reason: "Before SQL execution")
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            if analysis.kind.usesQueryEndpoint {
                let result = try await Task.detached { [operations] in
                    try operations.query(connection: connection, sql: sql, values: [], limit: 10_000)
                }.value
                let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                let columns = result.columns ?? result.rows.reduce(into: [String]()) { result, row in
                    for key in row.keys where !result.contains(key) { result.append(key) }
                }
                let execution = DatabaseSQLExecution(startedAt: startedAt, durationMilliseconds: duration, rowsReturned: result.rows.count, rowsAffected: nil, truncated: result.truncated)
                guard isCurrent(profileID: profile.id, generation: generation) else { return }
                updateSQLTab(tabID) { tab in
                    tab.result = masked(result); tab.resultColumns = columns; tab.execution = execution; tab.isRunning = false
                }
                recordSQLHistory(profileID: profile.id, sql: sql, analysis: analysis, execution: execution)
                appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .sql, operation: analysis.kind.rawValue, startedAt: startedAt, durationMilliseconds: execution.durationMilliseconds, status: .succeeded, rowsReturned: execution.rowsReturned, rowsAffected: execution.rowsAffected, errorMessage: nil))
                if let recoveryPoint { appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "sql", summary: "Executed \(analysis.kind.rawValue) statement", createdAt: startedAt, recoveryPointID: recoveryPoint.id, rowsAffected: execution.rowsAffected, succeeded: true, errorMessage: nil)) }
            } else {
                let result = try await Task.detached { [operations] in
                    try operations.execute(connection: connection, sql: sql, values: [], confirmed: confirmedRisk, allowWrite: false)
                }.value
                let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                let execution = DatabaseSQLExecution(startedAt: startedAt, durationMilliseconds: duration, rowsReturned: nil, rowsAffected: result.rowsAffected, truncated: false)
                guard isCurrent(profileID: profile.id, generation: generation) else { return }
                updateSQLTab(tabID) { tab in
                    tab.rowsAffected = result.rowsAffected; tab.execution = execution; tab.isRunning = false
                }
                recordSQLHistory(profileID: profile.id, sql: sql, analysis: analysis, execution: execution)
                appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .sql, operation: analysis.kind.rawValue, startedAt: startedAt, durationMilliseconds: execution.durationMilliseconds, status: .succeeded, rowsReturned: execution.rowsReturned, rowsAffected: execution.rowsAffected, errorMessage: nil))
                appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "sql", summary: "Executed \(analysis.kind.rawValue) statement", createdAt: startedAt, recoveryPointID: recoveryPoint?.id, rowsAffected: execution.rowsAffected, succeeded: true, errorMessage: nil))
                await refreshTables()
            }
        } catch {
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            let sanitizedError = executionError(error)
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .sql, operation: analysis.kind.rawValue, startedAt: startedAt, durationMilliseconds: duration, status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: sanitizedError))
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "sql", summary: "SQL execution failed", createdAt: startedAt, recoveryPointID: nil, rowsAffected: nil, succeeded: false, errorMessage: sanitizedError))
            updateSQLTab(tabID) { tab in
                tab.isRunning = false; tab.errorMessage = sanitizedError; tab.execution = nil; tab.rowsAffected = nil; tab.result = nil; tab.resultColumns = []
            }
        }
    }

    func rollback(to point: DatabaseRecoveryPoint) async -> Bool {
        guard let profile = selectedProfile, profile.id == point.profileID else { errorMessage = "Select the connection that owns this recovery point."; return false }
        let generation = profileGeneration
        isLoading = true; errorMessage = nil
        do {
            let connection = connection(profile)
            if point.isCompressed {
                let data = try recoveryStore.data(for: point)
                _ = try await Task.detached { [operations] in try operations.restoreSQL(connection: connection, data: data, confirmed: true, allowWrite: false) }.value
            } else {
                let fileURL = try recoveryStore.fileURL(for: point)
                _ = try await Task.detached { [operations] in try operations.restoreSQLFile(connection: connection, fileURL: fileURL, confirmed: true, allowWrite: false) }.value
            }
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "rollback", summary: "Restored recovery point", createdAt: Date(), recoveryPointID: point.id, rowsAffected: nil, succeeded: true, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return true }
            await refreshTables()
            if let table = selectedTable { await openTable(table) }
            isLoading = false
            return true
        } catch {
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = executionError(error)
                isLoading = false
            }
            return false
        }
    }

    func configureBackupSchedule(profileID: UUID, isEnabled: Bool, intervalHours: Int, retentionCount: Int) {
        let nextRun = Date().addingTimeInterval(TimeInterval(max(1, intervalHours)) * 3_600)
        let schedule = DatabaseBackupSchedule(profileID: profileID, isEnabled: isEnabled, intervalHours: intervalHours, retentionCount: retentionCount, nextRunAt: nextRun)
        backupSchedules.removeAll { $0.profileID == profileID }
        backupSchedules.append(schedule)
        persistBackupSchedules()
        refreshBackupTimer()
    }

    func createBackup(profileID: UUID, reason: String = "Manual backup") async -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { errorMessage = "The backup connection no longer exists."; return false }
        let generation = profileGeneration
        do {
            let point = try await createRecoveryPoint(profile: profile, reason: reason)
            pruneRecoveryPoints(for: profile.id)
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "backup", summary: reason, createdAt: Date(), recoveryPointID: point.id, rowsAffected: nil, succeeded: true, errorMessage: nil))
            return true
        } catch {
            let sanitizedError = executionError(error)
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "backup", summary: "Backup failed", createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: false, errorMessage: sanitizedError))
            if isCurrent(profileID: profileID, generation: generation) {
                errorMessage = sanitizedError
            }
            return false
        }
    }

    private func runScheduledBackups() {
        let now = Date()
        for schedule in backupSchedules where schedule.isEnabled && schedule.nextRunAt <= now {
            Task { [weak self] in
                guard let self else { return }
                let succeeded = await self.createBackup(profileID: schedule.profileID, reason: "Scheduled backup")
                self.advanceBackupSchedule(for: schedule.profileID, succeeded: succeeded)
            }
        }
    }

    private func refreshBackupTimer() {
        let needsTimer = backupSchedules.contains(where: \.isEnabled)
        if needsTimer, backupTimer == nil {
            backupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.runScheduledBackups() }
            }
        } else if !needsTimer {
            backupTimer?.invalidate()
            backupTimer = nil
        }
    }

    private func advanceBackupSchedule(for profileID: UUID, succeeded: Bool) {
        guard let index = backupSchedules.firstIndex(where: { $0.profileID == profileID }) else { return }
        let interval = TimeInterval(max(1, backupSchedules[index].intervalHours)) * 3_600
        backupSchedules[index].nextRunAt = Date().addingTimeInterval(succeeded ? interval : min(interval, 300))
        persistBackupSchedules()
    }

    private func pruneRecoveryPoints(for profileID: UUID) {
        let retention = backupSchedules.first(where: { $0.profileID == profileID })?.retentionCount ?? 14
        let points = recoveryStore.recoveryPoints(for: profileID)
        for point in points.dropFirst(retention) { try? recoveryStore.delete(point) }
        recoveryPoints = recoveryStore.recoveryPoints()
    }

    private func persistBackupSchedules() {
        do { try connectionStore.saveBackupSchedules(backupSchedules) }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Redis workspace

    func loadRedisKeys(pattern: String, reset: Bool = true) async {
        guard let profile = selectedProfile, profile.kind == .redis else { return }
        let generation = profileGeneration
        let cursor = reset ? "0" : redisNextCursor
        if !reset && cursor == "0" { return }
        let startedAt = Date()
        let includeSize = redisIncludeSize
        isLoading = true
        errorMessage = nil
        setConnectionStatus(.connecting, for: profile.id)
        do {
            let connection = connection(profile)
            let result = try await Task.detached { [operations] in
                try operations.redisScan(connection: connection, cursor: cursor, pattern: pattern.isEmpty ? "*" : pattern, count: 100, includeSize: includeSize)
            }.value
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .redis, operation: "SCAN", startedAt: startedAt, durationMilliseconds: duration, status: .succeeded, rowsReturned: result.keys.count, rowsAffected: nil, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            setConnectionStatus(.connected, for: profile.id)
            redisKeys = reset ? result.keys : Array(Dictionary(grouping: redisKeys + result.keys, by: \.key).compactMap { $0.value.first })
            redisNextCursor = result.nextCursor
        } catch {
            let sanitizedError = executionError(error)
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .redis, operation: "SCAN", startedAt: startedAt, durationMilliseconds: duration, status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: sanitizedError))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            errorMessage = sanitizedError
            setConnectionStatus(.failed, for: profile.id)
        }
        if isCurrent(profileID: profile.id, generation: generation) { isLoading = false }
    }

    func loadRedisKey(_ key: String) async {
        guard let profile = selectedProfile, profile.kind == .redis else { return }
        let generation = profileGeneration
        let startedAt = Date()
        isLoading = true
        errorMessage = nil
        do {
            let connection = connection(profile)
            let detail = try await Task.detached { [operations] in
                try operations.redisGetKey(connection: connection, key: key)
            }.value
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .redis, operation: "GET \(key)", startedAt: startedAt, durationMilliseconds: duration, status: .succeeded, rowsReturned: 1, rowsAffected: nil, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            setConnectionStatus(.connected, for: profile.id)
            redisSelectedKey = detail
        } catch {
            let sanitizedError = executionError(error)
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .redis, operation: "GET \(key)", startedAt: startedAt, durationMilliseconds: duration, status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: sanitizedError))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            errorMessage = sanitizedError
            setConnectionStatus(.failed, for: profile.id)
        }
        if isCurrent(profileID: profile.id, generation: generation) { isLoading = false }
    }

    func saveRedisString(key: String, value: String, ttl: Int64?, confirmed: Bool) async -> Bool {
        await performRedisWrite(summary: "Updated Redis string \(key)", confirmed: confirmed) { connection, operations in
            try operations.redisSetString(connection: connection, key: key, value: value, ttl: ttl, confirmed: confirmed, allowWrite: false)
        } afterSuccess: {
            await self.loadRedisKey(key)
        }
    }

    func replaceRedisHash(key: String, entries: [RedisHashEntry], confirmed: Bool) async -> Bool {
        await performRedisWrite(summary: "Updated Redis hash \(key)", confirmed: confirmed) { connection, operations in
            try operations.redisReplaceHash(connection: connection, key: key, entries: entries, confirmed: confirmed, allowWrite: false)
        } afterSuccess: {
            await self.loadRedisKey(key)
        }
    }

    func setRedisTTL(key: String, ttl: Int64, confirmed: Bool) async -> Bool {
        await performRedisWrite(summary: "Changed Redis TTL for \(key)", confirmed: confirmed) { connection, operations in
            try operations.redisSetTTL(connection: connection, key: key, ttl: ttl, confirmed: confirmed, allowWrite: false)
        } afterSuccess: {
            await self.loadRedisKey(key)
        }
    }

    func renameRedisKey(key: String, newKey: String, confirmed: Bool) async -> Bool {
        await performRedisWrite(summary: "Renamed Redis key \(key)", confirmed: confirmed) { connection, operations in
            try operations.redisRenameKey(connection: connection, key: key, newKey: newKey, confirmed: confirmed, allowWrite: false)
        } afterSuccess: {
            await self.loadRedisKey(newKey)
        }
    }

    func deleteRedisKey(key: String, confirmed: Bool) async -> Bool {
        await performRedisWrite(summary: "Deleted Redis key \(key)", confirmed: confirmed) { connection, operations in
            try operations.redisDeleteKey(connection: connection, key: key, confirmed: confirmed, allowWrite: false)
        } afterSuccess: {
            self.redisSelectedKey = nil
            self.redisKeys.removeAll { $0.key == key }
        }
    }

    func flushRedisDatabase(confirmed: Bool) async -> Bool {
        await performRedisWrite(summary: "Cleared Redis database", confirmed: confirmed) { connection, operations in
            try operations.redisFlushDatabase(connection: connection, confirmed: confirmed, allowWrite: false)
        } afterSuccess: {
            self.redisKeys = []
            self.redisNextCursor = "0"
            self.redisSelectedKey = nil
        }
    }

    private func performRedisWrite(
        summary: String,
        confirmed: Bool,
        operation: @escaping @Sendable (DatabaseConnection, any DatabaseOperations) throws -> Void,
        afterSuccess: @escaping @MainActor () async -> Void
    ) async -> Bool {
        guard let profile = selectedProfile, profile.kind == .redis else { return false }
        let generation = profileGeneration
        let startedAt = Date()
        isLoading = true
        errorMessage = nil
        do {
            let activeConnection = connection(profile)
            try await Task.detached { [operations] in try operation(activeConnection, operations) }.value
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .redis, operation: summary, startedAt: startedAt, durationMilliseconds: duration, status: .succeeded, rowsReturned: nil, rowsAffected: nil, errorMessage: nil))
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "redis", summary: summary, createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: true, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return true }
            setConnectionStatus(.connected, for: profile.id)
            await afterSuccess()
            isLoading = false
            return true
        } catch {
            let sanitizedError = executionError(error)
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .redis, operation: summary, startedAt: startedAt, durationMilliseconds: duration, status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: sanitizedError))
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "redis", summary: summary, createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: false, errorMessage: sanitizedError))
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = sanitizedError
                setConnectionStatus(.failed, for: profile.id)
                isLoading = false
            }
            return false
        }
    }

    // MARK: - Nacos workspace

    func loadNacosConfigs(dataId: String, group: String, page: Int = 1) async {
        guard let profile = selectedProfile, profile.kind == .nacos else { return }
        let generation = profileGeneration
        let startedAt = Date()
        isLoading = true
        errorMessage = nil
        setConnectionStatus(.connecting, for: profile.id)
        do {
            let connection = connection(profile)
            let result = try await Task.detached { [operations] in
                try operations.nacosListConfigs(connection: connection, dataId: dataId, group: group, page: page, pageSize: 100)
            }.value
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: "LIST CONFIGS", startedAt: startedAt, durationMilliseconds: duration, status: .succeeded, rowsReturned: result.items.count, rowsAffected: nil, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            setConnectionStatus(.connected, for: profile.id)
            nacosConfigs = result.items
            nacosConfigTotalCount = result.totalCount
        } catch {
            let sanitizedError = executionError(error)
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: "LIST CONFIGS", startedAt: startedAt, durationMilliseconds: duration, status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: sanitizedError))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            errorMessage = sanitizedError
            setConnectionStatus(.failed, for: profile.id)
        }
        if isCurrent(profileID: profile.id, generation: generation) { isLoading = false }
    }

    func loadNacosConfig(dataId: String, group: String) async {
        guard let profile = selectedProfile, profile.kind == .nacos else { return }
        let generation = profileGeneration
        let startedAt = Date()
        isLoading = true
        errorMessage = nil
        do {
            let connection = connection(profile)
            let detail = try await Task.detached { [operations] in
                try operations.nacosGetConfig(connection: connection, dataId: dataId, group: group)
            }.value
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: "GET CONFIG \(group)/\(dataId)", startedAt: startedAt, durationMilliseconds: duration, status: .succeeded, rowsReturned: 1, rowsAffected: nil, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            setConnectionStatus(.connected, for: profile.id)
            nacosSelectedConfig = detail
        } catch {
            let sanitizedError = executionError(error)
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: "GET CONFIG \(group)/\(dataId)", startedAt: startedAt, durationMilliseconds: duration, status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: sanitizedError))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            errorMessage = sanitizedError
            setConnectionStatus(.failed, for: profile.id)
        }
        if isCurrent(profileID: profile.id, generation: generation) { isLoading = false }
    }

    func publishNacosConfig(dataId: String, group: String, content: String, type: String?, confirmed: Bool) async -> Bool {
        guard let profile = selectedProfile, profile.kind == .nacos else { return false }
        let summary = "Published Nacos config \(group)/\(dataId)"
        return await performNacosWrite(profile: profile, summary: summary) { connection, operations in
            try operations.nacosPublishConfig(connection: connection, dataId: dataId, group: group, content: content, type: type, confirmed: confirmed, allowWrite: false)
        } afterSuccess: {
            await self.loadNacosConfig(dataId: dataId, group: group)
        }
    }

    func deleteNacosConfig(dataId: String, group: String, confirmed: Bool) async -> Bool {
        guard let profile = selectedProfile, profile.kind == .nacos else { return false }
        let summary = "Deleted Nacos config \(group)/\(dataId)"
        return await performNacosWrite(profile: profile, summary: summary) { connection, operations in
            try operations.nacosDeleteConfig(connection: connection, dataId: dataId, group: group, confirmed: confirmed, allowWrite: false)
        } afterSuccess: {
            self.nacosSelectedConfig = nil
            self.nacosConfigs.removeAll { $0.dataId == dataId && $0.group == group }
        }
    }

    func loadNacosServices(serviceName: String, group: String, page: Int = 1) async {
        guard let profile = selectedProfile, profile.kind == .nacos else { return }
        let generation = profileGeneration
        let startedAt = Date()
        isLoading = true
        errorMessage = nil
        setConnectionStatus(.connecting, for: profile.id)
        do {
            let connection = connection(profile)
            let result = try await Task.detached { [operations] in
                try operations.nacosListServices(connection: connection, serviceName: serviceName, group: group, page: page, pageSize: 100)
            }.value
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: "LIST SERVICES", startedAt: startedAt, durationMilliseconds: duration, status: .succeeded, rowsReturned: result.items.count, rowsAffected: nil, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            setConnectionStatus(.connected, for: profile.id)
            nacosServices = result.items
            nacosServiceTotalCount = result.totalCount
        } catch {
            let sanitizedError = executionError(error)
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: "LIST SERVICES", startedAt: startedAt, durationMilliseconds: duration, status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: sanitizedError))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            errorMessage = sanitizedError
            setConnectionStatus(.failed, for: profile.id)
        }
        if isCurrent(profileID: profile.id, generation: generation) { isLoading = false }
    }

    func loadNacosInstances(serviceName: String, group: String) async {
        guard let profile = selectedProfile, profile.kind == .nacos else { return }
        let generation = profileGeneration
        let startedAt = Date()
        isLoading = true
        errorMessage = nil
        do {
            let connection = connection(profile)
            let items = try await Task.detached { [operations] in
                try operations.nacosListInstances(connection: connection, serviceName: serviceName, group: group)
            }.value
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: "LIST INSTANCES", startedAt: startedAt, durationMilliseconds: duration, status: .succeeded, rowsReturned: items.count, rowsAffected: nil, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            setConnectionStatus(.connected, for: profile.id)
            nacosInstances = items
        } catch {
            let sanitizedError = executionError(error)
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: "LIST INSTANCES", startedAt: startedAt, durationMilliseconds: duration, status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: sanitizedError))
            guard isCurrent(profileID: profile.id, generation: generation) else { return }
            errorMessage = sanitizedError
            setConnectionStatus(.failed, for: profile.id)
        }
        if isCurrent(profileID: profile.id, generation: generation) { isLoading = false }
    }

    private func performNacosWrite(
        profile: DatabaseProfile,
        summary: String,
        operation: @escaping @Sendable (DatabaseConnection, any DatabaseOperations) throws -> Void,
        afterSuccess: @escaping @MainActor () async -> Void
    ) async -> Bool {
        let generation = profileGeneration
        let startedAt = Date()
        isLoading = true
        errorMessage = nil
        do {
            let activeConnection = connection(profile)
            try await Task.detached { [operations] in try operation(activeConnection, operations) }.value
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: summary, startedAt: startedAt, durationMilliseconds: duration, status: .succeeded, rowsReturned: nil, rowsAffected: nil, errorMessage: nil))
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "nacos", summary: summary, createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: true, errorMessage: nil))
            guard isCurrent(profileID: profile.id, generation: generation) else { return true }
            setConnectionStatus(.connected, for: profile.id)
            await afterSuccess()
            isLoading = false
            return true
        } catch {
            let sanitizedError = executionError(error)
            let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            appendExecutionEvent(DatabaseExecutionEvent(id: UUID(), profileID: profile.id, profileName: profile.name, source: .nacos, operation: summary, startedAt: startedAt, durationMilliseconds: duration, status: .failed, rowsReturned: nil, rowsAffected: nil, errorMessage: sanitizedError))
            appendAudit(DatabaseAuditEntry(id: UUID(), profileID: profile.id, action: "nacos", summary: summary, createdAt: Date(), recoveryPointID: nil, rowsAffected: nil, succeeded: false, errorMessage: sanitizedError))
            if isCurrent(profileID: profile.id, generation: generation) {
                errorMessage = sanitizedError
                setConnectionStatus(.failed, for: profile.id)
                isLoading = false
            }
            return false
        }
    }

    private func clearSpecializedWorkspace() {
        redisKeys = []
        redisNextCursor = "0"
        redisSelectedKey = nil
        nacosConfigs = []
        nacosConfigTotalCount = 0
        nacosSelectedConfig = nil
        nacosServices = []
        nacosServiceTotalCount = 0
        nacosInstances = []
    }

    private func migrateLegacyGroupsIfNeeded() {
        let legacyNames = profiles
            .filter { $0.folderID == nil }
            .map(\.group)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !legacyNames.isEmpty else { return }

        var updatedFolders = folders
        for name in Set(legacyNames) where !updatedFolders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            updatedFolders.append(DatabaseConnectionFolder(name: name))
        }
        let folderByName = Dictionary(uniqueKeysWithValues: updatedFolders.map { ($0.name.lowercased(), $0.id) })
        let updatedProfiles = profiles.map { profile -> DatabaseProfile in
            guard profile.folderID == nil else { return profile }
            let legacyName = profile.group.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let folderID = folderByName[legacyName.lowercased()] else { return profile }
            var profile = profile
            profile.folderID = folderID
            profile.group = ""
            return profile
        }
        do {
            try connectionStore.saveFolders(updatedFolders)
            try connectionStore.save(updatedProfiles)
            folders = sortedFolders(updatedFolders)
            profiles = sortedProfiles(updatedProfiles)
        } catch {
            // Existing connections remain usable even if the one-time local
            // migration cannot be persisted. Try again on the next launch.
        }
    }

    private func sortedProfiles(_ values: [DatabaseProfile]) -> [DatabaseProfile] {
        values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sortedFolders(_ values: [DatabaseConnectionFolder]) -> [DatabaseConnectionFolder] {
        values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func createRecoveryPoint(profile: DatabaseProfile, reason: String) async throws -> DatabaseRecoveryPoint {
        let connection = connection(profile)
        let generation = profileGeneration
        let tracksUI = selectedProfileID == profile.id
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-recovery-\(UUID().uuidString).sql")
        if tracksUI { backupProgress = 0 }
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            if tracksUI && isCurrent(profileID: profile.id, generation: generation) { backupProgress = nil }
        }
        let export = try await Task.detached { [operations] in
            try operations.exportSQLToFile(
                connection: connection,
                options: DatabaseSQLExportOptions(schema: "", selectedTables: [], includeStructure: true, includeData: true, limit: 0),
                outputURL: temporaryURL
            )
        }.value
        if tracksUI && isCurrent(profileID: profile.id, generation: generation) { backupProgress = 0.7 }
        let point = try recoveryStore.createRecoveryPoint(profileID: profile.id, reason: reason, fileURL: temporaryURL, expectedSHA256: export.sha256) { [weak self] progress in
            guard let self, tracksUI, self.isCurrent(profileID: profile.id, generation: generation) else { return }
            self.backupProgress = 0.7 + progress * 0.3
        }
        recoveryPoints = recoveryStore.recoveryPoints()
        return point
    }

    private func appendAudit(_ entry: DatabaseAuditEntry) {
        do {
            try recoveryStore.appendAudit(entry)
            auditEntries = recoveryStore.auditEntries()
        } catch {
            // Recovery and audit failures are surfaced only when they prevent a
            // write. A completed write must not be misreported as failed.
        }
    }

    private func appendExecutionEvent(_ event: DatabaseExecutionEvent) {
        do {
            try recoveryStore.appendExecutionEvent(event)
            executionEvents = recoveryStore.executionEvents()
        } catch {
            // Execution logging must never change the result of a database operation.
        }
    }

    private func executionError(_ error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.count > 500 ? "\(message.prefix(497))..." : message
    }

    private func activateProfile(_ profile: DatabaseProfile) {
        profileGeneration &+= 1
        tableRequestID = nil
        selectedProfileID = profile.id
        selectedTable = nil
        openTableTabs = []
        columns = []
        columnTypes = [:]
        rows = []
        sourceRows = []
        totalRows = 0
        currentOffset = 0
        primaryKeyColumns = []
        indexes = []
        foreignKeys = []
        tables = []
        databaseOptions = []
        objects = [:]
        lastExplainResult = nil
        lastDiagnostics = nil
        backupProgress = nil
        clearSQLResults()
        resetSQLWorkspace()
        clearSpecializedWorkspace()
        errorMessage = nil
        isLoading = true
        setConnectionStatus(.connecting, for: profile.id)
    }

    private func clearProfileScopedState() {
        profileGeneration &+= 1
        tableRequestID = nil
        selectedProfileID = nil
        selectedTable = nil
        openTableTabs = []
        columns = []
        columnTypes = [:]
        rows = []
        sourceRows = []
        totalRows = 0
        currentOffset = 0
        primaryKeyColumns = []
        indexes = []
        foreignKeys = []
        tables = []
        databaseOptions = []
        objects = [:]
        lastExplainResult = nil
        lastDiagnostics = nil
        backupProgress = nil
        resetSQLWorkspace()
        clearSpecializedWorkspace()
        errorMessage = nil
        isLoading = false
    }

    private func resetSQLWorkspace() {
        let tab = DatabaseSQLTab(title: "Query 1")
        sqlTabs = [tab]
        selectedSQLTabID = tab.id
    }

    private func isCurrent(profileID: UUID, generation: UInt64) -> Bool {
        selectedProfileID == profileID && profileGeneration == generation
    }

    private func clearSQLResults() {
        sqlTabs = sqlTabs.map { tab in
            var tab = tab
            tab.result = nil; tab.resultColumns = []; tab.rowsAffected = nil; tab.execution = nil; tab.errorMessage = nil; tab.isRunning = false
            return tab
        }
    }

    private func updateSQLTab(_ id: UUID, update: (inout DatabaseSQLTab) -> Void) {
        guard let index = sqlTabs.firstIndex(where: { $0.id == id }) else { return }
        update(&sqlTabs[index])
    }

    private func recordSQLHistory(profileID: UUID, sql: String, analysis: DatabaseSQLAnalysis, execution: DatabaseSQLExecution) {
        let entry = DatabaseSQLHistoryEntry(
            profileID: profileID,
            sql: sql,
            kind: analysis.kind,
            executedAt: execution.startedAt,
            durationMilliseconds: execution.durationMilliseconds,
            rowsReturned: execution.rowsReturned,
            rowsAffected: execution.rowsAffected
        )
        do {
            try connectionStore.appendSQLHistory(entry)
            sqlHistory.insert(entry, at: 0)
            sqlHistory = Array(sqlHistory.prefix(100))
        } catch {
            // A successful database operation must not be reported as failed
            // merely because the local convenience history cannot be saved.
        }
    }

    private func keyValues(_ row: DatabaseRow) -> DatabaseRow? {
        guard !primaryKeyColumns.isEmpty else { return nil }
        var key: DatabaseRow = [:]
        for column in primaryKeyColumns { guard let value = row[column] else { return nil }; key[column] = value }
        return key
    }

    private func masked(_ result: DatabaseQueryResult) -> DatabaseQueryResult {
        DatabaseQueryResult(rows: masked(result.rows), columns: result.columns, truncated: result.truncated, totalRows: result.totalRows)
    }

    private func masked(_ rows: [DatabaseRow]) -> [DatabaseRow] {
        guard let profile = selectedProfile else { return rows }
        return DatabaseSensitiveFieldMasker.mask(rows: rows, enabled: profile.maskSensitiveFields, patterns: profile.sensitiveColumnPatterns)
    }

    private func typedValue(_ value: DatabaseValue, for column: String) -> DatabaseValue {
        guard case let .string(text) = value else { return value }
        let type = columnTypes[column] ?? ""
        if type.contains("int"), let number = Int64(text) { return .integer(number) }
        if type.contains("numeric") || type.contains("decimal") { return .decimal(text) }
        if type.contains("double") || type.contains("float") || type.contains("real"), let number = Double(text) { return .number(number) }
        if type == "boolean" || type == "bool" {
            if ["true", "1"].contains(text.lowercased()) { return .bool(true) }
            if ["false", "0"].contains(text.lowercased()) { return .bool(false) }
        }
        if type == "date" { return .object(["date": .string(text)]) }
        if type.starts(with: "time") && !type.contains("stamp") { return .object(["time": .string(text)]) }
        if type.contains("timestamp with time zone") || type == "timestamptz" { return .object(["timestampWithTimeZone": .string(text)]) }
        if type.contains("timestamp") || type.contains("datetime") { return .object(["datetime": .string(text)]) }
        if type == "uuid" { return .object(["uuid": .string(text)]) }
        if selectedProfile?.kind == .mongodb,
           ["document", "array", "objectid", "date", "value"].contains(type),
           let parsed = try? JSONDecoder().decode(DatabaseValue.self, from: Data(text.utf8)) {
            return parsed
        }
        if type == "json" || type == "jsonb",
           let parsed = try? JSONDecoder().decode(DatabaseValue.self, from: Data(text.utf8)) {
            return .object(["json": parsed])
        }
        return value
    }

    var selectedProfile: DatabaseProfile? { profiles.first { $0.id == selectedProfileID } }

    func connectionStatus(for profile: DatabaseProfile) -> DatabaseConnectionStatus {
        connectionStatuses[profile.id] ?? .idle
    }

    var connectedProfileCount: Int {
        connectionStatuses.values.reduce(into: 0) { count, status in
            if status == .connected { count += 1 }
        }
    }

    private func setConnectionStatus(_ status: DatabaseConnectionStatus, for profileID: UUID) {
        connectionStatuses[profileID] = status
    }

    private func connection(_ profile: DatabaseProfile, password: String? = nil) -> DatabaseConnection {
        DatabaseConnection(kind: profile.kind, host: profile.host, port: profile.port, username: profile.username,
            password: password ?? connectionStore.password(for: profile.id), database: profile.database, path: profile.path, ssl: profile.ssl,
            caCertificatePath: profile.caCertificatePath, serverName: profile.serverName,
            sshHost: profile.sshHost, sshPort: profile.sshPort, sshUsername: profile.sshUsername,
            sshKeyPath: profile.sshKeyPath, sshLocalPort: profile.sshLocalPort, proxyURL: profile.proxyURL,
            readOnly: profile.readOnly, productionProtection: profile.productionProtection)
    }

    nonisolated private static func quotedIdentifier(_ identifier: String, for kind: DatabaseKind) -> String {
        if kind == .mysql || kind == .mariadb { return "`\(identifier.replacingOccurrences(of: "`", with: "``"))`" }
        if kind == .sqlserver { return "[\(identifier.replacingOccurrences(of: "]", with: "]]"))]" }
        return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private extension DatabaseValue {
    var text: String? {
        switch self { case let .string(value): value; case let .integer(value): String(value); case let .number(value): String(value); default: nil }
    }
    var integerValue: Int64? { if case let .integer(value) = self { value } else { nil } }
}

private extension Dictionary where Key == String, Value == DatabaseValue {
    func mapValuesWithKeys(_ transform: (String, DatabaseValue) -> DatabaseValue) -> Self {
        Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}

struct DatabaseCellDraft: Sendable {
    let rowIndex: Int
    let column: String
    let value: DatabaseValue
}

enum DatabaseTransferFormat: String, Sendable { case csv, json, sql }
private enum DatabaseTransferError: LocalizedError { case tableRequired; var errorDescription: String? { "Select a table first." } }

import Foundation

package enum DatabaseKind: String, Codable, CaseIterable, Sendable {
    case mysql
    case mariadb
    case postgresql
    case sqlite
    case sqlserver
    case mongodb
    case redis
    case nacos

    package var isSQLDatabase: Bool {
        switch self {
        case .mysql, .mariadb, .postgresql, .sqlite, .sqlserver: true
        case .mongodb, .redis, .nacos: false
        }
    }

    package var supportsDataGrid: Bool { isSQLDatabase || self == .mongodb }
}

package struct DatabaseConnection: Codable, Equatable, Sendable {
    package let kind: DatabaseKind
    package var host = ""
    package var port: UInt16 = 0
    package var username = ""
    package var password = ""
    package var database = ""
    package var path = ""
    package var ssl = false
    package var caCertificatePath = ""
    package var serverName = ""
    package var sshHost = ""
    package var sshPort: UInt16 = 0
    package var sshUsername = ""
    package var sshKeyPath = ""
    package var sshLocalPort: UInt16 = 0
    package var proxyURL = ""
    package var readOnly = false
    package var productionProtection = false

    private enum CodingKeys: String, CodingKey {
        case kind, host, port, username, password, database, path, ssl
        case caCertificatePath, serverName, sshHost, sshPort, sshUsername, sshKeyPath, sshLocalPort, proxyURL
        case readOnly, productionProtection
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(DatabaseKind.self, forKey: .kind)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 0
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        database = try container.decodeIfPresent(String.self, forKey: .database) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        ssl = try container.decodeIfPresent(Bool.self, forKey: .ssl) ?? false
        caCertificatePath = try container.decodeIfPresent(String.self, forKey: .caCertificatePath) ?? ""
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName) ?? ""
        sshHost = try container.decodeIfPresent(String.self, forKey: .sshHost) ?? ""
        sshPort = try container.decodeIfPresent(UInt16.self, forKey: .sshPort) ?? 0
        sshUsername = try container.decodeIfPresent(String.self, forKey: .sshUsername) ?? ""
        sshKeyPath = try container.decodeIfPresent(String.self, forKey: .sshKeyPath) ?? ""
        sshLocalPort = try container.decodeIfPresent(UInt16.self, forKey: .sshLocalPort) ?? 0
        proxyURL = try container.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        productionProtection = try container.decodeIfPresent(Bool.self, forKey: .productionProtection) ?? false
    }

    package init(
        kind: DatabaseKind,
        host: String = "",
        port: UInt16 = 0,
        username: String = "",
        password: String = "",
        database: String = "",
        path: String = "",
        ssl: Bool = false,
        caCertificatePath: String = "",
        serverName: String = "",
        sshHost: String = "",
        sshPort: UInt16 = 0,
        sshUsername: String = "",
        sshKeyPath: String = "",
        sshLocalPort: UInt16 = 0,
        proxyURL: String = "",
        readOnly: Bool = false,
        productionProtection: Bool = false
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.path = path
        self.ssl = ssl
        self.caCertificatePath = caCertificatePath
        self.serverName = serverName
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUsername = sshUsername
        self.sshKeyPath = sshKeyPath
        self.sshLocalPort = sshLocalPort
        self.proxyURL = proxyURL
        self.readOnly = readOnly
        self.productionProtection = productionProtection
    }
}

package struct DatabaseCapabilities: Codable, Equatable, Sendable {
    package let protocolVersion: Int
    package let databaseTypes: [String]
    package let features: [String]
}

package struct DatabaseSQLFileExportResult: Codable, Equatable, Sendable {
    package let path: String
    package let byteCount: Int
    package let sha256: String
}

/// Redis and Nacos are deliberately modeled as specialised workspaces rather
/// than as SQL tables. Keeping their protocol types separate prevents callers
/// from accidentally issuing SQL-style operations to a non-SQL service.
package struct RedisKeySummary: Codable, Equatable, Identifiable, Sendable {
    package let key: String
    package let type: String
    package let ttl: Int64
    package let size: Int64

    package var id: String { key }
}

package struct RedisScanResult: Codable, Equatable, Sendable {
    package let keys: [RedisKeySummary]
    package let nextCursor: String
}

package struct RedisHashEntry: Codable, Equatable, Identifiable, Sendable {
    package let field: String
    package let value: String

    package var id: String { field }
    package init(field: String, value: String) { self.field = field; self.value = value }
}

package struct RedisKeyDetail: Codable, Equatable, Sendable {
    package let key: String
    package let type: String
    package let ttl: Int64
    package let size: Int64
    package let stringValue: String?
    package let hashEntries: [RedisHashEntry]
}

package struct NacosConfigSummary: Codable, Equatable, Identifiable, Sendable {
    package let dataId: String
    package let group: String
    package let namespace: String
    package let type: String?
    package let md5: String?

    package var id: String { "\(namespace)|\(group)|\(dataId)" }
}

package struct NacosConfigList: Codable, Equatable, Sendable {
    package let items: [NacosConfigSummary]
    package let totalCount: Int
}

package struct NacosConfigDetail: Codable, Equatable, Sendable {
    package let dataId: String
    package let group: String
    package let namespace: String
    package let content: String
    package let type: String?
    package let md5: String?
}

package struct NacosServiceSummary: Codable, Equatable, Identifiable, Sendable {
    package let name: String
    package let group: String
    package let clusterCount: Int

    package var id: String { "\(group)|\(name)" }
}

package struct NacosServiceList: Codable, Equatable, Sendable {
    package let items: [NacosServiceSummary]
    package let totalCount: Int
}

package struct NacosInstanceSummary: Codable, Equatable, Identifiable, Sendable {
    package let ip: String
    package let port: Int
    package let healthy: Bool
    package let enabled: Bool
    package let ephemeral: Bool
    package let clusterName: String?

    package var id: String { "\(ip):\(port):\(clusterName ?? "")" }
}

package enum DatabaseValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case decimal(String)
    case string(String)
    case binary(Data)
    case object([String: DatabaseValue])
    case array([DatabaseValue])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let tagged = try? container.decode([String: String].self), tagged.count == 1, let value = tagged["decimal"] {
            self = .decimal(value)
        } else if let tagged = try? container.decode([String: String].self), tagged.count == 1,
                  let encoded = tagged["binary"],
                  let value = Data(base64Encoded: encoded) {
            self = .binary(value)
        }
        else if let value = try? container.decode([String: DatabaseValue].self) { self = .object(value) }
        else { self = .array(try container.decode([DatabaseValue].self)) }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .decimal(value): try container.encode(["decimal": value])
        case let .string(value): try container.encode(value)
        case let .binary(value): try container.encode(["binary": value.base64EncodedString()])
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        }
    }

    /// A stable value representation for grids, details panels, and metadata.
    /// Keeping this on the protocol value prevents an empty string from being
    /// rendered like a missing value in one of the database workspaces.
    package var displayText: String {
        switch self {
        case .null: "NULL"
        case let .bool(value): value ? "true" : "false"
        case let .integer(value): String(value)
        case let .number(value): String(value)
        case let .decimal(value): value
        case let .string(value): value.isEmpty ? "\"\"" : value
        case let .binary(value): "Binary (\(value.count) bytes)"
        case let .object(value): Self.jsonText(.object(value))
        case let .array(value): Self.jsonText(.array(value))
        }
    }

    private static func jsonText(_ value: DatabaseValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}

package typealias DatabaseRow = [String: DatabaseValue]

package struct DatabaseQueryResult: Codable, Equatable, Sendable {
    package let rows: [DatabaseRow]
    package let columns: [String]?
    package let truncated: Bool
    package var totalRows: Int64?

    package init(rows: [DatabaseRow], columns: [String]? = nil, truncated: Bool, totalRows: Int64? = nil) {
        self.rows = rows
        self.columns = columns
        self.truncated = truncated
        self.totalRows = totalRows
    }

    private enum CodingKeys: String, CodingKey { case rows, columns, truncated, totalRows }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decode([DatabaseRow].self, forKey: .rows)
        columns = try container.decodeIfPresent([String].self, forKey: .columns)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        totalRows = try container.decodeIfPresent(Int64.self, forKey: .totalRows)
    }
}

package struct DatabaseExecuteResult: Codable, Equatable, Sendable {
    package let rowsAffected: UInt64
}

package enum DatabaseMutationAction: String, Codable, Sendable { case insert, update, delete }

package struct DatabaseMutation: Codable, Equatable, Sendable {
    package let action: DatabaseMutationAction
    package let table: String
    package var values: DatabaseRow = [:]
    package var key: DatabaseRow = [:]
}

package enum DatabaseFilterOperator: String, Codable, CaseIterable, Sendable { case equals, notEquals, greaterThan, lessThan, contains, startsWith, isNull, isNotNull }
package enum DatabaseFilterJoin: String, Codable, CaseIterable, Sendable { case and, or }
package struct DatabaseFilter: Codable, Equatable, Sendable {
    package let column: String
    package let `operator`: DatabaseFilterOperator
    package var value: DatabaseValue = .null
    package var join: DatabaseFilterJoin = .and
    package init(column: String, operator: DatabaseFilterOperator = .equals, value: DatabaseValue = .null, join: DatabaseFilterJoin = .and) {
        self.column = column; self.operator = `operator`; self.value = value; self.join = join
    }
}
package struct DatabaseSort: Codable, Equatable, Sendable {
    package let column: String
    package var descending = false
    package init(column: String, descending: Bool = false) { self.column = column; self.descending = descending }
}
package struct DatabaseSQLExportOptions: Codable, Equatable, Sendable {
    package var schema = ""
    package var selectedTables: [String] = []
    package var includeStructure = true
    package var includeData = true
    // A SQL backup must be complete. Zero is the sidecar protocol's explicit
    // unbounded sentinel; the sidecar streams rows directly to the output.
    package var limit = 0
}

package enum DatabaseObjectKind: String, Codable, CaseIterable, Sendable {
    case tables
    case views
    case routines
    case triggers
    case sequences
}

package struct DatabaseSchemaChange: Codable, Equatable, Sendable {
    package var operation: String
    package var table = ""
    package var name = ""
    package var oldName = ""
    package var dataType = ""
    package var nullable = true
    package var defaultValue = ""
    package var indexName = ""
    package var indexColumns: [String] = []
    package var constraintName = ""
    package var referencedTable = ""
    package var referencedColumns: [String] = []
    package var sql = ""
    package init(operation: String, table: String = "", name: String = "", oldName: String = "", dataType: String = "", nullable: Bool = true, defaultValue: String = "", indexName: String = "", indexColumns: [String] = [], constraintName: String = "", referencedTable: String = "", referencedColumns: [String] = [], sql: String = "") {
        self.operation = operation; self.table = table; self.name = name; self.oldName = oldName; self.dataType = dataType; self.nullable = nullable; self.defaultValue = defaultValue; self.indexName = indexName; self.indexColumns = indexColumns; self.constraintName = constraintName; self.referencedTable = referencedTable; self.referencedColumns = referencedColumns; self.sql = sql
    }
}

package struct DatabaseTransactionStatement: Codable, Equatable, Sendable {
    package let sql: String
    package var values: [DatabaseValue] = []
}

package struct DatabaseDiagnosticsRequest: Codable, Equatable, Sendable {
    package var kind = "tableSize"
    package var schema = ""
    package var table = ""
    package init(kind: String = "tableSize", schema: String = "", table: String = "") { self.kind = kind; self.schema = schema; self.table = table }
}

package protocol DatabaseOperations: Sendable {
    func capabilities() throws -> DatabaseCapabilities
    func testConnection(_ connection: DatabaseConnection) throws
    func listDatabases(connection: DatabaseConnection) throws -> [String]
    func listTables(connection: DatabaseConnection, schema: String) throws -> [DatabaseRow]
    func describeTable(connection: DatabaseConnection, schema: String, table: String) throws -> [DatabaseRow]
    func listIndexes(connection: DatabaseConnection, schema: String, table: String) throws -> [DatabaseRow]
    func listForeignKeys(connection: DatabaseConnection, schema: String, table: String) throws -> [DatabaseRow]
    func listObjects(connection: DatabaseConnection, schema: String, kind: DatabaseObjectKind) throws -> [DatabaseRow]
    func pageTable(connection: DatabaseConnection, schema: String, table: String, limit: Int, offset: Int, filters: [DatabaseFilter], sort: [DatabaseSort]) throws -> DatabaseQueryResult
    func query(connection: DatabaseConnection, sql: String, values: [DatabaseValue], limit: Int) throws -> DatabaseQueryResult
    func execute(connection: DatabaseConnection, sql: String, values: [DatabaseValue], confirmed: Bool, allowWrite: Bool) throws -> DatabaseExecuteResult
    func applyChanges(connection: DatabaseConnection, schema: String, mutations: [DatabaseMutation], confirmed: Bool, allowWrite: Bool) throws -> DatabaseExecuteResult
    func applySchemaChange(connection: DatabaseConnection, schema: String, change: DatabaseSchemaChange, confirmed: Bool, allowWrite: Bool) throws -> DatabaseExecuteResult
    func explain(connection: DatabaseConnection, sql: String, format: String) throws -> DatabaseQueryResult
    func diagnostics(connection: DatabaseConnection, request: DatabaseDiagnosticsRequest) throws -> DatabaseQueryResult
    func transaction(connection: DatabaseConnection, statements: [DatabaseTransactionStatement], confirmed: Bool, allowWrite: Bool) throws -> DatabaseExecuteResult
    func exportCSV(connection: DatabaseConnection, sql: String, values: [DatabaseValue], limit: Int) throws -> Data
    func exportJSON(connection: DatabaseConnection, sql: String, values: [DatabaseValue], limit: Int) throws -> Data
    func importCSV(connection: DatabaseConnection, schema: String, table: String, data: Data) throws -> DatabaseExecuteResult
    func importJSON(connection: DatabaseConnection, schema: String, table: String, data: Data) throws -> DatabaseExecuteResult
    func exportSQL(connection: DatabaseConnection, options: DatabaseSQLExportOptions) throws -> Data
    func exportSQLToFile(connection: DatabaseConnection, options: DatabaseSQLExportOptions, outputURL: URL) throws -> DatabaseSQLFileExportResult
    func importSQL(connection: DatabaseConnection, data: Data, confirmed: Bool, allowWrite: Bool) throws -> DatabaseExecuteResult
    func importSQLFile(connection: DatabaseConnection, fileURL: URL, confirmed: Bool, allowWrite: Bool) throws -> DatabaseExecuteResult
    func restoreSQL(connection: DatabaseConnection, data: Data, confirmed: Bool, allowWrite: Bool) throws -> DatabaseExecuteResult
    func restoreSQLFile(connection: DatabaseConnection, fileURL: URL, confirmed: Bool, allowWrite: Bool) throws -> DatabaseExecuteResult

    func redisScan(connection: DatabaseConnection, cursor: String, pattern: String, count: Int, includeSize: Bool) throws -> RedisScanResult
    func redisGetKey(connection: DatabaseConnection, key: String) throws -> RedisKeyDetail
    func redisSetString(connection: DatabaseConnection, key: String, value: String, ttl: Int64?, confirmed: Bool, allowWrite: Bool) throws
    func redisReplaceHash(connection: DatabaseConnection, key: String, entries: [RedisHashEntry], confirmed: Bool, allowWrite: Bool) throws
    func redisDeleteKey(connection: DatabaseConnection, key: String, confirmed: Bool, allowWrite: Bool) throws
    func redisRenameKey(connection: DatabaseConnection, key: String, newKey: String, confirmed: Bool, allowWrite: Bool) throws
    func redisSetTTL(connection: DatabaseConnection, key: String, ttl: Int64, confirmed: Bool, allowWrite: Bool) throws
    func redisFlushDatabase(connection: DatabaseConnection, confirmed: Bool, allowWrite: Bool) throws

    func nacosListConfigs(connection: DatabaseConnection, dataId: String, group: String, page: Int, pageSize: Int) throws -> NacosConfigList
    func nacosGetConfig(connection: DatabaseConnection, dataId: String, group: String) throws -> NacosConfigDetail
    func nacosPublishConfig(connection: DatabaseConnection, dataId: String, group: String, content: String, type: String?, confirmed: Bool, allowWrite: Bool) throws
    func nacosDeleteConfig(connection: DatabaseConnection, dataId: String, group: String, confirmed: Bool, allowWrite: Bool) throws
    func nacosListServices(connection: DatabaseConnection, serviceName: String, group: String, page: Int, pageSize: Int) throws -> NacosServiceList
    func nacosListInstances(connection: DatabaseConnection, serviceName: String, group: String) throws -> [NacosInstanceSummary]
}

package extension DatabaseOperations {
    func listDatabases(connection: DatabaseConnection) throws -> [String] { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Database selection is not available for this database service.") }
    func redisScan(connection: DatabaseConnection, cursor: String, pattern: String, count: Int) throws -> RedisScanResult {
        try redisScan(connection: connection, cursor: cursor, pattern: pattern, count: count, includeSize: true)
    }
    func redisScan(connection: DatabaseConnection, cursor: String, pattern: String, count: Int, includeSize: Bool) throws -> RedisScanResult { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Redis is not available in this database service.") }
    func redisGetKey(connection: DatabaseConnection, key: String) throws -> RedisKeyDetail { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Redis is not available in this database service.") }
    func redisSetString(connection: DatabaseConnection, key: String, value: String, ttl: Int64?, confirmed: Bool, allowWrite: Bool) throws { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Redis is not available in this database service.") }
    func redisReplaceHash(connection: DatabaseConnection, key: String, entries: [RedisHashEntry], confirmed: Bool, allowWrite: Bool) throws { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Redis is not available in this database service.") }
    func redisDeleteKey(connection: DatabaseConnection, key: String, confirmed: Bool, allowWrite: Bool) throws { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Redis is not available in this database service.") }
    func redisRenameKey(connection: DatabaseConnection, key: String, newKey: String, confirmed: Bool, allowWrite: Bool) throws { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Redis is not available in this database service.") }
    func redisSetTTL(connection: DatabaseConnection, key: String, ttl: Int64, confirmed: Bool, allowWrite: Bool) throws { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Redis is not available in this database service.") }
    func redisFlushDatabase(connection: DatabaseConnection, confirmed: Bool, allowWrite: Bool) throws { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Redis is not available in this database service.") }
    func nacosListConfigs(connection: DatabaseConnection, dataId: String, group: String, page: Int, pageSize: Int) throws -> NacosConfigList { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Nacos is not available in this database service.") }
    func nacosGetConfig(connection: DatabaseConnection, dataId: String, group: String) throws -> NacosConfigDetail { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Nacos is not available in this database service.") }
    func nacosPublishConfig(connection: DatabaseConnection, dataId: String, group: String, content: String, type: String?, confirmed: Bool, allowWrite: Bool) throws { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Nacos is not available in this database service.") }
    func nacosDeleteConfig(connection: DatabaseConnection, dataId: String, group: String, confirmed: Bool, allowWrite: Bool) throws { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Nacos is not available in this database service.") }
    func nacosListServices(connection: DatabaseConnection, serviceName: String, group: String, page: Int, pageSize: Int) throws -> NacosServiceList { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Nacos is not available in this database service.") }
    func nacosListInstances(connection: DatabaseConnection, serviceName: String, group: String) throws -> [NacosInstanceSummary] { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Nacos is not available in this database service.") }
}

package enum DatabaseSidecarError: LocalizedError, Equatable {
    case executableNotFound
    case processFailed(exitCode: Int32, output: String)
    case invalidResponse(String)
    case requestFailed(code: String, message: String)

    package var errorDescription: String? {
        switch self {
        case .executableNotFound: return "The Lithe database helper is not installed."
        case let .processFailed(exitCode, output): return "The database helper exited with code \(exitCode): \(Self.bounded(output))"
        case let .invalidResponse(message): return "The database helper returned invalid JSON: \(Self.bounded(message))"
        case let .requestFailed(code, message): return "Database request failed (\(code)): \(Self.bounded(message))"
        }
    }

    private static func bounded(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count > 500 ? "\(normalized.prefix(497))..." : normalized
    }
}

/// Executes the independently packaged database core only on demand. Connection
/// secrets are sent over stdin and are never included in arguments or logs.
package final class DatabaseSidecarService: DatabaseOperations, @unchecked Sendable {
    private let processRunner: any DatabaseProcessRunning
    private let executableURL: URL?
    private let environment: [String: String]?

    package init(processRunner: any DatabaseProcessRunning, executableURL: URL?, environment: [String: String]? = nil) {
        self.processRunner = processRunner
        self.executableURL = executableURL
        self.environment = environment
    }

    package func capabilities() throws -> DatabaseCapabilities {
        try request(method: "capabilities", params: EmptyParams())
    }

    package func testConnection(_ connection: DatabaseConnection) throws {
        let _: ConnectedResult = try request(method: "testConnection", params: ConnectionParams(connection: connection))
    }

    package func listDatabases(connection: DatabaseConnection) throws -> [String] {
        try request(method: "listDatabases", params: ConnectionParams(connection: connection))
    }

    package func listTables(connection: DatabaseConnection, schema: String = "") throws -> [DatabaseRow] {
        let result: DatabaseRowsResult = try request(method: "listTables", params: TableParams(connection: connection, schema: schema))
        return result.rows
    }

    package func describeTable(connection: DatabaseConnection, schema: String = "", table: String) throws -> [DatabaseRow] {
        let result: DatabaseRowsResult = try request(method: "describeTable", params: TableParams(connection: connection, schema: schema, table: table))
        return result.rows
    }

    package func listIndexes(connection: DatabaseConnection, schema: String = "", table: String) throws -> [DatabaseRow] {
        let result: DatabaseRowsResult = try request(method: "listIndexes", params: TableParams(connection: connection, schema: schema, table: table))
        return result.rows
    }

    package func listForeignKeys(connection: DatabaseConnection, schema: String = "", table: String) throws -> [DatabaseRow] {
        let result: DatabaseRowsResult = try request(method: "listForeignKeys", params: TableParams(connection: connection, schema: schema, table: table))
        return result.rows
    }

    package func listObjects(connection: DatabaseConnection, schema: String = "", kind: DatabaseObjectKind) throws -> [DatabaseRow] {
        let result: DatabaseRowsResult = try request(method: "listObjects", params: ObjectParams(connection: connection, schema: schema, objectKind: kind.rawValue))
        return result.rows
    }

    package func pageTable(connection: DatabaseConnection, schema: String = "", table: String, limit: Int = 200, offset: Int = 0, filters: [DatabaseFilter] = [], sort: [DatabaseSort] = []) throws -> DatabaseQueryResult {
        try request(method: "pageTable", params: TableParams(connection: connection, schema: schema, table: table, limit: limit, offset: offset, filters: filters, sort: sort))
    }

    package func query(connection: DatabaseConnection, sql: String, values: [DatabaseValue] = [], limit: Int = 200) throws -> DatabaseQueryResult {
        try request(method: "query", params: QueryParams(connection: connection, sql: sql, values: values, limit: limit))
    }

    package func execute(connection: DatabaseConnection, sql: String, values: [DatabaseValue] = [], confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "execute", params: QueryParams(connection: connection, sql: sql, values: values, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func applyChanges(connection: DatabaseConnection, schema: String = "", mutations: [DatabaseMutation], confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "applyChanges", params: MutationParams(connection: connection, schema: schema, mutations: mutations, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func applySchemaChange(connection: DatabaseConnection, schema: String = "", change: DatabaseSchemaChange, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "schemaChange", params: SchemaChangeParams(connection: connection, schema: schema, change: change, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func explain(connection: DatabaseConnection, sql: String, format: String = "json") throws -> DatabaseQueryResult {
        let result: ExplainResult = try request(method: "explain", params: ExplainParams(connection: connection, sql: sql, explainFormat: format))
        return DatabaseQueryResult(rows: result.rows, truncated: result.truncated, totalRows: nil)
    }

    package func diagnostics(connection: DatabaseConnection, request: DatabaseDiagnosticsRequest) throws -> DatabaseQueryResult {
        let result: DiagnosticsResult = try self.request(method: "diagnostics", params: DiagnosticsParams(connection: connection, request: request))
        return DatabaseQueryResult(rows: result.rows, truncated: result.truncated, totalRows: nil)
    }

    package func transaction(connection: DatabaseConnection, statements: [DatabaseTransactionStatement], confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "transaction", params: TransactionParams(connection: connection, statements: statements, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func exportCSV(connection: DatabaseConnection, sql: String, values: [DatabaseValue] = [], limit: Int = 10_000) throws -> Data {
        try export(method: "exportCsv", connection: connection, sql: sql, values: values, limit: limit)
    }

    package func exportJSON(connection: DatabaseConnection, sql: String, values: [DatabaseValue] = [], limit: Int = 10_000) throws -> Data {
        try export(method: "exportJson", connection: connection, sql: sql, values: values, limit: limit)
    }

    package func importCSV(connection: DatabaseConnection, schema: String = "", table: String, data: Data) throws -> DatabaseExecuteResult {
        try request(method: "importCsv", params: ImportParams(connection: connection, schema: schema, table: table, data: data.base64EncodedString()))
    }

    package func importJSON(connection: DatabaseConnection, schema: String = "", table: String, data: Data) throws -> DatabaseExecuteResult {
        try request(method: "importJson", params: ImportParams(connection: connection, schema: schema, table: table, data: data.base64EncodedString()))
    }

    package func exportSQL(connection: DatabaseConnection, options: DatabaseSQLExportOptions = DatabaseSQLExportOptions()) throws -> Data {
        let result: ExportResult = try request(method: "exportSql", params: SQLExportParams(
            connection: connection, schema: options.schema, selectedTables: options.selectedTables,
            includeStructure: options.includeStructure, includeData: options.includeData, limit: options.limit
        ), timeoutMilliseconds: 120_000)
        guard result.encoding == "base64", let data = Data(base64Encoded: result.data) else {
            throw DatabaseSidecarError.invalidResponse("Invalid SQL backup payload")
        }
        return data
    }

    package func exportSQLToFile(connection: DatabaseConnection, options: DatabaseSQLExportOptions = DatabaseSQLExportOptions(), outputURL: URL) throws -> DatabaseSQLFileExportResult {
        try request(method: "exportSqlToFile", params: SQLFileExportParams(
            connection: connection, schema: options.schema, selectedTables: options.selectedTables,
            includeStructure: options.includeStructure, includeData: options.includeData,
            limit: options.limit, outputPath: outputURL.path
        ), timeoutMilliseconds: 120_000)
    }

    package func importSQL(connection: DatabaseConnection, data: Data, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "importSql", params: SQLImportParams(connection: connection, data: data.base64EncodedString(), confirmed: confirmed, allowWrite: allowWrite), timeoutMilliseconds: 120_000)
    }

    package func importSQLFile(connection: DatabaseConnection, fileURL: URL, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "importSqlFile", params: SQLFileImportParams(connection: connection, outputPath: fileURL.path, confirmed: confirmed, allowWrite: allowWrite), timeoutMilliseconds: 120_000)
    }

    package func restoreSQL(connection: DatabaseConnection, data: Data, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "restoreSql", params: SQLImportParams(connection: connection, data: data.base64EncodedString(), confirmed: confirmed, allowWrite: allowWrite), timeoutMilliseconds: 120_000)
    }

    package func restoreSQLFile(connection: DatabaseConnection, fileURL: URL, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "restoreSqlFile", params: SQLFileImportParams(connection: connection, outputPath: fileURL.path, confirmed: confirmed, allowWrite: allowWrite), timeoutMilliseconds: 120_000)
    }

    package func redisScan(connection: DatabaseConnection, cursor: String = "0", pattern: String = "*", count: Int = 100, includeSize: Bool = true) throws -> RedisScanResult {
        try request(method: "redisScan", params: RedisScanParams(connection: connection, cursor: cursor, pattern: pattern, count: count, includeSize: includeSize))
    }

    package func redisGetKey(connection: DatabaseConnection, key: String) throws -> RedisKeyDetail {
        try request(method: "redisGetKey", params: RedisKeyParams(connection: connection, key: key))
    }

    package func redisSetString(connection: DatabaseConnection, key: String, value: String, ttl: Int64? = nil, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisSetString", params: RedisWriteParams(connection: connection, key: key, value: value, ttl: ttl, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func redisReplaceHash(connection: DatabaseConnection, key: String, entries: [RedisHashEntry], confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisReplaceHash", params: RedisWriteParams(connection: connection, key: key, entries: entries, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func redisDeleteKey(connection: DatabaseConnection, key: String, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisDeleteKey", params: RedisWriteParams(connection: connection, key: key, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func redisRenameKey(connection: DatabaseConnection, key: String, newKey: String, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisRenameKey", params: RedisWriteParams(connection: connection, key: key, newKey: newKey, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func redisSetTTL(connection: DatabaseConnection, key: String, ttl: Int64, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisSetTTL", params: RedisWriteParams(connection: connection, key: key, ttl: ttl, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func redisFlushDatabase(connection: DatabaseConnection, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisFlushDatabase", params: RedisWriteParams(connection: connection, key: "", confirmed: confirmed, allowWrite: allowWrite))
    }

    package func nacosListConfigs(connection: DatabaseConnection, dataId: String = "", group: String = "", page: Int = 1, pageSize: Int = 100) throws -> NacosConfigList {
        try request(method: "nacosListConfigs", params: NacosParams(connection: connection, dataId: dataId, group: group, page: page, pageSize: pageSize))
    }

    package func nacosGetConfig(connection: DatabaseConnection, dataId: String, group: String) throws -> NacosConfigDetail {
        try request(method: "nacosGetConfig", params: NacosParams(connection: connection, dataId: dataId, group: group))
    }

    package func nacosPublishConfig(connection: DatabaseConnection, dataId: String, group: String, content: String, type: String? = nil, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "nacosPublishConfig", params: NacosParams(connection: connection, dataId: dataId, group: group, content: content, type: type ?? "", confirmed: confirmed, allowWrite: allowWrite))
    }

    package func nacosDeleteConfig(connection: DatabaseConnection, dataId: String, group: String, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "nacosDeleteConfig", params: NacosParams(connection: connection, dataId: dataId, group: group, confirmed: confirmed, allowWrite: allowWrite))
    }

    package func nacosListServices(connection: DatabaseConnection, serviceName: String = "", group: String = "", page: Int = 1, pageSize: Int = 100) throws -> NacosServiceList {
        try request(method: "nacosListServices", params: NacosParams(connection: connection, group: group, serviceName: serviceName, page: page, pageSize: pageSize))
    }

    package func nacosListInstances(connection: DatabaseConnection, serviceName: String, group: String = "") throws -> [NacosInstanceSummary] {
        try request(method: "nacosListInstances", params: NacosParams(connection: connection, group: group, serviceName: serviceName))
    }

    private func export(method: String, connection: DatabaseConnection, sql: String, values: [DatabaseValue], limit: Int) throws -> Data {
        let result: ExportResult = try request(method: method, params: QueryParams(connection: connection, sql: sql, values: values, limit: limit))
        guard result.encoding == "base64", let data = Data(base64Encoded: result.data) else {
            throw DatabaseSidecarError.invalidResponse("Invalid CSV payload")
        }
        return data
    }

    private func request<Params: Encodable, Result: Decodable>(method: String, params: Params, timeoutMilliseconds: Int = 30_000) throws -> Result {
        guard let executableURL else { throw DatabaseSidecarError.executableNotFound }
        let requestID = UUID().uuidString
        let body = RequestEnvelope(id: requestID, method: method, params: params)
        let input: Data
        do { input = try JSONEncoder().encode(body) }
        catch { throw DatabaseSidecarError.invalidResponse(error.localizedDescription) }

        let process = processRunner.runDatabaseProcess(DatabaseProcessRequest(
            executablePath: executableURL.path,
            environment: environment,
            standardInput: input,
            timeoutMilliseconds: timeoutMilliseconds
        ))
        let data = Data(process.output.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let envelope: ResponseEnvelope<Result>
        do { envelope = try JSONDecoder().decode(ResponseEnvelope<Result>.self, from: data) }
        catch {
            if !process.succeeded { throw DatabaseSidecarError.processFailed(exitCode: process.exitCode, output: process.output) }
            throw DatabaseSidecarError.invalidResponse(error.localizedDescription)
        }
        guard envelope.id == requestID else { throw DatabaseSidecarError.invalidResponse("Response ID did not match request") }
        if let error = envelope.error { throw DatabaseSidecarError.requestFailed(code: error.code, message: error.message) }
        guard envelope.ok, let result = envelope.result else { throw DatabaseSidecarError.invalidResponse("Missing result") }
        return result
    }

}

private struct EmptyParams: Codable {}
private struct ConnectionParams: Codable { let connection: DatabaseConnection }
private struct ConnectedResult: Codable { let connected: Bool }
private struct EmptyResult: Codable {}
private struct DatabaseRowsResult: Decodable {
    package let rows: [DatabaseRow]

    package init(from decoder: Decoder) throws {
        if let rows = try? decoder.singleValueContainer().decode([DatabaseRow].self) {
            self.rows = rows
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decode([DatabaseRow].self, forKey: .rows)
    }

    private enum CodingKeys: String, CodingKey { case rows }
}
private struct ExportResult: Codable { let encoding: String; let data: String }
private struct ExplainResult: Codable { let format: String; let rows: [DatabaseRow]; let truncated: Bool }
private struct DiagnosticsResult: Codable { let rows: [DatabaseRow]; let truncated: Bool }
private struct TableParams: Codable {
    package let connection: DatabaseConnection
    package var schema = ""
    package var table = ""
    package var limit = 200
    package var offset = 0
    package var filters: [DatabaseFilter] = []
    package var sort: [DatabaseSort] = []
}
private struct ObjectParams: Codable {
    package let connection: DatabaseConnection
    package var schema = ""
    package var objectKind = ""
}
private struct QueryParams: Codable {
    package let connection: DatabaseConnection
    package let sql: String
    package var values: [DatabaseValue] = []
    package var limit = 200
    package var confirmed = false
    package var allowWrite = false
}
private struct MutationParams: Codable {
    package let connection: DatabaseConnection
    package var schema = ""
    package let mutations: [DatabaseMutation]
    package var confirmed = false
    package var allowWrite = false
}
private struct SchemaChangeParams: Codable {
    package let connection: DatabaseConnection
    package var schema = ""
    package var operation: String
    package var table = ""
    package var name = ""
    package var oldName = ""
    package var dataType = ""
    package var nullable = true
    package var defaultValue = ""
    package var indexName = ""
    package var indexColumns: [String] = []
    package var constraintName = ""
    package var referencedTable = ""
    package var referencedColumns: [String] = []
    package var sql = ""
    package var confirmed = false
    package var allowWrite = false

    package init(connection: DatabaseConnection, schema: String, change: DatabaseSchemaChange, confirmed: Bool, allowWrite: Bool) {
        self.connection = connection
        self.schema = schema
        operation = change.operation
        table = change.table
        name = change.name
        oldName = change.oldName
        dataType = change.dataType
        nullable = change.nullable
        defaultValue = change.defaultValue
        indexName = change.indexName
        indexColumns = change.indexColumns
        constraintName = change.constraintName
        referencedTable = change.referencedTable
        referencedColumns = change.referencedColumns
        sql = change.sql
        self.confirmed = confirmed
        self.allowWrite = allowWrite
    }
}
private struct ExplainParams: Codable {
    package let connection: DatabaseConnection
    package let sql: String
    package var explainFormat = "json"
}
private struct DiagnosticsParams: Codable {
    package let connection: DatabaseConnection
    package var schema = ""
    package var table = ""
    package var diagnosticKind = "tableSize"

    package init(connection: DatabaseConnection, request: DatabaseDiagnosticsRequest) {
        self.connection = connection
        schema = request.schema
        table = request.table
        diagnosticKind = request.kind
    }
}
private struct TransactionParams: Codable {
    package let connection: DatabaseConnection
    package let statements: [DatabaseTransactionStatement]
    package var confirmed = false
    package var allowWrite = false
}
private struct ImportParams: Codable {
    package let connection: DatabaseConnection
    package var schema = ""
    package let table: String
    package let data: String
}
private struct SQLExportParams: Codable {
    package let connection: DatabaseConnection
    package var schema = ""
    package var selectedTables: [String] = []
    package var includeStructure = true
    package var includeData = true
    package var limit = 0
}
private struct SQLFileExportParams: Codable {
    package let connection: DatabaseConnection
    package var schema = ""
    package var selectedTables: [String] = []
    package var includeStructure = true
    package var includeData = true
    package var limit = 0
    package let outputPath: String
}
private struct SQLImportParams: Codable { let connection: DatabaseConnection; let data: String; var confirmed = false; var allowWrite = false }
private struct SQLFileImportParams: Codable { let connection: DatabaseConnection; let outputPath: String; var confirmed = false; var allowWrite = false }
private struct RedisScanParams: Codable {
    package let connection: DatabaseConnection
    package var cursor = "0"
    package var pattern = "*"
    package var count = 100
    package var includeSize = true
}
private struct RedisKeyParams: Codable { let connection: DatabaseConnection; let key: String }
private struct RedisWriteParams: Codable {
    package let connection: DatabaseConnection
    package let key: String
    package var newKey = ""
    package var value = ""
    package var entries: [RedisHashEntry] = []
    package var ttl: Int64?
    package var confirmed = false
    package var allowWrite = false
}
private struct NacosParams: Codable {
    package let connection: DatabaseConnection
    package var dataId = ""
    package var group = ""
    package var content = ""
    package var type = ""
    package var serviceName = ""
    package var page = 1
    package var pageSize = 100
    package var confirmed = false
    package var allowWrite = false
}
private struct RequestEnvelope<Params: Encodable>: Encodable { let id: String; let method: String; let params: Params }
private struct ResponseEnvelope<Result: Decodable>: Decodable { let id: String; let ok: Bool; let result: Result?; let error: ResponseError? }
private struct ResponseError: Decodable { let code: String; let message: String }

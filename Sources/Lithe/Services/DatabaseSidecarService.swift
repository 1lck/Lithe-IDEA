import Foundation

enum DatabaseKind: String, Codable, CaseIterable, Sendable {
    case mysql
    case postgresql
    case sqlite
    case redis
    case nacos

    var isSQLDatabase: Bool {
        switch self {
        case .mysql, .postgresql, .sqlite: true
        case .redis, .nacos: false
        }
    }
}

struct DatabaseConnection: Codable, Equatable, Sendable {
    let kind: DatabaseKind
    var host = ""
    var port: UInt16 = 0
    var username = ""
    var password = ""
    var database = ""
    var path = ""
    var ssl = false
    var caCertificatePath = ""
    var serverName = ""
    var sshHost = ""
    var sshPort: UInt16 = 0
    var sshUsername = ""
    var sshKeyPath = ""
    var sshLocalPort: UInt16 = 0
    var proxyURL = ""
    var readOnly = false
    var productionProtection = false

    private enum CodingKeys: String, CodingKey {
        case kind, host, port, username, password, database, path, ssl
        case caCertificatePath, serverName, sshHost, sshPort, sshUsername, sshKeyPath, sshLocalPort, proxyURL
        case readOnly, productionProtection
    }

    init(from decoder: Decoder) throws {
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

    init(
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

struct DatabaseCapabilities: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let databaseTypes: [String]
    let features: [String]
}

struct DatabaseSQLFileExportResult: Codable, Equatable, Sendable {
    let path: String
    let byteCount: Int
    let sha256: String
}

/// Redis and Nacos are deliberately modeled as specialised workspaces rather
/// than as SQL tables. Keeping their protocol types separate prevents callers
/// from accidentally issuing SQL-style operations to a non-SQL service.
struct RedisKeySummary: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let type: String
    let ttl: Int64
    let size: Int64

    var id: String { key }
}

struct RedisScanResult: Codable, Equatable, Sendable {
    let keys: [RedisKeySummary]
    let nextCursor: String
}

struct RedisHashEntry: Codable, Equatable, Identifiable, Sendable {
    let field: String
    let value: String

    var id: String { field }
}

struct RedisKeyDetail: Codable, Equatable, Sendable {
    let key: String
    let type: String
    let ttl: Int64
    let size: Int64
    let stringValue: String?
    let hashEntries: [RedisHashEntry]
}

struct NacosConfigSummary: Codable, Equatable, Identifiable, Sendable {
    let dataId: String
    let group: String
    let namespace: String
    let type: String?
    let md5: String?

    var id: String { "\(namespace)|\(group)|\(dataId)" }
}

struct NacosConfigList: Codable, Equatable, Sendable {
    let items: [NacosConfigSummary]
    let totalCount: Int
}

struct NacosConfigDetail: Codable, Equatable, Sendable {
    let dataId: String
    let group: String
    let namespace: String
    let content: String
    let type: String?
    let md5: String?
}

struct NacosServiceSummary: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let group: String
    let clusterCount: Int

    var id: String { "\(group)|\(name)" }
}

struct NacosServiceList: Codable, Equatable, Sendable {
    let items: [NacosServiceSummary]
    let totalCount: Int
}

struct NacosInstanceSummary: Codable, Equatable, Identifiable, Sendable {
    let ip: String
    let port: Int
    let healthy: Bool
    let enabled: Bool
    let ephemeral: Bool
    let clusterName: String?

    var id: String { "\(ip):\(port):\(clusterName ?? "")" }
}

enum DatabaseValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case object([String: DatabaseValue])
    case array([DatabaseValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: DatabaseValue].self) { self = .object(value) }
        else { self = .array(try container.decode([DatabaseValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        }
    }
}

typealias DatabaseRow = [String: DatabaseValue]

struct DatabaseQueryResult: Codable, Equatable, Sendable {
    let rows: [DatabaseRow]
    let truncated: Bool
    var totalRows: Int64?
}

struct DatabaseExecuteResult: Codable, Equatable, Sendable {
    let rowsAffected: UInt64
}

enum DatabaseMutationAction: String, Codable, Sendable { case insert, update, delete }

struct DatabaseMutation: Codable, Equatable, Sendable {
    let action: DatabaseMutationAction
    let table: String
    var values: DatabaseRow = [:]
    var key: DatabaseRow = [:]
}

enum DatabaseFilterOperator: String, Codable, Sendable { case equals, notEquals, greaterThan, lessThan, contains, startsWith, isNull, isNotNull }
struct DatabaseFilter: Codable, Equatable, Sendable { let column: String; let `operator`: DatabaseFilterOperator; var value: DatabaseValue = .null }
struct DatabaseSort: Codable, Equatable, Sendable { let column: String; var descending = false }
struct DatabaseSQLExportOptions: Codable, Equatable, Sendable {
    var schema = ""
    var selectedTables: [String] = []
    var includeStructure = true
    var includeData = true
    // A SQL backup must be complete. Zero is the sidecar protocol's explicit
    // unbounded sentinel; the sidecar streams rows directly to the output.
    var limit = 0
}

enum DatabaseObjectKind: String, Codable, CaseIterable, Sendable {
    case tables
    case views
    case routines
    case triggers
    case sequences
}

struct DatabaseSchemaChange: Codable, Equatable, Sendable {
    var operation: String
    var table = ""
    var name = ""
    var oldName = ""
    var dataType = ""
    var nullable = true
    var defaultValue = ""
    var indexName = ""
    var indexColumns: [String] = []
    var constraintName = ""
    var referencedTable = ""
    var referencedColumns: [String] = []
    var sql = ""
}

struct DatabaseTransactionStatement: Codable, Equatable, Sendable {
    let sql: String
    var values: [DatabaseValue] = []
}

struct DatabaseDiagnosticsRequest: Codable, Equatable, Sendable {
    var kind = "tableSize"
    var schema = ""
    var table = ""
}

protocol DatabaseOperations: Sendable {
    func capabilities() throws -> DatabaseCapabilities
    func testConnection(_ connection: DatabaseConnection) throws
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

    func redisScan(connection: DatabaseConnection, cursor: String, pattern: String, count: Int) throws -> RedisScanResult
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

extension DatabaseOperations {
    func redisScan(connection: DatabaseConnection, cursor: String, pattern: String, count: Int) throws -> RedisScanResult { throw DatabaseSidecarError.requestFailed(code: "unsupported_operation", message: "Redis is not available in this database service.") }
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

enum DatabaseSidecarError: LocalizedError, Equatable {
    case executableNotFound
    case processFailed(exitCode: Int32, output: String)
    case invalidResponse(String)
    case requestFailed(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: return "The Lithe database helper is not installed."
        case let .processFailed(exitCode, output): return "The database helper exited with code \(exitCode): \(output)"
        case let .invalidResponse(message): return "The database helper returned invalid JSON: \(message)"
        case let .requestFailed(code, message): return "Database request failed (\(code)): \(message)"
        }
    }
}

/// Executes the independently packaged database core only on demand. Connection
/// secrets are sent over stdin and are never included in arguments or logs.
final class DatabaseSidecarService: DatabaseOperations, @unchecked Sendable {
    private let processRunner: any ProcessRunner
    private let executableURL: URL?
    private let environment: [String: String]?

    init(processRunner: any ProcessRunner, executableURL: URL? = defaultExecutableURL(), environment: [String: String]? = nil) {
        self.processRunner = processRunner
        self.executableURL = executableURL
        self.environment = environment
    }

    func capabilities() throws -> DatabaseCapabilities {
        try request(method: "capabilities", params: EmptyParams())
    }

    func testConnection(_ connection: DatabaseConnection) throws {
        let _: ConnectedResult = try request(method: "testConnection", params: ConnectionParams(connection: connection))
    }

    func listTables(connection: DatabaseConnection, schema: String = "") throws -> [DatabaseRow] {
        try request(method: "listTables", params: TableParams(connection: connection, schema: schema))
    }

    func describeTable(connection: DatabaseConnection, schema: String = "", table: String) throws -> [DatabaseRow] {
        try request(method: "describeTable", params: TableParams(connection: connection, schema: schema, table: table))
    }

    func listIndexes(connection: DatabaseConnection, schema: String = "", table: String) throws -> [DatabaseRow] {
        try request(method: "listIndexes", params: TableParams(connection: connection, schema: schema, table: table))
    }

    func listForeignKeys(connection: DatabaseConnection, schema: String = "", table: String) throws -> [DatabaseRow] {
        try request(method: "listForeignKeys", params: TableParams(connection: connection, schema: schema, table: table))
    }

    func listObjects(connection: DatabaseConnection, schema: String = "", kind: DatabaseObjectKind) throws -> [DatabaseRow] {
        try request(method: "listObjects", params: ObjectParams(connection: connection, schema: schema, objectKind: kind.rawValue))
    }

    func pageTable(connection: DatabaseConnection, schema: String = "", table: String, limit: Int = 200, offset: Int = 0, filters: [DatabaseFilter] = [], sort: [DatabaseSort] = []) throws -> DatabaseQueryResult {
        try request(method: "pageTable", params: TableParams(connection: connection, schema: schema, table: table, limit: limit, offset: offset, filters: filters, sort: sort))
    }

    func query(connection: DatabaseConnection, sql: String, values: [DatabaseValue] = [], limit: Int = 200) throws -> DatabaseQueryResult {
        try request(method: "query", params: QueryParams(connection: connection, sql: sql, values: values, limit: limit))
    }

    func execute(connection: DatabaseConnection, sql: String, values: [DatabaseValue] = [], confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "execute", params: QueryParams(connection: connection, sql: sql, values: values, confirmed: confirmed, allowWrite: allowWrite))
    }

    func applyChanges(connection: DatabaseConnection, schema: String = "", mutations: [DatabaseMutation], confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "applyChanges", params: MutationParams(connection: connection, schema: schema, mutations: mutations, confirmed: confirmed, allowWrite: allowWrite))
    }

    func applySchemaChange(connection: DatabaseConnection, schema: String = "", change: DatabaseSchemaChange, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "schemaChange", params: SchemaChangeParams(connection: connection, schema: schema, change: change, confirmed: confirmed, allowWrite: allowWrite))
    }

    func explain(connection: DatabaseConnection, sql: String, format: String = "json") throws -> DatabaseQueryResult {
        let result: ExplainResult = try request(method: "explain", params: ExplainParams(connection: connection, sql: sql, explainFormat: format))
        return DatabaseQueryResult(rows: result.rows, truncated: result.truncated, totalRows: nil)
    }

    func diagnostics(connection: DatabaseConnection, request: DatabaseDiagnosticsRequest) throws -> DatabaseQueryResult {
        let result: DiagnosticsResult = try self.request(method: "diagnostics", params: DiagnosticsParams(connection: connection, request: request))
        return DatabaseQueryResult(rows: result.rows, truncated: result.truncated, totalRows: nil)
    }

    func transaction(connection: DatabaseConnection, statements: [DatabaseTransactionStatement], confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "transaction", params: TransactionParams(connection: connection, statements: statements, confirmed: confirmed, allowWrite: allowWrite))
    }

    func exportCSV(connection: DatabaseConnection, sql: String, values: [DatabaseValue] = [], limit: Int = 10_000) throws -> Data {
        try export(method: "exportCsv", connection: connection, sql: sql, values: values, limit: limit)
    }

    func exportJSON(connection: DatabaseConnection, sql: String, values: [DatabaseValue] = [], limit: Int = 10_000) throws -> Data {
        try export(method: "exportJson", connection: connection, sql: sql, values: values, limit: limit)
    }

    func importCSV(connection: DatabaseConnection, schema: String = "", table: String, data: Data) throws -> DatabaseExecuteResult {
        try request(method: "importCsv", params: ImportParams(connection: connection, schema: schema, table: table, data: data.base64EncodedString()))
    }

    func importJSON(connection: DatabaseConnection, schema: String = "", table: String, data: Data) throws -> DatabaseExecuteResult {
        try request(method: "importJson", params: ImportParams(connection: connection, schema: schema, table: table, data: data.base64EncodedString()))
    }

    func exportSQL(connection: DatabaseConnection, options: DatabaseSQLExportOptions = DatabaseSQLExportOptions()) throws -> Data {
        let result: ExportResult = try request(method: "exportSql", params: SQLExportParams(
            connection: connection, schema: options.schema, selectedTables: options.selectedTables,
            includeStructure: options.includeStructure, includeData: options.includeData, limit: options.limit
        ), timeoutMilliseconds: 120_000)
        guard result.encoding == "base64", let data = Data(base64Encoded: result.data) else {
            throw DatabaseSidecarError.invalidResponse("Invalid SQL backup payload")
        }
        return data
    }

    func exportSQLToFile(connection: DatabaseConnection, options: DatabaseSQLExportOptions = DatabaseSQLExportOptions(), outputURL: URL) throws -> DatabaseSQLFileExportResult {
        try request(method: "exportSqlToFile", params: SQLFileExportParams(
            connection: connection, schema: options.schema, selectedTables: options.selectedTables,
            includeStructure: options.includeStructure, includeData: options.includeData,
            limit: options.limit, outputPath: outputURL.path
        ), timeoutMilliseconds: 120_000)
    }

    func importSQL(connection: DatabaseConnection, data: Data, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "importSql", params: SQLImportParams(connection: connection, data: data.base64EncodedString(), confirmed: confirmed, allowWrite: allowWrite), timeoutMilliseconds: 120_000)
    }

    func importSQLFile(connection: DatabaseConnection, fileURL: URL, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "importSqlFile", params: SQLFileImportParams(connection: connection, outputPath: fileURL.path, confirmed: confirmed, allowWrite: allowWrite), timeoutMilliseconds: 120_000)
    }

    func restoreSQL(connection: DatabaseConnection, data: Data, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "restoreSql", params: SQLImportParams(connection: connection, data: data.base64EncodedString(), confirmed: confirmed, allowWrite: allowWrite), timeoutMilliseconds: 120_000)
    }

    func restoreSQLFile(connection: DatabaseConnection, fileURL: URL, confirmed: Bool = false, allowWrite: Bool = false) throws -> DatabaseExecuteResult {
        try request(method: "restoreSqlFile", params: SQLFileImportParams(connection: connection, outputPath: fileURL.path, confirmed: confirmed, allowWrite: allowWrite), timeoutMilliseconds: 120_000)
    }

    func redisScan(connection: DatabaseConnection, cursor: String = "0", pattern: String = "*", count: Int = 100) throws -> RedisScanResult {
        try request(method: "redisScan", params: RedisScanParams(connection: connection, cursor: cursor, pattern: pattern, count: count))
    }

    func redisGetKey(connection: DatabaseConnection, key: String) throws -> RedisKeyDetail {
        try request(method: "redisGetKey", params: RedisKeyParams(connection: connection, key: key))
    }

    func redisSetString(connection: DatabaseConnection, key: String, value: String, ttl: Int64? = nil, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisSetString", params: RedisWriteParams(connection: connection, key: key, value: value, ttl: ttl, confirmed: confirmed, allowWrite: allowWrite))
    }

    func redisReplaceHash(connection: DatabaseConnection, key: String, entries: [RedisHashEntry], confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisReplaceHash", params: RedisWriteParams(connection: connection, key: key, entries: entries, confirmed: confirmed, allowWrite: allowWrite))
    }

    func redisDeleteKey(connection: DatabaseConnection, key: String, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisDeleteKey", params: RedisWriteParams(connection: connection, key: key, confirmed: confirmed, allowWrite: allowWrite))
    }

    func redisRenameKey(connection: DatabaseConnection, key: String, newKey: String, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisRenameKey", params: RedisWriteParams(connection: connection, key: key, newKey: newKey, confirmed: confirmed, allowWrite: allowWrite))
    }

    func redisSetTTL(connection: DatabaseConnection, key: String, ttl: Int64, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisSetTTL", params: RedisWriteParams(connection: connection, key: key, ttl: ttl, confirmed: confirmed, allowWrite: allowWrite))
    }

    func redisFlushDatabase(connection: DatabaseConnection, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "redisFlushDatabase", params: RedisWriteParams(connection: connection, key: "", confirmed: confirmed, allowWrite: allowWrite))
    }

    func nacosListConfigs(connection: DatabaseConnection, dataId: String = "", group: String = "", page: Int = 1, pageSize: Int = 100) throws -> NacosConfigList {
        try request(method: "nacosListConfigs", params: NacosParams(connection: connection, dataId: dataId, group: group, page: page, pageSize: pageSize))
    }

    func nacosGetConfig(connection: DatabaseConnection, dataId: String, group: String) throws -> NacosConfigDetail {
        try request(method: "nacosGetConfig", params: NacosParams(connection: connection, dataId: dataId, group: group))
    }

    func nacosPublishConfig(connection: DatabaseConnection, dataId: String, group: String, content: String, type: String? = nil, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "nacosPublishConfig", params: NacosParams(connection: connection, dataId: dataId, group: group, content: content, type: type ?? "", confirmed: confirmed, allowWrite: allowWrite))
    }

    func nacosDeleteConfig(connection: DatabaseConnection, dataId: String, group: String, confirmed: Bool = false, allowWrite: Bool = false) throws {
        let _: EmptyResult = try request(method: "nacosDeleteConfig", params: NacosParams(connection: connection, dataId: dataId, group: group, confirmed: confirmed, allowWrite: allowWrite))
    }

    func nacosListServices(connection: DatabaseConnection, serviceName: String = "", group: String = "", page: Int = 1, pageSize: Int = 100) throws -> NacosServiceList {
        try request(method: "nacosListServices", params: NacosParams(connection: connection, group: group, serviceName: serviceName, page: page, pageSize: pageSize))
    }

    func nacosListInstances(connection: DatabaseConnection, serviceName: String, group: String = "") throws -> [NacosInstanceSummary] {
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

        let process = processRunner.run(ProcessRequest(
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

    static func defaultExecutableURL(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> URL? {
        if let override = environment["LITHE_DB_SIDECAR_EXECUTABLE"], !override.isEmpty { return URL(fileURLWithPath: override) }
        let candidates = [
            bundle.bundleURL.appendingPathComponent("Contents/Helpers/lithe-db-sidecar"),
            bundle.bundleURL.appendingPathComponent("Contents/Resources/Database/lithe-db-sidecar")
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

private struct EmptyParams: Codable {}
private struct ConnectionParams: Codable { let connection: DatabaseConnection }
private struct ConnectedResult: Codable { let connected: Bool }
private struct EmptyResult: Codable {}
private struct ExportResult: Codable { let encoding: String; let data: String }
private struct ExplainResult: Codable { let format: String; let rows: [DatabaseRow]; let truncated: Bool }
private struct DiagnosticsResult: Codable { let rows: [DatabaseRow]; let truncated: Bool }
private struct TableParams: Codable {
    let connection: DatabaseConnection
    var schema = ""
    var table = ""
    var limit = 200
    var offset = 0
    var filters: [DatabaseFilter] = []
    var sort: [DatabaseSort] = []
}
private struct ObjectParams: Codable {
    let connection: DatabaseConnection
    var schema = ""
    var objectKind = ""
}
private struct QueryParams: Codable {
    let connection: DatabaseConnection
    let sql: String
    var values: [DatabaseValue] = []
    var limit = 200
    var confirmed = false
    var allowWrite = false
}
private struct MutationParams: Codable {
    let connection: DatabaseConnection
    var schema = ""
    let mutations: [DatabaseMutation]
    var confirmed = false
    var allowWrite = false
}
private struct SchemaChangeParams: Codable {
    let connection: DatabaseConnection
    var schema = ""
    var operation: String
    var table = ""
    var name = ""
    var oldName = ""
    var dataType = ""
    var nullable = true
    var defaultValue = ""
    var indexName = ""
    var indexColumns: [String] = []
    var constraintName = ""
    var referencedTable = ""
    var referencedColumns: [String] = []
    var sql = ""
    var confirmed = false
    var allowWrite = false

    init(connection: DatabaseConnection, schema: String, change: DatabaseSchemaChange, confirmed: Bool, allowWrite: Bool) {
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
    let connection: DatabaseConnection
    let sql: String
    var explainFormat = "json"
}
private struct DiagnosticsParams: Codable {
    let connection: DatabaseConnection
    var schema = ""
    var table = ""
    var diagnosticKind = "tableSize"

    init(connection: DatabaseConnection, request: DatabaseDiagnosticsRequest) {
        self.connection = connection
        schema = request.schema
        table = request.table
        diagnosticKind = request.kind
    }
}
private struct TransactionParams: Codable {
    let connection: DatabaseConnection
    let statements: [DatabaseTransactionStatement]
    var confirmed = false
    var allowWrite = false
}
private struct ImportParams: Codable {
    let connection: DatabaseConnection
    var schema = ""
    let table: String
    let data: String
}
private struct SQLExportParams: Codable {
    let connection: DatabaseConnection
    var schema = ""
    var selectedTables: [String] = []
    var includeStructure = true
    var includeData = true
    var limit = 0
}
private struct SQLFileExportParams: Codable {
    let connection: DatabaseConnection
    var schema = ""
    var selectedTables: [String] = []
    var includeStructure = true
    var includeData = true
    var limit = 0
    let outputPath: String
}
private struct SQLImportParams: Codable { let connection: DatabaseConnection; let data: String; var confirmed = false; var allowWrite = false }
private struct SQLFileImportParams: Codable { let connection: DatabaseConnection; let outputPath: String; var confirmed = false; var allowWrite = false }
private struct RedisScanParams: Codable {
    let connection: DatabaseConnection
    var cursor = "0"
    var pattern = "*"
    var count = 100
}
private struct RedisKeyParams: Codable { let connection: DatabaseConnection; let key: String }
private struct RedisWriteParams: Codable {
    let connection: DatabaseConnection
    let key: String
    var newKey = ""
    var value = ""
    var entries: [RedisHashEntry] = []
    var ttl: Int64?
    var confirmed = false
    var allowWrite = false
}
private struct NacosParams: Codable {
    let connection: DatabaseConnection
    var dataId = ""
    var group = ""
    var content = ""
    var type = ""
    var serviceName = ""
    var page = 1
    var pageSize = 100
    var confirmed = false
    var allowWrite = false
}
private struct RequestEnvelope<Params: Encodable>: Encodable { let id: String; let method: String; let params: Params }
private struct ResponseEnvelope<Result: Decodable>: Decodable { let id: String; let ok: Bool; let result: Result?; let error: ResponseError? }
private struct ResponseError: Decodable { let code: String; let message: String }

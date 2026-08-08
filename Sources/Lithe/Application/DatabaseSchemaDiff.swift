import Foundation

struct DatabaseSchemaColumnSnapshot: Codable, Equatable, Sendable {
    let name: String
    let dataType: String
    let isNullable: Bool
    let defaultValue: String?
    let isPrimaryKey: Bool
}

struct DatabaseSchemaIndexSnapshot: Codable, Equatable, Sendable {
    let name: String
    let definition: String
}

struct DatabaseSchemaForeignKeySnapshot: Codable, Equatable, Sendable {
    let name: String
    let column: String
    let referencedTable: String
    let referencedColumn: String
}

struct DatabaseSchemaTableSnapshot: Codable, Equatable, Sendable {
    let name: String
    let columns: [DatabaseSchemaColumnSnapshot]
    let indexes: [DatabaseSchemaIndexSnapshot]
    let foreignKeys: [DatabaseSchemaForeignKeySnapshot]
}

struct DatabaseSchemaSnapshot: Codable, Equatable, Sendable {
    let profileID: UUID
    let profileName: String
    let kind: DatabaseKind
    let schema: String
    let tables: [DatabaseSchemaTableSnapshot]
}

private struct DatabaseForeignKeyGroup {
    let name: String
    let referencedTable: String
    let columns: [DatabaseSchemaForeignKeySnapshot]
}

enum DatabaseSchemaDiffKind: String, Codable, CaseIterable, Sendable {
    case addTable
    case dropTable
    case addColumn
    case dropColumn
    case changeColumn
    case addIndex
    case dropIndex
    case addForeignKey
    case dropForeignKey

    var isDestructive: Bool {
        switch self {
        case .dropTable, .dropColumn, .dropIndex, .dropForeignKey: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .addTable: "Add table"
        case .dropTable: "Drop table"
        case .addColumn: "Add column"
        case .dropColumn: "Drop column"
        case .changeColumn: "Change column"
        case .addIndex: "Add index"
        case .dropIndex: "Drop index"
        case .addForeignKey: "Add foreign key"
        case .dropForeignKey: "Drop foreign key"
        }
    }
}

struct DatabaseSchemaDiffItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: DatabaseSchemaDiffKind
    let table: String
    let detail: String
    let sql: String

    var isDestructive: Bool { kind.isDestructive }
}

struct DatabaseSchemaDiffResult: Codable, Equatable, Sendable {
    let source: DatabaseSchemaSnapshot
    let target: DatabaseSchemaSnapshot
    let items: [DatabaseSchemaDiffItem]

    var requiresConfirmation: Bool { items.contains(where: { $0.isDestructive }) }
    var migrationSQL: String { items.map(\.sql).joined(separator: "\n") }
}

enum DatabaseSchemaDiffEngine {
    static func statements(in sql: String) -> [String] {
        var result: [String] = []
        var statement = ""
        var quote: Character?
        var escaped = false
        for character in sql {
            statement.append(character)
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && quote != nil {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
            } else if character == ";" {
                let completed = statement.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                if !completed.isEmpty { result.append(String(completed)) }
                statement = ""
            }
        }
        let remaining = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty { result.append(remaining) }
        return result
    }

    static func compare(source: DatabaseSchemaSnapshot, target: DatabaseSchemaSnapshot) -> DatabaseSchemaDiffResult {
        var items: [DatabaseSchemaDiffItem] = []
        let sourceTables = Dictionary(uniqueKeysWithValues: source.tables.map { ($0.name, $0) })
        let targetTables = Dictionary(uniqueKeysWithValues: target.tables.map { ($0.name, $0) })

        let newTables = orderedNewTables(source.tables.filter { targetTables[$0.name] == nil })
        let newTableOrder = Dictionary(uniqueKeysWithValues: newTables.enumerated().map { ($0.element.name, $0.offset) })
        for table in newTables {
            items.append(DatabaseSchemaDiffItem(
                id: "add-table:\(table.name)",
                kind: .addTable,
                table: table.name,
                detail: "Create table \(table.name)",
                sql: createTableSQL(table, kind: target.kind, schema: target.schema)
            ))
            // Index definitions cannot be expressed portably inside CREATE
            // TABLE, so carry explicit source indexes as subsequent steps.
            compareIndexes(
                table,
                DatabaseSchemaTableSnapshot(name: table.name, columns: [], indexes: [], foreignKeys: []),
                target: target,
                items: &items
            )
        }
        for table in target.tables where sourceTables[table.name] == nil {
            items.append(DatabaseSchemaDiffItem(
                id: "drop-table:\(table.name)",
                kind: .dropTable,
                table: table.name,
                detail: "Drop table \(table.name)",
                sql: "DROP TABLE \(qualified(target.schema, table.name, kind: target.kind))"
            ))
        }

        for sourceTable in source.tables {
            guard let targetTable = targetTables[sourceTable.name] else { continue }
            compareColumns(sourceTable, targetTable, target: target, items: &items)
            compareIndexes(sourceTable, targetTable, target: target, items: &items)
            compareForeignKeys(sourceTable, targetTable, target: target, items: &items)
        }

        return DatabaseSchemaDiffResult(
            source: source,
            target: target,
            items: items.sorted {
                let leftRank = migrationRank($0.kind)
                let rightRank = migrationRank($1.kind)
                if leftRank != rightRank { return leftRank < rightRank }
                if $0.kind == .addTable, $1.kind == .addTable,
                   let leftOrder = newTableOrder[$0.table], let rightOrder = newTableOrder[$1.table], leftOrder != rightOrder {
                    return leftOrder < rightOrder
                }
                return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
            }
        )
    }

    private static func orderedNewTables(_ tables: [DatabaseSchemaTableSnapshot]) -> [DatabaseSchemaTableSnapshot] {
        var remaining = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })
        var result: [DatabaseSchemaTableSnapshot] = []
        while !remaining.isEmpty {
            let ready = remaining.values.filter { table in
                table.foreignKeys.allSatisfy { remaining[$0.referencedTable] == nil }
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if ready.isEmpty {
                // A cycle cannot be topologically ordered. SQLite permits these
                // declarations during table creation; other engines present the
                // generated migration for the user to review.
                result.append(contentsOf: remaining.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
                break
            }
            for table in ready {
                result.append(table)
                remaining.removeValue(forKey: table.name)
            }
        }
        return result
    }

    private static func migrationRank(_ kind: DatabaseSchemaDiffKind) -> Int {
        switch kind {
        case .addTable: 0
        case .addColumn, .changeColumn: 1
        case .addIndex: 2
        case .addForeignKey: 3
        case .dropForeignKey: 4
        case .dropIndex: 5
        case .dropColumn: 6
        case .dropTable: 7
        }
    }

    private static func compareColumns(
        _ source: DatabaseSchemaTableSnapshot,
        _ target: DatabaseSchemaTableSnapshot,
        target snapshot: DatabaseSchemaSnapshot,
        items: inout [DatabaseSchemaDiffItem]
    ) {
        let sourceColumns = Dictionary(uniqueKeysWithValues: source.columns.map { ($0.name, $0) })
        let targetColumns = Dictionary(uniqueKeysWithValues: target.columns.map { ($0.name, $0) })

        for column in source.columns where targetColumns[column.name] == nil {
            items.append(DatabaseSchemaDiffItem(
                id: "add-column:\(source.name):\(column.name)",
                kind: .addColumn,
                table: source.name,
                detail: "Add column \(column.name)",
                sql: addColumnSQL(table: source.name, column: column, kind: snapshot.kind, schema: snapshot.schema)
            ))
        }
        for column in target.columns where sourceColumns[column.name] == nil {
            items.append(DatabaseSchemaDiffItem(
                id: "drop-column:\(source.name):\(column.name)",
                kind: .dropColumn,
                table: source.name,
                detail: "Drop column \(column.name)",
                sql: "ALTER TABLE \(qualified(snapshot.schema, source.name, kind: snapshot.kind)) DROP COLUMN \(quote(column.name, kind: snapshot.kind))"
            ))
        }
        for sourceColumn in source.columns {
            guard let targetColumn = targetColumns[sourceColumn.name] else { continue }
            guard sourceColumn.dataType.caseInsensitiveCompare(targetColumn.dataType) != .orderedSame
                || sourceColumn.isNullable != targetColumn.isNullable
                || sourceColumn.defaultValue != targetColumn.defaultValue else { continue }
            let type = sourceColumn.dataType.isEmpty ? targetColumn.dataType : sourceColumn.dataType
            let nullable = sourceColumn.isNullable ? "NULL" : "NOT NULL"
            let defaultSQL = sourceColumn.defaultValue.map { " DEFAULT \($0)" } ?? ""
            let sql: String
            switch snapshot.kind {
            case .mysql:
                sql = "ALTER TABLE \(qualified(snapshot.schema, source.name, kind: snapshot.kind)) MODIFY COLUMN \(quote(sourceColumn.name, kind: snapshot.kind)) \(type) \(nullable)\(defaultSQL)"
            case .postgresql:
                // PostgreSQL requires separate statements for type/nullability.
                // The first statement is the deterministic, non-destructive part;
                // the complete migration text below retains all requested clauses.
                sql = "ALTER TABLE \(qualified(snapshot.schema, source.name, kind: snapshot.kind)) ALTER COLUMN \(quote(sourceColumn.name, kind: snapshot.kind)) TYPE \(type); ALTER TABLE \(qualified(snapshot.schema, source.name, kind: snapshot.kind)) ALTER COLUMN \(quote(sourceColumn.name, kind: snapshot.kind)) \(sourceColumn.isNullable ? "DROP NOT NULL" : "SET NOT NULL")\(defaultSQL.isEmpty ? "" : "; ALTER TABLE \(qualified(snapshot.schema, source.name, kind: snapshot.kind)) ALTER COLUMN \(quote(sourceColumn.name, kind: snapshot.kind)) SET DEFAULT \(String(defaultSQL.dropFirst(9)))")"
            case .sqlite, .redis, .nacos:
                sql = "-- SQLite requires a table rebuild to change column definition: \(source.name).\(sourceColumn.name)"
            }
            items.append(DatabaseSchemaDiffItem(
                id: "change-column:\(source.name):\(sourceColumn.name)",
                kind: .changeColumn,
                table: source.name,
                detail: "Change column \(sourceColumn.name) (\(targetColumn.dataType) -> \(sourceColumn.dataType))",
                sql: sql
            ))
        }
    }

    private static func compareIndexes(
        _ source: DatabaseSchemaTableSnapshot,
        _ target: DatabaseSchemaTableSnapshot,
        target snapshot: DatabaseSchemaSnapshot,
        items: inout [DatabaseSchemaDiffItem]
    ) {
        let sourceNames = Set(source.indexes.map(\.name))
        let targetNames = Set(target.indexes.map(\.name))
        for index in source.indexes where !targetNames.contains(index.name) {
            let sql = index.definition.isEmpty
                ? "-- Create index \(index.name) on \(source.name) from the source definition"
                : normalizeDefinition(index.definition, target: snapshot)
            items.append(DatabaseSchemaDiffItem(id: "add-index:\(source.name):\(index.name)", kind: .addIndex, table: source.name, detail: "Add index \(index.name)", sql: sql))
        }
        for index in target.indexes where !sourceNames.contains(index.name) {
            let sql = snapshot.kind == .mysql
                ? "DROP INDEX \(quote(index.name, kind: snapshot.kind)) ON \(qualified(snapshot.schema, source.name, kind: snapshot.kind))"
                : "DROP INDEX \(qualified(snapshot.schema, index.name, kind: snapshot.kind))"
            items.append(DatabaseSchemaDiffItem(id: "drop-index:\(source.name):\(index.name)", kind: .dropIndex, table: source.name, detail: "Drop index \(index.name)", sql: sql))
        }
    }

    private static func compareForeignKeys(
        _ source: DatabaseSchemaTableSnapshot,
        _ target: DatabaseSchemaTableSnapshot,
        target snapshot: DatabaseSchemaSnapshot,
        items: inout [DatabaseSchemaDiffItem]
    ) {
        let sourceGroups = foreignKeyGroups(source.foreignKeys)
        let targetGroups = foreignKeyGroups(target.foreignKeys)
        let sourceSignatures = Set(sourceGroups.map(foreignKeySignature))
        let targetSignatures = Set(targetGroups.map(foreignKeySignature))

        for group in sourceGroups where !targetSignatures.contains(foreignKeySignature(group)) {
            let sql: String
            if snapshot.kind == .sqlite {
                sql = "-- SQLite requires a table rebuild to add foreign key \(group.name) to \(source.name)"
            } else {
                let clause = foreignKeyClause(group, kind: snapshot.kind, includeConstraintName: true)
                sql = "ALTER TABLE \(qualified(snapshot.schema, source.name, kind: snapshot.kind)) ADD \(clause)"
            }
            items.append(DatabaseSchemaDiffItem(id: "add-fk:\(source.name):\(group.name)", kind: .addForeignKey, table: source.name, detail: "Add foreign key \(group.name)", sql: sql))
        }
        for group in targetGroups where !sourceSignatures.contains(foreignKeySignature(group)) {
            let sql: String
            if snapshot.kind == .sqlite {
                sql = "-- SQLite requires a table rebuild to drop foreign key \(group.name) from \(source.name)"
            } else if snapshot.kind == .mysql {
                sql = "ALTER TABLE \(qualified(snapshot.schema, source.name, kind: snapshot.kind)) DROP FOREIGN KEY \(quote(group.name, kind: snapshot.kind))"
            } else {
                sql = "ALTER TABLE \(qualified(snapshot.schema, source.name, kind: snapshot.kind)) DROP CONSTRAINT \(quote(group.name, kind: snapshot.kind))"
            }
            items.append(DatabaseSchemaDiffItem(id: "drop-fk:\(source.name):\(group.name)", kind: .dropForeignKey, table: source.name, detail: "Drop foreign key \(group.name)", sql: sql))
        }
    }

    private static func createTableSQL(_ table: DatabaseSchemaTableSnapshot, kind: DatabaseKind, schema: String) -> String {
        let definitions = table.columns.map { column in
            var definition = "\(quote(column.name, kind: kind)) \(column.dataType.isEmpty ? "TEXT" : column.dataType)"
            if !column.isNullable { definition += " NOT NULL" }
            if let defaultValue = column.defaultValue, !defaultValue.isEmpty { definition += " DEFAULT \(defaultValue)" }
            return definition
        }
        let primaryKeys = table.columns.filter(\.isPrimaryKey).map { quote($0.name, kind: kind) }
        let primarySQL = primaryKeys.isEmpty ? [] : ["PRIMARY KEY (\(primaryKeys.joined(separator: ", ")))" ]
        let foreignKeys = foreignKeyGroups(table.foreignKeys).map {
            foreignKeyClause($0, kind: kind, includeConstraintName: !(kind == .sqlite && Int($0.name) != nil))
        }
        let body = (definitions + primarySQL + foreignKeys).joined(separator: ", ")
        return "CREATE TABLE \(qualified(schema, table.name, kind: kind)) (\(body))"
    }

    private static func foreignKeyGroups(_ keys: [DatabaseSchemaForeignKeySnapshot]) -> [DatabaseForeignKeyGroup] {
        Dictionary(grouping: keys) { "\($0.name)\u{0}\($0.referencedTable)" }
            .values
            .compactMap { entries -> DatabaseForeignKeyGroup? in
                guard let first = entries.first else { return nil }
                return DatabaseForeignKeyGroup(
                    name: first.name,
                    referencedTable: first.referencedTable,
                    columns: entries.sorted { $0.column.localizedCaseInsensitiveCompare($1.column) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func foreignKeySignature(_ group: DatabaseForeignKeyGroup) -> String {
        "\(group.name)|\(group.referencedTable)|\(group.columns.map { "\($0.column)>\($0.referencedColumn)" }.joined(separator: ","))"
    }

    private static func foreignKeyClause(_ group: DatabaseForeignKeyGroup, kind: DatabaseKind, includeConstraintName: Bool) -> String {
        let constraint = includeConstraintName ? "CONSTRAINT \(quote(group.name, kind: kind)) " : ""
        let columns = group.columns.map { quote($0.column, kind: kind) }.joined(separator: ", ")
        let references = group.columns.map { quote($0.referencedColumn, kind: kind) }.joined(separator: ", ")
        return "\(constraint)FOREIGN KEY (\(columns)) REFERENCES \(quote(group.referencedTable, kind: kind)) (\(references))"
    }

    private static func addColumnSQL(table: String, column: DatabaseSchemaColumnSnapshot, kind: DatabaseKind, schema: String) -> String {
        var sql = "ALTER TABLE \(qualified(schema, table, kind: kind)) ADD COLUMN \(quote(column.name, kind: kind)) \(column.dataType.isEmpty ? "TEXT" : column.dataType)"
        if !column.isNullable { sql += " NOT NULL" }
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty { sql += " DEFAULT \(defaultValue)" }
        return sql
    }

    private static func normalizeDefinition(_ definition: String, target: DatabaseSchemaSnapshot) -> String {
        // PostgreSQL already returns a complete CREATE INDEX definition. For
        // other engines the source definition is still the safest reviewable SQL.
        definition.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ";$", with: "", options: .regularExpression)
    }

    private static func qualified(_ schema: String, _ name: String, kind: DatabaseKind) -> String {
        let quotedName = quote(name, kind: kind)
        guard !schema.isEmpty, kind != .mysql else { return quotedName }
        return "\(quote(schema, kind: kind)).\(quotedName)"
    }

    private static func quote(_ value: String, kind: DatabaseKind) -> String {
        switch kind {
        case .mysql: return "`\(value.replacingOccurrences(of: "`", with: "``"))`"
        case .postgresql, .sqlite, .redis, .nacos: return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }
}

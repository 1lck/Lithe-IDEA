import SwiftUI
import LitheDatabaseModule

/// Database operations keep some user-facing status values as strings so they
/// can be persisted in the audit log. Resolve those strings at the view edge:
/// known keys follow the app's injected locale, while database-driver errors
/// that have no translation continue to be shown verbatim.
enum DatabaseLocalization {
    static func text(_ value: String) -> Text {
        Text(LocalizedStringKey(value))
    }

    /// Turns failures emitted by our helper process into a localized summary
    /// without changing the driver/server supplied detail. The detail can
    /// contain SQL, identifiers, error codes, or vendor-specific diagnostics,
    /// so it must remain exact for troubleshooting.
    static func error(_ value: String) -> Text {
        if value == "The Lithe database helper is not installed." {
            return Text("The Lithe database helper is not installed.")
        }

        let processPrefix = "The database helper exited with code "
        if value.hasPrefix(processPrefix) {
            let remainder = String(value.dropFirst(processPrefix.count))
            let parts = remainder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               let code = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                let detail = String(parts[1]).trimmingCharacters(in: .whitespaces)
                return Text("The database helper exited with code \(code). Details: \(detail)")
            }
        }

        let invalidResponsePrefix = "The database helper returned invalid JSON: "
        if value.hasPrefix(invalidResponsePrefix) {
            let detail = String(value.dropFirst(invalidResponsePrefix.count))
            return Text("The database helper returned an invalid response. Details: \(detail)")
        }

        let requestFailedPrefix = "Database request failed ("
        if value.hasPrefix(requestFailedPrefix) {
            let remainder = String(value.dropFirst(requestFailedPrefix.count))
            if let separator = remainder.range(of: "): ") {
                let code = String(remainder[..<separator.lowerBound])
                let detail = String(remainder[separator.upperBound...])
                return Text("The database request failed (\(code)). Details: \(detail)")
            }
        }

        return text(value)
    }

    static func statementKind(_ kind: DatabaseSQLStatementKind?) -> Text {
        switch kind {
        case .query: Text("Query")
        case .mutation: Text("Data change")
        case .definition: Text("Schema change")
        case .transaction: Text("Transaction")
        case .batch: Text("Batch")
        case .unknown: Text("Unknown")
        case nil: Text("None")
        }
    }

    static func auditAction(_ action: String) -> Text {
        switch action {
        case "schemaMigration": Text("Schema migration")
        case "schemaChange": Text("Schema change")
        case "tableEdit": Text("Table edit")
        case "import": Text("Import")
        case "sql": Text("SQL")
        case "rollback": Text("Restore")
        case "backup": Text("Backup")
        default: text(action)
        }
    }

    static func queryTabTitle(_ title: String) -> Text {
        let prefix = "Query "
        if title.hasPrefix(prefix), let number = Int(title.dropFirst(prefix.count)) {
            return Text("Query \(number)")
        }
        return Text(title)
    }

    static func schemaDiffDetail(_ item: DatabaseSchemaDiffItem) -> Text {
        switch item.kind {
        case .addTable:
            Text("Create table \(item.table)")
        case .dropTable:
            Text("Drop table \(item.table)")
        case .addColumn:
            Text("Add column \(detailSuffix(item.detail, prefix: "Add column "))")
        case .dropColumn:
            Text("Drop column \(detailSuffix(item.detail, prefix: "Drop column "))")
        case .changeColumn:
            Text("Change column \(detailSuffix(item.detail, prefix: "Change column "))")
        case .addIndex:
            Text("Add index \(detailSuffix(item.detail, prefix: "Add index "))")
        case .dropIndex:
            Text("Drop index \(detailSuffix(item.detail, prefix: "Drop index "))")
        case .addForeignKey:
            Text("Add foreign key \(detailSuffix(item.detail, prefix: "Add foreign key "))")
        case .dropForeignKey:
            Text("Drop foreign key \(detailSuffix(item.detail, prefix: "Drop foreign key "))")
        }
    }

    private static func detailSuffix(_ detail: String, prefix: String) -> String {
        guard detail.hasPrefix(prefix) else { return detail }
        return String(detail.dropFirst(prefix.count))
    }
}

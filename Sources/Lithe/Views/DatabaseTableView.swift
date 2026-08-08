import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DatabaseTableView: View {
    @EnvironmentObject private var model: AppModel
    @State private var drafts: [CellKey: DatabaseValue] = [:]
    @State private var insertedRows: [DatabaseRow] = []
    @State private var selectedRows: Set<Int> = []
    @State private var deletedRows: Set<Int> = []
    @State private var exportDocument: DatabaseTransferDocument?
    @State private var temporaryExportURL: URL?
    @State private var exportFormat = DatabaseTransferFormat.csv
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var filterColumn = ""
    @State private var filterText = ""
    @State private var sort: [DatabaseSort] = []
    @State private var pasteAnchor: CellKey?
    @State private var showsReplaceSheet = false
    @State private var replaceColumn = ""
    @State private var replaceText = ""
    @State private var replacementText = ""
    @State private var pendingImportData: Data?
    @State private var pendingImportURL: URL?
    @State private var pendingImportFormat: DatabaseTransferFormat?
    @State private var showsProtectedImportConfirmation = false
    @State private var showsProtectedTableChangeConfirmation = false
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.databaseFeature.selectedTable != nil { filterBar }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if model.databaseFeature.selectedTable == nil {
                DatabaseTableEmptyState(hasConnection: model.databaseFeature.selectedProfile != nil)
            } else if model.databaseFeature.columns.isEmpty && !model.databaseFeature.isLoading {
                DatabaseTableEmptyState(hasConnection: true, hasColumns: false)
            } else {
                grid
            }
        }
        .background(LitheTheme.editor)
        .onChange(of: model.databaseFeature.selectedTable) { _, _ in discard() }
        .sheet(isPresented: $showsReplaceSheet) {
            DatabaseReplaceSheet(
                columns: model.databaseFeature.columns,
                column: $replaceColumn,
                searchText: $replaceText,
                replacementText: $replacementText,
                onReplace: replaceCurrentPage
            )
            .environment(\.locale, model.settings.language.locale)
            .id(model.settings.language)
        }
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: exportFormat.contentType, defaultFilename: exportFilename) { result in
            if case let .failure(error) = result { model.databaseFeature.errorMessage = error.localizedDescription }
            if let temporaryExportURL { try? FileManager.default.removeItem(at: temporaryExportURL) }
            temporaryExportURL = nil
            exportDocument = nil
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.commaSeparatedText, .json, .sql]) { result in
            importFile(result)
        }
        .confirmationDialog(
            "Confirm Database Import",
            isPresented: $showsProtectedImportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Import and Modify Database", role: .destructive) {
                startPendingImport(confirmed: true)
            }
            Button("Cancel", role: .cancel) {
                discardPendingImport()
            }
        } message: {
            DatabaseLocalization.text(importConfirmationMessage)
        }
        .confirmationDialog(
            "Confirm Table Changes",
            isPresented: $showsProtectedTableChangeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply Changes and Delete Rows", role: .destructive) {
                performApply(confirmed: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This protected connection will delete selected rows. The other pending table edits will be applied in the same transaction.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "tablecells")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 24, height: 24)
                    .background(LitheTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Group {
                        if let table = model.databaseFeature.selectedTable {
                            Text(table)
                        } else {
                            Text("Database")
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    if model.databaseFeature.selectedTable != nil {
                        Text("\(model.databaseFeature.totalRows) rows")
                            .font(.system(size: 9.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
            toolbarGroup {
                Button { insertedRows.append([:]) } label: { Image(systemName: "plus") }.litheIconButton().help("Add row")
                    .disabled(model.databaseFeature.selectedTable == nil)
                Button { markSelectedForDeletion() } label: { Image(systemName: "trash") }.litheIconButton().help("Delete selected rows")
                    .disabled(selectedRows.isEmpty)
                Menu {
                    Button { pasteFromClipboard() } label: { Label("Paste TSV from Clipboard", systemImage: "doc.on.clipboard") }
                        .disabled(model.databaseFeature.selectedTable == nil)
                    Button { showsReplaceSheet = true } label: { Label("Replace in Current Page…", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(model.databaseFeature.rows.isEmpty)
                } label: { Image(systemName: "doc.on.clipboard") }
                    .menuStyle(.borderlessButton).frame(width: 28).help("Batch paste or replace table values")
            }
            toolbarGroup {
                Button { discard() } label: { Image(systemName: "arrow.uturn.backward") }.litheIconButton().help("Discard changes")
                    .disabled(!hasChanges)
                Button { apply() } label: { Image(systemName: "checkmark") }.litheIconButton().help("Apply changes")
                    .disabled(!hasChanges || model.databaseFeature.isLoading)
            }
            toolbarGroup {
                Button { if let table = model.databaseFeature.selectedTable { Task { await model.databaseFeature.openTable(table) } } } label: { Image(systemName: "arrow.clockwise") }.litheIconButton().help("Refresh table")
                Menu {
                    Section("Columns") {
                        ForEach(model.databaseFeature.columns, id: \.self) { Text($0) }
                    }
                    Section("Indexes (\(model.databaseFeature.indexes.count))") {
                        if model.databaseFeature.indexes.isEmpty { Text("None") }
                        ForEach(Array(model.databaseFeature.indexes.enumerated()), id: \.offset) { _, row in Text(metadataLabel(row)) }
                    }
                    Section("Foreign Keys (\(model.databaseFeature.foreignKeys.count))") {
                        if model.databaseFeature.foreignKeys.isEmpty { Text("None") }
                        ForEach(Array(model.databaseFeature.foreignKeys.enumerated()), id: \.offset) { _, row in Text(metadataLabel(row)) }
                    }
                } label: { Image(systemName: "info.circle") }
                    .menuStyle(.borderlessButton).frame(width: 28).help("Table structure, indexes, and foreign keys")
                    .disabled(model.databaseFeature.selectedTable == nil)
                Menu {
                    Button("Import CSV…") { importFormat = .csv; showsImporter = true }
                    Button("Import JSON…") { importFormat = .json; showsImporter = true }
                    Button("Restore SQL Backup…") { importFormat = .sql; showsImporter = true }
                    Divider()
                    Button("Export Table as CSV…") { export(.csv) }
                    Button("Export Table as JSON…") { export(.json) }
                    Button("Back Up Database as SQL…") { export(.sql) }
                } label: { Image(systemName: "square.and.arrow.up.on.square") }
                    .menuStyle(.borderlessButton).frame(width: 28).help("Import or export database data")
            }
        }
        .padding(.horizontal, 12).frame(height: 44).foregroundStyle(LitheTheme.primaryText).background(LitheTheme.toolHeader)
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            Picker("", selection: $filterColumn) {
                Text("Column").tag("")
                ForEach(model.databaseFeature.columns, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 120)
            TextField("Filter rows", text: $filterText)
                .textFieldStyle(.plain)
                .focused($isFilterFocused)
                .litheSearchField(isFocused: isFilterFocused)
                .frame(maxWidth: 240)
                .onSubmit { applyFilter() }
            Button { applyFilter() } label: { Image(systemName: "line.3.horizontal.decrease") }.litheIconButton().help("Apply filter")
            Button { clearFilter() } label: { Image(systemName: "xmark") }.litheIconButton().help("Clear filter").disabled(filterText.isEmpty && sort.isEmpty)
            Spacer()
            Button { previousPage() } label: { Image(systemName: "chevron.left") }.litheIconButton().help("Previous page").disabled(model.databaseFeature.currentOffset == 0)
            Text(pageLabel).font(.system(size: 10.5)).foregroundStyle(LitheTheme.secondaryText).lineLimit(1).frame(minWidth: 90)
            Button { nextPage() } label: { Image(systemName: "chevron.right") }.litheIconButton().help("Next page")
                .disabled(model.databaseFeature.currentOffset + model.databaseFeature.rows.count >= model.databaseFeature.totalRows)
        }
        .padding(.horizontal, 12).frame(height: 38).background(LitheTheme.toolHeader.opacity(0.92))
    }

    private func toolbarGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0, content: content)
            .padding(2)
            .background(LitheTheme.inputBackground.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .stroke(LitheTheme.panelBorder.opacity(0.7), lineWidth: 1)
            }
    }

    private var grid: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(model.databaseFeature.rows.enumerated()), id: \.offset) { index, row in
                            rowView(index: index, row: row, isInserted: false)
                                .opacity(deletedRows.contains(index) ? 0.42 : 1)
                        }
                        ForEach(Array(insertedRows.enumerated()), id: \.offset) { index, row in
                            insertedRowView(index: index, row: row)
                        }
                    } header: { header }
                }
                .frame(minWidth: max(geometry.size.width, CGFloat(model.databaseFeature.columns.count) * 160 + 42), alignment: .topLeading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 42)
            ForEach(model.databaseFeature.columns, id: \.self) { column in
                Button { toggleSort(column) } label: {
                    HStack(spacing: 4) {
                        Text(column).lineLimit(1)
                        if let selected = sort.first, selected.column == column { Image(systemName: selected.descending ? "arrow.down" : "arrow.up").font(.system(size: 8)) }
                    }.font(.system(size: 11.5, weight: .semibold)).padding(.horizontal, 7).frame(width: 160, height: 29, alignment: .leading)
                }.buttonStyle(.plain)
                    .overlay(alignment: .trailing) { Rectangle().fill(LitheTheme.divider).frame(width: 1) }
            }
        }.foregroundStyle(LitheTheme.secondaryText).background(LitheTheme.raised)
    }

    private func rowView(index: Int, row: DatabaseRow, isInserted: Bool) -> some View {
        HStack(spacing: 0) {
            Button { toggleSelection(index) } label: { Text("\(index + 1)").frame(width: 42, height: 27) }
                .buttonStyle(.plain).background(selectedRows.contains(index) ? LitheTheme.selection : LitheTheme.toolHeader)
            ForEach(model.databaseFeature.columns, id: \.self) { column in
                TextField("NULL", text: binding(row: index, column: column, original: row[column]))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 7)
                    .frame(width: 160, height: 27).background(drafts[CellKey(row: index, column: column)] == nil ? Color.clear : LitheTheme.warning.opacity(0.12))
                    .overlay(alignment: .trailing) { Rectangle().fill(LitheTheme.divider).frame(width: 1) }
                    .onTapGesture { pasteAnchor = CellKey(row: index, column: column) }
                    .contextMenu {
                        Button("Set NULL") { setNull(row: index, column: column) }
                        Button("Revert Cell") { drafts.removeValue(forKey: CellKey(row: index, column: column)) }
                    }
            }
        }.overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
    }

    private func insertedRowView(index: Int, row: DatabaseRow) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "plus").frame(width: 42, height: 27).background(LitheTheme.success.opacity(0.12))
            ForEach(model.databaseFeature.columns, id: \.self) { column in
                TextField("Default", text: insertedBinding(row: index, column: column))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 7)
                    .frame(width: 160, height: 27).background(LitheTheme.success.opacity(0.08))
                    .overlay(alignment: .trailing) { Rectangle().fill(LitheTheme.divider).frame(width: 1) }
                    .contextMenu {
                        Button("Set NULL") { insertedRows[index][column] = .null }
                        Button("Use Column Default") { insertedRows[index].removeValue(forKey: column) }
                    }
            }
        }.overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
    }

    private var hasChanges: Bool { !drafts.isEmpty || !insertedRows.isEmpty || !deletedRows.isEmpty }
    private func toggleSelection(_ index: Int) { if selectedRows.contains(index) { selectedRows.remove(index) } else { selectedRows.insert(index) } }
    private func markSelectedForDeletion() { deletedRows.formUnion(selectedRows); selectedRows = [] }
    private func discard() { drafts = [:]; insertedRows = []; selectedRows = []; deletedRows = []; pasteAnchor = nil }

    private func binding(row: Int, column: String, original: DatabaseValue?) -> Binding<String> {
        let key = CellKey(row: row, column: column)
        let originalText = display(original)
        return Binding(get: { drafts[key].map(display) ?? originalText }, set: { value in
            if value == originalText { drafts.removeValue(forKey: key) } else { drafts[key] = .string(value) }
        })
    }

    private func insertedBinding(row: Int, column: String) -> Binding<String> {
        Binding(get: { insertedRows[row][column].map(display) ?? "" }, set: { insertedRows[row][column] = .string($0) })
    }

    private func setNull(row: Int, column: String) {
        let key = CellKey(row: row, column: column)
        if model.databaseFeature.rows[row][column] == .null { drafts.removeValue(forKey: key) }
        else { drafts[key] = .null }
    }

    private func apply() {
        if model.databaseFeature.selectedProfile?.productionProtection == true, !deletedRows.isEmpty {
            showsProtectedTableChangeConfirmation = true
            return
        }
        performApply(confirmed: false)
    }

    private func performApply(confirmed: Bool) {
        let cellDrafts = drafts.map { DatabaseCellDraft(rowIndex: $0.key.row, column: $0.key.column, value: $0.value) }
        Task {
            if await model.databaseFeature.apply(
                drafts: cellDrafts,
                insertedRows: insertedRows,
                deletedIndexes: deletedRows,
                confirmed: confirmed
            ) {
                discard()
            }
        }
    }

    private func display(_ value: DatabaseValue?) -> String {
        switch value { case nil, .null: ""; case let .string(value): value; case let .integer(value): String(value); case let .number(value): String(value); case let .bool(value): value ? "true" : "false"; case let .object(value): String(describing: value); case let .array(value): String(describing: value) }
    }

    private func metadataLabel(_ row: DatabaseRow) -> String {
        let preferredKeys = ["index_name", "name", "constraint_name", "column_name", "referenced_table_name"]
        let values = preferredKeys.compactMap { key -> String? in
            guard let value = row[key] else { return nil }
            let text = display(value)
            return text.isEmpty ? nil : text
        }
        return values.isEmpty ? row.keys.sorted().joined(separator: ", ") : values.joined(separator: " - ")
    }

    private var activeFilters: [DatabaseFilter] {
        guard !filterColumn.isEmpty, !filterText.isEmpty else { return [] }
        return [DatabaseFilter(column: filterColumn, operator: .contains, value: .string(filterText))]
    }
    private var pageLabel: String {
        guard model.databaseFeature.totalRows > 0 else { return "0 / 0" }
        return "\(model.databaseFeature.currentOffset + 1)-\(model.databaseFeature.currentOffset + model.databaseFeature.rows.count) / \(model.databaseFeature.totalRows)"
    }
    private func applyFilter() { Task { await model.databaseFeature.loadPage(filters: activeFilters, sort: sort, offset: 0); discard() } }
    private func clearFilter() { filterText = ""; filterColumn = ""; sort = []; applyFilter() }
    private func toggleSort(_ column: String) {
        if let current = sort.first, current.column == column { sort = current.descending ? [] : [DatabaseSort(column: column, descending: true)] }
        else { sort = [DatabaseSort(column: column)] }
        applyFilter()
    }
    private func previousPage() { Task { await model.databaseFeature.loadPage(filters: activeFilters, sort: sort, offset: max(0, model.databaseFeature.currentOffset - model.databaseFeature.pageSize)); discard() } }
    private func nextPage() { Task { await model.databaseFeature.loadPage(filters: activeFilters, sort: sort, offset: model.databaseFeature.currentOffset + model.databaseFeature.pageSize); discard() } }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty, !model.databaseFeature.columns.isEmpty else { return }
        let anchorRow = pasteAnchor?.row ?? selectedRows.min() ?? 0
        let anchorColumn = pasteAnchor.flatMap { model.databaseFeature.columns.firstIndex(of: $0.column) } ?? 0
        for (rowOffset, line) in lines.enumerated() {
            let values = line.components(separatedBy: "\t")
            let targetRow = anchorRow + rowOffset
            let insertedIndex = targetRow - model.databaseFeature.rows.count
            if insertedIndex >= 0 {
                while insertedRows.count <= insertedIndex { insertedRows.append([:]) }
            }
            for (columnOffset, value) in values.enumerated() {
                let columnIndex = anchorColumn + columnOffset
                guard model.databaseFeature.columns.indices.contains(columnIndex) else { continue }
                let column = model.databaseFeature.columns[columnIndex]
                if targetRow < model.databaseFeature.rows.count {
                    drafts[CellKey(row: targetRow, column: column)] = .string(value)
                } else {
                    insertedRows[insertedIndex][column] = .string(value)
                }
            }
        }
    }

    private func replaceCurrentPage() {
        guard !replaceText.isEmpty else { return }
        let columns = replaceColumn.isEmpty ? model.databaseFeature.columns : [replaceColumn]
        for (rowIndex, row) in model.databaseFeature.rows.enumerated() {
            for column in columns {
                guard let value = row[column] else { continue }
                let current = display(value)
                // A masked value is a display placeholder, never a safe source
                // value for a bulk replacement.
                guard current != "******" else { continue }
                let replacement = current.replacingOccurrences(of: replaceText, with: replacementText)
                if replacement != current {
                    drafts[CellKey(row: rowIndex, column: column)] = .string(replacement)
                }
            }
        }
    }

    @State private var importFormat = DatabaseTransferFormat.csv

    private var exportFilename: String {
        let base = exportFormat == .sql ? (model.databaseFeature.selectedProfile?.database.nonEmpty ?? "database") : (model.databaseFeature.selectedTable ?? "table")
        return "\(base).\(exportFormat.rawValue)"
    }

    private func export(_ format: DatabaseTransferFormat) {
        exportFormat = format
        Task {
            if format == .sql {
                guard let url = await model.databaseFeature.exportDataFile(format: format) else { return }
                temporaryExportURL = url
                exportDocument = DatabaseTransferDocument(fileURL: url)
            } else {
                guard let data = await model.databaseFeature.exportData(format: format) else { return }
                exportDocument = DatabaseTransferDocument(data: data)
            }
            showsExporter = true
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if importFormat == .sql {
                let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-import-\(UUID().uuidString).sql")
                try FileManager.default.copyItem(at: url, to: temporaryURL)
                stageImport(fileURL: temporaryURL, format: .sql)
                return
            }
            stageImport(data: try Data(contentsOf: url), format: importFormat)
        } catch { model.databaseFeature.errorMessage = error.localizedDescription }
    }

    private func stageImport(data: Data? = nil, fileURL: URL? = nil, format: DatabaseTransferFormat) {
        pendingImportData = data
        pendingImportURL = fileURL
        pendingImportFormat = format
        if format == .sql || model.databaseFeature.selectedProfile?.productionProtection == true {
            showsProtectedImportConfirmation = true
        } else {
            startPendingImport(confirmed: false)
        }
    }

    private func startPendingImport(confirmed: Bool) {
        guard let format = pendingImportFormat else { return }
        let data = pendingImportData
        let fileURL = pendingImportURL
        pendingImportData = nil
        pendingImportURL = nil
        pendingImportFormat = nil
        Task {
            if let fileURL {
                defer { try? FileManager.default.removeItem(at: fileURL) }
                _ = await model.databaseFeature.importDataFile(fileURL, format: format, confirmed: confirmed)
            } else if let data {
                _ = await model.databaseFeature.importData(data, format: format, confirmed: confirmed)
            }
        }
    }

    private func discardPendingImport() {
        if let pendingImportURL { try? FileManager.default.removeItem(at: pendingImportURL) }
        pendingImportData = nil
        pendingImportURL = nil
        pendingImportFormat = nil
    }

    private var importConfirmationMessage: String {
        if pendingImportFormat == .sql {
            return "Restoring a SQL backup replaces the current database objects and data. A recovery snapshot will be created first."
        }
        return "This connection has production protection enabled. Importing can change database data."
    }
}

private struct DatabaseTableEmptyState: View {
    let hasConnection: Bool
    var hasColumns = true

    private var title: LocalizedStringKey {
        hasColumns ? "No Table Selected" : "No Columns"
    }

    private var detail: LocalizedStringKey {
        if !hasConnection {
            "Choose a database connection and then a table from the sidebar."
        } else if hasColumns {
            "Choose a table from the sidebar to browse and edit data."
        } else {
            "The selected table has no columns to display."
        }
    }

    private var symbol: String {
        hasColumns ? "tablecells" : "tablecells.badge.ellipsis"
    }

    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
                .frame(width: 58, height: 58)
                .background(LitheTheme.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(LitheTheme.accent.opacity(0.22), lineWidth: 1)
                }
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct CellKey: Hashable { let row: Int; let column: String }

private struct DatabaseReplaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let columns: [String]
    @Binding var column: String
    @Binding var searchText: String
    @Binding var replacementText: String
    let onReplace: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Replace Values in Current Page")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Form {
                Picker("Column", selection: $column) {
                    Text("All columns").tag("")
                    ForEach(columns, id: \.self) { Text($0).tag($0) }
                }
                TextField("Find", text: $searchText)
                TextField("Replace with", text: $replacementText)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Replace") { onReplace(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(searchText.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 250)
    }
}

private struct DatabaseTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data?
    let fileURL: URL?
    init(data: Data) { self.data = data; fileURL = nil }
    init(fileURL: URL) { data = nil; self.fileURL = fileURL }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data(); fileURL = nil }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let fileURL { return try FileWrapper(url: fileURL, options: []) }
        return FileWrapper(regularFileWithContents: data ?? Data())
    }
}

private extension DatabaseTransferFormat {
    var contentType: UTType { switch self { case .csv: .commaSeparatedText; case .json: .json; case .sql: .sql } }
}

private extension UTType {
    static let sql = UTType(filenameExtension: "sql") ?? .plainText
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

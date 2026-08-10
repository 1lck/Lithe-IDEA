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
    @State private var filterConditions: [DatabaseTableFilterDraft] = [.init()]
    @State private var filterJoin = DatabaseFilterJoin.and
    @State private var appliedFilters: [DatabaseFilter] = []
    @State private var showsFilterPopover = false
    @State private var sortConditions: [DatabaseTableSortDraft] = []
    @State private var appliedSort: [DatabaseSort] = []
    @State private var showsSortPopover = false
    @State private var jumpTargetColumn: String?
    @State private var rowDetailsIndex: Int?
    @State private var pasteAnchor: CellKey?
    @State private var showsReplaceSheet = false
    @State private var showsBatchUpdateSheet = false
    @State private var showsBatchDeleteConfirmation = false
    @State private var replaceColumn = ""
    @State private var replaceText = ""
    @State private var replacementText = ""
    @State private var pendingImportData: Data?
    @State private var pendingImportURL: URL?
    @State private var pendingImportFormat: DatabaseTransferFormat?
    @State private var showsProtectedImportConfirmation = false
    @State private var showsProtectedTableChangeConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.databaseFeature.selectedTable != nil {
                queryClauseBar
                dataActionBar
            }
            if let error = model.databaseFeature.errorMessage, model.databaseFeature.selectedTable != nil {
                Label {
                    DatabaseLocalization.error(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.error)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(LitheTheme.toolHeader)
            }
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
        .onChange(of: model.databaseFeature.selectedTable) { _ in
            discard()
            appliedFilters = []
            appliedSort = []
            sortConditions = []
            filterJoin = .and
            filterConditions = [.init()]
        }
        .onChange(of: model.databaseFeature.columns) { columns in
            if filterConditions.count == 1, filterConditions[0].column.isEmpty {
                filterConditions[0].column = columns.first ?? ""
            }
        }
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
        .sheet(isPresented: $showsBatchUpdateSheet) {
            DatabaseBatchUpdateSheet(
                columns: model.databaseFeature.columns,
                selectedCount: selectedRows.count,
                onApply: applyBatchUpdate
            )
            .environment(\.locale, model.settings.language.locale)
            .id(model.settings.language)
        }
        .sheet(isPresented: Binding(
            get: { rowDetailsIndex != nil },
            set: { if !$0 { rowDetailsIndex = nil } }
        )) {
            if let rowDetailsIndex, model.databaseFeature.rows.indices.contains(rowDetailsIndex) {
                DatabaseRowDetailsSheet(
                    rowNumber: rowDetailsIndex + 1,
                    columns: model.databaseFeature.columns,
                    row: model.databaseFeature.rows[rowDetailsIndex]
                )
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
            }
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
            "Delete selected rows?",
            isPresented: $showsBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mark rows for deletion", role: .destructive) {
                markSelectedForDeletion()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected rows will be marked for deletion. Choose Apply to commit this change.")
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
            contextCrumb(model.databaseFeature.selectedProfile?.name ?? String(localized: "Database"), icon: "externaldrive.connected.to.line.below")
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(LitheTheme.tertiaryText)
            contextCrumb(databaseContextName, icon: "cylinder")
            if let table = model.databaseFeature.selectedTable {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(LitheTheme.tertiaryText)
                contextCrumb(table, icon: "tablecells", emphasized: true)
                Text("\(model.databaseFeature.columns.count) fields")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .monospacedDigit()
            }
            Spacer()
            toolbarGroup {
                Button { model.databaseFeature.workspaceSection = .structure } label: {
                    toolbarActionLabel("Table Properties", systemImage: "tablecells")
                }
                .buttonStyle(.plain)
                .disabled(model.databaseFeature.selectedProfile?.kind == .mongodb)

                toolbarDivider

                Menu {
                    Button("Import CSV…") { importFormat = .csv; showsImporter = true }
                        .disabled(model.databaseFeature.selectedProfile?.readOnly == true)
                    Button("Import JSON…") { importFormat = .json; showsImporter = true }
                        .disabled(model.databaseFeature.selectedProfile?.readOnly == true)
                    Button("Restore SQL Backup…") { importFormat = .sql; showsImporter = true }
                        .disabled(model.databaseFeature.selectedProfile?.readOnly == true || model.databaseFeature.selectedProfile?.kind == .sqlserver)
                    Divider()
                    Button("Export Table as CSV…") { export(.csv) }
                    Button("Export Table as JSON…") { export(.json) }
                    Button("Back Up Database as SQL…") { export(.sql) }
                        .disabled(model.databaseFeature.selectedProfile?.kind == .sqlserver)
                } label: {
                    toolbarActionLabel("Data Tools", systemImage: "shippingbox", showsChevron: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(model.databaseFeature.selectedProfile?.kind == .mongodb)

                toolbarDivider

                Menu {
                    Button("Paste TSV from Clipboard") { pasteFromClipboard() }
                    Button("Replace in Current Page…") { showsReplaceSheet = true }
                        .disabled(model.databaseFeature.rows.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: 30, height: 27)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Batch table tools")
            }
        }
        .padding(.horizontal, 12).frame(height: 44).foregroundStyle(LitheTheme.primaryText).background(LitheTheme.toolHeader)
    }

    private var queryClauseBar: some View {
        HStack(spacing: 6) {
            clausePill(title: Text("All rows"), icon: "tray.full", active: true) {}
            clausePill(
                title: Text(verbatim: appliedFilters.isEmpty ? "WHERE" : "WHERE · \(appliedFilters.count)"),
                icon: "line.3.horizontal.decrease",
                active: !appliedFilters.isEmpty
            ) { showsFilterPopover.toggle() }
            .popover(isPresented: $showsFilterPopover, arrowEdge: .bottom) { filterPopover }
            clausePill(
                title: Text(verbatim: sortClauseTitle),
                icon: "arrow.up.arrow.down",
                active: !appliedSort.isEmpty
            ) { showsSortPopover.toggle() }
            .popover(isPresented: $showsSortPopover, arrowEdge: .bottom) { sortPopover }
            Spacer()
            if !appliedFilters.isEmpty || !appliedSort.isEmpty {
                Button("Clear query") { clearQuery() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(LitheTheme.inputBackground.opacity(0.52))
        .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
    }

    private var dataActionBar: some View {
        HStack(spacing: 7) {
            Button { refreshTable() } label: { Label("Refresh table data", systemImage: "arrow.clockwise") }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
            Menu {
                ForEach(model.databaseFeature.columns, id: \.self) { column in
                    Button(column) { jumpTargetColumn = column }
                }
            } label: { Label("Jump to Column", systemImage: "rectangle.split.3x1") }
                .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button("Copy Selected Rows as TSV") { copySelectedRowsAsTSV() }
                    .disabled(selectedRows.isEmpty)
                Button("Paste TSV from Clipboard") { pasteFromClipboard() }
            } label: { Text("TSV") }
                .menuStyle(.borderlessButton).frame(width: 52)
            Button {
                rowDetailsIndex = selectedRows.first
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .litheIconButton()
            .help("Row details")
            .accessibilityLabel("Row details")
            .disabled(selectedRows.count != 1)
            Button { insertedRows.append([:]) } label: { Label("Add Row", systemImage: "plus") }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                .disabled(model.databaseFeature.selectedProfile?.readOnly == true)
            Button { apply() } label: { Label("Apply", systemImage: "checkmark") }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                .disabled(!hasChanges || model.databaseFeature.isLoading || model.databaseFeature.selectedProfile?.readOnly == true)
            Button { discard() } label: { Label("Discard", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                .disabled(!hasChanges)
            if !selectedRows.isEmpty {
                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(width: 1, height: 18)
                Text("\(selectedRows.count) selected")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
                    .monospacedDigit()
                Button { showsBatchUpdateSheet = true } label: {
                    Label("Batch Edit", systemImage: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .disabled(model.databaseFeature.selectedProfile?.readOnly == true)
                Button { showsBatchDeleteConfirmation = true } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.error)
                .disabled(model.databaseFeature.selectedProfile?.readOnly == true)
            }
            Spacer()
            Button { previousPage() } label: { Image(systemName: "chevron.left") }.litheIconButton().help("Previous page").disabled(model.databaseFeature.currentOffset == 0)
            Text(pageLabel).font(.system(size: 10.5)).foregroundStyle(LitheTheme.secondaryText).lineLimit(1).frame(minWidth: 90)
            Button { nextPage() } label: { Image(systemName: "chevron.right") }.litheIconButton().help("Next page")
                .disabled(model.databaseFeature.currentOffset + model.databaseFeature.rows.count >= model.databaseFeature.totalRows)
        }
        .padding(.horizontal, 12).frame(height: 38).background(LitheTheme.toolHeader.opacity(0.92))
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WHERE").font(.system(size: 13, weight: .semibold, design: .monospaced))
                Picker("Join conditions", selection: $filterJoin) {
                    Text("AND").tag(DatabaseFilterJoin.and)
                    Text("OR").tag(DatabaseFilterJoin.or)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 104)
                Spacer()
                Button { filterConditions.append(.init(column: model.databaseFeature.columns.first ?? "")) } label: {
                    Label("Add Condition", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
            ForEach($filterConditions) { $condition in
                HStack(spacing: 8) {
                    Button { condition.isEnabled.toggle() } label: {
                        Image(systemName: condition.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(condition.isEnabled ? LitheTheme.accent : LitheTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help(condition.isEnabled ? "Disable condition" : "Enable condition")
                    Picker("Column", selection: $condition.column) {
                        ForEach(model.databaseFeature.columns, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 150)
                    Picker("Operator", selection: $condition.operator) {
                        ForEach(DatabaseFilterOperator.allCases, id: \.self) { op in Text(op.title).tag(op) }
                    }
                    .frame(width: 130)
                    TextField("Value", text: $condition.value)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .disabled(condition.operator == .isNull || condition.operator == .isNotNull)
                    Button(role: .destructive) { filterConditions.removeAll { $0.id == condition.id } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Clear Filters") { clearFilters() }
                Spacer()
                Button("Reset Conditions") { filterConditions = [.init(column: model.databaseFeature.columns.first ?? "")] }
                Button("Apply Filter") { applyFilter(); showsFilterPopover = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 630)
    }

    private var sortPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ORDER BY").font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer()
                Button { sortConditions.append(.init(column: model.databaseFeature.columns.first ?? "")) } label: {
                    Label("Add Sort", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
            if sortConditions.isEmpty {
                Text("No sorting")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            ForEach(Array(sortConditions.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(LitheTheme.tertiaryText).frame(width: 18)
                    Picker("Column", selection: $sortConditions[index].column) {
                        ForEach(model.databaseFeature.columns, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 190)
                    Picker("Direction", selection: $sortConditions[index].descending) {
                        Text("Ascending").tag(false)
                        Text("Descending").tag(true)
                    }
                    .frame(width: 120)
                    Button { moveSort(from: index, by: -1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.plain).help("Move up").disabled(index == 0)
                    Button { moveSort(from: index, by: 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.plain).help("Move down").disabled(index == sortConditions.count - 1)
                    Button(role: .destructive) { sortConditions.remove(at: index) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Clear Sorting") { clearSorting() }
                Spacer()
                Button("Apply Sorting") { applySorting(); showsSortPopover = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 520)
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

    private func contextCrumb(_ title: String, icon: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(emphasized ? LitheTheme.accent : LitheTheme.secondaryText)
            Text(title)
                .font(.system(size: 10.5, weight: emphasized ? .semibold : .medium))
                .lineLimit(1)
        }
        .foregroundStyle(emphasized ? LitheTheme.primaryText : LitheTheme.secondaryText)
    }

    private func clausePill(title: Text, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .medium))
                title.font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(active ? LitheTheme.primaryText : LitheTheme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(active ? LitheTheme.accent.opacity(0.11) : LitheTheme.toolHeader)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(active ? LitheTheme.accent.opacity(0.34) : LitheTheme.panelBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toolbarActionLabel(
        _ title: LocalizedStringKey,
        systemImage: String,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .medium))
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
        }
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 9)
        .frame(height: 27)
        .contentShape(Rectangle())
    }

    private var toolbarDivider: some View {
        Rectangle().fill(LitheTheme.divider).frame(width: 1, height: 17)
    }

    private var grid: some View {
        GeometryReader { geometry in
            let width = columnWidth(availableWidth: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(model.databaseFeature.rows.enumerated()), id: \.offset) { index, row in
                                rowView(index: index, row: row, columnWidth: width)
                                    .opacity(deletedRows.contains(index) ? 0.42 : 1)
                            }
                            ForEach(Array(insertedRows.enumerated()), id: \.offset) { index, row in
                                insertedRowView(index: index, row: row, columnWidth: width)
                            }
                        } header: { header(columnWidth: width) }
                    }
                    .frame(
                        minWidth: max(geometry.size.width, CGFloat(model.databaseFeature.columns.count) * width + selectionColumnWidth),
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                }
                .onChange(of: jumpTargetColumn) { column in
                    guard let column else { return }
                    withAnimation { proxy.scrollTo("column-\(column)", anchor: .center) }
                    jumpTargetColumn = nil
                }
            }
        }
    }

    private func header(columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { toggleAllRows() } label: {
                HStack(spacing: 7) {
                    Image(systemName: selectionSymbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selectedRows.isEmpty ? LitheTheme.secondaryText : LitheTheme.accent)
                    Text("#")
                }
                .frame(width: selectionColumnWidth, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(allRowsSelected ? "Deselect all rows on this page" : "Select all rows on this page")
            ForEach(model.databaseFeature.columns, id: \.self) { column in
                HStack(spacing: 4) {
                    Text(column)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let index = appliedSort.firstIndex(where: { $0.column == column }), appliedSort.count > 1 {
                        Text("\(index + 1)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    Menu {
                        Button {
                            setSort(column: column, descending: false)
                        } label: {
                            Label("Ascending", systemImage: "arrow.up")
                        }
                        Button {
                            setSort(column: column, descending: true)
                        } label: {
                            Label("Descending", systemImage: "arrow.down")
                        }
                    } label: {
                        Image(systemName: sortIcon(for: column))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isSorted(column) ? LitheTheme.accent : LitheTheme.tertiaryText)
                            .frame(width: 24, height: 30)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sort column")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.leading, 7)
                .padding(.trailing, 3)
                .frame(width: columnWidth, height: 32, alignment: .leading)
                .id("column-\(column)")
                .overlay(alignment: .trailing) {
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                }
            }
        }.foregroundStyle(LitheTheme.secondaryText).background(LitheTheme.raised)
    }

    private func rowView(index: Int, row: DatabaseRow, columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { toggleSelection(index) } label: {
                HStack(spacing: 7) {
                    Image(systemName: selectedRows.contains(index) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selectedRows.contains(index) ? LitheTheme.accent : LitheTheme.secondaryText)
                    Text("\(index + 1)")
                        .monospacedDigit()
                }
                .frame(width: selectionColumnWidth, height: 29)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(LitheTheme.toolHeader)
            .disabled(deletedRows.contains(index))
            ForEach(model.databaseFeature.columns, id: \.self) { column in
                TextField("", text: binding(row: index, column: column, original: row[column]))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 7)
                    .frame(width: columnWidth, height: 29).background(drafts[CellKey(row: index, column: column)] == nil ? Color.clear : LitheTheme.warning.opacity(0.12))
                    .overlay(alignment: .trailing) { Rectangle().fill(LitheTheme.divider).frame(width: 1) }
                    .onTapGesture { pasteAnchor = CellKey(row: index, column: column) }
                    .contextMenu { cellContextMenu(row: index, column: column) }
            }
        }
        .background(selectedRows.contains(index) ? LitheTheme.selection.opacity(0.34) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu { rowContextMenu(index: index) }
        .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
    }

    private func insertedRowView(index: Int, row: DatabaseRow, columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "plus").frame(width: selectionColumnWidth, height: 29).background(LitheTheme.success.opacity(0.12))
            ForEach(model.databaseFeature.columns, id: \.self) { column in
                TextField("Default", text: insertedBinding(row: index, column: column))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 7)
                    .frame(width: columnWidth, height: 29).background(LitheTheme.success.opacity(0.08))
                    .overlay(alignment: .trailing) { Rectangle().fill(LitheTheme.divider).frame(width: 1) }
                    .contextMenu {
                        Button("Set NULL") { insertedRows[index][column] = .null }
                        Button("Use Column Default") { insertedRows[index].removeValue(forKey: column) }
                    }
            }
        }.overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
    }

    @ViewBuilder
    private func rowContextMenu(index: Int) -> some View {
        Button("Row Details") { rowDetailsIndex = index }
        Divider()
        Button("Delete Row", role: .destructive) {
            deletedRows.insert(index)
            selectedRows.remove(index)
        }
        .disabled(model.databaseFeature.selectedProfile?.readOnly == true)
    }

    @ViewBuilder
    private func cellContextMenu(row: Int, column: String) -> some View {
        Button("Set NULL") { setNull(row: row, column: column) }
            .disabled(model.databaseFeature.selectedProfile?.readOnly == true)
        Button("Set Empty String") { setEmptyString(row: row, column: column) }
            .disabled(model.databaseFeature.selectedProfile?.readOnly == true)
        Divider()
        rowContextMenu(index: row)
    }

    private func columnWidth(availableWidth: CGFloat) -> CGFloat {
        guard !model.databaseFeature.columns.isEmpty else { return 160 }
        return max(140, floor((availableWidth - selectionColumnWidth) / CGFloat(model.databaseFeature.columns.count)))
    }

    private var selectionColumnWidth: CGFloat { 64 }
    private var selectableRowIndexes: Set<Int> {
        Set(model.databaseFeature.rows.indices).subtracting(deletedRows)
    }
    private var allRowsSelected: Bool {
        !selectableRowIndexes.isEmpty && selectedRows == selectableRowIndexes
    }
    private var selectionSymbol: String {
        if selectedRows.isEmpty { return "square" }
        return allRowsSelected ? "checkmark.square.fill" : "minus.square.fill"
    }
    private var hasChanges: Bool { !drafts.isEmpty || !insertedRows.isEmpty || !deletedRows.isEmpty }
    private func toggleSelection(_ index: Int) { if selectedRows.contains(index) { selectedRows.remove(index) } else { selectedRows.insert(index) } }
    private func toggleAllRows() {
        if allRowsSelected { selectedRows = [] }
        else { selectedRows = selectableRowIndexes }
    }
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

    private func setEmptyString(row: Int, column: String) {
        let key = CellKey(row: row, column: column)
        if model.databaseFeature.rows[row][column] == .string("") { drafts.removeValue(forKey: key) }
        else { drafts[key] = .string("") }
    }

    private func applyBatchUpdate(column: String, value: String, setNull: Bool) {
        for rowIndex in selectedRows where model.databaseFeature.rows.indices.contains(rowIndex) && !deletedRows.contains(rowIndex) {
            let key = CellKey(row: rowIndex, column: column)
            let newValue: DatabaseValue = setNull ? .null : .string(value)
            if model.databaseFeature.rows[rowIndex][column] == newValue {
                drafts.removeValue(forKey: key)
            } else {
                drafts[key] = newValue
            }
        }
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
        value?.displayText ?? "NULL"
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

    private var draftFilters: [DatabaseFilter] {
        filterConditions.compactMap { condition in
            guard condition.isEnabled, !condition.column.isEmpty else { return nil }
            let needsValue = condition.operator != .isNull && condition.operator != .isNotNull
            guard !needsValue || !condition.value.isEmpty else { return nil }
            return DatabaseFilter(
                column: condition.column,
                operator: condition.operator,
                value: needsValue ? .string(condition.value) : .null,
                join: filterJoin
            )
        }
    }
    private var databaseContextName: String {
        guard let profile = model.databaseFeature.selectedProfile else { return String(localized: "Database") }
        if let database = profile.database.nonEmpty { return database }
        if profile.kind == .sqlite, let filename = profile.path.nonEmpty { return URL(fileURLWithPath: filename).lastPathComponent }
        return profile.kind.rawValue.uppercased()
    }
    private var sortClauseTitle: String {
        guard !appliedSort.isEmpty else { return "ORDER BY" }
        let summary = appliedSort.prefix(2).map { "\($0.column) \($0.descending ? "↓" : "↑")" }.joined(separator: ", ")
        return appliedSort.count > 2 ? "ORDER BY · \(summary)…" : "ORDER BY · \(summary)"
    }
    private var pageLabel: String {
        guard model.databaseFeature.totalRows > 0 else { return "0 / 0" }
        return "\(model.databaseFeature.currentOffset + 1)-\(model.databaseFeature.currentOffset + model.databaseFeature.rows.count) / \(model.databaseFeature.totalRows)"
    }
    private func applyFilter() {
        appliedFilters = draftFilters
        reloadQuery(offset: 0)
    }
    private func clearFilters() {
        filterConditions = [.init(column: model.databaseFeature.columns.first ?? "")]
        appliedFilters = []
        reloadQuery(offset: 0)
    }
    private func clearSorting() {
        sortConditions = []
        appliedSort = []
        reloadQuery(offset: 0)
    }
    private func clearQuery() {
        filterConditions = [.init(column: model.databaseFeature.columns.first ?? "")]
        sortConditions = []
        appliedFilters = []
        appliedSort = []
        reloadQuery(offset: 0)
    }
    private func applySorting() {
        appliedSort = sortConditions.compactMap { $0.column.isEmpty ? nil : DatabaseSort(column: $0.column, descending: $0.descending) }
        reloadQuery(offset: 0)
    }
    private func moveSort(from index: Int, by delta: Int) {
        let destination = index + delta
        guard sortConditions.indices.contains(index), sortConditions.indices.contains(destination) else { return }
        sortConditions.swapAt(index, destination)
    }
    private func reloadQuery(offset: Int) {
        Task {
            await model.databaseFeature.loadPage(filters: appliedFilters, sort: appliedSort, offset: offset)
            discard()
        }
    }
    private func refreshTable() {
        reloadQuery(offset: model.databaseFeature.currentOffset)
    }
    private func setSort(column: String, descending: Bool) {
        appliedSort = [DatabaseSort(column: column, descending: descending)]
        sortConditions = appliedSort.map { .init(column: $0.column, descending: $0.descending) }
        reloadQuery(offset: 0)
    }
    private func isSorted(_ column: String) -> Bool {
        appliedSort.contains { $0.column == column }
    }
    private func sortIcon(for column: String) -> String {
        guard let sort = appliedSort.first(where: { $0.column == column }) else {
            return "arrow.up.arrow.down"
        }
        return sort.descending ? "arrow.down" : "arrow.up"
    }
    private func previousPage() { reloadQuery(offset: max(0, model.databaseFeature.currentOffset - model.databaseFeature.pageSize)) }
    private func nextPage() { reloadQuery(offset: model.databaseFeature.currentOffset + model.databaseFeature.pageSize) }

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

    private func copySelectedRowsAsTSV() {
        let indexes = selectedRows.sorted().filter(model.databaseFeature.rows.indices.contains)
        guard !indexes.isEmpty else { return }
        let columns = model.databaseFeature.columns
        let text = indexes.map { index in
            columns.map { display(model.databaseFeature.rows[index][$0]) }.joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

struct DatabaseOpenTableTabsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.databaseFeature.openTableTabs, id: \.self) { table in
                    HStack(spacing: 7) {
                        Image(systemName: "tablecells")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(model.databaseFeature.selectedTable == table ? LitheTheme.accent : LitheTheme.secondaryText)
                        Button(table) {
                            Task { await model.databaseFeature.openTable(table) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        Button {
                            let wasSelected = model.databaseFeature.selectedTable == table
                            if let next = model.databaseFeature.closeTableTab(table), wasSelected {
                                Task { await model.databaseFeature.openTable(next) }
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Close table")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(
                        model.databaseFeature.selectedTable == table
                            ? LitheTheme.accent.opacity(0.12)
                            : LitheTheme.inputBackground.opacity(0.55)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                model.databaseFeature.selectedTable == table
                                    ? LitheTheme.accent.opacity(0.55)
                                    : LitheTheme.panelBorder,
                                lineWidth: 1
                            )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .frame(height: 40)
        .background(LitheTheme.toolHeader)
    }
}

private struct DatabaseBatchUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let columns: [String]
    let selectedCount: Int
    let onApply: (String, String, Bool) -> Void

    @State private var column = ""
    @State private var value = ""
    @State private var setNull = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Batch Edit Rows")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(selectedCount) selected")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(LitheTheme.toolHeader)

            VStack(alignment: .leading, spacing: 14) {
                Text("Set one field for every selected row. The change remains pending until you choose Apply.")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Column")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Picker("Column", selection: $column) {
                        ForEach(columns, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Value")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                    TextField("New value", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .disabled(setNull)
                    Toggle("Set NULL", isOn: $setNull)
                        .toggleStyle(.checkbox)
                }
            }
            .padding(16)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Stage Batch Edit") {
                    onApply(column, value, setNull)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(column.isEmpty || selectedCount == 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(LitheTheme.toolHeader)
        }
        .frame(width: 440)
        .background(LitheTheme.editor)
        .foregroundStyle(LitheTheme.primaryText)
        .onAppear {
            if column.isEmpty { column = columns.first ?? "" }
        }
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

private struct DatabaseTableFilterDraft: Identifiable {
    let id = UUID()
    var isEnabled = true
    var column = ""
    var `operator`: DatabaseFilterOperator = .contains
    var value = ""
}

private struct DatabaseTableSortDraft: Identifiable {
    let id = UUID()
    var column = ""
    var descending = false
}

private extension DatabaseFilterOperator {
    var title: LocalizedStringKey {
        switch self {
        case .equals: "Equals"
        case .notEquals: "Not Equals"
        case .greaterThan: "Greater Than"
        case .lessThan: "Less Than"
        case .contains: "Contains"
        case .startsWith: "Starts With"
        case .isNull: "Is NULL"
        case .isNotNull: "Is Not NULL"
        }
    }
}

private struct DatabaseRowDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let rowNumber: Int
    let columns: [String]
    let row: DatabaseRow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(LitheTheme.accent)
                Text("Row Details").font(.system(size: 14, weight: .semibold))
                Text("#\(rowNumber)").foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(16)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(columns, id: \.self) { column in
                        HStack(alignment: .top, spacing: 14) {
                            Text(column)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 150, alignment: .leading)
                            Text(valueText(row[column]))
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(LitheTheme.editor)
                        .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
                    }
                }
            }
        }
        .frame(width: 620, height: 460)
    }

    private func valueText(_ value: DatabaseValue?) -> String {
        value?.displayText ?? "NULL"
    }
}

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

struct DatabaseTransferDocument: FileDocument {
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

extension DatabaseTransferFormat {
    var contentType: UTType { switch self { case .csv: .commaSeparatedText; case .json: .json; case .sql: .sql } }
}

extension UTType {
    static let sql = UTType(filenameExtension: "sql") ?? .plainText
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

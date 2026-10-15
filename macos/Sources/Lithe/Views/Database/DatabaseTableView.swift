import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LitheDatabaseModule

struct DatabaseTableView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var gridActive = false
    @State private var editingCell: CellKey?
    @FocusState private var focusedFilter: UUID?
    @FocusState private var focusedCell: CellKey?
    private var drafts: [CellKey: DatabaseValue] {
        get { feature.tableCellDrafts }
        nonmutating set { feature.tableCellDrafts = newValue }
    }
    private var insertedRows: [DatabaseRow] {
        get { feature.tableInsertedRows }
        nonmutating set { feature.tableInsertedRows = newValue }
    }
    @State private var selectedRows: Set<Int> = []
    private var deletedRows: Set<Int> {
        get { feature.tableDeletedRows }
        nonmutating set { feature.tableDeletedRows = newValue }
    }
    private var applyFailed: Bool {
        get { feature.tableApplyFailed }
        nonmutating set { feature.tableApplyFailed = newValue }
    }
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
            if feature.selectedProfile?.kind.isSQLDatabase == true || feature.selectedTable != nil {
                dataActionBar
            }
            switch feature.workspaceSection {
            case .structure where feature.selectedProfile?.kind.isSQLDatabase == true:
                DatabaseStructureView()
            case .history where feature.selectedProfile?.kind.isSQLDatabase == true:
                DatabaseHistoryView()
            default:
                if feature.selectedTable != nil { queryClauseBar }
                if feature.selectedTable == nil {
                    DatabaseTableEmptyState(hasConnection: feature.selectedProfile != nil)
                } else if feature.columns.isEmpty && !feature.isLoading {
                    DatabaseTableEmptyState(hasConnection: true, hasColumns: false)
                } else {
                    grid
                }
            }
        }
        .disabled(feature.isApplyingTableEdits)
        .onChange(of: feature.isApplyingTableEdits) { applying in
            if applying { editingCell = nil; focusedCell = nil }
        }
        .litheWorkbenchSurface(LitheTheme.DatabaseGrid.background)
        .workbenchHoverTooltipScope()
        .onChange(of: focusedCell) { cell in
            if let cell { pasteAnchor = cell }
        }
        .onChange(of: gridActive) { active in
            if !active { editingCell = nil }
        }
        .onChange(of: feature.selectedTable) { _ in
            discard()
            focusedCell = nil
            editingCell = nil
            appliedFilters = []
            appliedSort = []
            sortConditions = []
            filterJoin = .and
            filterConditions = [.init()]
        }
        .onChange(of: feature.columns) { columns in
            if filterConditions.count == 1, filterConditions[0].column.isEmpty {
                filterConditions[0].column = columns.first ?? ""
            }
        }
        .background(LitheCenteredPopup(isPresented: $showsReplaceSheet, dialogTitle: String(localized: "Replace Values in Current Page")) {
            DatabaseReplaceSheet(
                columns: feature.columns,
                column: $replaceColumn,
                searchText: $replaceText,
                replacementText: $replacementText,
                onReplace: replaceCurrentPage,
                onCancel: { showsReplaceSheet = false }
            )
            .environment(\.locale, model.settings.language.locale)
            .id(model.settings.language)
        })
        .background(LitheCenteredPopup(isPresented: $showsBatchUpdateSheet, dialogTitle: String(localized: "Batch Edit Rows")) {
            DatabaseBatchUpdateSheet(
                columns: feature.columns,
                selectedCount: selectedRows.count,
                onApply: applyBatchUpdate,
                onCancel: { showsBatchUpdateSheet = false }
            )
            .environment(\.locale, model.settings.language.locale)
            .id(model.settings.language)
        })
        .background(LitheCenteredPopup(isPresented: Binding(
            get: { rowDetailsIndex != nil },
            set: { if !$0 { rowDetailsIndex = nil } }
        ), dialogTitle: String(localized: "Row Details")) {
            if let rowDetailsIndex, feature.rows.indices.contains(rowDetailsIndex) {
                DatabaseRowDetailsSheet(
                    rowNumber: rowDetailsIndex + 1,
                    columns: feature.columns,
                    row: feature.rows[rowDetailsIndex],
                    onCancel: { self.rowDetailsIndex = nil }
                )
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
            }
        })
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: exportFormat.contentType, defaultFilename: exportFilename) { result in
            if case let .failure(error) = result { feature.errorMessage = error.localizedDescription }
            if let temporaryExportURL { feature.removeTemporaryFile(temporaryExportURL) }
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

    private var queryClauseBar: some View {
        HStack(spacing: 0) {
            clausePill(
                title: Text(verbatim: appliedFilters.isEmpty ? "WHERE" : "WHERE · \(appliedFilters.count)"),
                icon: "expui/general/filter.svg",
                active: !appliedFilters.isEmpty
            ) { showsFilterPopover.toggle() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .litheDropdown(isPresented: $showsFilterPopover) { filterPopover }
            Rectangle().fill(gridBorder).frame(width: LitheTheme.DatabaseGrid.borderWidth)
            clausePill(title: Text(verbatim: sortClauseTitle), icon: "expui/general/sortBy.svg",
                       active: !appliedSort.isEmpty) { showsSortPopover.toggle() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .litheDropdown(isPresented: $showsSortPopover) { sortPopover }
            if !appliedFilters.isEmpty || !appliedSort.isEmpty {
                Button("Clear query") { clearQuery() }
                    .buttonStyle(.litheNoPress)
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: 30)
        .litheWorkbenchSurface(LitheTheme.editor)
        .overlay(alignment: .bottom) { Rectangle().fill(gridBorder).frame(height: LitheTheme.DatabaseGrid.borderWidth) }
    }

    private var dataActionBar: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if feature.selectedProfile?.kind.isSQLDatabase == true {
                        ForEach(DatabaseWorkspaceSection.allCases) { section in
                            Button {
                                if section == .sql, let profileID = feature.selectedProfileID {
                                    if let queryID = feature.selectedSQLTabID,
                                       model.editorTabItems.contains(.databaseQuery(profileID: profileID, queryID: queryID)) {
                                        model.selectDatabaseWorkspace(profileID: profileID, queryID: queryID)
                                    } else {
                                        model.openDatabaseQuery(profileID: profileID)
                                    }
                                } else {
                                    feature.workspaceSection = section
                                }
                            } label: {
                                LitheIDEAIcon(resourcePath: section.iconPath, size: 16, preservesOriginalColors: true)
                            }
                            .buttonStyle(LitheIconButtonStyle(
                                size: LitheTheme.Metrics.toolbarIconButtonSize,
                                isSelected: feature.workspaceSection == section
                            ))
                            .workbenchHoverHelp(Text(section.titleKey))
                            .accessibilityLabel(Text(section.titleKey))
                            .accessibilityValue(feature.workspaceSection == section ? Text("Selected") : Text("Not selected"))
                        }
                        toolbarDivider
                    }
                    HStack(spacing: 2) {
                        Button { refreshTable() } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/refresh.svg", size: 16, preservesOriginalColors: true)
                        }
                        .litheToolbarIconButton()
                        .workbenchHoverHelp(Text("Refresh table data"))
                        .accessibilityLabel("Refresh table data")
                        toolbarDivider
                        Button { insertedRows.append([:]) } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16, preservesOriginalColors: true)
                        }
                        .litheToolbarIconButton()
                        .workbenchHoverHelp(Text("Add Row"))
                        .accessibilityLabel("Add Row")
                        .disabled(feature.isLoading || feature.columns.isEmpty || feature.selectedProfile?.readOnly == true)
                        Button { apply() } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/upload.svg", size: 16, preservesOriginalColors: true)
                        }
                        .litheToolbarIconButton()
                        .workbenchHoverHelp(Text("Apply"))
                        .accessibilityLabel("Apply")
                        .disabled(!hasChanges || feature.isLoading || feature.selectedProfile?.readOnly == true)
                        Button { discard() } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/reset.svg", size: 16, preservesOriginalColors: true)
                        }
                        .litheToolbarIconButton()
                        .workbenchHoverHelp(Text("Discard"))
                        .accessibilityLabel("Discard")
                        .disabled(!hasChanges)
                        toolbarDivider
                        LitheMenu {
                            LitheContextMenuItem.submenu("Jump to Column", items: feature.columns.map { column in
                                .action(column) { jumpTargetColumn = column }
                            })
                            LitheContextMenuItem.action("Row details") { rowDetailsIndex = selectedRows.first }
                                .disabled(selectedRows.count != 1)
                            LitheContextMenuItem.separator
                            LitheContextMenuItem.action("Import CSV…") { importFormat = .csv; showsImporter = true }
                                .disabled(feature.selectedProfile?.readOnly == true || feature.selectedProfile?.kind == .mongodb)
                            LitheContextMenuItem.action("Import JSON…") { importFormat = .json; showsImporter = true }
                                .disabled(feature.selectedProfile?.readOnly == true || feature.selectedProfile?.kind == .mongodb)
                            LitheContextMenuItem.action("Restore SQL Backup…") { importFormat = .sql; showsImporter = true }
                                .disabled(feature.selectedProfile?.readOnly == true || feature.selectedProfile?.kind == .sqlserver || feature.selectedProfile?.kind == .mongodb)
                            LitheContextMenuItem.separator
                            LitheContextMenuItem.action("Export Table as CSV…") { export(.csv) }
                                .disabled(feature.selectedProfile?.kind == .mongodb)
                            LitheContextMenuItem.action("Export Table as JSON…") { export(.json) }
                                .disabled(feature.selectedProfile?.kind == .mongodb)
                            LitheContextMenuItem.action("Back Up Database as SQL…") { export(.sql) }
                                .disabled(feature.selectedProfile?.kind == .sqlserver || feature.selectedProfile?.kind == .mongodb)
                            LitheContextMenuItem.separator
                            LitheContextMenuItem.action("Replace in Current Page…") { showsReplaceSheet = true }
                                .disabled(feature.rows.isEmpty)
                            LitheContextMenuItem.action("Batch Edit") { showsBatchUpdateSheet = true }
                                .disabled(selectedRows.isEmpty || feature.selectedProfile?.readOnly == true)
                            LitheContextMenuItem.action("Delete Selected") { showsBatchDeleteConfirmation = true }
                                .disabled(selectedRows.isEmpty || feature.selectedProfile?.readOnly == true)
                        } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/moreHorizontal.svg", size: 16, preservesOriginalColors: true)
                        }
                        .litheToolbarIconButton()
                        .workbenchHoverHelp(Text("Data Tools"))
                        .accessibilityLabel("Data Tools")
                        if !selectedRows.isEmpty {
                            Text("\(selectedRows.count) selected")
                                .font(LitheTheme.uiFont(size: 12))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                    }
                    .disabled(feature.selectedTable == nil || feature.workspaceSection != .data)
                }
            }
            Spacer(minLength: 4)
            LitheMenu {
                LitheContextMenuItem.action("Copy Selected Rows as TSV") { copySelectedRowsAsTSV() }
                    .disabled(selectedRows.isEmpty)
                LitheContextMenuItem.action("Paste TSV from Clipboard") { pasteFromClipboard() }
            } label: {
                HStack(spacing: 2) {
                    Text("TSV").font(LitheTheme.uiFont(size: 12))
                    LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16, preservesOriginalColors: true)
                }
                .padding(.horizontal, 4)
            }
            .litheToolbarIconButton(isIconOnly: false)
            .fixedSize()
            .accessibilityLabel("TSV")
            .disabled(feature.selectedTable == nil || feature.workspaceSection != .data)
            toolbarDivider
            Button { previousPage() } label: {
                LitheIDEAIcon(resourcePath: "expui/general/chevronLeft.svg", size: 16, preservesOriginalColors: true)
            }
            .litheToolbarIconButton().workbenchHoverHelp(Text("Previous page"))
            .accessibilityLabel("Previous page")
            .disabled(feature.workspaceSection != .data || feature.selectedTable == nil || feature.currentOffset == 0)
            Text(pageLabel).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1).fixedSize()
            Button { nextPage() } label: {
                LitheIDEAIcon(resourcePath: "expui/general/chevronRight.svg", size: 16, preservesOriginalColors: true)
            }
            .litheToolbarIconButton().workbenchHoverHelp(Text("Next page"))
            .accessibilityLabel("Next page")
            .disabled(feature.workspaceSection != .data || feature.selectedTable == nil || feature.currentOffset + feature.rows.count >= feature.totalRows)
        }
        .padding(.horizontal, 6)
        .frame(height: LitheTheme.Metrics.toolWindowHeaderHeight)
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WHERE").font(LitheTheme.codeFont)
                LitheSettingsSegmentedControl(selection: $filterJoin, options: [.and, .or], width: 104) {
                    $0 == .and ? "AND" : "OR"
                }
                Spacer()
                Button { filterConditions.append(.init(column: feature.columns.first ?? "")) } label: {
                    HStack(spacing: 4) {
                        LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16, preservesOriginalColors: true)
                        Text("Add Condition")
                    }
                }
                .litheToolbarIconButton(isIconOnly: false)
            }
            ForEach($filterConditions) { $condition in
                HStack(spacing: 8) {
                    Toggle("Enable condition", isOn: $condition.isEnabled)
                        .toggleStyle(.checkbox).labelsHidden()
                        .help(condition.isEnabled ? "Disable condition" : "Enable condition")
                    LitheSettingsSelect(selection: $condition.column, options: feature.columns, width: 150, accessibilityLabel: "Column", title: { $0 }, localizesTitles: false)
                    .frame(width: 150)
                    LitheSettingsSelect(selection: $condition.operator, options: DatabaseFilterOperator.allCases, width: 130, accessibilityLabel: "Operator", title: { $0.menuTitle })
                    .frame(width: 130)
                    TextField("Value", text: $condition.value)
                        .focused($focusedFilter, equals: condition.id)
                        .modifier(LitheCommitDialogInputStyle(focused: focusedFilter == condition.id))
                        .frame(width: 170)
                        .disabled(condition.operator == .isNull || condition.operator == .isNotNull)
                    Button(role: .destructive) { filterConditions.removeAll { $0.id == condition.id } } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/delete.svg", size: 16, preservesOriginalColors: true)
                    }
                    .litheToolbarIconButton()
                }
            }
            HStack {
                Button("Clear Filters") { clearFilters() }.buttonStyle(LitheCommitDialogButtonStyle())
                Spacer()
                Button("Reset Conditions") { filterConditions = [.init(column: feature.columns.first ?? "")] }
                    .buttonStyle(LitheCommitDialogButtonStyle())
                Button("Apply Filter") { applyFilter(); showsFilterPopover = false }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true))
            }
        }
        .padding(16)
        .frame(width: 630)
    }

    private var sortPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ORDER BY").font(LitheTheme.uiFont(size: 13, weight: .semibold, design: .monospaced))
                Spacer()
                Button { sortConditions.append(.init(column: feature.columns.first ?? "")) } label: {
                    HStack(spacing: 4) {
                        LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16, preservesOriginalColors: true)
                        Text("Add Sort")
                    }
                }
                .litheToolbarIconButton(isIconOnly: false)
            }
            if sortConditions.isEmpty {
                Text("No sorting")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            ForEach(Array(sortConditions.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(LitheTheme.uiFont(size: 10, design: .monospaced)).foregroundStyle(LitheTheme.tertiaryText).frame(width: 18)
                    LitheSettingsSelect(selection: $sortConditions[index].column, options: feature.columns, width: 190, accessibilityLabel: "Column", title: { $0 }, localizesTitles: false)
                    .frame(width: 190)
                    LitheSettingsSelect(selection: $sortConditions[index].descending, options: [false, true], width: 120, accessibilityLabel: "Direction", title: { $0 ? "Descending" : "Ascending" })
                    .frame(width: 120)
                    Button { moveSort(from: index, by: -1) } label: { LitheIDEAIcon(resourcePath: "general/arrowUp.svg", size: 16, preservesOriginalColors: true) }
                        .litheToolbarIconButton().help("Move up").disabled(index == 0)
                    Button { moveSort(from: index, by: 1) } label: { LitheIDEAIcon(resourcePath: "general/arrowDown.svg", size: 16, preservesOriginalColors: true) }
                        .litheToolbarIconButton().help("Move down").disabled(index == sortConditions.count - 1)
                    Button(role: .destructive) { sortConditions.remove(at: index) } label: { LitheIDEAIcon(resourcePath: "expui/general/delete.svg", size: 16, preservesOriginalColors: true) }
                        .litheToolbarIconButton()
                }
            }
            HStack {
                Button("Clear Sorting") { clearSorting() }.buttonStyle(LitheCommitDialogButtonStyle())
                Spacer()
                Button("Apply Sorting") { applySorting(); showsSortPopover = false }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true))
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func clausePill(title: Text, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LitheIDEAIcon(resourcePath: icon, size: LitheTheme.Metrics.toolbarIconSize,
                              preservesOriginalColors: true)
                title.font(LitheTheme.codeFont)
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? LitheTheme.DatabaseConsole.keyword : LitheTheme.DatabaseGrid.clausePlaceholder)
            .padding(.horizontal, 6)
            .padding(.top, 6).padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(LitheTheme.ActionToolbar.separator)
            .frame(width: 1, height: 17).frame(width: 7, height: 24)
    }

    private var grid: some View {
        GeometryReader { geometry in
            let widths = columnWidths(availableWidth: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(0..<(feature.rows.count + insertedRows.count), id: \.self) { index in
                                if index < feature.rows.count {
                                    rowView(index: index, row: feature.rows[index], columnWidths: widths)
                                } else {
                                    insertedRowView(index: index - feature.rows.count, columnWidths: widths)
                                }
                            }
                        } header: { header(columnWidths: widths) }
                    }
                    .frame(
                        minWidth: max(geometry.size.width, widths.values.reduce(0, +) + selectionColumnWidth),
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                }
                .litheScrollViewChrome()
                .background(LitheToolWindowActivityTracker(isActive: $gridActive))
                .onChange(of: insertedRows.count) { count in
                    guard count > 0, let column = feature.columns.first else { return }
                    let row = feature.rows.count + count - 1
                    proxy.scrollTo(row, anchor: .bottom)
                    editingCell = nil
                    pasteAnchor = CellKey(row: row, column: column)
                    focusedCell = pasteAnchor
                }
                .onChange(of: jumpTargetColumn) { column in
                    guard let column else { return }
                    withAnimation { proxy.scrollTo("column-\(column)", anchor: .center) }
                    jumpTargetColumn = nil
                }
            }
        }
    }

    private var gridBorder: Color { LitheTheme.DatabaseGrid.border }

    private func isHighlightedRow(_ row: Int) -> Bool {
        selectedRows.contains(row) || pasteAnchor?.row == row
    }

    private func mutationBackground(_ color: Color, row: Int) -> Color {
        LitheTheme.DatabaseGrid.mutationBackground(color, highlighted: isHighlightedRow(row))
    }

    private func cellTextAlignment(_ value: DatabaseValue?) -> TextAlignment {
        switch value {
        case .integer, .number, .decimal: return .trailing
        default: return .leading
        }
    }

    private func header(columnWidths: [String: CGFloat]) -> some View {
        HStack(spacing: 0) {
            Button { toggleAllRows() } label: {
                HStack(spacing: 7) {
                    Text("#")
                }
                .frame(width: selectionColumnWidth, height: 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .help(allRowsSelected ? "Deselect all rows on this page" : "Select all rows on this page")
            .overlay(alignment: .trailing) {
                Rectangle().fill(gridBorder).frame(width: LitheTheme.DatabaseGrid.borderWidth).allowsHitTesting(false)
            }
            ForEach(feature.columns, id: \.self) { column in
                HStack(spacing: 4) {
                    LitheIDEAIcon(resourcePath: feature.primaryKeyColumns.contains(column)
                                      ? "database/expui/columnGoldKey.svg" : "database/expui/column.svg",
                                  size: LitheTheme.Tree.iconSize,
                                  preservesOriginalColors: true)
                    Text(column)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let index = appliedSort.firstIndex(where: { $0.column == column }), appliedSort.count > 1 {
                        Text("\(index + 1)")
                            .font(LitheTheme.uiFont(size: 12))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    LitheMenu {
                        LitheContextMenuItem.action("Ascending", icon: AnyView(LitheIDEAIcon(resourcePath: "general/arrowUp.svg", size: 16, preservesOriginalColors: true))) {
                            setSort(column: column, descending: false)
                        }
                        LitheContextMenuItem.action("Descending", icon: AnyView(LitheIDEAIcon(resourcePath: "general/arrowDown.svg", size: 16, preservesOriginalColors: true))) {
                            setSort(column: column, descending: true)
                        }
                    } label: {
                        LitheIDEAIcon(resourcePath: sortIcon(for: column), size: 16, preservesOriginalColors: true)
                            .foregroundStyle(isSorted(column) ? LitheTheme.accent : LitheTheme.tertiaryText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .fixedSize()
                    .help("Sort column")
                }
                .font(LitheTheme.codeFont)
                .padding(.leading, 4)
                .padding(.trailing, 3)
                .frame(width: columnWidths[column] ?? 40, height: 25, alignment: .leading)
                .id("column-\(column)")
                .background(!selectedRows.isEmpty || pasteAnchor?.column == column
                    ? LitheTheme.DatabaseGrid.currentRowBackground : Color.clear)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(gridBorder).frame(width: LitheTheme.DatabaseGrid.borderWidth)
                }
            }
        }
        .font(LitheTheme.codeFont)
        .foregroundStyle(LitheTheme.DatabaseGrid.text)
        .background(LitheTheme.DatabaseGrid.headerBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(gridBorder).frame(height: LitheTheme.DatabaseGrid.borderWidth)
        }
    }

    private func rowView(index: Int, row: DatabaseRow, columnWidths: [String: CGFloat]) -> some View {
        HStack(spacing: 0) {
            Button { toggleSelection(index) } label: {
                HStack(spacing: 7) {
                    Text("\(index + 1)")
                        .font(LitheTheme.codeFont)
                        .foregroundStyle(isHighlightedRow(index) ? LitheTheme.DatabaseGrid.currentRowNumber : LitheTheme.DatabaseGrid.rowNumber)
                        .monospacedDigit()
                }
                .frame(width: selectionColumnWidth, height: LitheTheme.DatabaseGrid.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .accessibilityValue(selectedRows.contains(index) ? Text("Selected") : Text("Not selected"))
            .background(deletedRows.contains(index)
                ? mutationBackground(applyFailed ? LitheTheme.DatabaseGrid.failedMutation : LitheTheme.Diff.deleted, row: index)
                : isHighlightedRow(index) ? LitheTheme.DatabaseGrid.currentRowBackground : Color.clear)
            .disabled(deletedRows.contains(index))
            .litheContextMenu { rowContextMenu(index: index) }
            .overlay(alignment: .trailing) {
                Rectangle().fill(gridBorder).frame(width: LitheTheme.DatabaseGrid.borderWidth).allowsHitTesting(false)
            }
            ForEach(feature.columns, id: \.self) { column in
                let key = CellKey(row: index, column: column)
                Group {
                    if editingCell == key {
                        TextField("", text: binding(row: index, column: column, original: row[column]))
                            .textFieldStyle(.plain)
                            .litheFocusEffectHidden()
                            .focused($focusedCell, equals: key)
                            // Request focus after the old focusable text leaves the key-view loop.
                            .task {
                                focusedCell = nil
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                focusedCell = key
                            }
                            .onSubmit { editingCell = nil }
                    } else {
                        Text(display(drafts[key] ?? row[column]))
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: cellTextAlignment(row[column]) == .trailing ? .trailing : .leading)
                            .focusable()
                            .litheFocusEffectHidden()
                            .focused($focusedCell, equals: key)
                    }
                }
                    .font(LitheTheme.codeFont).foregroundStyle(LitheTheme.DatabaseGrid.text)
                    .multilineTextAlignment(cellTextAlignment(row[column]))
                    .padding(.horizontal, 3)
                    .frame(width: columnWidths[column] ?? 40, height: LitheTheme.DatabaseGrid.rowHeight)
                    .background((pasteAnchor == key || selectedRows.contains(index)) && editingCell != key
                        ? (gridActive && controlActiveState == .key ? LitheTheme.DatabaseGrid.selected : LitheTheme.DatabaseGrid.inactiveSelected)
                        : deletedRows.contains(index) || drafts[key] == nil ? Color.clear
                        : mutationBackground(applyFailed ? LitheTheme.DatabaseGrid.failedMutation : LitheTheme.Diff.modified, row: index))
                    .contentShape(Rectangle())
                    .overlay {
                        if editingCell != key {
                            DatabaseGridCellClickTarget { clickCount in
                                selectedRows = []
                                pasteAnchor = key
                                focusedCell = key
                                editingCell = clickCount >= 2 && !feature.isApplyingTableEdits && feature.selectedProfile?.readOnly != true && !deletedRows.contains(index) ? key : nil
                            }
                        }
                    }
                    .overlay(alignment: .trailing) { Rectangle().fill(gridBorder).frame(width: LitheTheme.DatabaseGrid.borderWidth) }
                    .overlay {
                        if editingCell == key, gridActive, controlActiveState == .key {
                            Rectangle().strokeBorder(LitheTheme.DatabaseGrid.editingBorder,
                                lineWidth: LitheTheme.DatabaseGrid.editingBorderWidth)
                                .padding(.trailing, LitheTheme.DatabaseGrid.borderWidth).padding(.bottom, LitheTheme.DatabaseGrid.borderWidth)
                                .allowsHitTesting(false)
                        }
                    }
                    .litheContextMenu { cellContextMenu(row: index, column: column) }
            }
        }
        .background(deletedRows.contains(index)
            ? mutationBackground(applyFailed ? LitheTheme.DatabaseGrid.failedMutation : LitheTheme.Diff.deleted, row: index)
            : isHighlightedRow(index) ? LitheTheme.DatabaseGrid.currentRowBackground : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(gridBorder).frame(height: LitheTheme.DatabaseGrid.borderWidth)
        }
    }

    private func insertedRowView(index: Int, columnWidths: [String: CGFloat]) -> some View {
        HStack(spacing: 0) {
            Text("\(feature.rows.count + index + 1)")
                .font(LitheTheme.codeFont)
                .foregroundStyle(isHighlightedRow(feature.rows.count + index) ? LitheTheme.DatabaseGrid.currentRowNumber : LitheTheme.DatabaseGrid.rowNumber)
                .frame(width: selectionColumnWidth, height: LitheTheme.DatabaseGrid.rowHeight)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(gridBorder).frame(width: LitheTheme.DatabaseGrid.borderWidth).allowsHitTesting(false)
                }
            ForEach(feature.columns, id: \.self) { column in
                let key = CellKey(row: feature.rows.count + index, column: column)
                let value = insertedRows[index][column]
                Group {
                    if editingCell == key {
                        TextField("", text: insertedBinding(row: index, column: column))
                            .textFieldStyle(.plain).litheFocusEffectHidden()
                            .focused($focusedCell, equals: key)
                            .task {
                                focusedCell = nil
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                focusedCell = key
                            }
                            .onSubmit { editingCell = nil }
                    } else {
                        Text(value == nil || value == .null ? "<null>" : display(value))
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusable().litheFocusEffectHidden()
                            .focused($focusedCell, equals: key)
                    }
                }
                    .font(LitheTheme.codeFont)
                    .foregroundStyle(value == nil || value == .null ? LitheTheme.DatabaseGrid.nullText : LitheTheme.DatabaseGrid.text)
                    .padding(.horizontal, 3)
                    .frame(width: columnWidths[column] ?? 40, height: LitheTheme.DatabaseGrid.rowHeight)
                    .background(pasteAnchor == key && editingCell != key
                        ? (gridActive && controlActiveState == .key ? LitheTheme.DatabaseGrid.selected : LitheTheme.DatabaseGrid.inactiveSelected)
                        : Color.clear)
                    .contentShape(Rectangle())
                    .overlay {
                        if editingCell != key {
                            DatabaseGridCellClickTarget { clickCount in
                                selectedRows = []
                                pasteAnchor = key
                                focusedCell = key
                                editingCell = clickCount >= 2 && !feature.isApplyingTableEdits && feature.selectedProfile?.readOnly != true ? key : nil
                            }
                        }
                    }
                    .overlay(alignment: .trailing) { Rectangle().fill(gridBorder).frame(width: LitheTheme.DatabaseGrid.borderWidth) }
                    .overlay {
                        if editingCell == key, gridActive, controlActiveState == .key {
                            Rectangle().strokeBorder(LitheTheme.DatabaseGrid.editingBorder,
                                lineWidth: LitheTheme.DatabaseGrid.editingBorderWidth)
                                .padding(.trailing, LitheTheme.DatabaseGrid.borderWidth).padding(.bottom, LitheTheme.DatabaseGrid.borderWidth)
                                .allowsHitTesting(false)
                        }
                    }
                    .litheContextMenu {
                        var items: [LitheContextMenuItem] = []
                        items.append(.action("Set NULL", action: { insertedRows[index][column] = .null }))
                        items.append(.action("Use Column Default", action: { insertedRows[index].removeValue(forKey: column) }))
                        return items
                    }
            }
        }
        .background(mutationBackground(applyFailed ? LitheTheme.DatabaseGrid.failedMutation : LitheTheme.Diff.inserted,
                                       row: feature.rows.count + index))
        .overlay(alignment: .bottom) {
            Rectangle().fill(gridBorder).frame(height: LitheTheme.DatabaseGrid.borderWidth)
        }
    }

    private func rowContextMenu(index: Int) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("Row Details", action: { rowDetailsIndex = index }))
        items.append(.separator)
        items.append(.action("Delete Row", role: .destructive, isEnabled: !(feature.selectedProfile?.readOnly == true), action: {
            deletedRows.insert(index)
            selectedRows.remove(index)
        }))
        return items
    }

    private func cellContextMenu(row: Int, column: String) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("Set NULL", isEnabled: !(feature.selectedProfile?.readOnly == true), action: { setNull(row: row, column: column) }))
        items.append(.action("Set Empty String", isEnabled: !(feature.selectedProfile?.readOnly == true), action: { setEmptyString(row: row, column: column) }))
        items.append(.separator)
        items.append(contentsOf: rowContextMenu(index: row))
        return items
    }

    private func columnWidths(availableWidth: CGFloat) -> [String: CGFloat] {
        // ponytail: sample 100 loaded rows; persistent user-resized widths can replace this.
        LitheTheme.DatabaseGrid.columnWidths(feature.columns, availableWidth: availableWidth,
                                            rowHeaderWidth: selectionColumnWidth) { column in
            feature.rows.prefix(100).map { display($0[column]) }
        }
    }

    private var selectionColumnWidth: CGFloat {
        LitheTheme.DatabaseGrid.rowHeaderWidth(rowCount: feature.rows.count + insertedRows.count)
    }
    private var selectableRowIndexes: Set<Int> {
        Set(feature.rows.indices).subtracting(deletedRows)
    }
    private var allRowsSelected: Bool {
        !selectableRowIndexes.isEmpty && selectedRows == selectableRowIndexes
    }
    private var hasChanges: Bool { !drafts.isEmpty || !insertedRows.isEmpty || !deletedRows.isEmpty }
    private func toggleSelection(_ index: Int) {
        editingCell = nil
        if selectedRows.contains(index) { selectedRows.remove(index) } else { selectedRows.insert(index) }
    }
    private func toggleAllRows() {
        editingCell = nil
        if allRowsSelected { selectedRows = [] }
        else { selectedRows = selectableRowIndexes }
    }
    private func markSelectedForDeletion() { deletedRows.formUnion(selectedRows); selectedRows = [] }
    private func discard() { drafts = [:]; insertedRows = []; selectedRows = []; deletedRows = []; pasteAnchor = nil; editingCell = nil; focusedCell = nil; applyFailed = false }

    private func binding(row: Int, column: String, original: DatabaseValue?) -> Binding<String> {
        let key = CellKey(row: row, column: column)
        let originalText = display(original)
        return Binding(get: { drafts[key].map(display) ?? originalText }, set: { value in
            if value == originalText { drafts.removeValue(forKey: key) } else { drafts[key] = .string(value) }
        })
    }

    private func insertedBinding(row: Int, column: String) -> Binding<String> {
        Binding(get: {
            guard insertedRows.indices.contains(row) else { return "" }
            let value = insertedRows[row][column]
            if case let .string(text) = value { return text }
            return value == .null ? "" : value.map(display) ?? ""
        }, set: {
            guard insertedRows.indices.contains(row) else { return }
            if $0.isEmpty, insertedRows[row][column] == nil || insertedRows[row][column] == .null { return }
            insertedRows[row][column] = .string($0)
        })
    }

    private func setNull(row: Int, column: String) {
        let key = CellKey(row: row, column: column)
        if feature.rows[row][column] == .null { drafts.removeValue(forKey: key) }
        else { drafts[key] = .null }
    }

    private func setEmptyString(row: Int, column: String) {
        let key = CellKey(row: row, column: column)
        if feature.rows[row][column] == .string("") { drafts.removeValue(forKey: key) }
        else { drafts[key] = .string("") }
    }

    private func applyBatchUpdate(column: String, value: String, setNull: Bool) {
        for rowIndex in selectedRows where feature.rows.indices.contains(rowIndex) && !deletedRows.contains(rowIndex) {
            let key = CellKey(row: rowIndex, column: column)
            let newValue: DatabaseValue = setNull ? .null : .string(value)
            if feature.rows[rowIndex][column] == newValue {
                drafts.removeValue(forKey: key)
            } else {
                drafts[key] = newValue
            }
        }
    }

    private func apply() {
        if feature.selectedProfile?.productionProtection == true, !deletedRows.isEmpty {
            showsProtectedTableChangeConfirmation = true
            return
        }
        performApply(confirmed: false)
    }

    private func performApply(confirmed: Bool) {
        let profileID = feature.selectedProfileID
        let table = feature.selectedTable
        Task {
            guard feature.selectedProfileID == profileID, feature.selectedTable == table,
                  !feature.isApplyingTableEdits else { return }
            _ = await feature.apply(
                drafts: drafts.map { DatabaseCellDraft(rowIndex: $0.key.row, column: $0.key.column, value: $0.value) },
                insertedRows: insertedRows,
                deletedIndexes: deletedRows,
                confirmed: confirmed
            )
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
    private var sortClauseTitle: String {
        guard !appliedSort.isEmpty else { return "ORDER BY" }
        let summary = appliedSort.prefix(2).map { "\($0.column) \($0.descending ? "↓" : "↑")" }.joined(separator: ", ")
        return appliedSort.count > 2 ? "ORDER BY · \(summary)…" : "ORDER BY · \(summary)"
    }
    private var pageLabel: String {
        guard feature.totalRows > 0 else { return "0 / 0" }
        return "\(feature.currentOffset + 1)-\(feature.currentOffset + feature.rows.count) / \(feature.totalRows)"
    }
    private func applyFilter() {
        appliedFilters = draftFilters
        reloadQuery(offset: 0)
    }
    private func clearFilters() {
        filterConditions = [.init(column: feature.columns.first ?? "")]
        appliedFilters = []
        reloadQuery(offset: 0)
    }
    private func clearSorting() {
        sortConditions = []
        appliedSort = []
        reloadQuery(offset: 0)
    }
    private func clearQuery() {
        filterConditions = [.init(column: feature.columns.first ?? "")]
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
        selectedRows = []; pasteAnchor = nil; editingCell = nil; focusedCell = nil
        Task {
            await feature.loadPage(filters: appliedFilters, sort: appliedSort, offset: offset)
        }
    }
    private func refreshTable() {
        reloadQuery(offset: feature.currentOffset)
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
            return "general/arrowSplitCenterV.svg"
        }
        return sort.descending ? "general/arrowDown.svg" : "general/arrowUp.svg"
    }
    private func previousPage() { reloadQuery(offset: max(0, feature.currentOffset - feature.pageSize)) }
    private func nextPage() { reloadQuery(offset: feature.currentOffset + feature.pageSize) }

    private func pasteFromClipboard() {
        guard !feature.isApplyingTableEdits else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty, !feature.columns.isEmpty else { return }
        let anchorRow = pasteAnchor?.row ?? selectedRows.min() ?? 0
        let anchorColumn = pasteAnchor.flatMap { feature.columns.firstIndex(of: $0.column) } ?? 0
        for (rowOffset, line) in lines.enumerated() {
            let values = line.components(separatedBy: "\t")
            let targetRow = anchorRow + rowOffset
            let insertedIndex = targetRow - feature.rows.count
            if insertedIndex >= 0 {
                while insertedRows.count <= insertedIndex { insertedRows.append([:]) }
            }
            for (columnOffset, value) in values.enumerated() {
                let columnIndex = anchorColumn + columnOffset
                guard feature.columns.indices.contains(columnIndex) else { continue }
                let column = feature.columns[columnIndex]
                if targetRow < feature.rows.count {
                    drafts[CellKey(row: targetRow, column: column)] = .string(value)
                } else {
                    insertedRows[insertedIndex][column] = .string(value)
                }
            }
        }
    }

    private func copySelectedRowsAsTSV() {
        let indexes = selectedRows.sorted().filter(feature.rows.indices.contains)
        guard !indexes.isEmpty else { return }
        let columns = feature.columns
        let text = indexes.map { index in
            columns.map { display(feature.rows[index][$0]) }.joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func replaceCurrentPage() {
        guard !replaceText.isEmpty else { return }
        let columns = replaceColumn.isEmpty ? feature.columns : [replaceColumn]
        for (rowIndex, row) in feature.rows.enumerated() {
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
        let base = exportFormat == .sql ? (feature.selectedProfile?.database.nonEmpty ?? "database") : (feature.selectedTable ?? "table")
        return "\(base).\(exportFormat.rawValue)"
    }

    private func export(_ format: DatabaseTransferFormat) {
        exportFormat = format
        Task {
            if format == .sql {
                guard let url = await feature.exportDataFile(format: format) else { return }
                temporaryExportURL = url
                exportDocument = DatabaseTransferDocument(fileURL: url)
            } else {
                guard let data = await feature.exportData(format: format) else { return }
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
                let temporaryURL = try feature.prepareImportFile(from: url)
                stageImport(fileURL: temporaryURL, format: .sql)
                return
            }
            stageImport(data: try feature.readImportData(from: url), format: importFormat)
        } catch { feature.errorMessage = error.localizedDescription }
    }

    private func stageImport(data: Data? = nil, fileURL: URL? = nil, format: DatabaseTransferFormat) {
        pendingImportData = data
        pendingImportURL = fileURL
        pendingImportFormat = format
        if format == .sql || feature.selectedProfile?.productionProtection == true {
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
                defer { feature.removeTemporaryFile(fileURL) }
                _ = await feature.importDataFile(fileURL, format: format, confirmed: confirmed)
            } else if let data {
                _ = await feature.importData(data, format: format, confirmed: confirmed)
            }
        }
    }

    private func discardPendingImport() {
        if let pendingImportURL { feature.removeTemporaryFile(pendingImportURL) }
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

private struct DatabaseBatchUpdateSheet: View {
    let columns: [String]
    let selectedCount: Int
    let onApply: (String, String, Bool) -> Void
    let onCancel: () -> Void
    @State private var column = ""
    @State private var value = ""
    @State private var setNull = false
    @FocusState private var valueFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(selectedCount) selected").foregroundStyle(LitheTheme.secondaryText)
                Text("Set one field for every selected row. The change remains pending until you choose Apply.")
                    .foregroundStyle(LitheTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Column").frame(width: 80, alignment: .leading)
                        LitheSettingsSelect(selection: $column, options: columns, width: 316, accessibilityLabel: "Column", title: { $0 }, localizesTitles: false)
                    }
                    GridRow {
                        Text("Value")
                        TextField("New value", text: $value).focused($valueFocused)
                            .modifier(LitheCommitDialogInputStyle(focused: valueFocused)).disabled(setNull)
                    }
                    GridRow { Color.clear.frame(width: 80, height: 1); Toggle("Set NULL", isOn: $setNull).toggleStyle(.checkbox) }
                }
            }.padding(16)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(LitheCommitDialogButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Stage Batch Edit") { onApply(column, value, setNull); onCancel() }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(column.isEmpty || selectedCount == 0)
            }.padding(16)
        }
        .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.primaryText)
        .frame(width: 440).background(LitheCommitDialogStyle.background)
        .onAppear { if column.isEmpty { column = columns.first ?? "" } }
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
        LitheUnavailableView(title, systemImage: symbol, description: Text(detail))
            .foregroundStyle(LitheTheme.secondaryText)
            .accessibilityElement(children: .combine)
    }
}

typealias CellKey = DatabaseCellKey

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
    var title: LocalizedStringKey { LocalizedStringKey(menuTitle) }
    var menuTitle: String {
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
    let rowNumber: Int
    let columns: [String]
    let row: DatabaseRow
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("#\(rowNumber)").foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(columns, id: \.self) { column in
                        GridRow {
                            Text(column).frame(width: 150, alignment: .leading)
                            Text(row[column]?.displayText ?? "<null>").font(LitheTheme.codeFont)
                                .foregroundStyle(row[column] == .null ? LitheTheme.DatabaseGrid.nullText : LitheTheme.DatabaseGrid.text)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(16)
            }.litheScrollViewChrome()
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack { Spacer(); Button("Close", action: onCancel).buttonStyle(LitheCommitDialogButtonStyle()).keyboardShortcut(.cancelAction) }.padding(16)
        }
        .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.primaryText)
        .frame(width: 620, height: 460).background(LitheCommitDialogStyle.background)
    }
}

private struct DatabaseReplaceSheet: View {
    @Environment(\.locale) private var locale
    let columns: [String]
    @Binding var column: String
    @Binding var searchText: String
    @Binding var replacementText: String
    let onReplace: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Column").frame(width: 96, alignment: .leading)
                    LitheSettingsSelect(selection: $column, options: [""] + columns, width: 280, accessibilityLabel: "Column",
                        title: { $0.isEmpty ? String(localized: "All columns", locale: locale) : $0 }, localizesTitles: false)
                }
                GridRow {
                    Text("Find")
                    TextField("", text: $searchText).accessibilityLabel("Find").focused($focusedField, equals: "find")
                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "find"))
                }
                GridRow {
                    Text("Replace with")
                    TextField("", text: $replacementText).accessibilityLabel("Replace with").focused($focusedField, equals: "replace")
                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "replace"))
                }
            }.padding(16)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(LitheCommitDialogButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Replace") { onReplace(); onCancel() }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(searchText.isEmpty)
            }.padding(16)
        }
        .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.primaryText)
        .frame(width: 420).background(LitheCommitDialogStyle.background)
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

struct DatabaseGridCellClickTarget: NSViewRepresentable {
    let onMouseDown: (Int) -> Void

    func makeNSView(context: Context) -> DatabaseGridCellClickView {
        let view = DatabaseGridCellClickView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ view: DatabaseGridCellClickView, context: Context) {
        view.onMouseDown = onMouseDown
    }
}

final class DatabaseGridCellClickView: NSView {
    var onMouseDown: ((Int) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Select on the first down event; never wait for double-click arbitration.
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else { return }
        onMouseDown?(event.clickCount)
    }
}

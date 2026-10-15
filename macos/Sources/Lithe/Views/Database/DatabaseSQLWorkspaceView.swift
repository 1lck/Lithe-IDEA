import AppKit
import SwiftUI
import LitheDatabaseModule

/// Observe the feature directly so changing sections updates an already open tab.
struct DatabaseWorkspaceTabTitle: View {
    @ObservedObject var feature: DatabaseFeatureModel

    var profileID: UUID?
    var queryID: UUID?

    var title: String {
        guard let profileID, let profile = feature.profiles.first(where: { $0.id == profileID }) else {
            return "SQL History"
        }
        if let queryID, let query = feature.sqlTab(queryID, profileID: profileID) {
            let suffix = query.title == "Query 1" ? "" : " \(query.title)"
            return "console\(suffix) [\(profile.name)]"
        }
        return profile.database.isEmpty ? profile.name : profile.database
    }

    var body: some View { Text(verbatim: title) }
}

struct DatabaseWorkspaceView: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel

    var body: some View {
        Group {
            if feature.selectedProfile == nil || (feature.workspaceSection == .history && feature.selectedProfile?.kind.isSQLDatabase != true) {
                DatabaseHistoryView()
            } else if feature.selectedProfile?.kind == .redis {
                RedisWorkspaceView()
            } else if feature.selectedProfile?.kind == .nacos {
                NacosWorkspaceView()
            } else if feature.selectedProfile?.kind == .mongodb {
                mongoWorkspace
            } else {
                sqlWorkspace
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .id(feature.selectedProfileID)
    }

    private var sqlWorkspace: some View { DatabaseTableView() }

    private var mongoWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if let profile = feature.selectedProfile {
                    DatabaseBrandIcon(kind: .mongodb, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MongoDB Documents").font(LitheTheme.uiFont(size: 12, weight: .semibold))
                        Text(profile.database.isEmpty ? "admin" : profile.database)
                            .font(LitheTheme.uiFont(size: 9.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                Spacer()
                Text("Collection data can be edited directly in the grid.")
                    .font(LitheTheme.uiFont(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .litheWorkbenchSurface(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            DatabaseTableView()
        }
    }
}

extension DatabaseWorkspaceSection {
    var titleKey: LocalizedStringKey {
        switch self {
        case .data: "Data"
        case .sql: "SQL"
        case .structure: "Structure"
        case .history: "History"
        }
    }
    var iconPath: String {
        switch self {
        case .data: "database/expui/table.svg"
        case .sql: "expui/fileTypes/shell.svg"
        case .structure: "expui/toolwindows/structure.svg"
        case .history: "expui/general/history.svg"
        }
    }
}

struct DatabaseHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel

    private var entries: [DatabaseSQLHistoryEntry] {
        guard let profileID = feature.selectedProfileID else { return feature.sqlHistory }
        return feature.sqlHistory.filter { $0.profileID == profileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "SQL History") {
                Text("\(entries.count) statements")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            LitheToolWindowHeaderDivider()
            if entries.isEmpty {
                LitheUnavailableView("No query history", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(LitheTheme.secondaryText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            Button {
                                model.openDatabaseQuery(profileID: entry.profileID, sql: entry.sql)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                            .font(LitheTheme.codeFont)
                                            .foregroundStyle(LitheTheme.primaryText)
                                            .lineLimit(2)
                                        Text(entry.executedAt, format: .dateTime.year().month().day().hour().minute().second())
                                            .font(LitheTheme.uiFont(size: 12))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.litheNoPress)
                            .litheRowHover()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(12)
                }
                .litheScrollViewChrome()
            }
        }
    }
}

private extension DatabaseKind {
    var displayName: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        case .sqlite: "SQLite"
        case .sqlserver: "SQL Server"
        case .mongodb: "MongoDB"
        case .redis: "Redis"
        case .nacos: "Nacos"
        }
    }

    var symbolName: String {
        switch self {
        case .mysql: "cylinder.split.1x2"
        case .mariadb: "cylinder.split.1x2"
        case .postgresql: "cylinder.split.1x2"
        case .sqlite: "externaldrive"
        case .sqlserver: "server.rack"
        case .mongodb: "leaf"
        case .redis: "square.stack.3d.up.fill"
        case .nacos: "slider.horizontal.3"
        }
    }
}

struct DatabaseSQLWorkspaceView: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @EnvironmentObject private var model: AppModel
    @State private var pendingRisk: DatabaseSQLAnalysis?
    @State private var pendingScope: DatabaseSQLExecutionScope = .all
    @State private var pendingTabID: UUID?
    @State private var showsRiskConfirmation = false
    @State private var sqlSelection = ""
    @State private var sqlSelectionRange = NSRange(location: 0, length: 0)
    @State private var showsQueryHistory = false
    @State private var historyProfileID: UUID?
    @State private var historyTabID: UUID?
    @State private var historySelectionRange = NSRange(location: 0, length: 0)

    var body: some View {
        VStack(spacing: 0) {
            commandBar
            LitheToolWindowHeaderDivider()
            editor
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .workbenchHoverTooltipScope()
        .alert("Confirm database change", isPresented: $showsRiskConfirmation, presenting: pendingRisk) { analysis in
            Button("Cancel", role: .cancel) {
                pendingRisk = nil
                pendingTabID = nil
            }
            Button(analysis.statementCount > 1 ? "Run batch" : "Run statement", role: .destructive) {
                if let tabID = pendingTabID {
                    model.showToolWindow(.databaseServices)
                    Task { await feature.runSQL(in: tabID, scope: pendingScope, confirmedRisk: true, selectionRange: sqlSelectionRange) }
                }
                pendingRisk = nil
                pendingTabID = nil
            }
        } message: { analysis in
            DatabaseLocalization.text(analysis.warning ?? "This statement can change the database.")
        }
        .background(LitheCenteredPopup(isPresented: $showsQueryHistory,
            dialogTitle: feature.profiles.first { $0.id == historyProfileID }.map {
                String(format: DatabaseLocalization.string("%@ Query History", locale: model.settings.language.locale), $0.name)
            }) {
            DatabaseQueryHistoryDialog(profileID: historyProfileID, onClose: { showsQueryHistory = false }) { entry in
                guard let id = historyTabID, feature.selectedProfileID == historyProfileID,
                      let tab = feature.sqlTabs.first(where: { $0.id == id }),
                      historySelectionRange.location <= tab.sql.utf16.count,
                      historySelectionRange.length <= tab.sql.utf16.count - historySelectionRange.location else { return }
                feature.updateSQL((tab.sql as NSString).replacingCharacters(in: historySelectionRange, with: entry.sql), in: id)
                showsQueryHistory = false
            }
            .environmentObject(feature)
        })
        .onChange(of: feature.selectedSQLTabID) { _ in
            sqlSelection = ""
            sqlSelectionRange = NSRange(location: 0, length: 0)
        }
    }

    private var commandBar: some View {
        HStack(spacing: 5) {
            Button(action: runSelectedQuery) {
                LitheIDEAIcon(resourcePath: "expui/run/run.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .accessibilityLabel("Run")
            .disabled(feature.selectedSQLTab?.isRunning == true || feature.selectedProfile == nil)
            .help(hasSQLSelection ? "Run selected SQL (Command-Return)" : "Run all SQL (Command-Return)")

            LitheMenu {
                LitheContextMenuItem.action("Run All", icon: AnyView(LitheIDEAIcon(resourcePath: "expui/run/run.svg", size: 16, preservesOriginalColors: true))) { runAllQuery() }
                LitheContextMenuItem.action("Run Selection") { runSelectionQuery() }
                    .disabled(!hasSQLSelection)
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .disabled(feature.selectedSQLTab?.isRunning == true || feature.selectedProfile == nil)
            .workbenchHoverHelp(Text("Choose SQL execution scope"))
            .accessibilityLabel("Choose SQL execution scope")

            Rectangle().fill(LitheTheme.ActionToolbar.separator).frame(width: 1, height: 17)
                .frame(width: 7, height: 24)

            Button { if let id = feature.selectedSQLTabID { feature.formatSQL(in: id) } } label: {
                LitheIDEAIcon(resourcePath: "expui/actions/reformatCode.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .disabled(feature.selectedSQLTab?.sql.isEmpty != false)
            .workbenchHoverHelp(Text("Format SQL"))
            .accessibilityLabel("Format SQL")

            Button {
                historyProfileID = feature.selectedProfileID
                historyTabID = feature.selectedSQLTabID
                historySelectionRange = sqlSelectionRange
                showsQueryHistory = true
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/history.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .disabled(feature.selectedProfile == nil)
            .workbenchHoverHelp(Text("Query history"))
            .accessibilityLabel("Query history")

            if let execution = feature.selectedSQLTab?.execution {
                executionLabel(execution)
                    .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            if let profile = feature.selectedProfile {
                let currentDatabase = profile.database.isEmpty ? profile.name : profile.database
                let canSwitchDatabase = profile.kind == .mysql || profile.kind == .mariadb
                LitheMenu {
                    if !profile.database.isEmpty || !canSwitchDatabase {
                        LitheContextMenuItem.action(currentDatabase, localizesTitle: false, initiallySelected: true) {}
                    }
                    if canSwitchDatabase {
                        let otherDatabases = feature.databaseOptions.filter { $0 != profile.database }
                        if !otherDatabases.isEmpty {
                            LitheContextMenuItem.heading("Non-Introspected")
                            for database in otherDatabases {
                                LitheContextMenuItem.action(database, localizesTitle: false) {
                                    Task { await feature.selectDatabase(database, for: profile) }
                                }
                            }
                        } else if feature.databaseOptions.isEmpty {
                            LitheContextMenuItem.heading("No databases loaded")
                        }
                        LitheContextMenuItem.separator
                        LitheContextMenuItem.action("Refresh databases") { Task { await feature.refreshDatabases() } }
                    }
                } label: {
                    // Community ActionButtonWithText: 2pt icon/text/arrow gaps, 4pt horizontal margins.
                    HStack(spacing: 2) {
                        LitheIDEAIcon(resourcePath: "database/expui/schema.svg", size: 16, preservesOriginalColors: true)
                        Text(verbatim: currentDatabase).lineLimit(1)
                        LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16, preservesOriginalColors: true)
                    }
                    .font(LitheTheme.uiFont(size: 13))
                    .padding(.horizontal, 4)
                }
                .litheToolbarIconButton(isIconOnly: false)
                .disabled(feature.sqlTabs.contains(where: { $0.isRunning }) || showsRiskConfirmation)
                .workbenchHoverHelp(Text("Switch current database"))
                .accessibilityLabel("Switch current database")
                .accessibilityValue(Text(verbatim: currentDatabase))
            } else {
                Text("No connection")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.warning)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: LitheTheme.Metrics.toolWindowHeaderHeight)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    @ViewBuilder
    private var editor: some View {
        if let tab = feature.selectedSQLTab {
            SQLSyntaxEditor(
                text: Binding(
                    get: { feature.selectedSQLTab?.sql ?? "" },
                    set: { feature.updateSQL($0, in: tab.id) }
                ),
                completions: feature.sqlCompletionItems,
                onRun: runSelectedQuery,
                onSelectionChange: { sqlSelection = $0 },
                executions: tab.statementExecutions,
                onSelectionRangeChange: { sqlSelectionRange = $0 }
            )
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if let error = tab.errorMessage {
                    HStack {
                        DatabaseLocalization.error(error)
                            .font(LitheTheme.uiFont(size: 13)).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button { feature.dismissSQLError(in: tab.id) } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/closeSmall.svg", size: 16)
                        }.litheToolbarIconButton().accessibilityLabel("Close")
                    }
                    .foregroundStyle(LitheTheme.DatabaseGrid.text)
                    // Editor.Notification.WithoutStatus.borderInsets.compact (Darcula parent).
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(LitheTheme.DatabaseGrid.failedMutation)
                    .overlay(alignment: .top) { Rectangle().fill(LitheTheme.DatabaseConsole.errorBorder).frame(height: 1) }

                }
            }
        } else {
            LitheUnavailableView("No Query Tab", systemImage: "terminal")
        }
    }

    private func runSelectedQuery() {
        if hasSQLSelection {
            run(scope: .selection(sqlSelection))
        } else {
            runAllQuery()
        }
    }

    private func runAllQuery() {
        run(scope: .all)
    }

    private func runSelectionQuery() {
        guard hasSQLSelection else { return }
        run(scope: .selection(sqlSelection))
    }

    private func run(scope: DatabaseSQLExecutionScope) {
        guard let tabID = feature.selectedSQLTabID else { return }
        let analysis = feature.analysis(forSQLTab: tabID, scope: scope)
        if analysis.requiresConfirmation {
            pendingRisk = analysis
            pendingScope = scope
            pendingTabID = tabID
            showsRiskConfirmation = true
        } else {
            model.showToolWindow(.databaseServices)
            let selection = sqlSelectionRange
            Task { await feature.runSQL(in: tabID, scope: scope, selectionRange: selection) }
        }
    }

    private var hasSQLSelection: Bool {
        !sqlSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func executionLabel(_ execution: DatabaseSQLExecution) -> Text {
        if let rows = execution.rowsReturned, let affected = execution.rowsAffected {
            return Text("\(rows) rows, \(affected) affected  \(execution.durationMilliseconds) ms")
        }
        if let rows = execution.rowsReturned { return Text("\(rows) rows  \(execution.durationMilliseconds) ms") }
        if let affected = execution.rowsAffected { return Text("\(affected) affected  \(execution.durationMilliseconds) ms") }
        return Text("\(execution.durationMilliseconds) ms")
    }


}

struct DatabaseQueryResultGrid: View {
    private struct ResultCell: Hashable { let row: Int; let column: Int }
    let columns: [String]
    let rows: [DatabaseRow]
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var gridActive = false
    @State private var selectedCell: ResultCell?
    @State private var selectedRows: Set<Int> = []
    @FocusState private var focusedCell: ResultCell?

    private var rowHeaderWidth: CGFloat { LitheTheme.DatabaseGrid.rowHeaderWidth(rowCount: rows.count) }
    private var border: Color { LitheTheme.DatabaseGrid.border }

    var body: some View {
        GeometryReader { geometry in
            // ponytail: match the table editor's bounded 100-row width sample.
            let widths = LitheTheme.DatabaseGrid.columnWidths(columns, availableWidth: geometry.size.width,
                                                             rowHeaderWidth: rowHeaderWidth) { column in
                rows.prefix(100).map { display($0[column]) }
            }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            resultRow(index: index, row: row, widths: widths)
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Button {
                                selectedRows = selectedRows.count == rows.count ? [] : Set(rows.indices)
                            } label: { Text("#").frame(width: rowHeaderWidth, height: 25) }
                            .buttonStyle(.litheNoPress)
                            .overlay(alignment: .trailing) { Rectangle().fill(border).frame(width: 1) }
                            ForEach(Array(columns.enumerated()), id: \.offset) { columnIndex, column in
                                HStack(spacing: 4) {
                                    LitheIDEAIcon(resourcePath: "database/expui/column.svg", size: 16, preservesOriginalColors: true)
                                    Text(column).lineLimit(1)
                                }
                                .padding(.leading, 4).padding(.trailing, 3)
                                .frame(width: widths[column] ?? 40, height: 25, alignment: .leading)
                                .background(selectedCell?.column == columnIndex || !selectedRows.isEmpty
                                    ? LitheTheme.DatabaseGrid.currentRowBackground : Color.clear)
                                .overlay(alignment: .trailing) { Rectangle().fill(border).frame(width: 1) }
                            }
                        }
                        .foregroundStyle(LitheTheme.DatabaseGrid.text)
                        .background(LitheTheme.DatabaseGrid.headerBackground)
                        .overlay(alignment: .bottom) { Rectangle().fill(border).frame(height: 1) }
                    }
                }
                .font(LitheTheme.codeFont)
                .frame(minWidth: max(geometry.size.width, columns.reduce(0) { $0 + (widths[$1] ?? 40) } + rowHeaderWidth),
                       minHeight: geometry.size.height, alignment: .topLeading)
            }
            .litheScrollViewChrome()
            .background(LitheToolWindowActivityTracker(isActive: $gridActive))
            .onChange(of: focusedCell) { cell in if let cell { selectedCell = cell } }
            .onMoveCommand { direction in
                guard let current = selectedCell, columns.indices.contains(current.column), !rows.isEmpty else { return }
                var row = current.row
                var nextColumn = current.column
                switch direction {
                case .up: row = max(0, row - 1)
                case .down: row = min(rows.count - 1, row + 1)
                case .left: nextColumn = max(0, current.column - 1)
                case .right: nextColumn = min(columns.count - 1, current.column + 1)
                @unknown default: return
                }
                selectedRows = []
                focusedCell = ResultCell(row: row, column: nextColumn)
            }
            .onCopyCommand {
                let text: String
                if !selectedRows.isEmpty {
                    text = selectedRows.sorted().filter { rows.indices.contains($0) }
                        .map { index in columns.map { display(rows[index][$0]) }.joined(separator: "\t") }.joined(separator: "\n")
                } else if let selectedCell, rows.indices.contains(selectedCell.row) {
                    text = display(rows[selectedCell.row][columns[selectedCell.column]])
                } else { return [] }
                return [NSItemProvider(object: text as NSString)]
            }
        }
        .background(LitheTheme.DatabaseGrid.background)
        .onChange(of: columns) { _ in selectedCell = nil; focusedCell = nil; selectedRows = [] }
        .onChange(of: rows) { _ in selectedCell = nil; focusedCell = nil; selectedRows = [] }
    }

    private func resultRow(index: Int, row: DatabaseRow, widths: [String: CGFloat]) -> some View {
        HStack(spacing: 0) {
            Button {
                if selectedRows.contains(index) { selectedRows.remove(index) }
                else { selectedRows.insert(index) }
            } label: {
                Text("\(index + 1)")
                    .foregroundStyle(selectedCell?.row == index || selectedRows.contains(index)
                        ? LitheTheme.DatabaseGrid.currentRowNumber : LitheTheme.DatabaseGrid.rowNumber)
                    .frame(width: rowHeaderWidth, height: LitheTheme.DatabaseGrid.rowHeight)
            }
            .buttonStyle(.litheNoPress)
            .overlay(alignment: .trailing) { Rectangle().fill(border).frame(width: 1) }
            ForEach(Array(columns.enumerated()), id: \.offset) { columnIndex, column in
                resultCell(index: index, row: row, columnIndex: columnIndex, column: column, width: widths[column] ?? 40)
            }
        }
        .background(selectedCell?.row == index || selectedRows.contains(index)
            ? LitheTheme.DatabaseGrid.currentRowBackground : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(border).frame(height: 1) }
    }

    private func resultCell(index: Int, row: DatabaseRow, columnIndex: Int, column: String, width: CGFloat) -> some View {
        let key = ResultCell(row: index, column: columnIndex)
        return Text(display(row[column]))
            .foregroundStyle(row[column] == nil || row[column] == .null
                ? LitheTheme.DatabaseGrid.nullText : LitheTheme.DatabaseGrid.text)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: alignment(row[column]))
            .focusable().litheFocusEffectHidden().focused($focusedCell, equals: key)
            .padding(.horizontal, 3)
            .frame(width: width, height: LitheTheme.DatabaseGrid.rowHeight)
            .background(selectedCell == key || selectedRows.contains(index)
                ? (gridActive && controlActiveState == .key ? LitheTheme.DatabaseGrid.selected : LitheTheme.DatabaseGrid.inactiveSelected) : Color.clear)
            .overlay {
                DatabaseGridCellClickTarget { _ in
                    selectedRows = []
                    selectedCell = key
                    focusedCell = key
                }
            }
            .overlay(alignment: .trailing) { Rectangle().fill(border).frame(width: 1) }
            .litheContextMenu {
                [LitheContextMenuItem.action("Copy Cell") { copy(display(row[column])) },
                 LitheContextMenuItem.action("Copy Row as TSV") { copy(columns.map { display(row[$0]) }.joined(separator: "\t")) }]
            }
    }

    private func alignment(_ value: DatabaseValue?) -> Alignment {
        switch value { case .integer, .number, .decimal: return .trailing; default: return .leading }
    }
    private func display(_ value: DatabaseValue?) -> String { value?.displayText ?? "<null>" }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

struct DatabaseStructureView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @State private var editor: DatabaseSchemaEditorKind?
    @State private var pendingChange: DatabaseSchemaChange?
    @State private var showsDestructiveConfirmation = false

    var body: some View {
        if let table = feature.selectedTable {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(table).font(LitheTheme.uiFont(size: 13))
                    Spacer()
                    Button { editor = .column } label: { LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16, preservesOriginalColors: true) }.litheToolbarIconButton().help("Add column")
                    Button { editor = .index } label: { LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16, preservesOriginalColors: true) }.litheToolbarIconButton().help("Add index")
                    Button { editor = .foreignKey } label: { LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16, preservesOriginalColors: true) }.litheToolbarIconButton().help("Add foreign key")
                    Button { Task { await feature.openTable(table) } } label: { LitheIDEAIcon(resourcePath: "expui/general/refresh.svg", size: 16, preservesOriginalColors: true) }.litheToolbarIconButton().help("Refresh structure")
                }
                .padding(.horizontal, 8).frame(height: LitheTheme.Metrics.toolWindowHeaderHeight).litheWorkbenchSurface(LitheTheme.editor)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LitheToolWindowHeader(title: "Columns")
                        LitheToolWindowHeaderDivider()
                        Group {
                            ForEach(feature.columns, id: \.self) { column in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(column)
                                        Text(feature.columnTypes[column] ?? "")
                                            .font(LitheTheme.codeFont)
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                    Spacer()
                                    HStack(spacing: 2) {
                                        Button {
                                            editor = .renameColumn(column)
                                        } label: {
                                            LitheIDEAIcon(resourcePath: "expui/general/edit.svg", size: 16, preservesOriginalColors: true)
                                        }
                                        .litheToolbarIconButton()
                                        .help("Rename Column…")

                                        Button(role: .destructive) {
                                            pendingChange = DatabaseSchemaChange(operation: "dropColumn", table: table, name: column)
                                            showsDestructiveConfirmation = true
                                        } label: {
                                            LitheIDEAIcon(resourcePath: "expui/general/delete.svg", size: 16, preservesOriginalColors: true)
                                                .foregroundStyle(LitheTheme.error)
                                        }
                                        .litheToolbarIconButton()
                                        .help("Drop Column")
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                            }
                        }
                        LitheToolWindowHeader(title: "Indexes")
                        LitheToolWindowHeaderDivider()
                        Group {
                            if feature.indexes.isEmpty { Text("No indexes").foregroundStyle(LitheTheme.secondaryText) }
                            ForEach(Array(feature.indexes.enumerated()), id: \.offset) { _, row in
                                Text(metadata(row))
                            }
                        }
                        LitheToolWindowHeader(title: "Foreign Keys")
                        LitheToolWindowHeaderDivider()
                        Group {
                            if feature.foreignKeys.isEmpty { Text("No foreign keys").foregroundStyle(LitheTheme.secondaryText) }
                            ForEach(Array(feature.foreignKeys.enumerated()), id: \.offset) { _, row in
                                Text(metadata(row))
                            }
                        }
                    }
                    .font(LitheTheme.uiFont(size: 13))
                    .padding(16)
                }
                .litheScrollViewChrome()
            }
            .background(LitheCenteredPopup(isPresented: Binding(
                get: { editor != nil }, set: { if !$0 { editor = nil } }
            ), dialogTitle: String(localized: String.LocalizationValue(editor?.title ?? "Structure"))) {
                if let editor { DatabaseSchemaEditorView(
                    kind: editor,
                    table: table,
                    columns: feature.columns,
                    onCancel: { self.editor = nil },
                    onSave: { change in
                        self.editor = nil
                        Task { _ = await feature.applySchemaChange(change, confirmed: false) }
                    }
                )
                .environment(\.locale, model.settings.language.locale)
                .id(editor.id + model.settings.language.rawValue)
                }
            })
            .alert("Drop database object?", isPresented: $showsDestructiveConfirmation, presenting: pendingChange) { change in
                Button("Cancel", role: .cancel) { pendingChange = nil }
                Button("Drop", role: .destructive) {
                    Task { _ = await feature.applySchemaChange(change, confirmed: true) }
                    pendingChange = nil
                }
            } message: { change in
                Text("Dropping \(change.name) cannot be undone by the table editor. A recovery snapshot should be taken before this operation.")
            }
        } else {
            LitheUnavailableView("No Table Selected", systemImage: "list.bullet.rectangle", description: Text("Choose a table to inspect its columns, indexes, and foreign keys."))
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private func metadata(_ row: DatabaseRow) -> String {
        row.keys.sorted().compactMap { key in
            guard let value = row[key] else { return nil }
            return "\(key): \(display(value))"
        }.joined(separator: "  ")
    }

    private func display(_ value: DatabaseValue) -> String {
        value.displayText
    }
}

private enum DatabaseSchemaEditorKind: Identifiable {
    case column
    case renameColumn(String)
    case index
    case foreignKey

    var title: String {
        switch self {
        case .column: "Add Column"
        case .renameColumn: "Rename Column"
        case .index: "Add Index"
        case .foreignKey: "Add Foreign Key"
        }
    }

    var id: String {
        switch self {
        case .column: "column"
        case let .renameColumn(name): "rename-\(name)"
        case .index: "index"
        case .foreignKey: "foreign-key"
        }
    }
}

private struct DatabaseSchemaEditorView: View {
    let kind: DatabaseSchemaEditorKind
    let table: String
    let columns: [String]
    let onCancel: () -> Void
    let onSave: (DatabaseSchemaChange) -> Void
    @State private var name = ""
    @State private var oldName = ""
    @State private var dataType = "TEXT"
    @State private var nullable = true
    @State private var defaultValue = ""
    @State private var indexName = ""
    @State private var indexColumns: Set<String> = []
    @State private var constraintName = ""
    @State private var referencedTable = ""
    @State private var referencedColumns = ""

    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    switch kind {
                    case .column:
                        GridRow { Text("Column name").frame(width: 150, alignment: .leading); TextField("", text: $name).accessibilityLabel("Column name").focused($focusedField, equals: "name").modifier(LitheCommitDialogInputStyle(focused: focusedField == "name")) }
                        GridRow { Text("SQL type"); TextField("", text: $dataType).accessibilityLabel("SQL type").focused($focusedField, equals: "type").modifier(LitheCommitDialogInputStyle(focused: focusedField == "type")) }
                        GridRow { Text("Default expression"); TextField("Optional", text: $defaultValue).focused($focusedField, equals: "default").modifier(LitheCommitDialogInputStyle(focused: focusedField == "default")) }
                        GridRow { Color.clear.frame(width: 150, height: 1); Toggle("Allow NULL", isOn: $nullable).toggleStyle(.checkbox) }
                    case let .renameColumn(column):
                        GridRow { Text("Current name").frame(width: 150, alignment: .leading); Text(column).font(LitheTheme.codeFont).frame(maxWidth: .infinity, alignment: .leading) }
                        GridRow { Text("New name"); TextField("", text: $name).accessibilityLabel("New name").focused($focusedField, equals: "name").modifier(LitheCommitDialogInputStyle(focused: focusedField == "name")) }
                    case .index:
                        GridRow { Text("Index name").frame(width: 150, alignment: .leading); TextField("", text: $indexName).accessibilityLabel("Index name").focused($focusedField, equals: "name").modifier(LitheCommitDialogInputStyle(focused: focusedField == "name")) }
                        columnSelection
                    case .foreignKey:
                        GridRow { Text("Constraint name").frame(width: 150, alignment: .leading); TextField("", text: $constraintName).accessibilityLabel("Constraint name").focused($focusedField, equals: "name").modifier(LitheCommitDialogInputStyle(focused: focusedField == "name")) }
                        GridRow { Text("Referenced table"); TextField("", text: $referencedTable).accessibilityLabel("Referenced table").focused($focusedField, equals: "table").modifier(LitheCommitDialogInputStyle(focused: focusedField == "table")) }
                        GridRow { Text("Referenced columns"); TextField("Comma separated", text: $referencedColumns).focused($focusedField, equals: "columns").modifier(LitheCommitDialogInputStyle(focused: focusedField == "columns")) }
                        columnSelection
                    }
                }.padding(16)
            }.litheScrollViewChrome()
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(LitheCommitDialogButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Apply") { onSave(makeChange()) }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(!isValid)
            }.padding(16)
        }
        .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.primaryText)
        .frame(width: 480, height: editorHeight).background(LitheCommitDialogStyle.background)
        .onAppear { if case let .renameColumn(column) = kind { oldName = column } }
    }

    private var columnSelection: some View {
        GridRow {
            Text("Columns").frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(columns, id: \.self) { column in
                    Toggle(column, isOn: Binding(get: { indexColumns.contains(column) }, set: {
                        if $0 { indexColumns.insert(column) } else { indexColumns.remove(column) }
                    })).toggleStyle(.checkbox)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editorHeight: CGFloat {
        if case .foreignKey = kind { return 430 }
        return 330
    }

    private var isValid: Bool {
        switch kind {
        case .column: !name.isEmpty && !dataType.isEmpty
        case .renameColumn: !oldName.isEmpty && !name.isEmpty
        case .index: !indexName.isEmpty && !indexColumns.isEmpty
        case .foreignKey: !constraintName.isEmpty && !referencedTable.isEmpty && !indexColumns.isEmpty && !referencedColumns.isEmpty
        }
    }

    private func makeChange() -> DatabaseSchemaChange {
        switch kind {
        case .column:
            return DatabaseSchemaChange(operation: "addColumn", table: table, name: name, dataType: dataType, nullable: nullable, defaultValue: defaultValue)
        case .renameColumn:
            return DatabaseSchemaChange(operation: "renameColumn", table: table, name: name, oldName: oldName)
        case .index:
            return DatabaseSchemaChange(operation: "createIndex", table: table, indexName: indexName, indexColumns: columns.filter { indexColumns.contains($0) })
        case .foreignKey:
            return DatabaseSchemaChange(operation: "addForeignKey", table: table, indexColumns: columns.filter { indexColumns.contains($0) }, constraintName: constraintName, referencedTable: referencedTable, referencedColumns: referencedColumns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }
}

private struct DatabaseDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @State private var diagnosticKind = "tableSize"
    @State private var pendingRollback: DatabaseRecoveryPoint?
    @State private var showsRollbackConfirmation = false
    @State private var showsBackupSchedule = false

    var body: some View {
        let tab = feature.selectedSQLTab
        let analysis = tab.map { feature.analysis(forSQLTab: $0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                LitheSettingsSelect(selection: $diagnosticKind, options: ["tableSize", "locks", "slowQueries", "indexes", "dataQuality", "schemaImpact"], width: 170, accessibilityLabel: "Diagnostic", title: { ["tableSize": "Table size", "locks": "Locks", "slowQueries": "Slow queries", "indexes": "Indexes", "dataQuality": "Data quality", "schemaImpact": "Schema impact"][$0] ?? $0 })
                .frame(width: 170)
                Button { loadDiagnostics() } label: { Image(systemName: "arrow.clockwise") }.litheIconButton().help("Run diagnostic")
                Button { if let profileID = feature.selectedProfileID { Task { _ = await feature.createBackup(profileID: profileID) } } } label: { Image(systemName: "archivebox") }.litheIconButton().help("Create database backup")
                Button { showsBackupSchedule = true } label: { Image(systemName: "calendar.badge.clock") }.litheIconButton().help("Configure backup schedule")
                if let progress = feature.backupProgress {
                    ProgressView(value: progress)
                        .frame(width: 90)
                        .help("Backing up database")
                }
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 36).litheWorkbenchSurface(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            List {
                Section("SQL safety") {
                    LabeledContent("Selected statement") { DatabaseLocalization.statementKind(analysis?.kind) }
                    LabeledContent("Statements") { Text("\(analysis?.statementCount ?? 0)") }
                    if let warning = analysis?.warning {
                        Label {
                            DatabaseLocalization.text(warning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                            .foregroundStyle(LitheTheme.warning)
                    } else {
                        Label("No destructive pattern detected", systemImage: "checkmark.shield")
                            .foregroundStyle(LitheTheme.success)
                    }
                }
                Section("Execution log") {
                    let events = feature.executionEvents
                        .filter { $0.profileID == feature.selectedProfileID }
                        .prefix(20)
                    if events.isEmpty {
                        Text("No execution events yet").foregroundStyle(LitheTheme.secondaryText)
                    } else {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: event.status == .succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(event.status == .succeeded ? LitheTheme.success : LitheTheme.error)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("\(event.source.rawValue.uppercased()) · \(event.operation)")
                                            .font(LitheTheme.uiFont(size: 11, weight: .medium))
                                        Spacer()
                                        Text("\(event.durationMilliseconds) ms")
                                            .font(LitheTheme.uiFont(size: 10, design: .monospaced))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                    if let error = event.errorMessage {
                                        Text(error)
                                            .font(LitheTheme.uiFont(size: 10))
                                            .foregroundStyle(LitheTheme.error)
                                            .lineLimit(2)
                                    } else if let rows = event.rowsReturned {
                                        Text("\(rows) rows returned")
                                            .font(LitheTheme.uiFont(size: 10))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Recent executions") {
                    let entries = feature.sqlHistory
                        .filter { $0.profileID == feature.selectedProfileID }
                        .prefix(10)
                    if entries.isEmpty {
                        Text("No executed SQL yet").foregroundStyle(LitheTheme.secondaryText)
                    } else {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    DatabaseLocalization.statementKind(entry.kind)
                                    Spacer()
                                    Text("\(entry.durationMilliseconds) ms")
                                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                }
                                Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                    .font(LitheTheme.uiFont(size: 10, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                Section("Recovery points") {
                    let points = feature.recoveryPoints.prefix(10)
                    if points.isEmpty { Text("No recovery point yet").foregroundStyle(LitheTheme.secondaryText) }
                    ForEach(points) { point in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                DatabaseLocalization.text(point.reason)
                                Text("\(point.byteCount) bytes")
                                    .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                            Spacer()
                            Button { pendingRollback = point; showsRollbackConfirmation = true } label: { Image(systemName: "arrow.uturn.backward") }
                                .litheIconButton().help("Restore recovery point")
                        }
                    }
                }
                Section("Audit") {
                    let entries = feature.auditEntries
                        .filter { $0.profileID == feature.selectedProfileID }
                        .prefix(10)
                    if entries.isEmpty {
                        Text("No audit entries yet").foregroundStyle(LitheTheme.secondaryText)
                    }
                    ForEach(entries) { entry in
                        HStack {
                            Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(entry.succeeded ? LitheTheme.success : LitheTheme.error)
                            DatabaseLocalization.text(entry.summary)
                            Spacer()
                            DatabaseLocalization.auditAction(entry.action).foregroundStyle(LitheTheme.secondaryText)
                        }
                    }
                }
            }
            .listStyle(.inset)
            if let result = feature.lastDiagnostics {
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                let columns = result.columns ?? result.rows.reduce(into: [String]()) { columns, row in
                    for key in row.keys where !columns.contains(key) { columns.append(key) }
                }
                DatabaseQueryResultGrid(columns: columns, rows: result.rows)
                    .frame(minHeight: 170)
            }
        }
        .alert("Restore recovery point?", isPresented: $showsRollbackConfirmation, presenting: pendingRollback) { point in
            Button("Cancel", role: .cancel) { pendingRollback = nil }
            Button("Restore", role: .destructive) {
                Task { _ = await feature.rollback(to: point) }
                pendingRollback = nil
            }
        } message: { point in
            Text("This will restore the saved SQL snapshot from \(point.reason). Current data may be overwritten.")
        }
        .sheet(isPresented: $showsBackupSchedule) {
            if let profile = feature.selectedProfile {
                DatabaseBackupScheduleEditor(profile: profile)
                    .environment(\.locale, model.settings.language.locale)
                    .id(model.settings.language)
            }
        }
    }

    private func loadDiagnostics() {
        Task {
            _ = await feature.loadDiagnostics(DatabaseDiagnosticsRequest(kind: diagnosticKind, schema: "", table: feature.selectedTable ?? ""))
        }
    }
}

private struct DatabaseBackupScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var feature: DatabaseFeatureModel
    let profile: DatabaseProfile
    @State private var enabled = true
    @State private var intervalHours = 24
    @State private var retentionCount = 14

    var body: some View {
        VStack(spacing: 0) {
            Text("Backup Schedule").font(LitheTheme.uiFont(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Form {
                LabeledContent("Connection") { Text(profile.name) }
                Toggle("Enable scheduled backups", isOn: $enabled)
                Stepper(value: $intervalHours, in: 1...720) {
                    Text("Backup interval: \(intervalHours) hours")
                }
                Stepper("Keep \(retentionCount) recovery points", value: $retentionCount, in: 1...365)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    feature.configureBackupSchedule(profileID: profile.id, isEnabled: enabled, intervalHours: intervalHours, retentionCount: retentionCount)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420, height: 280)
        .onAppear {
            if let schedule = feature.backupSchedules.first(where: { $0.profileID == profile.id }) {
                enabled = schedule.isEnabled
                intervalHours = schedule.intervalHours
                retentionCount = schedule.retentionCount
            }
        }
    }
}

struct SQLSyntaxEditor: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings
    @Binding var text: String
    let completions: [String]
    let onRun: () -> Void
    let onSelectionChange: (String) -> Void
    var executions: [DatabaseSQLStatementExecution] = []
    var onSelectionRangeChange: (NSRange) -> Void = { _ in }
    var isEditable = true
    var wrapsLines = false

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, completions: completions, onRun: onRun, onSelectionChange: onSelectionChange) }

    func makeNSView(context: Context) -> EditorContainerView {
        let isDark = colorScheme == .dark
        let scrollView = SQLScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller = LitheScrollViewChrome.CompactScroller()
        scrollView.horizontalScroller = LitheScrollViewChrome.CompactScroller()
        (scrollView.verticalScroller as? LitheScrollViewChrome.CompactScroller)?.role = .editor
        (scrollView.horizontalScroller as? LitheScrollViewChrome.CompactScroller)?.role = .editor

        let textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = LitheTheme.editorFont(size: settings.editorFontSize)
        textView.defaultParagraphStyle = LitheTheme.editorParagraphStyle
        applyAppearance(to: textView, in: scrollView, isDark: isDark)
        // Community EditorComponentImpl paints from its content origin; avoid stacking AppKit insets.
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        LitheTextViewportLayout.apply(to: textView, in: scrollView,
            softWrap: wrapsLines && LitheTextViewportLayout.isSoftWrapSupported(lineCount: LitheTextViewportLayout.lineCount(of: text)))
        textView.completionItems = completions
        textView.onRun = onRun
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onSelectionRangeChange = onSelectionRangeChange
        context.coordinator.textView = textView
        context.coordinator.isDarkAppearance = isDark
        context.coordinator.colorTheme = settings.colorTheme
        context.coordinator.fontSize = CGFloat(settings.editorFontSize)
        context.coordinator.highlight()
        scrollView.documentView = textView
        let container = EditorContainerView()
        container.displaysTransparentBackground = true
        let gutter = LineNumberGutterView()
        gutter.usesDatabaseConsoleAppearance = true
        gutter.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gutter)
        container.addSubview(scrollView)
        if isEditable {
            let stripe = SQLExecutionStripe()
            stripe.textView = textView
            stripe.wantsLayer = true
            stripe.locale = settings.language.locale
            stripe.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stripe)
            NSLayoutConstraint.activate([
                stripe.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                stripe.topAnchor.constraint(equalTo: container.topAnchor),
                stripe.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                stripe.widthAnchor.constraint(equalToConstant: LitheScrollBarStyle.editorThickness)
            ])
            textView.executionStripe = stripe
        }
        let gutterWidth = gutter.widthAnchor.constraint(equalToConstant: EditorLayoutMetrics.standardGutterWidth)
        if !isEditable {
            gutter.onStandardWidthChange = { [weak gutter, weak gutterWidth] _ in
                if let gutter { gutterWidth?.constant = gutter.consoleLineNumberOnlyWidth }
            }
        }
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutterWidth,
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        gutter.attach(textView: textView, scrollView: scrollView)
        if !isEditable { gutterWidth.constant = gutter.consoleLineNumberOnlyWidth }
        textView.gutter = gutter
        gutter.applyAppearance(CodeEditorPalette(isDark: isDark, theme: settings.colorTheme), isTransparent: true)
        context.coordinator.gutter = gutter
        context.coordinator.scrollView = scrollView
        textView.executions = executions
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        guard let scrollView = context.coordinator.scrollView,
              let textView = scrollView.documentView as? SQLTextView else { return }
        context.coordinator.gutter?.applyAppearance(CodeEditorPalette(isDark: colorScheme == .dark, theme: settings.colorTheme), isTransparent: true)
        let isDark = colorScheme == .dark
        let fontChanged = context.coordinator.fontSize != CGFloat(settings.editorFontSize)
        let appearanceChanged = context.coordinator.isDarkAppearance != isDark || context.coordinator.colorTheme != settings.colorTheme || fontChanged
        context.coordinator.isDarkAppearance = isDark
        context.coordinator.colorTheme = settings.colorTheme
        context.coordinator.fontSize = CGFloat(settings.editorFontSize)
        if fontChanged { textView.font = LitheTheme.editorFont(size: settings.editorFontSize) }
        context.coordinator.completions = completions
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onSelectionRangeChange = onSelectionRangeChange
        textView.isEditable = isEditable
        textView.executions = executions
        let wraps = wrapsLines && LitheTextViewportLayout.isSoftWrapSupported(lineCount: LitheTextViewportLayout.lineCount(of: text))
        if textView.textContainer?.widthTracksTextView != wraps {
            LitheTextViewportLayout.apply(to: textView, in: scrollView, softWrap: wraps)
        }
        textView.completionItems = completions
        textView.onRun = onRun
        if appearanceChanged {
            applyAppearance(to: textView, in: scrollView, isDark: isDark)
            context.coordinator.highlight()
        }
        if textView.string != text, !textView.hasMarkedText(), !context.coordinator.isApplyingChange {
            let selection = textView.selectedRange()
            let mappedSelection = Self.selection(selection, replacing: textView.string, with: text)
            textView.string = text
            textView.setSelectedRange(mappedSelection)
            context.coordinator.highlight()
        }
        var markers: [Int: String] = [:]
        let lines = TextLineIndex(source: text as NSString)
        for execution in textView.visibleExecutions {
            guard let range = execution.sourceRange else { continue }
            let line = lines.lineNumber(at: range.location) + 1
            if execution.errorMessage != nil { markers[line] = "expui/status/error.svg" }
            else if markers[line] == nil { markers[line] = "expui/general/greenCheckmark.svg" }
        }
        context.coordinator.gutter?.consoleExecutionMarkers = markers
        textView.executionStripe?.locale = settings.language.locale
        textView.executionStripe?.needsDisplay = true
    }

    /// Map native UTF-16 selection endpoints across a model-driven replacement, including execution-time formatting.
    static func selection(_ selection: NSRange, replacing original: String, with replacement: String) -> NSRange {
        let old = Array(original.utf16), new = Array(replacement.utf16)
        guard selection.location >= 0, selection.location <= old.count,
              selection.length >= 0, selection.length <= old.count - selection.location else { return NSRange(location: 0, length: 0) }
        // Formatting changes several whitespace gaps. Scan those edits linearly rather than diffing the whole script quadratically.
        var edits: [(range: NSRange, length: Int)] = []
        var oldIndex = 0, newIndex = 0
        func isWhitespace(_ unit: UInt16) -> Bool { UnicodeScalar(unit)?.properties.isWhitespace == true }
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, newIndex < new.count, old[oldIndex] == new[newIndex] {
                oldIndex += 1; newIndex += 1
                continue
            }
            let start = oldIndex, newStart = newIndex
            while oldIndex < old.count, isWhitespace(old[oldIndex]) { oldIndex += 1 }
            while newIndex < new.count, isWhitespace(new[newIndex]) { newIndex += 1 }
            guard oldIndex != start || newIndex != newStart else { break }
            edits.append((NSRange(location: start, length: oldIndex - start), newIndex - newStart))
        }
        if oldIndex != old.count || newIndex != new.count {
            // ponytail: non-format replacements remain one envelope; use provider edit ranges for future disjoint token edits.
            var start = 0, suffix = 0
            while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
            while suffix < min(old.count, new.count) - start, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
            edits = [(NSRange(location: start, length: old.count - suffix - start), new.count - suffix - start)]
        }
        func position(_ value: Int, trailing: Bool) -> Int {
            var delta = 0
            for edit in edits {
                if value < edit.range.location || (value == edit.range.location && !trailing && selection.length > 0) { break }
                if value >= NSMaxRange(edit.range) { delta += edit.length - edit.range.length }
                else { return edit.range.location + delta + (trailing ? edit.length : 0) }
            }
            return min(new.count, value + delta)
        }
        let location = position(min(selection.location, old.count), trailing: selection.length == 0)
        let end = position(min(NSMaxRange(selection), old.count), trailing: true)
        return NSRange(location: location, length: max(0, end - location))
    }

    private func applyAppearance(to textView: NSTextView, in scrollView: NSScrollView, isDark: Bool) {
        let foreground = NSColor(LitheTheme.DatabaseGrid.text)
        // As in CodeEditorView, the SwiftUI workbench surface owns the canvas background.
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = foreground
        textView.insertionPointColor = foreground
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(LitheTheme.DatabaseGrid.selected),
            .foregroundColor: foreground
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        var completions: [String]
        let onRun: () -> Void
        var onSelectionChange: (String) -> Void
        var onSelectionRangeChange: (NSRange) -> Void = { _ in }
        weak var textView: SQLTextView?
        weak var scrollView: NSScrollView?
        weak var gutter: LineNumberGutterView?
        var isApplyingChange = false
        var isDarkAppearance = true
        var colorTheme: AppColorTheme = .lithe
        var fontSize: CGFloat = 13

        init(text: Binding<String>, completions: [String], onRun: @escaping () -> Void, onSelectionChange: @escaping (String) -> Void) {
            self.text = text
            self.completions = completions
            self.onRun = onRun
            self.onSelectionChange = onSelectionChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isApplyingChange = true
            text.wrappedValue = textView.string
            highlight()
            isApplyingChange = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textView.synchronizeCaretPresentation()
            let range = textView.selectedRange()
            onSelectionRangeChange(range)
            guard range.length > 0, range.location + range.length <= textView.string.utf16.count else {
                onSelectionChange("")
                return
            }
            onSelectionChange((textView.string as NSString).substring(with: range))
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange).lowercased()
            let matches = completions.filter { $0.lowercased().hasPrefix(prefix) }
            if let index { index.pointee = 0 }
            return matches
        }

        func highlight() {
            guard let storage = textView?.textStorage else { return }
            SQLSyntaxHighlighter.apply(to: storage, font: LitheTheme.editorFont(size: fontSize), isDark: isDarkAppearance)
            gutter?.refreshLineNumberLayout()
            gutter?.needsDisplay = true
        }
    }
}

/// Keep even the empty editor's document under the pointer, including after resizing.
private final class SQLScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        if textView.frame.origin != .zero { textView.setFrameOrigin(.zero) }
        if textView.minSize != contentSize { textView.minSize = contentSize }
        if textView.frame.height < contentSize.height {
            textView.setFrameSize(NSSize(width: max(textView.frame.width, contentSize.width), height: contentSize.height))
        }
    }
}

final class SQLTextView: NSTextView {
    override init(frame frameRect: NSRect) {
        // The shared gutter and line decoration use NSLayoutManager, as in CodeTextView.
        // Build TextKit 1 directly instead of switching the lazy TextKit 2 viewport after attachment.
        let container = NSTextContainer(containerSize: NSSize(width: max(frameRect.width, 1), height: CGFloat.greatestFiniteMagnitude))
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var completionItems: [String] = []
    var onRun: (() -> Void)?
    var executions: [DatabaseSQLStatementExecution] = [] {
        didSet {
            if executions != oldValue { needsDisplay = true; gutter?.needsDisplay = true; executionStripe?.needsDisplay = true }
        }
    }
    private var pointerTrackingArea: NSTrackingArea?
    weak var gutter: LineNumberGutterView?
    weak var executionStripe: SQLExecutionStripe?
    var visibleExecutions: [DatabaseSQLStatementExecution] {
        var seen = Set<NSRange>()
        let length = (string as NSString).length
        return executions.reversed().filter {
            guard $0.sourceSQL == string, let range = $0.sourceRange, range.location != NSNotFound,
                  range.length > 0, range.location >= 0, range.location <= length, range.length <= length - range.location else { return false }
            return seen.insert(range).inserted
        }
    }
    private var caretLineRect = NSRect.zero

    override func setSelectedRange(_ charRange: NSRange) {
        let oldLine = LitheTextViewportLayout.consoleCaretLineRect(in: self)
        super.setSelectedRange(charRange)
        synchronizeCaretPresentation(from: oldLine)
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        let oldLine = LitheTextViewportLayout.consoleCaretLineRect(in: self)
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: flag)
        synchronizeCaretPresentation(from: oldLine)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        let oldLine = LitheTextViewportLayout.consoleCaretLineRect(in: self)
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        synchronizeCaretPresentation(from: oldLine)
    }

    func synchronizeCaretPresentation(from previousLine: NSRect? = nil) {
        guard let gutter else { return }
        let nextLine = LitheTextViewportLayout.consoleCaretLineRect(in: self)
        let oldLine = previousLine ?? caretLineRect
        guard nextLine != oldLine else { return }
        caretLineRect = nextLine
        gutter.currentConsoleLine = TextLineIndex(source: string as NSString).lineNumber(at: selectedRange().location) + 1
        // AppKit withholds selection notifications while tracking. Repaint both rows in this event, before waiting for mouse-up.
        for line in [oldLine, nextLine] where !line.isEmpty {
            setNeedsDisplay(line.intersection(visibleRect))
            let gutterLine = NSRect(x: 0, y: line.minY - (enclosingScrollView?.documentVisibleRect.minY ?? 0),
                                    width: gutter.bounds.width, height: line.height)
            gutter.setNeedsDisplay(gutterLine.intersection(gutter.visibleRect))
        }
        displayIfNeeded()
        gutter.displayIfNeeded()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEditable }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.inVisibleRect, .activeAlways, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: isEditable ? .iBeam : .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard LitheTextViewportLayout.isPointerHitTarget(self, at: event.locationInWindow) else { return }
        (isEditable ? NSCursor.iBeam : .arrow).set()
    }
    override func mouseEntered(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        cursorUpdate(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let line = LitheTextViewportLayout.consoleCaretLineRect(in: self)
        NSColor(LitheTheme.DatabaseGrid.currentRowBackground).setFill()
        line.intersection(rect).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout = layoutManager else { return }
        var labeledLines = Set<CGFloat>()
        for execution in visibleExecutions {
            guard let range = execution.sourceRange else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let outline = statementOutline(range)
            guard outline.bounds.intersects(dirtyRect) else { continue }
            NSColor(LitheTheme.DatabaseConsole.statementOutline).setStroke()
            outline.lineWidth = 1; outline.stroke()
            let firstLine = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            // A physical row can contain several statements; their individual times remain in Output.
            guard labeledLines.insert(firstLine.minY).inserted else { continue }
            let firstBounds = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let label = " \(execution.durationMilliseconds) ms" as NSString
            label.draw(at: NSPoint(x: firstBounds.maxX + textContainerOrigin.x + 4,
                                   y: firstLine.minY + textContainerOrigin.y),
                       withAttributes: [.font: LitheTheme.uiNSFont(size: 13), .foregroundColor: NSColor(LitheTheme.DatabaseConsole.executionInfo)])
        }
    }

    func statementRect(_ range: NSRange) -> NSRect {
        let box = statementLineRects(range).reduce(NSRect.null) { $0.union($1) }
        return box.isNull ? .zero : box
    }

    func statementOutline(_ range: NSRange) -> NSBezierPath {
        let lines = statementLineRects(range)
        guard let first = lines.first, let last = lines.last else { return NSBezierPath() }
        if lines.count == 1 { return NSBezierPath(rect: first.insetBy(dx: 0.5, dy: 0.5)) }
        // EditorPainter.paintBorderEffect: the body spans the widest row; the final row ends at its own range endpoint.
        // ponytail: LTR range envelope, matching this SQL editor; split visual runs if bidi range painting is introduced.
        // Community drawLine truncates X/Y to integers; align AppKit's centered 1pt stroke to the same pixel grid.
        let left = max(bounds.minX + 0.5, floor(lines.map(\.minX).min() ?? first.minX) + 0.5)
        let right = floor(lines.map(\.maxX).max() ?? first.maxX) + 0.5
        let points = [
            NSPoint(x: floor(first.minX) + 0.5, y: floor(first.minY) + 0.5),
            NSPoint(x: right, y: floor(first.minY) + 0.5),
            NSPoint(x: right, y: floor(last.minY) - 0.5),
            NSPoint(x: floor(last.maxX) + 0.5, y: floor(last.minY) - 0.5),
            NSPoint(x: floor(last.maxX) + 0.5, y: floor(last.maxY) - 0.5),
            NSPoint(x: floor(last.minX) + 0.5, y: floor(last.maxY) - 0.5),
            NSPoint(x: floor(last.minX) + 0.5, y: floor(last.minY) - 0.5),
            NSPoint(x: left, y: floor(last.minY) - 0.5),
            NSPoint(x: left, y: floor(first.maxY) - 0.5),
            NSPoint(x: floor(first.minX) + 0.5, y: floor(first.maxY) - 0.5)
        ]
        let path = NSBezierPath()
        path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }; path.close()
        return path
    }

    func statementLineRects(_ range: NSRange) -> [NSRect] {
        guard let layout = layoutManager, let container = textContainer, range.location != NSNotFound,
              range.length > 0, NSMaxRange(range) <= string.utf16.count else { return [] }
        let source = string as NSString
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var lines: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, fragment, _ in
            var characters = layout.characterRange(forGlyphRange: NSIntersectionRange(glyphs, fragment), actualGlyphRange: nil)
            // A newline glyph spans the unused viewport; its advance is not SQL content.
            while characters.length > 0 {
                guard let scalar = UnicodeScalar(source.character(at: NSMaxRange(characters) - 1)),
                      CharacterSet.newlines.contains(scalar) else { break }
                characters.length -= 1
            }
            guard characters.length > 0 else { return }
            let content = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil), in: container)
            lines.append(NSRect(x: content.minX + self.textContainerOrigin.x, y: lineRect.minY + self.textContainerOrigin.y,
                                width: content.width, height: lineRect.height))
        }
        return lines
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isEditable, (modifiers == .command && event.keyCode == 36) || (modifiers == .command && event.keyCode == 76) {
            onRun?()
            return
        }
        if modifiers == .control, event.keyCode == 49 {
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// Execution ticks share the editor scrollbar lane; ordinary scroll/drag events pass through.
final class SQLExecutionStripe: NSView {
    var locale = Locale.current
    weak var textView: SQLTextView?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); needsDisplay = true }

    func markerRect(_ range: NSRange) -> NSRect {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return .zero }
        let box = textView.statementRect(range)
        guard !box.isEmpty else { return .zero }
        // EditorMarkupModelImpl: short documents keep their Y positions; only long documents compress.
        let targetHeight = min(bounds.height, textView.enclosingScrollView?.contentSize.height ?? bounds.height)
        let scale = min(1, targetHeight / max(1, layout.usedRect(for: container).maxY + textView.textContainerOrigin.y))
        let height = LitheScrollBarStyle.minimumMarkHeight
        return NSRect(x: bounds.width - LitheScrollBarStyle.thickness,
            y: min(max(0, targetHeight - height), floor(box.maxY * scale)),
            width: LitheScrollBarStyle.thickness, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }
        let records = textView.visibleExecutions
        for failed in [false, true] {
            NSColor(failed ? LitheTheme.DatabaseConsole.failureStripe : LitheTheme.DatabaseConsole.successStripe).setFill()
            for record in records where (record.errorMessage != nil) == failed {
                if let range = record.sourceRange { markerRect(range).fill() }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil, let textView else { return nil }
        // NSView.hitTest receives coordinates in the superview, not in this trailing overlay.
        let local = convert(point, from: superview)
        if let scroller = textView.enclosingScrollView?.verticalScroller, scroller.isEnabled, !scroller.isHidden,
           scroller.knobProportion < 1, scroller.rect(for: .knob).contains(scroller.convert(local, from: self)) { return nil }
        return textView.visibleExecutions.contains { record in
            record.sourceRange.map { markerRect($0).insetBy(dx: 0, dy: -3).contains(local) } ?? false
        } ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let textView, let record = textView.visibleExecutions.min(by: {
            abs(markerRect($0.sourceRange!).midY - point.y) < abs(markerRect($1.sourceRange!).midY - point.y)
        }), let range = record.sourceRange else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        window?.makeFirstResponder(textView)
    }

    override func scrollWheel(with event: NSEvent) { textView?.enclosingScrollView?.scrollWheel(with: event) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { DatabaseLocalization.string("SQL execution markers", locale: locale) }
    override func accessibilityValue() -> Any? {
        guard let textView else { return nil }
        let lines = TextLineIndex(source: textView.string as NSString)
        return textView.visibleExecutions.map { record in
            let line = lines.lineNumber(at: record.sourceRange!.location) + 1
            return String(format: DatabaseLocalization.string(record.errorMessage == nil ? "Succeeded, line %d" : "Failed, line %d", locale: locale), line)
        }.joined(separator: "; ")
    }
}

enum SQLSyntaxHighlighter {
    // ponytail: lexical colors only; dialect-specific syntax should move to a bundled SQL language engine.
    // One token stream keeps comment markers and SQL keywords inside quoted values untouched.
    private static let tokens = try? NSRegularExpression(pattern: #"(?<comment>--[^\n]*|#[^\n]*|/\*[\s\S]*?\*/)|(?<string>(?:\b[EeNnXxBb])?'(?:''|\\[\s\S]|[^'\\])*'|(?<dollar>\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$)[\s\S]*?\k<dollar>)|(?<identifier>"(?:""|[^"])*"|`(?:``|[^`])*`|\[(?:\]\]|[^\]])*\])|(?<keyword>(?i:\b(?:SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|DELETE|MERGE|REPLACE|CREATE|ALTER|DROP|TRUNCATE|TABLE|VIEW|INDEX|DATABASE|SCHEMA|TRIGGER|PROCEDURE|FUNCTION|JOIN|LEFT|RIGHT|INNER|OUTER|FULL|CROSS|ON|AS|AND|OR|NOT|NULL|IS|IN|EXISTS|BETWEEN|LIKE|DISTINCT|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|UNION|INTERSECT|EXCEPT|ALL|WITH|RETURNING|SET|SHOW|DESCRIBE|DESC|EXPLAIN|PRAGMA|BEGIN|COMMIT|ROLLBACK|GRANT|REVOKE|CASE|WHEN|THEN|ELSE|END|ASC)\b))|(?<number>\b\d+(?:\.\d+)?(?:[Ee][+-]?\d+)?\b)|(?<operation>[+*/%<>=~!@^|&?-]+)"#)

    static func apply(to storage: NSTextStorage, font: NSFont, isDark: Bool) {
        let range = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .paragraphStyle: LitheTheme.editorParagraphStyle,
                               .foregroundColor: NSColor(LitheTheme.DatabaseGrid.text)], range: range)
        for token in tokens?.matches(in: storage.string, range: range) ?? [] {
            let color: Color
            if token.range(withName: "comment").location != NSNotFound {
                color = LitheTheme.DatabaseConsole.comment
                if !isDark { storage.addAttribute(.font, value: LitheTheme.editorFont(size: font.pointSize, italic: true), range: token.range) }
            } else if token.range(withName: "string").location != NSNotFound { color = LitheTheme.DatabaseConsole.string }
            else if token.range(withName: "identifier").location != NSNotFound { color = LitheTheme.DatabaseGrid.text }
            else if token.range(withName: "number").location != NSNotFound { color = LitheTheme.DatabaseConsole.number }
            else { color = LitheTheme.DatabaseConsole.keyword }
            storage.addAttribute(.foregroundColor, value: NSColor(color), range: token.range)
        }
        storage.endEditing()
    }
}

/// Overview uses the existing database state; closing its tab does not release connections or drafts.
struct DatabaseOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @State private var showsConnectionEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 24) {
                    statistic("Connections", value: feature.profiles.count)
                    statistic("Connected", value: feature.connectedProfileCount)
                    statistic("Database types", value: Set(feature.profiles.map(\.kind)).count)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                LitheToolWindowHeaderDivider()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        quickStart.frame(minWidth: 300, maxWidth: .infinity)
                        commonActions.frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        quickStart
                        commonActions
                    }
                }
                recentSQL
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .litheScrollViewChrome()
        .litheWorkbenchSurface(LitheTheme.editor)
        .background(LitheCenteredPopup(isPresented: $showsConnectionEditor,
                                       dialogTitle: String(localized: "Add Database Connection")) {
            DatabaseConnectionEditor(isPresented: $showsConnectionEditor)
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
        })
    }

    private func statistic(_ title: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(value.formatted()).font(LitheTheme.uiFont(size: 22, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 0) {
            LitheToolWindowHeader(title: "Quick Start")
            LitheToolWindowHeaderDivider()
            if feature.profiles.isEmpty {
                Text("No saved connections yet.")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(12)
            } else {
                ForEach(feature.profiles) { profile in
                    Button { open(profile, query: false) } label: {
                        HStack(spacing: 10) {
                            DatabaseBrandIcon(kind: profile.kind, size: LitheTheme.Metrics.toolbarIconSize)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).foregroundStyle(LitheTheme.primaryText)
                                Text(profile.kind == .sqlite ? profile.path : "\(profile.host):\(profile.port)")
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                            .lineLimit(1)
                            Spacer()
                            status(profile)
                        }
                        .font(LitheTheme.uiFont(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .litheRowHover()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var commonActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            LitheToolWindowHeader(title: "Common Actions")
            LitheToolWindowHeaderDivider()
            action("New Connection", icon: "expui/general/add.svg") { showsConnectionEditor = true }
            action("New Query", icon: "expui/fileTypes/shell.svg",
                   enabled: feature.profiles.contains { $0.kind.isSQLDatabase }) {
                if let profile = feature.selectedProfile.flatMap({ $0.kind.isSQLDatabase ? $0 : nil })
                    ?? feature.profiles.first(where: { $0.kind.isSQLDatabase }) {
                    open(profile, query: true)
                }
            }
            action("Browse Database", icon: "expui/toolwindows/toolWindowDataView@20x20.svg",
                   enabled: !feature.profiles.isEmpty) {
                if let profile = feature.selectedProfile ?? feature.profiles.first { open(profile, query: false) }
            }
            action("History", icon: "expui/general/history.svg") { openHistory() }
        }
    }

    private var recentSQL: some View {
        VStack(alignment: .leading, spacing: 0) {
            LitheToolWindowHeader(title: "Recent SQL") {
                Button { openHistory() } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/history.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                  preservesOriginalColors: true)
                }
                .litheToolbarIconButton().workbenchHoverHelp(Text("SQL History"))
                .accessibilityLabel("SQL History")
            }
            LitheToolWindowHeaderDivider()
            if feature.sqlHistory.isEmpty {
                Text("No SQL history yet.")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(12)
            } else {
                ForEach(Array(feature.sqlHistory.prefix(8))) { entry in
                    Button {
                        if let profile = feature.profiles.first(where: { $0.id == entry.profileID }) {
                            open(profile, query: true, history: entry)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                                .foregroundStyle(LitheTheme.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Text(entry.executedAt, style: .relative)
                                .font(LitheTheme.uiFont(size: 11))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .litheRowHover(hoverBackground: feature.profiles.first(where: { $0.id == entry.profileID })?.kind.isSQLDatabase == true ? LitheTheme.hoverBackground : .clear)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(feature.profiles.first(where: { $0.id == entry.profileID })?.kind.isSQLDatabase != true)
                }
            }
        }
        .workbenchHoverTooltipScope()
    }

    private func action(_ title: LocalizedStringKey, icon: String, enabled: Bool = true,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                LitheIDEAIcon(resourcePath: icon, size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                Text(title).font(LitheTheme.uiFont(size: 12))
            }
            .foregroundStyle(enabled ? LitheTheme.primaryText : LitheTheme.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .litheRowHover(hoverBackground: enabled ? LitheTheme.hoverBackground : .clear)
        .disabled(!enabled)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func status(_ profile: DatabaseProfile) -> some View {
        switch feature.connectionStatus(for: profile) {
        case .idle: Text("Not connected").foregroundStyle(LitheTheme.secondaryText)
        case .connecting: Text("Connecting").foregroundStyle(LitheTheme.secondaryText)
        case .connected: Text("Connected").foregroundStyle(LitheTheme.success)
        case .failed: Text("Connection failed").foregroundStyle(LitheTheme.warning)
        }
    }

    private func openHistory() {
        feature.workspaceSection = .history
        model.openDatabaseWorkspace()
    }

    private func open(_ profile: DatabaseProfile, query: Bool, history: DatabaseSQLHistoryEntry? = nil) {
        if query {
            model.openDatabaseQuery(profileID: profile.id, sql: history?.sql ?? "")
        } else {
            model.selectDatabaseWorkspace(profileID: profile.id)
            guard feature.selectedProfileID == profile.id, model.databaseFeatureIfActive === feature else { return }
            feature.workspaceSection = .data
        }
    }
}

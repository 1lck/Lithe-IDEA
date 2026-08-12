import AppKit
import SwiftUI

struct DatabaseWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.databaseFeature.selectedProfile == nil {
                DatabaseDashboardView(
                    onOpenConnection: { profile in
                        Task { await model.databaseFeature.select(profile) }
                    },
                    onNewQuery: { profile in
                        Task {
                            await model.databaseFeature.select(profile)
                            guard model.databaseFeature.selectedProfileID == profile.id else { return }
                            model.databaseFeature.workspaceSection = .sql
                        }
                    }
                )
            } else if model.databaseFeature.selectedProfile?.kind == .redis {
                RedisWorkspaceView()
            } else if model.databaseFeature.selectedProfile?.kind == .nacos {
                NacosWorkspaceView()
            } else if model.databaseFeature.selectedProfile?.kind == .mongodb {
                mongoWorkspace
            } else {
                sqlWorkspace
            }
        }
        .background(LitheTheme.editor)
    }

    private var sqlWorkspace: some View {
        VStack(spacing: 0) {
            if !model.databaseFeature.openTableTabs.isEmpty {
                DatabaseOpenTableTabsView()
            }

            workspaceSectionNavigation

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            switch model.databaseFeature.workspaceSection {
            case .data:
                DatabaseTableView()
            case .sql:
                DatabaseSQLWorkspaceView()
            case .structure:
                DatabaseStructureView()
            case .history:
                DatabaseHistoryView()
            }
        }
    }

    private var workspaceSectionNavigation: some View {
        HStack {
            Picker(
                "Database workspace",
                selection: Binding(
                    get: { model.databaseFeature.workspaceSection },
                    set: { model.databaseFeature.workspaceSection = $0 }
                )
            ) {
                ForEach(DatabaseWorkspaceSection.allCases) { section in
                    Label(section.titleKey, systemImage: section.symbol).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 276, height: 28)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(LitheTheme.toolHeader)
    }

    private var mongoWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if let profile = model.databaseFeature.selectedProfile {
                    DatabaseBrandIcon(kind: .mongodb, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MongoDB Documents").font(.system(size: 12, weight: .semibold))
                        Text(profile.database.isEmpty ? "admin" : profile.database)
                            .font(.system(size: 9.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                Spacer()
                Text("Collection data can be edited directly in the grid.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            DatabaseTableView()
        }
    }
}

private struct DatabaseDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsConnectionEditor = false
    let onOpenConnection: (DatabaseProfile) -> Void
    let onNewQuery: (DatabaseProfile) -> Void

    private var profiles: [DatabaseProfile] { model.databaseFeature.profiles }
    private var sqlProfiles: [DatabaseProfile] { profiles.filter { $0.kind.isSQLDatabase } }
    private var databaseTypeCount: Int { Set(profiles.map(\.kind)).count }
    private var connectedCount: Int { model.databaseFeature.connectedProfileCount }
    private let dashboardColumns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1)
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            metricCard(title: "Connections", value: profiles.count, symbol: "cylinder.split.1x2")
                            metricCard(title: "Connected", value: connectedCount, symbol: "checkmark.shield")
                            metricCard(title: "Database types", value: databaseTypeCount, symbol: "sparkles")
                        }

                        HStack(alignment: .top, spacing: 12) {
                            dashboardSection(title: "Quick Start", symbol: "bolt") {
                                quickStartContent
                            }

                            dashboardSection(title: "Common Actions", symbol: "wand.and.stars") {
                                LazyVGrid(columns: dashboardColumns, spacing: 1) {
                                    dashboardAction("New Connection", symbol: "plus") { showsConnectionEditor = true }
                                    dashboardAction("New Query", symbol: "doc.badge.plus", isEnabled: !sqlProfiles.isEmpty) {
                                        if let first = sqlProfiles.first { onNewQuery(first) }
                                    }
                                    dashboardAction("Browse Database", symbol: "tablecells", isEnabled: !profiles.isEmpty) {
                                        if let first = profiles.first { onOpenConnection(first) }
                                    }
                                    dashboardAction("History", symbol: "clock.arrow.circlepath") {
                                        withAnimation { proxy.scrollTo("recent-sql", anchor: .top) }
                                    }
                                }
                                .background(LitheTheme.divider)
                            }
                            .frame(width: 270)
                        }

                        dashboardSection(
                            title: "Recent SQL",
                            symbol: "clock.arrow.circlepath",
                            minHeight: max(160, min(320, geometry.size.height - 288))
                        ) {
                            if model.databaseFeature.sqlHistory.isEmpty {
                                dashboardEmpty("No SQL history yet.")
                            } else {
                                ForEach(Array(model.databaseFeature.sqlHistory.prefix(8))) { entry in
                                    Button { openHistoryEntry(entry) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "terminal")
                                                .foregroundStyle(LitheTheme.accent)
                                            Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .lineLimit(1)
                                            Spacer()
                                            Text(entry.executedAt, style: .relative)
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(LitheTheme.tertiaryText)
                                        }
                                        .padding(.horizontal, 12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .frame(height: 36)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(profiles.first(where: { $0.id == entry.profileID })?.kind.isSQLDatabase != true)
                                    .litheRowHover(cornerRadius: 0)
                                }
                            }
                        }
                        .id("recent-sql")
                    }
                    .padding(16)
                }
            }
        }
        .background(LitheTheme.editor)
        .sheet(isPresented: $showsConnectionEditor) {
            DatabaseConnectionEditor(isPresented: $showsConnectionEditor)
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
        }
    }

    @ViewBuilder
    private var quickStartContent: some View {
        if profiles.isEmpty {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "cylinder.split.1x2")
                        .foregroundStyle(LitheTheme.tertiaryText)
                    Text("No saved connections yet.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                Button { showsConnectionEditor = true } label: {
                    Label("New Connection", systemImage: "plus")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(LitheTheme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                                .stroke(LitheTheme.panelBorder, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .lithePointer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 97)
        } else {
            let quickProfiles = profiles
            ForEach(quickProfiles) { profile in
                quickStartRow(profile)
                if profile.id != quickProfiles.last?.id || quickProfiles.count == 1 {
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                }
            }
            if quickProfiles.count == 1 {
                quickStartAddConnectionRow
            }
        }
    }

    private var quickStartAddConnectionRow: some View {
        Button { showsConnectionEditor = true } label: {
            Label("New Connection", systemImage: "plus")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .litheRowHover(cornerRadius: 0)
    }

    private func quickStartRow(_ profile: DatabaseProfile) -> some View {
        HStack(spacing: 0) {
            Button { onOpenConnection(profile) } label: {
                HStack(spacing: 10) {
                    DatabaseBrandIcon(kind: profile.kind, size: 18)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(profile.colorHex.isEmpty ? LitheTheme.accent : Color(hex: profile.colorHex))
                        .frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(connectionSubtitle(profile))
                            .font(.system(size: 9.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    Spacer()
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if profile.kind.isSQLDatabase {
                Button { onNewQuery(profile) } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
                .help("New Query")
                .accessibilityLabel("New Query")
                .padding(.trailing, 6)
            }
        }
        .lithePointer()
        .litheRowHover(cornerRadius: 0)
    }

    private func openHistoryEntry(_ entry: DatabaseSQLHistoryEntry) {
        guard let profile = profiles.first(where: { $0.id == entry.profileID }), profile.kind.isSQLDatabase else { return }
        Task {
            await model.databaseFeature.select(profile)
            guard model.databaseFeature.selectedProfileID == profile.id else { return }
            model.databaseFeature.workspaceSection = .sql
            model.databaseFeature.restoreSQLHistory(entry)
        }
    }

    private func metricCard(title: LocalizedStringKey, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("\(value)")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundStyle(LitheTheme.primaryText)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(LitheTheme.panelBorder, lineWidth: 1) }
    }

    private func dashboardSection<Content: View>(
        title: LocalizedStringKey,
        symbol: String,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 13)
                .frame(height: 40)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(LitheTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(LitheTheme.panelBorder, lineWidth: 1) }
    }

    private func dashboardAction(
        _ title: LocalizedStringKey,
        symbol: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
        .background(LitheTheme.raised)
        .lithePointer()
        .litheRowHover(cornerRadius: 0)
    }

    private func dashboardEmpty(_ message: LocalizedStringKey) -> some View {
        Text(message)
            .font(.system(size: 10.5))
            .foregroundStyle(LitheTheme.tertiaryText)
            .padding(16)
    }

    private func connectionSubtitle(_ profile: DatabaseProfile) -> String {
        if profile.kind == .sqlite { return "SQLite · \(URL(fileURLWithPath: profile.path).lastPathComponent)" }
        return "\(profile.kind.displayName) · \(profile.host):\(profile.port)"
    }
}

enum DatabaseWorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case data
    case sql
    case structure
    case history

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .data: "Data"
        case .sql: "SQL"
        case .structure: "Structure"
        case .history: "History"
        }
    }
    var symbol: String {
        switch self {
        case .data: "tablecells"
        case .sql: "terminal"
        case .structure: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        }
    }
}

private struct DatabaseHistoryView: View {
    @EnvironmentObject private var model: AppModel

    private var entries: [DatabaseSQLHistoryEntry] {
        guard let profileID = model.databaseFeature.selectedProfileID else { return [] }
        return model.databaseFeature.sqlHistory.filter { $0.profileID == profileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(LitheTheme.accent)
                Text("SQL History").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(entries.count) statements")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if entries.isEmpty {
                LitheUnavailableView("No query history", systemImage: "clock.arrow.circlepath")
            } else {
                List(entries) { entry in
                    Button {
                        model.databaseFeature.restoreSQLHistory(entry)
                        model.databaseFeature.workspaceSection = .sql
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "terminal").foregroundStyle(LitheTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .lineLimit(2)
                                Text(entry.executedAt, format: .dateTime.year().month().day().hour().minute().second())
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(LitheTheme.tertiaryText)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
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
    @EnvironmentObject private var model: AppModel
    @State private var pendingRisk: DatabaseSQLAnalysis?
    @State private var pendingScope: DatabaseSQLExecutionScope = .all
    @State private var pendingTabID: UUID?
    @State private var showsRiskConfirmation = false
    @State private var sqlSelection = ""

    var body: some View {
        VStack(spacing: 0) {
            queryTabs
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            commandBar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            editor
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            results
        }
        .background(LitheTheme.editor)
        .alert("Confirm database change", isPresented: $showsRiskConfirmation, presenting: pendingRisk) { analysis in
            Button("Cancel", role: .cancel) {
                pendingRisk = nil
                pendingTabID = nil
            }
            Button(analysis.statementCount > 1 ? "Run batch" : "Run statement", role: .destructive) {
                if let tabID = pendingTabID {
                    Task { await model.databaseFeature.runSQL(in: tabID, scope: pendingScope, confirmedRisk: true) }
                }
                pendingRisk = nil
                pendingTabID = nil
            }
        } message: { analysis in
            DatabaseLocalization.text(analysis.warning ?? "This statement can change the database.")
        }
        .onChange(of: model.databaseFeature.selectedSQLTabID) { _ in
            sqlSelection = ""
        }
    }

    private var queryTabs: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.databaseFeature.sqlTabs) { tab in
                        HStack(spacing: 2) {
                            Button { model.databaseFeature.selectedSQLTabID = tab.id } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: tab.isRunning ? "arrow.triangle.2.circlepath" : "terminal")
                                        .font(.system(size: 10))
                                    DatabaseLocalization.queryTabTitle(tab.title).lineLimit(1)
                                }
                                .font(.system(size: 11.5))
                                .foregroundStyle(model.databaseFeature.selectedSQLTabID == tab.id ? LitheTheme.primaryText : LitheTheme.secondaryText)
                                .padding(.leading, 10)
                                .frame(height: 31)
                            }
                            .buttonStyle(.plain)

                            Button { model.databaseFeature.closeSQLTab(tab.id) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .litheIconButton()
                            .foregroundStyle(LitheTheme.secondaryText)
                            .padding(.trailing, 5)
                            .help("Close query tab")
                        }
                        .background(model.databaseFeature.selectedSQLTabID == tab.id ? LitheTheme.activeTabBackground : LitheTheme.inactiveTabBackground)
                        .overlay(alignment: .bottom) {
                            if model.databaseFeature.selectedSQLTabID == tab.id {
                                Rectangle().fill(LitheTheme.accent).frame(height: 2)
                            }
                        }
                    }
                }
            }
            Button { model.databaseFeature.addSQLTab() } label: { Image(systemName: "plus") }
                .litheIconButton()
                .help("New query tab")
                .padding(.horizontal, 5)
        }
        .frame(height: 32)
        .background(LitheTheme.sidebar)
    }

    private var commandBar: some View {
        HStack(spacing: 5) {
            Button(action: runSelectedQuery) {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.databaseFeature.selectedSQLTab?.isRunning == true || model.databaseFeature.selectedProfile == nil)
            .help(hasSQLSelection ? "Run selected SQL (Command-Return)" : "Run all SQL (Command-Return)")

            Menu {
                Button { runAllQuery() } label: {
                    Label("Run All", systemImage: "play.fill")
                }
                Button { runSelectionQuery() } label: {
                    Label("Run Selection", systemImage: "text.cursor")
                }
                .disabled(!hasSQLSelection)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 18)
            .disabled(model.databaseFeature.selectedSQLTab?.isRunning == true || model.databaseFeature.selectedProfile == nil)
            .help("Choose SQL execution scope")

            Button { if let id = model.databaseFeature.selectedSQLTabID { model.databaseFeature.formatSQL(in: id) } } label: {
                Image(systemName: "text.alignleft")
            }
            .litheIconButton()
            .disabled(model.databaseFeature.selectedSQLTab?.sql.isEmpty != false)
            .help("Format SQL")

            Menu {
                let history = historyForSelectedProfile
                if history.isEmpty {
                    Text("No query history")
                } else {
                    ForEach(history) { entry in
                        Button(historyLabel(entry)) { model.databaseFeature.restoreSQLHistory(entry) }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("Query history")

            if let execution = model.databaseFeature.selectedSQLTab?.execution {
                executionLabel(execution)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            if let profile = model.databaseFeature.selectedProfile {
                Text(profile.database.isEmpty ? (profile.path.isEmpty ? profile.name : profile.path) : profile.database)
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
            } else {
                Text("No connection")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.warning)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 37)
        .background(LitheTheme.toolHeader)
    }

    @ViewBuilder
    private var editor: some View {
        if let tab = model.databaseFeature.selectedSQLTab {
            SQLSyntaxEditor(
                text: Binding(
                    get: { model.databaseFeature.selectedSQLTab?.sql ?? "" },
                    set: { model.databaseFeature.updateSQL($0, in: tab.id) }
                ),
                completions: model.databaseFeature.sqlCompletionItems,
                onRun: runSelectedQuery,
                onSelectionChange: { sqlSelection = $0 }
            )
            .id(tab.id)
            .frame(minHeight: 180, idealHeight: 240, maxHeight: 320)
            .overlay(alignment: .bottomLeading) {
                if let error = tab.errorMessage {
                    Label {
                        DatabaseLocalization.error(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.error)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LitheTheme.toolHeader)
                }
            }
        } else {
            LitheUnavailableView("No Query Tab", systemImage: "terminal")
        }
    }

    @ViewBuilder
    private var results: some View {
        if let tab = model.databaseFeature.selectedSQLTab,
           let result = tab.result {
            DatabaseQueryResultGrid(columns: tab.resultColumns, rows: result.rows)
                .overlay(alignment: .topTrailing) {
                    if result.truncated {
                        Text("Limited to 10,000 rows")
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.warning)
                            .padding(8)
                    }
                }
        } else if let affected = model.databaseFeature.selectedSQLTab?.rowsAffected {
            let count = model.databaseFeature.selectedSQLTab.map { model.databaseFeature.analysis(forSQLTab: $0.id).statementCount } ?? 1
            LitheUnavailableView(count > 1 ? "Statements completed" : "Statement completed", systemImage: "checkmark.circle", description: Text("Rows affected: \(affected)"))
                .foregroundStyle(LitheTheme.secondaryText)
        } else {
            LitheUnavailableView("Query Results", systemImage: "tablecells", description: Text("Run a SELECT, SHOW, DESCRIBE, or EXPLAIN statement to inspect results."))
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private var historyForSelectedProfile: [DatabaseSQLHistoryEntry] {
        guard let profileID = model.databaseFeature.selectedProfileID else { return [] }
        return model.databaseFeature.sqlHistory.filter { $0.profileID == profileID }
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
        guard let tabID = model.databaseFeature.selectedSQLTabID else { return }
        let analysis = model.databaseFeature.analysis(forSQLTab: tabID, scope: scope)
        if analysis.requiresConfirmation {
            pendingRisk = analysis
            pendingScope = scope
            pendingTabID = tabID
            showsRiskConfirmation = true
        } else {
            Task { await model.databaseFeature.runSQL(in: tabID, scope: scope) }
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

    private func historyLabel(_ entry: DatabaseSQLHistoryEntry) -> String {
        let singleLine = entry.sql.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 72 ? "\(singleLine.prefix(72))..." : singleLine
    }
}

private struct DatabaseQueryResultGrid: View {
    let columns: [String]
    let rows: [DatabaseRow]

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            HStack(spacing: 0) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .frame(width: 44, height: 27)
                                    .background(LitheTheme.toolHeader)
                                ForEach(columns, id: \.self) { column in
                                    Text(display(row[column]))
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .padding(.horizontal, 7)
                                        .frame(width: 180, height: 27, alignment: .leading)
                                        .overlay(alignment: .trailing) { Rectangle().fill(LitheTheme.divider).frame(width: 1) }
                                }
                            }
                            .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Text("#").frame(width: 44, height: 29)
                            ForEach(columns, id: \.self) { column in
                                Text(column)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .frame(width: 180, height: 29, alignment: .leading)
                                    .overlay(alignment: .trailing) { Rectangle().fill(LitheTheme.divider).frame(width: 1) }
                            }
                        }
                        .foregroundStyle(LitheTheme.secondaryText)
                        .background(LitheTheme.raised)
                    }
                }
                .frame(minWidth: max(geometry.size.width, CGFloat(columns.count) * 180 + 44), alignment: .topLeading)
            }
        }
    }

    private func display(_ value: DatabaseValue?) -> String {
        value?.displayText ?? "NULL"
    }
}

private struct DatabaseStructureView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: DatabaseSchemaEditorKind?
    @State private var pendingChange: DatabaseSchemaChange?
    @State private var showsDestructiveConfirmation = false

    var body: some View {
        if let table = model.databaseFeature.selectedTable {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(table).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button { editor = .column } label: { Image(systemName: "plus") }.litheIconButton().help("Add column")
                    Button { editor = .index } label: { Image(systemName: "plus.square.on.square") }.litheIconButton().help("Add index")
                    Button { editor = .foreignKey } label: { Image(systemName: "link.badge.plus") }.litheIconButton().help("Add foreign key")
                    Button { Task { await model.databaseFeature.openTable(table) } } label: { Image(systemName: "arrow.clockwise") }.litheIconButton().help("Refresh structure")
                }
                .padding(.horizontal, 10).frame(height: 36).background(LitheTheme.toolHeader)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                List {
                    Section("Columns") {
                        ForEach(model.databaseFeature.columns, id: \.self) { column in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(column)
                                    Text(model.databaseFeature.columnTypes[column] ?? "")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                }
                                Spacer()
                                HStack(spacing: 2) {
                                    Button {
                                        editor = .renameColumn(column)
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .litheIconButton()
                                    .help("Rename Column…")

                                    Button(role: .destructive) {
                                        pendingChange = DatabaseSchemaChange(operation: "dropColumn", table: table, name: column)
                                        showsDestructiveConfirmation = true
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(LitheTheme.error)
                                    }
                                    .litheIconButton()
                                    .help("Drop Column")
                                }
                            }
                        }
                    }
                    Section("Indexes") {
                        if model.databaseFeature.indexes.isEmpty { Text("No indexes").foregroundStyle(LitheTheme.secondaryText) }
                        ForEach(Array(model.databaseFeature.indexes.enumerated()), id: \.offset) { _, row in
                            Text(metadata(row))
                        }
                    }
                    Section("Foreign Keys") {
                        if model.databaseFeature.foreignKeys.isEmpty { Text("No foreign keys").foregroundStyle(LitheTheme.secondaryText) }
                        ForEach(Array(model.databaseFeature.foreignKeys.enumerated()), id: \.offset) { _, row in
                            Text(metadata(row))
                        }
                    }
                }
                .listStyle(.inset)
            }
            .sheet(item: $editor) { editor in
                DatabaseSchemaEditorView(
                    kind: editor,
                    table: table,
                    columns: model.databaseFeature.columns,
                    onSave: { change in
                        self.editor = nil
                        Task { _ = await model.databaseFeature.applySchemaChange(change, confirmed: false) }
                    }
                )
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
            }
            .alert("Drop database object?", isPresented: $showsDestructiveConfirmation, presenting: pendingChange) { change in
                Button("Cancel", role: .cancel) { pendingChange = nil }
                Button("Drop", role: .destructive) {
                    Task { _ = await model.databaseFeature.applySchemaChange(change, confirmed: true) }
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
    @Environment(\.dismiss) private var dismiss
    let kind: DatabaseSchemaEditorKind
    let table: String
    let columns: [String]
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

    var body: some View {
        VStack(spacing: 0) {
            Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Form {
                switch kind {
                case .column:
                    TextField("Column name", text: $name)
                    TextField("SQL type", text: $dataType)
                    Toggle("Allow NULL", isOn: $nullable)
                    TextField("Default expression (optional)", text: $defaultValue)
                case let .renameColumn(column):
                    TextField("Current name", text: Binding(get: { column }, set: { oldName = $0 })).disabled(true)
                    TextField("New name", text: $name)
                case .index:
                    TextField("Index name", text: $indexName)
                    ForEach(columns, id: \.self) { column in
                        Toggle(column, isOn: Binding(get: { indexColumns.contains(column) }, set: { value in if value { indexColumns.insert(column) } else { indexColumns.remove(column) } }))
                    }
                case .foreignKey:
                    TextField("Constraint name", text: $constraintName)
                    TextField("Referenced table", text: $referencedTable)
                    TextField("Referenced columns (comma separated)", text: $referencedColumns)
                    ForEach(columns, id: \.self) { column in
                        Toggle(column, isOn: Binding(get: { indexColumns.contains(column) }, set: { value in if value { indexColumns.insert(column) } else { indexColumns.remove(column) } }))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { onSave(makeChange()); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 480, height: editorHeight)
        .onAppear {
            if case let .renameColumn(column) = kind { oldName = column }
        }
    }

    private var title: String {
        switch kind {
        case .column: "Add Column"
        case .renameColumn: "Rename Column"
        case .index: "Add Index"
        case .foreignKey: "Add Foreign Key"
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
    @State private var diagnosticKind = "tableSize"
    @State private var pendingRollback: DatabaseRecoveryPoint?
    @State private var showsRollbackConfirmation = false
    @State private var showsBackupSchedule = false

    var body: some View {
        let tab = model.databaseFeature.selectedSQLTab
        let analysis = tab.map { model.databaseFeature.analysis(forSQLTab: $0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("Diagnostic", selection: $diagnosticKind) {
                    Text("Table size").tag("tableSize")
                    Text("Locks").tag("locks")
                    Text("Slow queries").tag("slowQueries")
                    Text("Indexes").tag("indexes")
                    Text("Data quality").tag("dataQuality")
                    Text("Schema impact").tag("schemaImpact")
                }
                .frame(width: 170)
                Button { loadDiagnostics() } label: { Image(systemName: "arrow.clockwise") }.litheIconButton().help("Run diagnostic")
                Button { if let profileID = model.databaseFeature.selectedProfileID { Task { _ = await model.databaseFeature.createBackup(profileID: profileID) } } } label: { Image(systemName: "archivebox") }.litheIconButton().help("Create database backup")
                Button { showsBackupSchedule = true } label: { Image(systemName: "calendar.badge.clock") }.litheIconButton().help("Configure backup schedule")
                if let progress = model.databaseFeature.backupProgress {
                    ProgressView(value: progress)
                        .frame(width: 90)
                        .help("Backing up database")
                }
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 36).background(LitheTheme.toolHeader)
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
                    let events = model.databaseFeature.executionEvents
                        .filter { $0.profileID == model.databaseFeature.selectedProfileID }
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
                                            .font(.system(size: 11, weight: .medium))
                                        Spacer()
                                        Text("\(event.durationMilliseconds) ms")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                    if let error = event.errorMessage {
                                        Text(error)
                                            .font(.system(size: 10))
                                            .foregroundStyle(LitheTheme.error)
                                            .lineLimit(2)
                                    } else if let rows = event.rowsReturned {
                                        Text("\(rows) rows returned")
                                            .font(.system(size: 10))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Recent executions") {
                    let entries = model.databaseFeature.sqlHistory
                        .filter { $0.profileID == model.databaseFeature.selectedProfileID }
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
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                }
                                Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                Section("Recovery points") {
                    let points = model.databaseFeature.recoveryPoints.prefix(10)
                    if points.isEmpty { Text("No recovery point yet").foregroundStyle(LitheTheme.secondaryText) }
                    ForEach(points) { point in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                DatabaseLocalization.text(point.reason)
                                Text("\(point.byteCount) bytes")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                            Spacer()
                            Button { pendingRollback = point; showsRollbackConfirmation = true } label: { Image(systemName: "arrow.uturn.backward") }
                                .litheIconButton().help("Restore recovery point")
                        }
                    }
                }
                Section("Audit") {
                    let entries = model.databaseFeature.auditEntries
                        .filter { $0.profileID == model.databaseFeature.selectedProfileID }
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
            if let result = model.databaseFeature.lastDiagnostics {
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
                Task { _ = await model.databaseFeature.rollback(to: point) }
                pendingRollback = nil
            }
        } message: { point in
            Text("This will restore the saved SQL snapshot from \(point.reason). Current data may be overwritten.")
        }
        .sheet(isPresented: $showsBackupSchedule) {
            if let profile = model.databaseFeature.selectedProfile {
                DatabaseBackupScheduleEditor(profile: profile)
                    .environment(\.locale, model.settings.language.locale)
                    .id(model.settings.language)
            }
        }
    }

    private func loadDiagnostics() {
        Task {
            _ = await model.databaseFeature.loadDiagnostics(DatabaseDiagnosticsRequest(kind: diagnosticKind, schema: "", table: model.databaseFeature.selectedTable ?? ""))
        }
    }
}

private struct DatabaseBackupScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let profile: DatabaseProfile
    @State private var enabled = true
    @State private var intervalHours = 24
    @State private var retentionCount = 14

    var body: some View {
        VStack(spacing: 0) {
            Text("Backup Schedule").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
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
                    model.databaseFeature.configureBackupSchedule(profileID: profile.id, isEnabled: enabled, intervalHours: intervalHours, retentionCount: retentionCount)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420, height: 280)
        .onAppear {
            if let schedule = model.databaseFeature.backupSchedules.first(where: { $0.profileID == profile.id }) {
                enabled = schedule.isEnabled
                intervalHours = schedule.intervalHours
                retentionCount = schedule.retentionCount
            }
        }
    }
}

private struct SQLSyntaxEditor: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let completions: [String]
    let onRun: () -> Void
    let onSelectionChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, completions: completions, onRun: onRun, onSelectionChange: onSelectionChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let isDark = colorScheme == .dark
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        applyAppearance(to: textView, in: scrollView, isDark: isDark)
        textView.textContainerInset = NSSize(width: 11, height: 9)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.completionItems = completions
        textView.onRun = onRun
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.textView = textView
        context.coordinator.isDarkAppearance = isDark
        context.coordinator.highlight()
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SQLTextView else { return }
        let isDark = colorScheme == .dark
        let appearanceChanged = context.coordinator.isDarkAppearance != isDark
        context.coordinator.isDarkAppearance = isDark
        context.coordinator.completions = completions
        context.coordinator.onSelectionChange = onSelectionChange
        textView.completionItems = completions
        textView.onRun = onRun
        if appearanceChanged {
            applyAppearance(to: textView, in: scrollView, isDark: isDark)
            context.coordinator.highlight()
        }
        if textView.string != text, !textView.hasMarkedText(), !context.coordinator.isApplyingChange {
            let selection = textView.selectedRange()
            textView.string = text
            let location = min(selection.location, text.utf16.count)
            let length = min(selection.length, text.utf16.count - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            context.coordinator.highlight()
        }
    }

    private func applyAppearance(to textView: NSTextView, in scrollView: NSScrollView, isDark: Bool) {
        let background = isDark
            ? NSColor(srgbRed: 0.075, green: 0.082, blue: 0.102, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let foreground = isDark
            ? NSColor(srgbRed: 0.84, green: 0.84, blue: 0.84, alpha: 1)
            : NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.textColor = foreground
        textView.insertionPointColor = foreground
        textView.selectedTextAttributes = [
            .backgroundColor: isDark
                ? NSColor(srgbRed: 0.16, green: 0.31, blue: 0.54, alpha: 1)
                : NSColor(srgbRed: 0.69, green: 0.82, blue: 0.98, alpha: 1),
            .foregroundColor: foreground
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        var completions: [String]
        let onRun: () -> Void
        var onSelectionChange: (String) -> Void
        weak var textView: SQLTextView?
        var isApplyingChange = false
        var isDarkAppearance = true

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
            let range = textView.selectedRange()
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
            SQLSyntaxHighlighter.apply(to: storage, isDark: isDarkAppearance)
        }
    }
}

private final class SQLTextView: NSTextView {
    var completionItems: [String] = []
    var onRun: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (modifiers == .command && event.keyCode == 36) || (modifiers == .command && event.keyCode == 76) {
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

private enum SQLSyntaxHighlighter {
    static func apply(to storage: NSTextStorage, isDark: Bool) {
        let range = NSRange(location: 0, length: storage.length)
        let textColor = isDark
            ? NSColor(srgbRed: 0.84, green: 0.84, blue: 0.84, alpha: 1)
            : NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)
        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: textColor
        ], range: range)
        apply(pattern: "(?i)\\b(SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|DELETE|MERGE|REPLACE|CREATE|ALTER|DROP|TRUNCATE|TABLE|VIEW|INDEX|DATABASE|SCHEMA|TRIGGER|PROCEDURE|FUNCTION|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|AND|OR|NOT|NULL|IS|IN|EXISTS|BETWEEN|LIKE|DISTINCT|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|UNION|ALL|WITH|RETURNING|SET|SHOW|DESCRIBE|DESC|EXPLAIN|PRAGMA|BEGIN|COMMIT|ROLLBACK|GRANT|REVOKE)\\b", color: isDark ? NSColor(srgbRed: 0.43, green: 0.67, blue: 0.98, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.39, blue: 0.72, alpha: 1), in: storage)
        apply(pattern: "\\b\\d+(?:\\.\\d+)?\\b", color: isDark ? NSColor(srgbRed: 0.87, green: 0.69, blue: 0.38, alpha: 1) : NSColor(srgbRed: 0.55, green: 0.39, blue: 0.03, alpha: 1), in: storage)
        apply(pattern: "'(?:''|[^'])*'|\\\"(?:\\\"\\\"|[^\\\"])*\\\"|`(?:``|[^`])*`", color: isDark ? NSColor(srgbRed: 0.66, green: 0.80, blue: 0.53, alpha: 1) : NSColor(srgbRed: 0.17, green: 0.48, blue: 0.20, alpha: 1), in: storage)
        apply(pattern: "--[^\\n]*|/\\*[\\s\\S]*?\\*/", color: isDark ? NSColor(srgbRed: 0.48, green: 0.55, blue: 0.61, alpha: 1) : NSColor(srgbRed: 0.38, green: 0.42, blue: 0.46, alpha: 1), in: storage)
        storage.endEditing()
    }

    private static func apply(pattern: String, color: NSColor, in storage: NSTextStorage) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: storage.length)
        for match in expression.matches(in: storage.string, range: range) {
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

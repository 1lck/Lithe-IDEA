import AppKit
import SwiftUI
import LitheDatabaseModule

/// Uses the workbench's bottom tool-window and split-pane owners.
struct DatabaseServicesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @Environment(\.locale) private var locale
    @State private var selectedResultID: UUID?
    @State private var wrapsOutput = true
    @State private var active = false

    private var results: [DatabaseSQLStatementExecution] {
        let records = feature.selectedSQLTab?.statementExecutions ?? []
        guard let batch = records.last?.batchStartedAt else { return [] }
        return records.filter { $0.batchStartedAt == batch && $0.result != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "Services", onMinimize: {
                model.workbenchFeature.setVisibility(.databaseServices, isVisible: false)
            }) { EmptyView() }
            LitheToolWindowHeaderDivider()
            GeometryReader { geometry in
                LitheSplitPaneView(axis: .horizontal, placement: .leading,
                    defaultSize: geometry.size.width * 0.3, minimum: 120,
                    maximum: max(120, geometry.size.width - 200), flexibleMinimum: 200) {
                    connections
                } flexible: {
                    VStack(spacing: 0) {
                        resultTabs
                        LitheToolWindowHeaderDivider()
                        if let result = results.first(where: { $0.id == selectedResultID }), let data = result.result {
                            DatabaseQueryResultGrid(columns: data.resolvedColumns, rows: data.rows)
                                .overlay(alignment: .topTrailing) {
                                    if data.truncated {
                                        Text("Limited to 10,000 rows").font(LitheTheme.uiFont(size: 12))
                                            .foregroundStyle(LitheTheme.warning).padding(8)
                                    }
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    Text("\(data.rows.count) rows · \(result.durationMilliseconds) ms")
                                        .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText).padding(8)
                                }
                        } else {
                            output
                        }
                    }
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .background(LitheToolWindowActivityTracker(isActive: $active))
        .workbenchHoverTooltipScope()
        .onChange(of: results.map(\.id)) { ids in selectedResultID = ids.last }
        .onChange(of: feature.selectedSQLTabID) { _ in selectedResultID = results.last?.id }
        .onAppear { selectedResultID = results.last?.id }
    }

    private var connections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    LitheIcon(kind: .folder, size: 16)
                    Text("Database")
                }.frame(height: LitheTheme.Tree.rowHeight)
                if let profile = feature.selectedProfile {
                    HStack(spacing: 4) {
                        DatabaseBrandIcon(kind: profile.kind, size: 16)
                        Text(profile.name).lineLimit(1)
                    }.padding(.leading, LitheTheme.Tree.indent).frame(height: LitheTheme.Tree.rowHeight)
                    ForEach(feature.sqlTabs) { tab in
                        Button {
                            model.selectDatabaseWorkspace(profileID: profile.id, queryID: tab.id)
                        } label: {
                            HStack(spacing: 4) {
                                DatabaseBrandIcon(kind: profile.kind, size: 16)
                                Text(tab.title == "Query 1" ? "console" : "console \(tab.title)").lineLimit(1)
                                if let execution = tab.execution {
                                    Text("\(execution.durationMilliseconds) ms").foregroundStyle(LitheTheme.DatabaseConsole.executionInfo)
                                }
                                Spacer(minLength: 0)
                            }.padding(.leading, LitheTheme.Tree.indent * 2).frame(height: LitheTheme.Tree.rowHeight)
                        }
                        .buttonStyle(.litheNoPress)
                        .litheTreeRow(isSelected: tab.id == feature.selectedSQLTabID, isFocused: active)
                    }
                }
            }.font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.Tree.text).padding(.horizontal, 12).padding(.vertical, 4)
        }.litheScrollViewChrome()
    }

    private var resultTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tab(DatabaseLocalization.string("Output", locale: locale), icon: "expui/fileTypes/shell.svg", selected: selectedResultID == nil) { selectedResultID = nil }
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    tab(String(format: DatabaseLocalization.string("Result %d", locale: locale), index + 1), icon: "database/expui/table.svg",
                        selected: selectedResultID == result.id) { selectedResultID = result.id }
                }
            }.padding(.horizontal, 8)
        }.frame(height: 34)
    }

    private func tab(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LitheIDEAIcon(resourcePath: icon, size: 16, preservesOriginalColors: true)
                Text(verbatim: title).font(LitheTheme.uiFont(size: 13)).lineLimit(1)
            }.padding(.horizontal, 8).frame(height: 28)
        }.buttonStyle(.litheNoPress).modifier(LitheToolWindowTabStyle(isSelected: selected, isActive: active))
    }

    private var output: some View {
        HStack(spacing: 0) {
            OutputTextView(output: outputText, searchRoots: [], fileExists: { _ in false }, emptyMessage: "No query output",
                wrapsLines: wrapsOutput, decorateOutput: decorateOutput, onToggleWrapsLines: { wrapsOutput.toggle() }, onOpenLocation: { _, _, _ in })
            VStack(spacing: 0) {
                Button { wrapsOutput.toggle() } label: { LitheIDEAIcon(resourcePath: "expui/general/softWrap.svg", size: 16) }
                    .buttonStyle(LitheIconButtonStyle(size: 22, isSelected: wrapsOutput)).workbenchHoverHelp(Text("Use soft wraps"))
                    .accessibilityLabel("Use soft wraps")
                Button {
                    if let id = feature.selectedSQLTabID { feature.clearSQLOutput(in: id) }
                } label: { LitheIDEAIcon(resourcePath: "expui/general/delete.svg", size: 16) }
                    .litheToolbarIconButton(isEnabled: !outputText.isEmpty && feature.selectedSQLTab?.isRunning != true)
                    .workbenchHoverHelp(Text("Clear output"))
                    .accessibilityLabel("Clear output")
                Spacer(minLength: 0)
            }.padding(.horizontal, 7).padding(.vertical, 5)
        }
    }

    private var visibleOutput: [DatabaseSQLStatementExecution] {
        let tab = feature.selectedSQLTab
        let records = tab?.statementExecutions ?? []
        let start = tab?.outputHiddenThroughExecutionID.flatMap { id in records.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        return Array(records.dropFirst(start))
    }

    private var outputDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss:SSS"
        return formatter
    }

    private func decorateOutput(_ output: NSMutableAttributedString, isDark: Bool) {
        // CONSOLE_NORMAL_OUTPUT inherits the editor text color, not general UI label foreground.
        output.addAttribute(.foregroundColor, value: NSColor(LitheTheme.DatabaseGrid.text), range: NSRange(location: 0, length: output.length))
        let source = output.string as NSString
        let formatter = outputDateFormatter
        var cursor = 0
        for record in visibleOutput {
            let prefix = "[\(formatter.string(from: record.startedAt))] "
            let range = source.range(of: prefix + record.sql, range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound else { continue }
            let sql = NSTextStorage(string: record.sql)
            SQLSyntaxHighlighter.apply(to: sql, font: LitheTheme.editorFont(size: 13), isDark: isDark)
            sql.enumerateAttributes(in: NSRange(location: 0, length: sql.length)) { attributes, local, _ in
                let colors = attributes.filter { $0.key == .foregroundColor || $0.key == .font }
                output.addAttributes(colors, range: NSRange(location: range.location + prefix.utf16.count + local.location, length: local.length))
            }
            cursor = NSMaxRange(range)
        }
    }

    private var outputText: String {
        let formatter = outputDateFormatter
        return visibleOutput.map { record in
            let start = formatter.string(from: record.startedAt)
            let end = formatter.string(from: record.startedAt.addingTimeInterval(Double(record.durationMilliseconds) / 1_000))
            let message: String
            if let error = record.errorMessage { message = error }
            else if let rows = record.rowsReturned { message = String(format: DatabaseLocalization.string("%d rows retrieved in %d ms", locale: locale), rows, record.durationMilliseconds) }
            else { message = String(format: DatabaseLocalization.string("%llu rows affected in %d ms", locale: locale), record.rowsAffected ?? 0, record.durationMilliseconds) }
            return "[\(start)] \(record.sql)\n[\(end)] \(message)"
        }.joined(separator: "\n")
    }
}

/// Community ConsoleHistoryController -> ContentChooser: list, read-only viewer, Close/Paste.
struct DatabaseQueryHistoryDialog: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel
    let profileID: UUID?
    let onClose: () -> Void
    let onPaste: (DatabaseSQLHistoryEntry) -> Void
    @State private var historyListActive = false
    @State private var selectedID: UUID?

    private var entries: [DatabaseSQLHistoryEntry] { feature.sqlHistory.filter { $0.profileID == profileID } }
    private var selected: DatabaseSQLHistoryEntry? { entries.first { $0.id == selectedID } ?? entries.first }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                LitheSplitPaneView(axis: .horizontal, placement: .leading,
                    defaultSize: geometry.size.width * 0.3, minimum: 120,
                    maximum: max(120, geometry.size.width - 180), flexibleMinimum: 180) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                Button { selectedID = entry.id } label: {
                                    Text(verbatim: entry.sql.replacingOccurrences(of: "\n", with: "↵   "))
                                        .font(LitheTheme.codeFont).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 24)
                                }.buttonStyle(.litheNoPress).litheSelectionRow(isSelected: selected?.id == entry.id,
                                    isFocused: historyListActive)
                            }
                        }
                    }.litheScrollViewChrome().background(LitheTheme.editor)
                        .background(LitheToolWindowActivityTracker(isActive: $historyListActive))
                } flexible: {
                    SQLSyntaxEditor(text: .constant(selected?.sql ?? ""), completions: [], onRun: {}, onSelectionChange: { _ in },
                                    isEditable: false)
                        .background(LitheTheme.editor)
                }
            }.padding(12)
            HStack {
                Spacer()
                Button("Close", action: onClose).buttonStyle(LitheCommitDialogButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Paste") { if let selected { onPaste(selected) } }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true)).disabled(selected == nil).keyboardShortcut(.defaultAction)
            }.padding(12)
        }.foregroundStyle(LitheTheme.primaryText).frame(width: 500, height: 500).background(LitheCommitDialogStyle.background)
    }
}

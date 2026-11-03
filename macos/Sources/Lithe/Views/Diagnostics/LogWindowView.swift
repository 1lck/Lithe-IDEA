import AppKit
import SwiftUI
import LitheModuleAPI

struct LogWindowView: View {
    @ObservedObject var model: LogWindowModel
    @ObservedObject var coordinator: LogWindowCoordinator
    @ObservedObject var exportFeature: DiagnosticsFeatureModel
    @EnvironmentObject private var settings: AppSettings
    @FocusState private var filterFocused: Bool
    @State private var tab = 0
    @State private var json = AttributedString()
    @State private var bookmarkName = ""
    @State private var namingBookmark = false
    @State private var appliedRevision = -1
    @State private var confirmsClear = false
    @State private var channelCursor: String?
    @State private var channelAnchor: String?
    @FocusState private var channelsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let diagnostic = model.diagnostics.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L10n.string("Filter error at %lld–%lld: %@"), Int64(diagnostic.start), Int64(diagnostic.end), filterError(diagnostic.code)))
                    Text(String(repeating: " ", count: min(128, diagnostic.start)) + String(repeating: "^", count: max(1, min(128, diagnostic.end - diagnostic.start))))
                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                }.foregroundStyle(Color(LogWindowPalette.red)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            if let error = model.error ?? exportFeature.logError { Text(error).foregroundStyle(Color(LogWindowPalette.red)) }
            LogHistogramView(model: model)
            HStack(spacing: 0) {
                sidebar.frame(width: 212)
                Rectangle().fill(Color(LogWindowPalette.line)).frame(width: 1)
                LitheSplitPaneView(axis: .vertical, placement: .trailing, defaultSize: 196,
                    minimum: 130, maximum: 420, flexibleMinimum: 100, dividerColor: Color(LogWindowPalette.line),
                    sized: { details }, flexible: {
                        ZStack(alignment: .bottom) {
                            LogWindowTable(model: model).litheScrollViewChrome()
                            if model.state.records.isEmpty {
                                Text(LocalizedStringKey(model.state.cleared ? "View cleared — files on disk are untouched; new records will appear here" : "No matches — try another level or channel"))
                                    .foregroundStyle(Color(LogWindowPalette.tx3)).frame(maxHeight: .infinity)
                            }
                            if !model.state.follows && model.state.newCount > 0 {
                                Button(String(format: L10n.string("↓ %lld new logs, jump to latest"), Int64(model.state.newCount))) { model.resume() }
                                    .buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 4)
                                    .foregroundStyle(Color(LogWindowPalette.white)).background(Color(LogWindowPalette.blu), in: Capsule()).padding(8)
                            }
                        }
                    })
            }
            status
        }
        .font(LitheTheme.uiFont(size: 12.5, design: .monospaced))
        .foregroundStyle(Color(LogWindowPalette.tx))
        .background(Color(LogWindowPalette.bg))
        .background(LogWindowChrome(title: sessionPath, shortcut: shortcut))
        .frame(minWidth: 900, minHeight: 500)
        .onAppear { [exportFeature] in
            model.onOpenExport = { [weak model, weak exportFeature] in
                guard let model else { return }
                exportFeature?.presentExport(filter: model.query, environment: model.environment)
            }
            model.start()
            applyRequest()
        }
        .onDisappear { model.onOpenExport = nil; model.stop(); exportFeature.dismiss() }
        .sheet(isPresented: Binding(get: { exportFeature.isPresented }, set: { if !$0 { exportFeature.dismiss() } })) {
            DiagnosticsExportSheet(feature: exportFeature)
        }
        .task { await exportFeature.refreshStatus() }
        .onReceive(coordinator.$request) { request in
            guard model.onOpenExport != nil, appliedRevision != coordinator.revision, let request else { return }
            appliedRevision = coordinator.revision; model.apply(request)
        }
        .task(id: model.selected.map(LogWindowModel.recordID)) {
            guard let record = model.selected else { json = AttributedString(); return }
            if let text = await model.formatted(records: [record], format: "json", includeEnvironment: false), !Task.isCancelled {
                json = LogJSONHighlight.attributed(text, fields: record.fields)
            }
        }
        .onChange(of: model.state.diagnosticRemaining) { _ in cardStarted = Date() }
        .onChange(of: model.state.selection) { _ in
            // A reference can select before the table is created; load its chain through the same path.
            if model.state.trace == nil, model.selected?.op != nil { model.select(model.state.selection) }
        }
        .background(Button("") { filterFocused = true }.keyboardShortcut("f", modifiers: .command).hidden())
        .confirmationDialog("Clear collected logs?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Logs", role: .destructive) {
                Task { await exportFeature.clearLogs(); model.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete only Lithe-managed logs in the active directory across all modules and sessions. Filters do not limit this action. New events will continue to be recorded.")
        }
        .alert("Name for this filter", isPresented: $namingBookmark) {
            TextField("Name for this filter", text: $bookmarkName)
            Button("Save") { model.saveBookmark(name: bookmarkName); bookmarkName = "" }
            Button("Cancel", role: .cancel) { bookmarkName = "" }
        }
    }
    private func applyRequest() {
        guard appliedRevision != coordinator.revision, let request = coordinator.request else { return }
        appliedRevision = coordinator.revision; model.apply(request)
    }
    private var sessionPath: String {
        guard let directory = model.state.directory else { return "" }
        return (directory.appendingPathComponent(model.state.currentSessionPath).path as NSString).abbreviatingWithTildeInPath
    }
    private var shortcut: String {
        let bindings = settings.keyboardShortcutOverrides["show-logs"] ?? LitheCommandCatalog.command(id: "show-logs").map { settings.keyboardShortcutPreset.bindings(for: $0) } ?? []
        return bindings.map(\.displayText).joined(separator: "  ")
    }
    private func toolbarLabel(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 5) { Text(verbatim: symbol); Text(LocalizedStringKey(title)) }
    }
    private var toolbar: some View {
        LogToolbarLayout {
            HStack(spacing: 6) {
                Text(verbatim: "❯").foregroundStyle(Color(LogWindowPalette.pur))
                if let since = model.query.since, let until = model.query.until {
                    Button { model.changeQuery { $0.since = nil; $0.until = nil } } label: {
                        Text(verbatim: String((since.split(separator: "T").last ?? "").prefix(8)) + "–" + String((until.split(separator: "T").last ?? "").prefix(8)) + " ✕")
                    }.buttonStyle(.plain).font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(LogWindowPalette.blu)).padding(.horizontal, 6)
                        .background(Color(LogWindowPalette.hl), in: RoundedRectangle(cornerRadius: 4)).help("Clear time range")
                }
                TextField("Filter: server:jdtls  level>=warn  -event:lsp.trace.received  /regex/  op:c0ffee",
                    text: Binding(get: { model.query.expression }, set: model.setExpression))
                    .textFieldStyle(.plain).focused($filterFocused)
                Text(verbatim: "⌘F").font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .foregroundStyle(Color(LogWindowPalette.tx2)).padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(LogWindowPalette.bd)))
            }.padding(.horizontal, 8).frame(minWidth: 260, idealWidth: 260, maxWidth: .infinity).frame(height: 28)
                .background(Color(LogWindowPalette.bg), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(filterFocused ? LogWindowPalette.blu : LogWindowPalette.bd)))
            ForEach(["ERROR", "WARN", "INFO", "DEBUG"], id: \.self) { level in
                let enabled = model.query.levels.contains(level)
                Button {
                    model.changeQuery { query in
                        if enabled { query.levels.removeAll { $0 == level } } else { query.levels.append(level) }
                    }
                } label: {
                    Text(verbatim: level).font(LitheTheme.uiFont(size: 11.5, weight: enabled ? .semibold : .regular, design: .monospaced))
                        .padding(.horizontal, 8).frame(height: 24)
                        .foregroundStyle(Color(enabled ? (colorScheme == .dark ? LogWindowPalette.bg : LogWindowPalette.white) : LogWindowPalette.tx2))
                        .background(Color(enabled ? (level == "DEBUG" ? LogWindowPalette.tx2 : LogWindowPalette.level(level)) : LogWindowPalette.bg), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(enabled ? (level == "DEBUG" ? LogWindowPalette.tx2 : LogWindowPalette.level(level)) : LogWindowPalette.bd)))
                }.buttonStyle(.plain)
            }
            LitheMenu {
                for value in ["current", "previous", "all"] {
                    LitheContextMenuItem.action(sessionTitle(value), checked: model.query.session == value) { model.changeQuery { $0.session = value } }
                }
            } label: { HStack(spacing: 6) { Text(LocalizedStringKey(sessionTitle(model.query.session))); Text(verbatim: "⌄") } }
            LitheMenu {
                if model.preferences.bookmarks.isEmpty { LitheContextMenuItem.heading("No saved filters") }
                for bookmark in model.preferences.bookmarks {
                    LitheContextMenuItem.submenu(bookmark.name, items: [
                        .action("Apply") { model.applyBookmark(bookmark) },
                        .action("Delete") { model.deleteBookmark(bookmark.id) }
                    ])
                }
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Save current filter…", isEnabled: model.preferences.bookmarks.count < LogWindowModel.maximumBookmarks) { namingBookmark = true }
            } label: { toolbarLabel("★", "Saved filters") }
            columnMenu
            Button { model.openExport() } label: { toolbarLabel("⇩", "Export") }.accessibilityLabel(Text("Export diagnostic logs"))
            Button { model.toggleCollapse() } label: { toolbarLabel("⇊", "Collapse repeats") }.buttonStyle(LogButtonStyle(active: model.preferences.collapse))
            Button { model.cycleTime() } label: { toolbarLabel("⏱", ["Absolute time", "Δ previous", "Δ selected"][model.preferences.timeMode]) }
            Button { model.toggleFollow() } label: { toolbarLabel(model.state.follows ? "●" : "❚❚", model.state.follows ? "Live follow" : "Paused") }
                .buttonStyle(LogButtonStyle(recording: model.state.follows))
            Button { model.clearDisplay() } label: { toolbarLabel("⌫", "Clear view") }.help("Clear only the display; log files are kept")
            maintenanceMenu
        }.buttonStyle(LogButtonStyle()).padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(LogWindowPalette.bg3)).overlay(alignment: .bottom) { rule }
    }
    @Environment(\.colorScheme) private var colorScheme
    private var rule: some View { Rectangle().fill(Color(LogWindowPalette.line)).frame(height: 1) }
    private var maintenanceMenu: some View {
        LitheMenu {
            LitheContextMenuItem.action(logDirectoryPath, localizesTitle: false, isEnabled: false) {}
            LitheContextMenuItem.action("Reveal Log Directory in Finder", isEnabled: model.state.directory != nil) {
                if let directory = model.state.directory { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
            }
            LitheContextMenuItem.action("Change Log Directory…", isEnabled: !exportFeature.isBusy) { chooseLogDirectory() }
            LitheContextMenuItem.action("Restore Default Directory", isEnabled: !exportFeature.isBusy && model.state.directory != nil && model.state.directory?.standardizedFileURL != settings.defaultLogDirectory.standardizedFileURL) {
                changeLogDirectory(to: settings.defaultLogDirectory, restoringDefault: true)
            }
            LitheContextMenuItem.separator
            LitheContextMenuItem.action(String(format: L10n.string("Clear Logs (used %@)…"),
                ByteCountFormatter.string(fromByteCount: Int64(clamping: exportFeature.diskBytes), countStyle: .file)),
                localizesTitle: false, isEnabled: !exportFeature.isBusy) { confirmsClear = true }
        } label: { Text(verbatim: "⋯") }
        .accessibilityLabel(Text("Log directory and cleanup"))
        .accessibilityIdentifier("logs.maintenance-menu")
    }
    private var logDirectoryPath: String {
        guard let directory = model.state.directory else { return L10n.string("Log directory") }
        return (directory.path as NSString).abbreviatingWithTildeInPath
    }
    private func chooseLogDirectory() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Choose Log Directory")
        panel.prompt = L10n.string("Choose")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = model.state.directory
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        changeLogDirectory(to: directory)
    }
    private func changeLogDirectory(to directory: URL, restoringDefault: Bool = false) {
        Task {
            if await exportFeature.changeLogDirectory(to: directory) {
                settings.setCustomLogDirectory(restoringDefault ? nil : directory)
                model.refresh()
            }
        }
    }
    private var columnMenu: some View {
        LitheMenu {
            for (index, column) in LogWindowTable.columns.enumerated() {
                LitheContextMenuItem.action(LogWindowTable.titles[index], checked: !model.preferences.hidden.contains(column)) {
                    model.setColumn(column, hidden: !model.preferences.hidden.contains(column))
                }
            }
        } label: { toolbarLabel("▦", "Columns") }
    }
    private func sessionTitle(_ value: String) -> String {
        switch value { case "previous": "Session: previous"; case "all": "Session: all"; default: "Session: current" }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(channelRows) { row in
                        if let root = row.root {
                            Text(verbatim: root).font(LitheTheme.uiFont(size: 10.5, design: .monospaced)).tracking(0.63)
                                .foregroundStyle(Color(LogWindowPalette.tx3)).padding(.leading, 12).padding(.top, 10).padding(.bottom, 3)
                        }
                        LogChannelRow(row: row, selected: row.id.isEmpty ? model.query.channelPrefixes.isEmpty : model.query.channelPrefixes.contains(row.id),
                            unread: model.state.unreadErrors.contains(row.id)) {
                            channelsFocused = true
                            selectChannel(row.id, flags: NSApp.currentEvent?.modifierFlags ?? [])
                        }
                    }
                    Text("⌘-click to select several").font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(LogWindowPalette.tx3)).padding(.horizontal, 12).padding(.vertical, 6)
                }
            }.litheScrollViewChrome().focusable().focused($channelsFocused).litheFocusEffectHidden()
                .onMoveCommand { direction in
                    guard direction == .up || direction == .down else { return }
                    let rows = channelRows.map(\.id)
                    let index = rows.firstIndex(of: channelCursor ?? model.query.channelPrefixes.first ?? "") ?? 0
                    let next = min(rows.count - 1, max(0, index + (direction == .down ? 1 : -1)))
                    selectChannel(rows[next], flags: NSApp.currentEvent?.modifierFlags ?? [])
                }
            if model.state.diagnosticRemaining > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) { Text(verbatim: "●"); Text("Verbose diagnostics on") }.foregroundStyle(Color(LogWindowPalette.grn))
                    Text(String(format: L10n.string("Category: %@"), model.state.diagnosticCategory ?? L10n.string("All channels")))
                        .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = Int(max(0, model.state.diagnosticRemaining - context.date.timeIntervalSince(cardStarted)))
                        HStack(spacing: 4) {
                            Text(String(format: L10n.string("Auto-off in %@"), String(format: "%02d:%02d", seconds / 60, seconds % 60)))
                            Text(verbatim: "·")
                            Button("Disable diagnostics") { Task { await model.stopDiagnostics() } }.buttonStyle(.plain).foregroundStyle(Color(LogWindowPalette.blu))
                        }.font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                    }
                }.frame(height: 50, alignment: .topLeading).foregroundStyle(Color(LogWindowPalette.tx2)).padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(LogWindowPalette.grn).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(LogWindowPalette.grn).opacity(0.4)))
                    .padding(.horizontal, 10).padding(.bottom, 6)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("Detailed diagnostics")
                        LitheInfoTip("Detailed diagnostics cover all channels and expire after 15 minutes.")
                    }
                    Spacer(minLength: 0)
                    Button("Enable diagnostics") { Task { await model.startDiagnostics(); await exportFeature.refreshStatus() } }
                        .buttonStyle(LogButtonStyle(height: 22))
                        .accessibilityIdentifier("logs.enable-diagnostics")
                }.frame(height: 50, alignment: .topLeading).padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(LogWindowPalette.bg3), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(LogWindowPalette.bd)))
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
        }.padding(.top, 8).background(Color(LogWindowPalette.bg2))
    }
    private func selectChannel(_ id: String, flags: NSEvent.ModifierFlags) {
        let selected = LitheTreeListSelection.select(id, in: channelRows.map(\.id),
            selected: Set(model.query.channelPrefixes), anchor: channelAnchor ?? channelCursor,
            extending: flags.contains(.shift), toggling: flags.contains(.command))
        if !flags.contains(.shift) || channelAnchor == nil { channelAnchor = id }
        channelCursor = id
        model.changeQuery { $0.channelPrefixes = selected.contains("") ? [] : selected.sorted() }
    }
    @State private var cardStarted = Date()
    struct ChannelRow: Identifiable { let id: String; let count: Int; var root: String? = nil }
    private var channelRows: [ChannelRow] {
        var previous = ""
        let order = ["app", "lsp", "vcs", "plugins"]
        let channels = model.state.channels.keys.sorted {
            let a = $0.split(separator: "/").first.map(String.init) ?? $0
            let b = $1.split(separator: "/").first.map(String.init) ?? $1
            let ai = order.firstIndex(of: a) ?? order.count, bi = order.firstIndex(of: b) ?? order.count
            return ai == bi ? $0 < $1 : ai < bi
        }
        return [.init(id: "", count: model.state.channels.values.reduce(0) { $0 + $1.total })] + channels.map { channel in
            let root = channel.split(separator: "/").first.map(String.init) ?? channel
            let heading = root == previous ? nil : root + "/"
            previous = root
            return .init(id: channel, count: model.state.channels[channel]!.total, root: heading)
        }
    }
    private var details: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    detailTab("Detail", index: 0)
                    detailTab("Call chain", index: 1, count: model.state.trace?.opSummary?.count)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8).padding(.top, 4).overlay(alignment: .bottom) { rule }
                if tab == 1 { trace } else { fieldDetails }
            }
            Rectangle().fill(Color(LogWindowPalette.line)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Button { copy("json") } label: { toolbarLabel("⧉", "Copy as JSON") }
                    Button { copy("markdown") } label: { toolbarLabel("⧉", "Copy as Markdown") }
                    Button { if let record = model.selected { Task { await model.compose(kind: "channel", value: record.channel) } } } label: { toolbarLabel("⊙", "Filter channel") }
                    Button { if let op = model.selected?.op { tab = 1; Task { await model.compose(kind: "op", value: op) } } } label: { toolbarLabel("⇢", "Trace operation") }.disabled(model.selected?.op == nil)
                    Button { reveal() } label: { toolbarLabel("↗", "Reveal in Finder") }
                    Button { model.openExport() } label: { toolbarLabel("⇩", "Export bundle…") }
                    Text("‹redacted› values were masked by Core; the window and exports never show the original")
                        .font(LitheTheme.uiFont(size: 10, design: .monospaced)).foregroundStyle(Color(LogWindowPalette.tx3)).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(LogButtonStyle(height: 25, fullWidth: true)).padding(8).disabled(model.selected == nil)
            }.frame(width: 209).litheScrollViewChrome()
        }.background(Color(LogWindowPalette.bg2)).overlay(alignment: .top) { rule }
    }
    private func detailTab(_ title: String, index: Int, count: Int? = nil) -> some View {
        Button { tab = index } label: {
            HStack(spacing: 5) { Text(LocalizedStringKey(title)); if let count { Text(verbatim: "(\(count))") } }
                .padding(.horizontal, 10).padding(.vertical, 3).padding(.bottom, 2)
                .foregroundStyle(Color(tab == index ? LogWindowPalette.tx : LogWindowPalette.tx2))
                .overlay(alignment: .bottom) { if tab == index { Color(LogWindowPalette.blu).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityIdentifier(index == 0 ? "logs.detail-tab" : "logs.trace-tab")
    }
    private var fieldDetails: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if let record = model.selected {
                    Text(verbatim: "// " + record.relativePath.replacingOccurrences(of: model.state.currentSessionPath + "/", with: "") + "  ·  " + String(format: L10n.string("Line %lld"), Int64(record.lineNumber)))
                        .foregroundStyle(Color(LogWindowPalette.tx3)).padding(.bottom, 2)
                    Text(json).textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "log-field", let key = url.host, let value = record.fields[key] else { return .discarded }
                            Task { await model.compose(kind: "field", key: key, value: value) }; return .handled
                        })
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
        }.font(LitheTheme.uiFont(size: 12.5, design: .monospaced)).litheScrollViewChrome()
    }
    private var trace: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.selected?.op == nil { Text("This record has no op id").foregroundStyle(Color(LogWindowPalette.tx3)) }
                if let result = model.state.trace {
                    if let summary = result.opSummary {
                        Text(String(format: L10n.string("Op %@ · %lld records · %@"), summary.op, Int64(summary.count), "\(summary.durationMs) ms"))
                            .foregroundStyle(Color(LogWindowPalette.tx3)).padding(.bottom, 4)
                    }
                    ForEach(result.records, id: \.line) { record in
                        HStack(spacing: 10) {
                            Text(verbatim: "+\(record.opOffsetMs ?? 0) ms").foregroundStyle(Color(LogWindowPalette.tx3)).frame(width: 70, alignment: .leading)
                            Text(verbatim: LogWindowPalette.symbol(record.level) + " " + record.level)
                                .foregroundStyle(Color(LogWindowPalette.level(record.level))).frame(width: 64, alignment: .leading)
                            Text(verbatim: record.channel).padding(.horizontal, 5).foregroundStyle(Color(LogWindowPalette.channel(record.channel)))
                                .background(Color(LogWindowPalette.channel(record.channel)).opacity(0.15), in: RoundedRectangle(cornerRadius: 3)).frame(width: 150, alignment: .leading)
                            Text(verbatim: record.event).foregroundStyle(Color(LogWindowPalette.pur)).frame(width: 210, alignment: .leading)
                            Text(verbatim: record.msg).frame(width: 180, alignment: .leading)
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 3).fill(Color(record.level == "ERROR" ? LogWindowPalette.red : LogWindowPalette.pur).opacity(0.7))
                                    .frame(width: max(3, geometry.size.width * CGFloat(record.opOffsetMs ?? 0) / CGFloat(max(1, result.opSummary?.durationMs ?? 1))), height: 6).frame(maxHeight: .infinity)
                            }.frame(width: 160)
                        }.font(LitheTheme.uiFont(size: 11.5, design: .monospaced)).lineLimit(1).frame(height: 22).padding(.horizontal, 4)
                            .background(model.state.selection.contains(LogWindowModel.recordID(record)) ? Color(LogWindowPalette.hl) : .clear)
                            .contentShape(Rectangle()).onTapGesture { model.jump(epochMs: record.epochMs) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
        }.litheScrollViewChrome()
    }
    private var status: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                if model.state.follows { LogFollowingPulse() } else { Text(verbatim: "❚❚") }
                Text(LocalizedStringKey(model.state.follows ? "Tailing" : model.state.scrolledUp ? "Paused (scrolled up)" : "Paused"))
            }
            Text(String(format: L10n.string("%@ / %@ rows · line %@"), model.displayRows.count.formatted(.number.locale(Locale(identifier: "en_US"))),
                model.state.channels.values.reduce(0) { $0 + $1.total }.formatted(.number.locale(Locale(identifier: "en_US"))), String(model.selected?.lineNumber ?? 0)))
            Spacer(minLength: 0)
            Text(String(format: L10n.string("Dropped %lld"), Int64(model.state.discarded + model.state.dropped)))
            Text(String(format: L10n.string("Write failures %lld"), Int64(model.state.writeFailures)))
            Text(verbatim: "v2 · UTF-8 · NDJSON")
        }.font(LitheTheme.uiFont(size: 11.5, design: .monospaced)).foregroundStyle(Color(LogWindowPalette.white))
            .padding(.horizontal, 10).frame(height: 24).background(Color(LogWindowPalette.foot))
    }
    private func copy(_ format: String) {
        Task {
            if let text = await model.formatted(records: model.selectedRecords, format: format) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
    private func reveal() {
        guard let record = model.selected, let root = model.state.directory else { return }
        let relative = record.relativePath.hasPrefix("sessions/") ? record.relativePath : model.state.currentSessionPath + "/" + record.relativePath
        NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(relative)])
    }
    private func filterError(_ code: String) -> String {
        L10n.string(key: "logs.filter." + code)
    }
}

private struct LogHistogramView: View {
    @ObservedObject var model: LogWindowModel
    @State private var dragStart: Int?
    @State private var dragEnd: Int?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Events over time")
                HStack(spacing: 4) {
                    Text(verbatim: "■").foregroundStyle(Color(LogWindowPalette.red)); Text(verbatim: "ERROR")
                    Text(verbatim: "■").foregroundStyle(Color(LogWindowPalette.yel)); Text(verbatim: "WARN")
                    Text(verbatim: "■").foregroundStyle(Color(LogWindowPalette.blu)); Text(verbatim: "INFO")
                }
                Text("Click to jump · drag for time range")
            }.font(LitheTheme.uiFont(size: 11, design: .monospaced)).foregroundStyle(Color(LogWindowPalette.tx3)).frame(width: 212, alignment: .leading)
            GeometryReader { geometry in
                if let histogram = model.state.histogram {
                    let maximum = max(1, histogram.buckets.map { $0.debug + $0.info + $0.warn + $0.error }.max() ?? 1)
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(histogram.buckets.indices, id: \.self) { index in
                            let bucket = histogram.buckets[index]
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle().fill(Color(LogWindowPalette.red)).frame(height: CGFloat(bucket.error) / CGFloat(maximum) * 44)
                                Rectangle().fill(Color(LogWindowPalette.yel)).frame(height: CGFloat(bucket.warn) / CGFloat(maximum) * 44)
                                Rectangle().fill(Color(LogWindowPalette.blu).opacity(0.4)).frame(height: CGFloat(bucket.info + bucket.debug) / CGFloat(maximum) * 44)
                            }.background {
                                if let start = dragStart, let end = dragEnd, (min(start, end)...max(start, end)).contains(index) {
                                    Color(LogWindowPalette.blu).opacity(0.16)
                                }
                            }.help(String(format: L10n.string("%@ · ERROR %lld · WARN %lld · other %lld"),
                                Date(timeIntervalSince1970: Double(histogram.startEpochMs + Int64(index) * histogram.bucketMs) / 1000).formatted(),
                                Int64(bucket.error), Int64(bucket.warn), Int64(bucket.debug + bucket.info)))
                        }
                    }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if dragStart == nil { dragStart = bucket(value.startLocation.x, width: geometry.size.width, count: histogram.buckets.count) }
                        dragEnd = bucket(value.location.x, width: geometry.size.width, count: histogram.buckets.count)
                    }.onEnded { value in
                        let end = bucket(value.location.x, width: geometry.size.width, count: histogram.buckets.count)
                        let start = dragStart ?? end; dragStart = nil; dragEnd = nil
                        if start == end { model.jump(epochMs: histogram.startEpochMs + Int64(end) * histogram.bucketMs) }
                        else { model.setRange(since: histogram.startEpochMs + Int64(min(start, end)) * histogram.bucketMs,
                            until: histogram.startEpochMs + Int64(max(start, end) + 1) * histogram.bucketMs - 1) }
                    })
                }
            }.accessibilityLabel(Text("Events over time"))
        }.padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4).frame(height: 58).background(Color(LogWindowPalette.bg2))
            .overlay(alignment: .bottom) { Color(LogWindowPalette.line).frame(height: 1) }
    }
    private func bucket(_ x: CGFloat, width: CGFloat, count: Int) -> Int { min(max(0, Int(x / max(1, width) * CGFloat(count))), max(0, count - 1)) }
}

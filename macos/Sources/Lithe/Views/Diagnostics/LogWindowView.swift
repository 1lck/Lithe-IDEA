import AppKit
import SwiftUI
import LitheModuleAPI

struct LogWindowView: View {
    @ObservedObject var model: LogWindowModel
    @ObservedObject var coordinator: LogWindowCoordinator
    var exportFeature: DiagnosticsFeatureModel? = nil
    @EnvironmentObject private var settings: AppSettings
    @FocusState private var filterFocused: Bool
    @State private var tab = 0
    @State private var bookmarkName = ""
    @State private var namingBookmark = false
    @State private var appliedRevision = -1

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let diagnostic = model.diagnostics.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L10n.string("Filter error at %lld–%lld: %@"), Int64(diagnostic.start), Int64(diagnostic.end), filterError(diagnostic.code)))
                    Text(String(repeating: " ", count: min(128, diagnostic.start)) + String(repeating: "^", count: max(1, min(128, diagnostic.end - diagnostic.start))))
                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                }.foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            LogHistogramView(model: model)
            HStack(spacing: 0) {
                sidebar.frame(width: 205)
                Divider()
                LitheSplitPaneView(axis: .vertical, placement: .trailing, defaultSize: 205,
                    minimum: 130, maximum: 420, flexibleMinimum: 100,
                    sized: { details }, flexible: {
                        ZStack(alignment: .bottom) {
                            LogWindowTable(model: model).litheScrollViewChrome()
                            if model.state.records.isEmpty {
                                Text(LocalizedStringKey(model.state.cleared ? "View cleared — files on disk are untouched; new records will appear here" : "No matches — try another level or channel"))
                                    .foregroundStyle(LitheTheme.secondaryText).frame(maxHeight: .infinity)
                            }
                            if !model.state.follows && model.state.newCount > 0 {
                                Button(String(format: L10n.string("↓ %lld new logs, jump to latest"), Int64(model.state.newCount))) { model.resume() }
                                    .buttonStyle(.borderedProminent).padding(8)
                            }
                        }
                    })
            }
            status
        }
        .font(LitheTheme.uiFont(size: 12))
        .background(LitheTheme.editor)
        .frame(minWidth: 900, minHeight: 500)
        .onAppear {
            model.onOpenExport = { [weak model, weak exportFeature] in
                guard let model else { return }
                exportFeature?.presentExport(filter: model.query, environment: model.environment)
            }
            model.start()
            applyRequest()
        }
        .onDisappear { model.onOpenExport = nil; model.stop(); exportFeature?.dismiss() }
        .sheet(isPresented: Binding(get: { (exportFeature?.isPresented ?? false) && (exportFeature?.isFromLogWindow ?? false) }, set: { if !$0 { exportFeature?.dismiss() } })) {
            if let exportFeature { DiagnosticsExportSheet(feature: exportFeature) }
        }
        .onReceive(coordinator.$request) { request in
            guard appliedRevision != coordinator.revision, let request else { return }
            appliedRevision = coordinator.revision; model.apply(request)
        }
        .onChange(of: model.state.diagnosticRemaining) { _ in cardStarted = Date() }
        .onChange(of: model.state.selection) { _ in
            // A reference can select before the table is created; load its chain through the same path.
            if model.state.trace == nil, model.selected?.op != nil { model.select(model.state.selection) }
        }
        .background(Button("") { filterFocused = true }.keyboardShortcut("f", modifiers: .command).hidden())
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
    private var toolbar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                LitheSearchField("Filter: server:jdtls  level>=warn  -event:lsp.trace.received  /regex/  op:c0ffee",
                    text: Binding(get: { model.query.expression }, set: model.setExpression), focus: $filterFocused)
                LitheSettingsSelect(selection: Binding(get: { model.query.session }, set: { value in model.changeQuery { $0.session = value } }),
                    options: ["current", "previous", "all"], width: 145, accessibilityLabel: "Session", title: sessionTitle)
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
                } label: { Text("Saved filters") }
                columnMenu
                Button("Export") { model.openExport() }.accessibilityLabel(Text("Export diagnostic logs"))
            }
            HStack(spacing: 8) {
                ForEach(["DEBUG", "INFO", "WARN", "ERROR"], id: \.self) { level in
                    Toggle(isOn: Binding(get: { model.query.levels.contains(level) }, set: { enabled in
                        model.changeQuery { query in
                            if enabled { query.levels.append(level) } else { query.levels.removeAll { $0 == level } }
                        }
                    })) { Text(level) }
                    .toggleStyle(.button).accessibilityLabel(Text(level))
                }
                Button(LocalizedStringKey(model.state.follows ? "Following" : "Paused")) { model.toggleFollow() }
                Toggle("Collapse repeats", isOn: Binding(get: { model.preferences.collapse }, set: { _ in model.toggleCollapse() })).toggleStyle(.button)
                Button(LocalizedStringKey(["Absolute time", "Δ previous", "Δ selected"][model.preferences.timeMode])) { model.cycleTime() }
                if let since = model.query.since, let until = model.query.until {
                    Text(since + " – " + until).font(LitheTheme.uiFont(size: 10, design: .monospaced)).lineLimit(1)
                    Button("Clear time range") { model.changeQuery { $0.since = nil; $0.until = nil } }
                        .help("Clear time range")
                }
                Spacer(minLength: 0)
                Button("Clear view") { model.clearDisplay() }.help("Clear only the display; log files are kept")
            }
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(LitheTheme.editor)
    }
    private var columnMenu: some View {
        LitheMenu {
            for (index, column) in LogWindowTable.columns.enumerated() {
                LitheContextMenuItem.action(LogWindowTable.titles[index], checked: !model.preferences.hidden.contains(column)) {
                    model.setColumn(column, hidden: !model.preferences.hidden.contains(column))
                }
            }
        } label: { Text("Columns") }
    }
    private func sessionTitle(_ value: String) -> String {
        switch value { case "previous": "Session: previous"; case "all": "Session: all"; default: "Session: current" }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            LitheTreeList(channelRows, id: \.id, selection: Binding(get: { Set(model.query.channelPrefixes) }, set: { values in
                model.changeQuery { $0.channelPrefixes = values.contains("") ? [] : Array(values).sorted() }
            })) { row in
                VStack(alignment: .leading, spacing: 3) {
                  if let root = row.root { Text(root).font(LitheTheme.uiFont(size: 10)).foregroundStyle(.secondary) }
                  HStack(spacing: 6) {
                    if row.id.isEmpty { Text("All channels") } else {
                        Text(row.id).foregroundStyle(Color(LogWindowTable.Coordinator.channelColor(row.id)))
                    }
                    if model.state.unreadErrors.contains(row.id) { Circle().fill(.red).frame(width: 6, height: 6).accessibilityLabel(Text("Unread errors")) }
                    Spacer(minLength: 0)
                    Text(String(row.count)).foregroundStyle(LitheTheme.secondaryText)
                  }
                }
            }
            Text("⌘-click to select several").foregroundStyle(LitheTheme.secondaryText).padding(.horizontal, 10)
            if model.state.diagnosticRemaining > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verbose diagnostics on")
                    Text(String(format: L10n.string("Category: %@"), model.state.diagnosticCategory ?? L10n.string("All channels")))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        // Timer belongs only to this visible diagnostics card.
                        Text(String(format: L10n.string("Auto-off in %@"), String(Int(max(0, model.state.diagnosticRemaining - context.date.timeIntervalSince(cardStarted))))))
                    }
                    Button("Stop") { Task { await model.stopDiagnostics() } }
                }.foregroundStyle(.green).padding(10)
            }
        }.padding(.vertical, 8).background(LitheTheme.editor)
    }
    @State private var cardStarted = Date()
    private struct ChannelRow: Identifiable { let id: String; let count: Int; var root: String? = nil }
    private var channelRows: [ChannelRow] {
        var previous = ""
        return [.init(id: "", count: model.state.channels.values.reduce(0) { $0 + $1.total })] + model.state.channels.keys.sorted().map { channel in
            let root = channel.split(separator: "/").first.map(String.init) ?? channel
            let heading = root == previous ? nil : root + (channel.contains("/") ? "/" : "")
            previous = root
            return .init(id: channel, count: model.state.channels[channel]!.total, root: heading)
        }
    }
    private var details: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Detail") { tab = 0 }
                Button("Call chain") { tab = 1 }
                Spacer()
            }.buttonStyle(.litheNoPress).padding(8)
            Divider()
            HStack(alignment: .top) {
                if tab == 1 { trace } else { fieldDetails }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Button("Copy as JSON") { copy("json") }
                    Button("Copy as Markdown") { copy("markdown") }
                    Button("Filter channel") { if let record = model.selected { Task { await model.compose(kind: "channel", value: record.channel) } } }
                    Button("Trace operation") { if let op = model.selected?.op { tab = 1; Task { await model.compose(kind: "op", value: op) } } }.disabled(model.selected?.op == nil)
                    Button("Reveal in Finder") { reveal() }
                    Text("‹redacted› values were masked by Core; the window and exports never show the original")
                        .font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.litheNoPress).frame(width: 200, alignment: .leading).padding(8).disabled(model.selected == nil)
            }
        }.background(LitheTheme.editor)
    }
    private var fieldDetails: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if let record = model.selected {
                    Text(record.channel + " · " + record.event).foregroundStyle(LitheTheme.secondaryText)
                    Text(record.msg).textSelection(.enabled)
                    ForEach(record.fields.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key).foregroundStyle(.cyan)
                            let value = record.fields[key]!
                            if value == "‹redacted›" || value == "<redacted>" { Text(value).foregroundStyle(.secondary) }
                            else { Button(value) { Task { await model.compose(kind: "field", key: key, value: value) } }.buttonStyle(.litheNoPress) }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.font(LitheTheme.uiFont(size: 11, design: .monospaced)).litheScrollViewChrome()
    }
    private var trace: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if model.selected?.op == nil { Text("This record has no op id") }
                if let result = model.state.trace {
                    if let summary = result.opSummary {
                        Text(String(format: L10n.string("Op %@ · %lld records · %@"), summary.op, Int64(summary.count), "\(summary.durationMs) ms"))
                    }
                    ForEach(result.records, id: \.line) { record in
                        HStack {
                            Text("+\(record.opOffsetMs ?? 0) ms").frame(width: 80, alignment: .leading)
                            Text(record.level).frame(width: 55)
                            Text(record.channel).frame(width: 120)
                            Text(record.event)
                            Text(record.msg)
                        }.lineLimit(1).onTapGesture { model.jump(epochMs: record.epochMs) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.font(LitheTheme.uiFont(size: 11, design: .monospaced)).litheScrollViewChrome()
    }
    private var status: some View {
        HStack(spacing: 14) {
            Text(LocalizedStringKey(model.state.follows ? "Following" : model.state.scrolledUp ? "Paused (scrolled up)" : "Paused"))
            Text(String(format: L10n.string("%lld rows · %lld selected"), Int64(model.state.records.count), Int64(model.state.selection.count)))
            Spacer()
            Text(String(format: L10n.string("Dropped %lld"), Int64(model.state.discarded + model.state.dropped)))
            Text(String(format: L10n.string("Write failures %lld"), Int64(model.state.writeFailures)))
            Text(verbatim: "v2 · UTF-8 · NDJSON")
            Text(model.state.directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "")
        }.font(LitheTheme.uiFont(size: 10)).padding(6).background(LitheTheme.accent.opacity(0.18))
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
        HStack(spacing: 8) {
            VStack(alignment: .leading) { Text("Events over time"); Text("Click to jump · drag for time range").font(LitheTheme.uiFont(size: 10)).foregroundStyle(.secondary) }.frame(width: 195, alignment: .leading)
            GeometryReader { geometry in
                if let histogram = model.state.histogram {
                    let maximum = max(1, histogram.buckets.map { $0.debug + $0.info + $0.warn + $0.error }.max() ?? 1)
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(histogram.buckets.indices, id: \.self) { index in
                            let bucket = histogram.buckets[index]
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle().fill(.red).frame(height: CGFloat(bucket.error) / CGFloat(maximum) * 40)
                                Rectangle().fill(.orange).frame(height: CGFloat(bucket.warn) / CGFloat(maximum) * 40)
                                Rectangle().fill(.blue.opacity(0.5)).frame(height: CGFloat(bucket.info + bucket.debug) / CGFloat(maximum) * 40)
                            }.background {
                                if let start = dragStart, let end = dragEnd, (min(start, end)...max(start, end)).contains(index) {
                                    LitheTheme.accent.opacity(0.18)
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
        }.padding(.horizontal, 10).frame(height: 56).background(LitheTheme.editor)
    }
    private func bucket(_ x: CGFloat, width: CGFloat, count: Int) -> Int { min(max(0, Int(x / max(1, width) * CGFloat(count))), max(0, count - 1)) }
}

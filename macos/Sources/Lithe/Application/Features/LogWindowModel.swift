import Combine
import Foundation
import LitheModuleAPI

struct LogRecordReference: Sendable, Equatable {
    let channel: String
    let event: String
    var op: String? = nil
}
struct LogWindowOpenRequest: Sendable, Equatable {
    var channelPrefixes: [String]? = nil
    var expression: String? = nil
    var reference: LogRecordReference? = nil
}
struct LogWindowPreferences: Codable, Equatable {
    struct Bookmark: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var query: LogWindowQuery
    }
    var query = LogWindowQuery()
    var collapse = true
    var timeMode = 0
    var widths: [String: Double] = [:]
    var hidden: Set<String> = []
    var bookmarks: [Bookmark] = []
}

/// App-owned opening coordinator; its single request stream is shared by every project.
@MainActor
final class LogWindowCoordinator: ObservableObject {
    @Published private(set) var request: LogWindowOpenRequest?
    private(set) var revision = 0
    var present: (() -> Void)?
    func open(_ request: LogWindowOpenRequest = .init()) {
        revision += 1
        self.request = request
        present?()
    }
}

/// Presentation state only. Native I/O and all query/format semantics live behind the port.
@MainActor
final class LogWindowModel: ObservableObject {
    static let maximumRecords = 20_000
    static let maximumBookmarks = 50
    static let maximumChannels = 64
    static let maximumExpressionBytes = 1024
    struct Snapshot {
        var records: [RustCoreBridge.LogQueryRecord] = []
        var channels: [String: RustCoreBridge.LogChannelCounts] = [:]
        var histogram: RustCoreBridge.LogHistogram?
        var foldMinimumRun = 3
        var selection: Set<String> = []
        var follows = true
        var scrolledUp = false
        var newCount = 0
        var discarded = 0
        var directory: URL?
        var currentSessionPath = ""
        var dropped = 0
        var writeFailures = 0
        var diagnosticCategory: String?
        var diagnosticRemaining: TimeInterval = 0
        var cleared = false
        var scrollTarget: String?
        var scrollRevision = 0
        var unreadErrors: Set<String> = []
        var trace: RustCoreBridge.LogQueryResult?
    }
    @Published private(set) var state = Snapshot()
    @Published private(set) var preferences: LogWindowPreferences
    @Published private(set) var diagnostics: [RustCoreBridge.LogFilterDiagnostic] = []
    @Published private(set) var terms: [RustCoreBridge.LogFilterTerm] = []
    @Published private(set) var error: String?
    @Published var expandedRuns: Set<String> = []
    private let logging: any LogWindowLogging
    private let sink: (any LogSink)?
    private let save: (LogWindowPreferences) -> Void
    private let delay: @Sendable () async throws -> Void
    private var queryTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var traceTask: Task<Void, Never>?
    private var generation = 0
    private var watermark: UInt64?
    private var latestSequence: UInt64?
    private var pendingReference: LogRecordReference?
    private var activeQuery = LogWindowQuery()
    private var queryPending = false
    private var needsRefresh = false
    private var running = false
    private var traceOperation: String?
    /// B2 installs the export presentation here; B1 intentionally has no export dialog.
    var onOpenExport: (() -> Void)?
    var environment = RustCoreBridge.LogEnvironment(appVersion: "", osVersion: "", architecture: "", plugins: [])

    init(logging: any LogWindowLogging, preferences: LogWindowPreferences = .init(),
         sink: (any LogSink)? = nil, save: @escaping (LogWindowPreferences) -> Void = { _ in },
         delay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(150)) }) {
        self.logging = logging; self.preferences = preferences; self.sink = sink; self.save = save; self.delay = delay
        let columns: Set<String> = ["seq", "time", "level", "channel", "event", "message", "fields"]
        self.preferences.hidden.formIntersection(columns)
        self.preferences.widths = preferences.widths.filter { columns.contains($0.key) && $0.value.isFinite }.mapValues { min(2000, max(40, $0)) }
        self.preferences.timeMode = min(2, max(0, preferences.timeMode))
        self.preferences.query.expression = Self.bounded(preferences.query.expression)
        self.preferences.query.channelPrefixes = Array(preferences.query.channelPrefixes.prefix(Self.maximumChannels))
        self.preferences.bookmarks = Array(preferences.bookmarks.prefix(Self.maximumBookmarks)).map {
            var bookmark = $0
            bookmark.name = String(bookmark.name.prefix(128))
            bookmark.query.expression = Self.bounded(bookmark.query.expression)
            bookmark.query.channelPrefixes = Array(bookmark.query.channelPrefixes.prefix(Self.maximumChannels))
            return bookmark
        }
    }
    deinit { queryTask?.cancel(); liveTask?.cancel(); traceTask?.cancel() }
    static func recordID(_ record: RustCoreBridge.LogQueryRecord) -> String {
        // seq is session-local; source path disambiguates historical sessions.
        record.relativePath + ":" + String(record.seq) + ":" + record.ts
    }
    /// One table row. A run head carries the run length; expanded or unfolded members count 1.
    struct DisplayRow: Equatable { let id: String; let count: Int; let last: String; let isRun: Bool }
    /// The rows the table shows. The status bar counts the same projection, so folded runs are
    /// counted once there too.
    var displayRows: [DisplayRow] {
        Self.project(state.records, collapse: preferences.collapse, minimumRun: state.foldMinimumRun, expanded: expandedRuns)
    }
    /// Groups adjacent records that share Core's fold key. Core owns the key and the minimum run;
    /// the host only applies the user's collapse and expansion choices to them.
    static func project(
        _ records: [RustCoreBridge.LogQueryRecord], collapse: Bool, minimumRun: Int, expanded: Set<String>
    ) -> [DisplayRow] {
        var rows: [DisplayRow] = []
        rows.reserveCapacity(records.count)
        var index = 0
        while index < records.count {
            var end = index + 1
            while end < records.count && records[end].foldKey == records[index].foldKey { end += 1 }
            let count = end - index, id = recordID(records[index])
            let isRun = collapse && count >= minimumRun
            rows.append(.init(id: id, count: count, last: records[end - 1].ts, isRun: isRun))
            if !isRun || expanded.contains(id) {
                for child in (index + 1)..<end { rows.append(.init(id: recordID(records[child]), count: 1, last: "", isRun: false)) }
            }
            index = end
        }
        return rows
    }
    private static func bounded(_ value: String) -> String {
        var result = value
        while result.utf8.count > maximumExpressionBytes { result.removeLast() }
        return result
    }
    var query: LogWindowQuery { preferences.query }
    var selectedRecords: [RustCoreBridge.LogQueryRecord] { state.records.filter { state.selection.contains(Self.recordID($0)) } }
    var selected: RustCoreBridge.LogQueryRecord? { selectedRecords.last }
    func start() {
        guard !running else { return }
        running = true
        refresh()
        liveTask = Task { [weak self, logging] in
            do {
                let stream = try await logging.subscribeWindow()
                for await batch in stream {
                    guard let self, !Task.isCancelled else { break }
                    // Only the current session receives this process's broadcast.
                    guard self.activeQuery.session != "previous", !self.activeQuery.levels.isEmpty else { continue }
                    if self.queryPending { self.needsRefresh = true; continue }
                    let generation = self.generation
                    let result = try await logging.queryWindowBatch(batch, query: self.activeQuery)
                    guard !Task.isCancelled, self.generation == generation else { continue }
                    // Summaries are computed by Core over the bounded retained window.
                    let records = Array((self.state.records + result.records).suffix(Self.maximumRecords))
                    let summary = try await logging.windowLiveSummary(records)
                    guard !Task.isCancelled, self.generation == generation else { continue }
                    self.append(result, summary: summary)
                }
            } catch { self?.report(error) }
        }
    }
    func stop() {
        running = false; generation += 1
        queryTask?.cancel(); queryTask = nil
        liveTask?.cancel(); liveTask = nil
        traceTask?.cancel(); traceTask = nil
        state = Snapshot()
        traceOperation = nil; watermark = nil; latestSequence = nil
        queryPending = false; needsRefresh = false
        expandedRuns = []
    }
    func setExpression(_ value: String) {
        preferences.query.expression = Self.bounded(value); persist(); refresh(debounce: true)
    }
    func changeQuery(_ update: (inout LogWindowQuery) -> Void) {
        update(&preferences.query)
        preferences.query.channelPrefixes = Array(preferences.query.channelPrefixes.prefix(Self.maximumChannels))
        preferences.query.expression = Self.bounded(preferences.query.expression)
        state.unreadErrors.subtract(preferences.query.channelPrefixes)
        persist(); refresh()
    }
    func refresh(debounce: Bool = false) {
        generation += 1
        queryPending = true
        let token = generation, query = query
        queryTask?.cancel()
        queryTask = Task { [weak self, logging, delay] in
            do {
                if debounce { try await delay() }
                try Task.checkCancellation()
                let parsed = try await logging.parseWindowFilter(query.expression)
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.diagnostics = parsed.errors
                guard parsed.errors.isEmpty else { self.queryPending = false; return }
                self.terms = parsed.terms
                if query.levels.isEmpty {
                    self.activeQuery = query; self.queryPending = false
                    self.state.records = []; self.state.histogram = nil; self.state.selection = []
                    return
                }
                let collection = try await logging.queryWindow(query)
                guard token == self.generation, !Task.isCancelled else { return }
                self.activeQuery = query
                var next = self.state
                next.directory = collection.directory; next.currentSessionPath = collection.currentSessionPath
                next.dropped = collection.dropped; next.writeFailures = collection.writeFailures
                next.diagnosticCategory = collection.diagnosticCategory; next.diagnosticRemaining = collection.diagnosticRemaining
                self.latestSequence = max(self.latestSequence ?? 0, collection.result.records.last?.seq ?? 0)
                next.records = self.afterWatermark(collection.result.records)
                next.channels = collection.result.channels; next.histogram = collection.result.histogram
                next.foldMinimumRun = collection.result.foldMinimumRun
                next.selection.formIntersection(Set(next.records.map(Self.recordID)))
                self.locateReference(in: &next)
                self.state = next; self.error = nil; self.queryPending = false
                if self.needsRefresh { self.needsRefresh = false; self.refresh() }
                else { self.select(self.state.selection) }
            } catch {
                guard let self, token == self.generation else { return }
                self.queryPending = false; self.report(error)
            }
        }
    }
    private func afterWatermark(_ records: [RustCoreBridge.LogQueryRecord]) -> [RustCoreBridge.LogQueryRecord] {
        guard let watermark else { return records }
        return records.filter { $0.seq > watermark }
    }
    func append(_ result: RustCoreBridge.LogQueryResult, summary: LogWindowLiveSummary? = nil) {
        var next = state
        // A subscription replays its bounded tail. Historical/current paths refer to the same seq.
        let retained = Set(next.records.map { $0.ts + ":" + String($0.seq) + ":" + $0.channel })
        let additions = afterWatermark(result.records).filter { !retained.contains($0.ts + ":" + String($0.seq) + ":" + $0.channel) }
        latestSequence = max(latestSequence ?? 0, result.records.last?.seq ?? 0)
        // Live sources are channel-relative. Normalize their native location once
        // so historical and live selection/scroll identities agree.
        let located = additions.map { record -> RustCoreBridge.LogQueryRecord in
            guard !record.relativePath.hasPrefix("sessions/"), !next.currentSessionPath.isEmpty else { return record }
            return .init(line: record.line, channel: record.channel, lineNumber: record.lineNumber,
                foldKey: record.foldKey, epochMs: record.epochMs, opOffsetMs: record.opOffsetMs,
                relativePath: next.currentSessionPath + "/" + record.relativePath, ts: record.ts,
                level: record.level, seq: record.seq, event: record.event, op: record.op, msg: record.msg, fields: record.fields)
        }
        next.records.append(contentsOf: located)
        if next.records.count > Self.maximumRecords {
            let removed = next.records.count - Self.maximumRecords
            next.records.removeFirst(removed); next.discarded += removed
        }
        if !next.follows { next.newCount += additions.count }
        for (channel, count) in result.channels where count.error > 0 && !query.channelPrefixes.isEmpty && !query.channelPrefixes.contains(channel) {
            if next.unreadErrors.count < Self.maximumChannels { next.unreadErrors.insert(channel) }
        }
        let retainedIDs = Set(next.records.map(Self.recordID))
        next.selection.formIntersection(retainedIDs)
        if !expandedRuns.isSubset(of: retainedIDs) { expandedRuns.formIntersection(retainedIDs) }
        // Core counts include its unfiltered source. A replay whose records are
        // entirely retained must not add the same channel counts twice.
        if result.records.isEmpty || !additions.isEmpty {
            for (channel, count) in result.channels {
                let old = next.channels[channel]
                next.channels[channel] = .init(total: (old?.total ?? 0) + count.total,
                    warn: (old?.warn ?? 0) + count.warn, error: (old?.error ?? 0) + count.error)
            }
        }
        if let summary {
            next.histogram = summary.histogram; next.dropped = summary.dropped; next.writeFailures = summary.writeFailures
            next.diagnosticCategory = summary.diagnosticCategory; next.diagnosticRemaining = summary.diagnosticRemaining
        }
        next.foldMinimumRun = result.foldMinimumRun
        locateReference(in: &next)
        state = next // One publication per realtime batch.
    }
    func apply(_ request: LogWindowOpenRequest) {
        if let expression = request.expression { preferences.query.expression = Self.bounded(expression) }
        if let channels = request.channelPrefixes { preferences.query.channelPrefixes = Array(channels.prefix(Self.maximumChannels)) }
        if let reference = request.reference {
            pendingReference = reference; preferences.query.channelPrefixes = [reference.channel]
            watermark = nil
            preferences.query.expression = request.expression ?? ""
            preferences.query.since = nil; preferences.query.until = nil
            preferences.query.levels = ["DEBUG", "INFO", "WARN", "ERROR"]
        }
        persist(); refresh()
    }
    private func locateReference(in next: inout Snapshot) {
        guard let reference = pendingReference,
              let record = next.records.last(where: { $0.channel == reference.channel && $0.event == reference.event && (reference.op == nil || $0.op == reference.op) }) else { return }
        let id = Self.recordID(record)
        let precedingRun = next.records.prefix { Self.recordID($0) != id }.reversed().prefix { $0.foldKey == record.foldKey }
        expandedRuns.formUnion(precedingRun.map(Self.recordID))
        next.selection = [id]; next.scrollTarget = id; next.scrollRevision += 1; next.follows = false
        pendingReference = nil
    }
    func select(_ ids: Set<String>) {
        state.selection = ids
        guard selected?.op != traceOperation else { return }
        traceTask?.cancel()
        state.trace = nil
        traceOperation = selected?.op
        guard let op = selected?.op else { return }
        let session = query.session
        traceTask = Task { [weak self, logging] in
            do {
                var query = LogWindowQuery(); query.session = session; query.op = op
                let collection = try await logging.queryWindow(query)
                guard let self, !Task.isCancelled, self.selected?.op == op else { return }
                self.state.trace = collection.result
            } catch { self?.report(error) }
        }
    }
    func userScrolledUp() {
        guard state.follows else { return }
        state.follows = false; state.scrolledUp = true; state.newCount = 0
    }
    func resume() { state.follows = true; state.scrolledUp = false; state.newCount = 0; state.scrollRevision += 1 }
    func toggleFollow() { if state.follows { state.follows = false; state.scrolledUp = false } else { resume() } }
    func clearDisplay() {
        watermark = latestSequence ?? state.records.last?.seq ?? watermark
        state.records = []; state.selection = []; state.trace = nil
        state.cleared = true; state.newCount = 0; state.follows = true
        traceTask?.cancel(); traceOperation = nil
    }
    func jump(epochMs: Int64) {
        guard let record = state.records.first(where: { $0.epochMs >= epochMs }) else { return }
        let id = Self.recordID(record)
        state.follows = false; state.scrollTarget = id; state.scrollRevision += 1
        select([id])
    }
    func setRange(since: Int64, until: Int64) {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        state.follows = false
        changeQuery {
            $0.since = formatter.string(from: Date(timeIntervalSince1970: Double(since) / 1000))
            $0.until = formatter.string(from: Date(timeIntervalSince1970: Double(until) / 1000))
        }
    }
    func compose(kind: String, key: String? = nil, value: String, negate: Bool = false) async {
        do {
            let expression = try await logging.composeWindowFilter(.init(expression: query.expression,
                term: .init(kind: kind, key: key, value: value, negate: negate)))
            setExpression(expression)
        } catch { report(error) }
    }
    func formatted(records: [RustCoreBridge.LogQueryRecord], format: String) async -> String? {
        do { return try await logging.formatWindowRecords(.init(lines: records.map(\.line), format: format, environment: environment)) }
        catch { report(error); return nil }
    }
    func toggleCollapse() { preferences.collapse.toggle(); persist() }
    func cycleTime() { preferences.timeMode = (preferences.timeMode + 1) % 3; persist() }
    func setColumn(_ column: String, hidden: Bool) {
        if hidden { preferences.hidden.insert(column) } else { preferences.hidden.remove(column) }; persist()
    }
    func setWidth(_ column: String, width: Double) { preferences.widths[column] = min(2000, max(40, width)); persist() }
    func saveBookmark(name: String) {
        guard !name.isEmpty, preferences.bookmarks.count < Self.maximumBookmarks else { return }
        preferences.bookmarks.append(.init(name: String(name.prefix(128)), query: query)); persist()
    }
    func applyBookmark(_ bookmark: LogWindowPreferences.Bookmark) { preferences.query = bookmark.query; persist(); refresh() }
    func deleteBookmark(_ id: UUID) { preferences.bookmarks.removeAll { $0.id == id }; persist() }
    func stopDiagnostics() async { await logging.configureDiagnostic(category: state.diagnosticCategory, enabled: false); refresh() }
    func openExport() { onOpenExport?() }
    private func persist() { save(preferences) }
    private func report(_ error: Error) {
        guard !error.isCancellation else { return }
        sink?.emit(AppLoggingDiagnosticsFailed(error: error))
        self.error = L10n.string("Could not load logs. Try again.")
    }
}

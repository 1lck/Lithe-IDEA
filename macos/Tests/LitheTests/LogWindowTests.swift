import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import LitheModuleAPI
@testable import Lithe

extension Duration {
    /// Deadline for log-window state that arrives through a real `MacLogStore`
    /// query. Channel lookup, filter parsing, the writer drain, file reads and the
    /// Core query run one after another on the store's I/O queue; on a loaded
    /// machine they can take longer than the default 2 s gate. This matches the
    /// store's own 10 s operation lease. Gates still open on the delivered state,
    /// so a passing test does not wait for the deadline.
    static let logStoreQuery = Duration.seconds(10)
}

/// Uses real Core parsing/query/formatting and real native disk storage. Gates only
/// control when an otherwise real query is delivered to the presentation model.
private final class WindowQueryGate: LogWindowLogging, @unchecked Sendable {
    let native: MacLogStore
    let entered = TestGate()
    let release = TestGate()
    private let lock = NSLock()
    private var first = true
    private var failsNextBatch = false
    private var subscriptions = 0
    let subscribed = TestGate()
    let batchAttempted = TestGate()
    init(_ native: MacLogStore) { self.native = native }
    func failNextBatch() { lock.withLock { failsNextBatch = true } }
    var subscriptionCount: Int { lock.withLock { subscriptions } }
    func windowLiveSummary(_ records: [RustCoreBridge.LogQueryRecord]) async throws -> LogWindowLiveSummary { try await native.windowLiveSummary(records) }
    func queryWindow(_ query: LogWindowQuery) async throws -> LogWindowCollection {
        let shouldGate = lock.withLock { let value = first; first = false; return value }
        let result = try await native.queryWindow(query)
        if shouldGate {
            entered.open()
            guard await release.waitUntilOpen() else { throw CancellationError() }
        }
        return result
    }
    func queryWindowBatch(_ entries: [LogWindowBatch], query: LogWindowQuery) async throws -> RustCoreBridge.LogQueryResult {
        if lock.withLock({ let fail = failsNextBatch; failsNextBatch = false; return fail }) {
            batchAttempted.open()
            throw CocoaError(.fileReadUnknown)
        }
        return try await native.queryWindowBatch(entries, query: query)
    }
    func subscribeWindow() async throws -> AsyncStream<[LogWindowBatch]> {
        let stream = try await native.subscribeWindow()
        lock.withLock { subscriptions += 1 }
        subscribed.open()
        return stream
    }
    func parseWindowFilter(_ expression: String) async throws -> RustCoreBridge.LogFilterParse { try await native.parseWindowFilter(expression) }
    func composeWindowFilter(_ request: RustCoreBridge.LogComposeRequest) async throws -> String { try await native.composeWindowFilter(request) }
    func formatWindowRecords(_ request: RustCoreBridge.LogFormatRequest) async throws -> String { try await native.formatWindowRecords(request) }
    func windowEngineChannel(providerID: String) async throws -> String { try await native.windowEngineChannel(providerID: providerID) }
    func configureDiagnostic(category: String?, enabled: Bool) async { await native.configureDiagnostic(category: category, enabled: enabled) }
}

@Suite("Application log window", .serialized)
@MainActor
struct LogWindowTests {
    @Test func findBelongsOnlyToTheWindowThatInstalledItsTarget() throws {
        let target = MacWindowFindTarget()
        var focuses = 0
        target.focus = { focuses += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = target
        defer { window.contentView = nil; window.close() }
        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f",
                charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        }
        #expect(MacWindowFindTarget.handle(try event(.command)))
        #expect(focuses == 1)
        #expect(!MacWindowFindTarget.handle(try event([.command, .shift])))
        window.contentView = NSView()
        #expect(!MacWindowFindTarget.handle(try event(.command)))
        #expect(focuses == 1)
    }

    @Test func tableColumnsUseTheViewportWithoutSavingAutomaticWidths() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        await writer.finishSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        var preferences = LogWindowPreferences()
        preferences.widths["channel"] = 190
        let model = LogWindowModel(logging: writer, preferences: preferences)
        let host = NSHostingView(rootView: LogWindowTable(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { model.stop(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try #require(descendants(host).compactMap { $0 as? LogTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        let widths = table.tableColumns.map(\.width)
        window.setContentSize(NSSize(width: 1900, height: 600))
        host.layoutSubtreeIfNeeded()
        let columns = table.tableColumns.filter { !$0.isHidden }
        let usedWidth = columns.reduce(0) { $0 + $1.width + table.intercellSpacing.width }
        #expect(abs(usedWidth - scroll.contentSize.width) <= 2)
        for identifier in ["event", "message", "fields"] {
            let index = table.column(withIdentifier: .init(identifier))
            #expect(table.tableColumns[index].width > widths[index])
        }
        #expect(table.tableColumn(withIdentifier: .init("channel"))?.width == 190)
        #expect(model.preferences.widths == preferences.widths)
        window.setContentSize(NSSize(width: 680, height: 400))
        host.layoutSubtreeIfNeeded()
        #expect(table.tableColumns.allSatisfy { $0.width >= $0.minWidth })
        #expect(scroll.hasHorizontalScroller)
        window.setContentSize(NSSize(width: 1900, height: 600))
        host.layoutSubtreeIfNeeded()
        #expect(model.preferences.widths == preferences.widths)
    }

    /// A header drag on an expanding column ends where the user released it: the
    /// viewport fit after the drag, a narrower window and a reopened window all
    /// agree, and only base widths are saved.
    @Test func draggedColumnsKeepTheirReleasedWidth() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        await writer.finishSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved = LogWindowPreferences()
        var opened: [(LogWindowModel, NSWindow)] = []
        defer { for (model, window) in opened { model.stop(); window.contentView = nil; window.close() } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func open() throws -> (NSWindow, NSView, LogTableView) {
            let model = LogWindowModel(logging: writer, preferences: saved, save: { saved = $0 })
            let host = NSHostingView(rootView: LogWindowTable(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1900, height: 600),
                styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            opened.append((model, window))
            host.layoutSubtreeIfNeeded()
            return (window, host, try #require(descendants(host).compactMap { $0 as? LogTableView }.first))
        }
        func width(_ table: LogTableView, _ column: String) -> CGFloat {
            table.tableColumn(withIdentifier: .init(column))?.width ?? 0
        }
        /// What a header drag does: AppKit resizes the column while the fit is
        /// paused, then the header commits the widths it started from.
        func drag(_ table: LogTableView, _ column: String, to released: CGFloat) throws {
            let previous = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier, $0.width) })
            table.isResizingColumns = true
            table.tableColumn(withIdentifier: .init(column))?.width = released
            table.isResizingColumns = false
            try #require(table.owner).commitColumnWidths(previous: previous)
        }
        func fillsViewport(_ table: LogTableView) throws -> Bool {
            let scroll = try #require(table.enclosingScrollView)
            let used = table.tableColumns.filter { !$0.isHidden }.reduce(0) { $0 + $1.width + table.intercellSpacing.width }
            return abs(used - scroll.contentSize.width) <= 2
        }

        let (window, host, table) = try open()
        let expanded = width(table, "event")
        #expect(expanded > 300)
        try drag(table, "event", to: expanded + 10)
        host.layoutSubtreeIfNeeded()
        #expect(abs(width(table, "event") - (expanded + 10)) <= 0.5)
        #expect(try fillsViewport(table))
        let base = try #require(saved.widths["event"])
        #expect(base < expanded)
        #expect(saved.widths.keys.sorted() == ["event"])

        // A narrower window shows the base and scrolls; widening again restores
        // the released width. Resizing the window saves nothing.
        window.setContentSize(NSSize(width: 680, height: 600))
        host.layoutSubtreeIfNeeded()
        #expect(abs(width(table, "event") - base) <= 0.5)
        window.setContentSize(NSSize(width: 1900, height: 600))
        host.layoutSubtreeIfNeeded()
        #expect(abs(width(table, "event") - (expanded + 10)) <= 0.5)
        #expect(saved.widths == ["event": base])

        let (_, _, reopened) = try open()
        #expect(abs(width(reopened, "event") - (expanded + 10)) <= 0.5)

        // Narrower than the minimum base allows: the other expanding columns take
        // larger bases so the released width still holds after reopening.
        try drag(reopened, "event", to: 60)
        #expect(abs(width(reopened, "event") - 60) <= 0.5)
        #expect(try fillsViewport(reopened))
        #expect(saved.widths["event"] == 40)
        let (_, _, again) = try open()
        #expect(abs(width(again, "event") - 60) <= 0.5)
        #expect(abs(width(again, "message") - width(reopened, "message")) <= 0.5)
    }

    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func emit(_ writer: MacLogStore) { writer.emit(AppSessionStarted()) }
    private func ready(_ model: LogWindowModel) -> (TestGate, AnyCancellable) {
        let gate = TestGate()
        let observation = model.$state.sink { if !$0.records.isEmpty { gate.open() } }
        return (gate, observation)
    }
    @Test func liveBatchRespectsSelectedTimeRange() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = RustCoreBridge()
        let lines = try core.encodeLogs(.init(events: [0, 1, 2].map { index in
            .init(ts: "2026-11-03T00:00:0\(index).000Z", level: "INFO", seq: UInt64(index + 1),
                event: "app.session.started", msg: "", fields: [:])
        }, deduplicate: false)).results.compactMap(\.line)
        var query = LogWindowQuery()
        query.since = "2026-11-03T00:00:01.000Z"; query.until = query.since
        let result = try await writer.queryWindowBatch(lines.map { .init(channel: "app", line: $0) }, query: query)
        #expect(result.records.map(\.seq) == [2])
        await writer.finishSession()
    }
    @Test func historicalSequenceDoesNotHideNewCurrentSessionRecords() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        let previous = directory.appendingPathComponent("sessions/2026-11-02T00-00-00_abcdef12")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        let line = try #require(try RustCoreBridge().encodeLogs(.init(events: [
            .init(ts: "2026-11-02T00:00:00.000Z", level: "INFO", seq: 5000,
                event: "app.session.started", msg: "", fields: [:])
        ])).results.first?.line)
        try Data((line + "\n").utf8).write(to: previous.appendingPathComponent("app.log"))
        var preferences = LogWindowPreferences(); preferences.query.session = "previous"
        let model = LogWindowModel(logging: writer, preferences: preferences)
        let previousLoaded = TestGate(), currentLoaded = TestGate(), freshLoaded = TestGate()
        let observation = model.$state.sink { state in
            if state.records.contains(where: { $0.seq == 5000 }) { previousLoaded.open() }
            if state.records.contains(where: { $0.event == "app.session.started" && $0.seq < 5000 }) { currentLoaded.open() }
            if state.records.contains(where: { $0.event == "app.notification.operation_rejected" }) { freshLoaded.open() }
        }
        defer { model.stop(); observation.cancel(); try? FileManager.default.removeItem(at: directory) }
        emit(writer); model.refresh()
        try #require(await previousLoaded.waitUntilOpen(timeout: .logStoreQuery))
        model.changeQuery { $0.session = "current" }
        try #require(await currentLoaded.waitUntilOpen(timeout: .logStoreQuery))
        model.clearDisplay()
        writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "after_clear"))
        model.refresh()
        try #require(await freshLoaded.waitUntilOpen(timeout: .logStoreQuery))
        #expect(model.state.records.allSatisfy { $0.event != "app.session.started" })
        await writer.finishSession()
    }
    @Test func liveFailureCanBeRetriedWithoutReopeningWindow() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        let logging = WindowQueryGate(writer)
        logging.release.open()
        let model = LogWindowModel(logging: logging)
        let loaded = TestGate()
        let observation = model.$state.sink { if $0.directory != nil { loaded.open() } }
        let failed = TestGate(), recovered = TestGate()
        let errors = model.$error.sink { if $0 != nil { failed.open() } }
        let records = model.$state.sink { state in
            if state.records.contains(where: { $0.fields["reason"] == "recovered" }) { recovered.open() }
        }
        defer { model.stop(); observation.cancel(); errors.cancel(); records.cancel(); try? FileManager.default.removeItem(at: directory) }
        model.start()
        try #require(await loaded.waitUntilOpen(timeout: .logStoreQuery))
        try #require(await logging.subscribed.waitUntilOpen(timeout: .logStoreQuery))
        logging.failNextBatch()
        writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "fail_batch"))
        try await writer.flush()
        try #require(await logging.batchAttempted.waitUntilOpen(timeout: .logStoreQuery))
        try #require(await failed.waitUntilOpen(timeout: .logStoreQuery))
        #expect(!model.state.follows)
        model.resume()
        writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "recovered"))
        try await writer.flush()
        try #require(await recovered.waitUntilOpen(timeout: .logStoreQuery))
        #expect(model.state.follows)
        #expect(logging.subscriptionCount == 2)
        await writer.finishSession()
    }
    @Test func realQueryInvalidDraftAndClearPreserveDiskEvidence() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        let model = LogWindowModel(logging: writer)
        let (loaded, observation) = ready(model)
        defer { model.stop(); observation.cancel(); try? FileManager.default.removeItem(at: directory) }
        emit(writer)
        model.refresh()
        #expect(await loaded.waitUntilOpen(timeout: .logStoreQuery))
        let records = model.state.records
        let invalid = TestGate()
        let parsed = model.$diagnostics.sink { if !$0.isEmpty { invalid.open() } }
        defer { parsed.cancel() }
        model.setExpression("level:invalid")
        #expect(await invalid.waitUntilOpen(timeout: .logStoreQuery))
        #expect(model.state.records == records)
        model.clearDisplay()
        #expect(model.state.records.isEmpty && model.state.cleared)
        let disk = try await writer.queryWindow(.init())
        #expect(!disk.result.records.isEmpty)
        await writer.finishSession()
    }
    @Test func debounceAndCancelledOldQueryCannotReplaceNewSelection() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        let logging = WindowQueryGate(writer)
        let delayEntered = TestGate(), delayRelease = TestGate()
        let model = LogWindowModel(logging: logging, delay: {
            delayEntered.open()
            guard await delayRelease.waitUntilOpen() else { throw CancellationError() }
        })
        defer { model.stop(); logging.release.open(); delayRelease.open(); try? FileManager.default.removeItem(at: directory) }
        emit(writer)
        model.refresh()
        #expect(await logging.entered.waitUntilOpen(timeout: .logStoreQuery))
        model.setExpression("event:app.session.started")
        #expect(await delayEntered.waitUntilOpen())
        #expect(model.state.records.isEmpty)
        let (loaded, observation) = ready(model)
        defer { observation.cancel() }
        delayRelease.open()
        #expect(await loaded.waitUntilOpen(timeout: .logStoreQuery))
        logging.release.open()
        #expect(model.query.expression == "event:app.session.started")
        #expect(model.state.records.allSatisfy { $0.event == "app.session.started" })
        await writer.finishSession()
    }
    @Test func realtimeWatermarkCapPauseAndReference() async throws {
        let directory = root()
        // A fixed lease clock keeps the 10 s control deadline from depending on
        // how fast this machine queries the three 10,000-record batches.
        let writer = MacLogStore(defaultDirectory: directory, diagnosticNow: { 0 })
        let model = LogWindowModel(logging: writer)
        defer { model.stop(); try? FileManager.default.removeItem(at: directory) }
        let core = RustCoreBridge()
        let stamp = "2026-11-03T00:00:00.000Z"
        // Canonical data is produced by the actual catalog encoder.
        let encoded = try core.encodeLogs(.init(events: [.init(ts: stamp, level: "INFO", seq: 1,
            event: "app.session.started", msg: "", fields: [:])]))
        let line = try #require(encoded.results.first?.line)
        let batch = try await writer.queryWindowBatch([.init(channel: "app", line: line)], query: .init())
        model.append(batch)
        model.userScrolledUp()
        #expect(!model.state.follows && model.state.scrolledUp)
        let second = try core.encodeLogs(.init(events: [.init(ts: stamp, level: "INFO", seq: 2,
            event: "app.session.started", msg: "", fields: [:])]))
        let next = try await writer.queryWindowBatch([.init(channel: "app", line: try #require(second.results.first?.line))], query: .init())
        model.append(next)
        #expect(model.state.newCount == 1)
        model.resume()
        #expect(model.state.follows && model.state.newCount == 0)
        model.clearDisplay()
        let clearedBatch = try await writer.queryWindowBatch([.init(channel: "app", line: line)], query: model.query)
        model.append(clearedBatch)
        #expect(model.state.records.isEmpty)
        let clearedNext = try await writer.queryWindowBatch([.init(channel: "app", line: try #require(second.results.first?.line))], query: model.query)
        model.append(clearedNext)
        #expect(model.state.records.isEmpty)
        // Generate every boundary record through the actual catalog codec; the
        // canonical line and the seq in the decoded model must agree.
        for base in [3, 10003, 20003] {
            let encoded = try core.encodeLogs(.init(events: (base..<(base + 10000)).map { index in
                .init(ts: stamp, level: "INFO", seq: UInt64(index), event: "app.session.started", msg: "", fields: [:])
            }, deduplicate: false))
            let result = try await writer.queryWindowBatch(encoded.results.compactMap(\.line).map {
                .init(channel: "app", line: $0)
            }, query: model.query)
            model.append(result)
        }
        #expect(model.state.records.count == LogWindowModel.maximumRecords)
        #expect(model.state.records.first?.seq == 10003)
        #expect(model.state.discarded == 10000)
        await writer.finishSession()
    }
    @Test func openReferenceAndPersistenceBoundsAndCoreChannelResolution() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        var preferences = LogWindowPreferences()
        preferences.query.expression = String(repeating: "中", count: 1000)
        preferences.query.channelPrefixes = (0..<100).map { "lsp/server\($0)" }
        let bounded = LogWindowModel(logging: writer, preferences: preferences)
        #expect(bounded.query.expression.utf8.count <= 1024)
        #expect(bounded.query.channelPrefixes.count == 64)
        for n in 0..<60 { bounded.saveBookmark(name: "filter \(n)") }
        #expect(bounded.preferences.bookmarks.count == 50)
        let restored = try JSONDecoder().decode(LogWindowPreferences.self, from: JSONEncoder().encode(bounded.preferences))
        #expect(restored == bounded.preferences)
        var previousPreferences = LogWindowPreferences(); previousPreferences.query.session = "previous"
        let model = LogWindowModel(logging: writer, preferences: previousPreferences)
        let located = TestGate()
        let observation = model.$state.sink { if !$0.selection.isEmpty { located.open() } }
        defer { model.stop(); bounded.stop(); observation.cancel(); try? FileManager.default.removeItem(at: directory) }
        emit(writer)
        model.apply(.init(reference: .init(channel: "app", event: "app.session.started")))
        #expect(model.query.session == "current")
        #expect(await located.waitUntilOpen(timeout: .logStoreQuery))
        #expect(model.selected?.event == "app.session.started")
        #expect(model.query.channelPrefixes == ["app"])
        #expect(model.state.scrollTarget != nil)
        let channel = try await writer.windowEngineChannel(providerID: "c++")
        #expect(channel == (try RustCoreBridge().engineLogChannel(providerID: "c++")))
        #expect(!channel.isEmpty)
        await writer.finishSession()
    }
    @Test func bridgeRoundTripsCoreShapesAndCopyEnvironment() throws {
        let core = RustCoreBridge()
        let parse = try core.parseLogFilter("event:app.session.started hello")
        #expect(parse.errors.isEmpty)
        let data = try JSONEncoder().encode(parse)
        #expect(try JSONDecoder().decode(RustCoreBridge.LogFilterParse.self, from: data).terms.count == 2)
        let expression = try core.composeLogFilter(.init(expression: "hello", term: .init(kind: "event", value: "app.session.started")))
        let encoded = try core.encodeLogs(.init(events: [.init(ts: "2026-11-03T00:00:00.000Z", level: "INFO", seq: 1, event: "app.session.started", msg: "", fields: [:])]))
        let line = try #require(encoded.results.first?.line)
        let query = RustCoreBridge.LogQueryV2(sources: [.init(relativePath: "app.log", text: line)],
            channelPrefixes: [], minimumLevel: nil, since: nil, until: nil, search: nil,
            expression: expression, levels: ["INFO"], histogramBuckets: 90)
        let roundTrip = try JSONDecoder().decode(RustCoreBridge.LogQueryV2.self, from: JSONEncoder().encode(query))
        #expect(roundTrip.levels == ["INFO"])
        let result = try core.queryLogsV2(roundTrip)
        // Bare text intentionally intersects the event predicate.
        #expect(result.records.isEmpty)
        let text = try core.formatLogRecords(.init(lines: [line], format: "markdown",
            environment: .init(appVersion: "1", osVersion: "macOS", architecture: "arm64", plugins: ["dev.example"])))
        #expect(text.contains("dev.example") && text.contains(line))
    }
    @Test func adjacentCoreFoldKeysMergeDuringLiveAppendAndExpand() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        let model = LogWindowModel(logging: writer)
        defer { model.stop(); try? FileManager.default.removeItem(at: directory) }
        let core = RustCoreBridge()
        let encoded = try core.encodeLogs(.init(events: (1...4).map {
            .init(ts: "2026-11-03T00:00:00.000Z", level: "INFO", seq: UInt64($0),
                  event: "app.session.started", msg: "", fields: [:])
        }, deduplicate: false))
        let lines = encoded.results.compactMap(\.line)
        let first = try await writer.queryWindowBatch(lines.prefix(2).map { .init(channel: "app", line: $0) }, query: .init())
        let last = try await writer.queryWindowBatch(lines.suffix(2).map { .init(channel: "app", line: $0) }, query: .init())
        model.append(first)
        let bridge = LogWindowTable(model: model)
        let coordinator = bridge.makeCoordinator()
        let table = LogTableView()
        let scroll = NSScrollView(); scroll.documentView = table
        coordinator.table = table; coordinator.scroll = scroll
        coordinator.update()
        #expect(coordinator.rows.count == 2)
        #expect(model.displayRows.count == coordinator.rows.count)
        model.append(last); coordinator.update()
        #expect(coordinator.rows.count == 1)
        #expect(coordinator.rows.first?.count == 4)
        // The status bar counts the folded run once, matching the table.
        #expect(model.displayRows.count == 1)
        model.expandedRuns.insert(LogWindowModel.recordID(model.state.records[0]))
        coordinator.update()
        #expect(coordinator.rows.count == 4)
        #expect(model.displayRows.count == 4)
        await writer.finishSession()
    }
    @Test func stageAFixtureQueryShapeDecodesAndReencodes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared/fixtures/diagnostics/logging-v2.json"))) as? [String: Any]
        let commands = try #require(fixture?["windowCommands"] as? [[String: Any]])
        let expected = try #require(commands.first { ($0["expected"] as? [String: Any])?["foldMinimumRun"] != nil }?["expected"])
        let result = try JSONDecoder().decode(RustCoreBridge.LogQueryResult.self, from: JSONSerialization.data(withJSONObject: expected))
        #expect(result.foldMinimumRun == 3 && result.records[0].foldKey == "c4d60ef213ff7102")
        let roundTrip = try JSONDecoder().decode(RustCoreBridge.LogQueryResult.self, from: JSONEncoder().encode(result))
        #expect(roundTrip.records == result.records)
        #expect(roundTrip.opSummary?.durationMs == 0)
    }
    @Test func languageServerEntryOpensEditorTabWithoutChangingApplicationLogs() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        let store = WindowPreferenceStore()
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode, applicationLogging: writer)
        defer { container.moduleLifecycleCoordinator.stop(); try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(settings: settings, services: container.services)
        let applicationLogs = LogWindowCoordinator()
        container.services.logWindowCoordinator = applicationLogs
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            let feature = try #require(model.languageServerLogsFeature)
            model.showLanguageServerLogs(providerID: "c++")
            #expect(model.editorTabItems.filter { $0 == .languageLogs }.count == 1)
            #expect(model.editorTabOrderFeature.focusedItem == .languageLogs)
            #expect(feature.providerID == "c++")
            #expect(applicationLogs.request == nil)
            // Opening again reuses the one tab and switches its server.
            model.showLanguageServerLogs(providerID: "java")
            #expect(model.editorTabItems.filter { $0 == .languageLogs }.count == 1)
            #expect(feature.providerID == "java")
            model.closeLanguageServerLogsTab()
            #expect(!model.editorTabItems.contains(.languageLogs))
        }
        await writer.finishSession()
    }
    @Test func savedPreferencesUseExistingSettingsStore() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        let store = WindowPreferenceStore()
        let settings = AppSettings(store: store)
        let model = LogWindowModel(logging: writer, save: { settings.logWindowPreferences = $0 })
        defer { model.stop(); try? FileManager.default.removeItem(at: directory) }
        model.toggleCollapse(); model.cycleTime(); model.setWidth("event", width: 245)
        model.setColumn("fields", hidden: true); model.saveBookmark(name: "startup")
        let restored = AppSettings(store: store).logWindowPreferences
        #expect(!restored.collapse && restored.timeMode == 1)
        #expect(restored.widths["event"] == 245 && restored.hidden.contains("fields"))
        #expect(restored.bookmarks.first?.name == "startup")
        await writer.finishSession()
    }
    @Test func exportOpenRequestKeepsWindowFilterAndPresentsOnce() {
        let writer = MacLogStore()
        var preferences = LogWindowPreferences()
        preferences.query.expression = "level>=warn"
        let model = LogWindowModel(logging: writer, preferences: preferences)
        defer { model.stop() }
        var presentations = 0
        model.onOpenExport = { presentations += 1 }
        model.apply(.init(presentsExport: true))
        #expect(presentations == 1)
        #expect(model.query.expression == "level>=warn")
        model.apply(.init())
        #expect(presentations == 1)
    }
    @Test func enablingDiagnosticsCoversAllChannelsAndRefreshesWindow() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = MacLogStore(defaultDirectory: directory)
        let model = LogWindowModel(logging: writer)
        defer { model.stop() }
        let enabled = TestGate()
        let observation = model.$state.sink {
            if $0.diagnosticRemaining > 0 { enabled.open() }
        }
        defer { observation.cancel() }
        model.changeQuery { $0.levels = [] }
        await model.startDiagnostics()
        try #require(await enabled.waitUntilOpen(timeout: .logStoreQuery))
        #expect(model.state.diagnosticCategory == nil)
        #expect(model.state.directory?.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
        #expect(model.state.records.isEmpty)
        let status = try await writer.status()
        #expect(status.diagnosticEnabled && status.diagnosticCategory == nil)
        await model.stopDiagnostics()
        #expect(try await !writer.status().diagnosticEnabled)
        await writer.finishSession()
    }
    @Test func menusAndKeymapUseOneOpenRequest() throws {
        let binding = KeyboardShortcutBinding.keyPress(key: "l", modifiers: [.shift, .command])
        let owners = LitheCommandCatalog.commands.filter { $0.defaultBindings.contains(binding) }
        #expect(owners.map(\.id) == ["show-logs"])
        let coordinator = LogWindowCoordinator()
        var opened = 0
        coordinator.present = { opened += 1 }
        coordinator.open(.init(channelPrefixes: ["lsp/example"]))
        #expect(opened == 1 && coordinator.request?.channelPrefixes == ["lsp/example"])
    }
}

private final class WindowPreferenceStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

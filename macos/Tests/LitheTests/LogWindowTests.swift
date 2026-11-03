import AppKit
import Combine
import Foundation
import Testing
import LitheModuleAPI
@testable import Lithe

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
        try #require(await previousLoaded.waitUntilOpen())
        model.changeQuery { $0.session = "current" }
        try #require(await currentLoaded.waitUntilOpen())
        model.clearDisplay()
        writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "after_clear"))
        model.refresh()
        try #require(await freshLoaded.waitUntilOpen())
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
        try #require(await loaded.waitUntilOpen())
        try #require(await logging.subscribed.waitUntilOpen())
        logging.failNextBatch()
        writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "fail_batch"))
        try await writer.flush()
        try #require(await logging.batchAttempted.waitUntilOpen())
        try #require(await failed.waitUntilOpen())
        #expect(!model.state.follows)
        model.resume()
        writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "recovered"))
        try await writer.flush()
        try #require(await recovered.waitUntilOpen())
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
        #expect(await loaded.waitUntilOpen())
        let records = model.state.records
        let invalid = TestGate()
        let parsed = model.$diagnostics.sink { if !$0.isEmpty { invalid.open() } }
        defer { parsed.cancel() }
        model.setExpression("level:invalid")
        #expect(await invalid.waitUntilOpen())
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
        #expect(await logging.entered.waitUntilOpen())
        model.setExpression("event:app.session.started")
        #expect(await delayEntered.waitUntilOpen())
        #expect(model.state.records.isEmpty)
        let (loaded, observation) = ready(model)
        defer { observation.cancel() }
        delayRelease.open()
        #expect(await loaded.waitUntilOpen())
        logging.release.open()
        #expect(model.query.expression == "event:app.session.started")
        #expect(model.state.records.allSatisfy { $0.event == "app.session.started" })
        await writer.finishSession()
    }
    @Test func realtimeWatermarkCapPauseAndReference() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
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
        #expect(await located.waitUntilOpen())
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
    @Test func languageServerEntryEmitsCoreResolvedOpenRequestWithoutEditorTab() async throws {
        let directory = root()
        let writer = MacLogStore(defaultDirectory: directory)
        let store = WindowPreferenceStore()
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode, applicationLogging: writer)
        defer { container.moduleLifecycleCoordinator.stop(); try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(settings: settings, services: container.services)
        let coordinator = LogWindowCoordinator()
        container.services.logWindowCoordinator = coordinator
        let opened = TestGate()
        coordinator.present = { opened.open() }
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            let tabs = model.editorTabItems
            model.showLanguageServerLogs(providerID: "c++")
            #expect(await opened.waitUntilOpen())
            let expected = try await writer.windowEngineChannel(providerID: "c++")
            #expect(coordinator.request?.channelPrefixes == [expected])
            #expect(model.editorTabItems == tabs)
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
        try #require(await enabled.waitUntilOpen())
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
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Lithe/Views/Workbench/WorkbenchView.swift"), encoding: .utf8)
        let plugin = try #require(source.range(of: ".action(\"Plugins…\")"))
        let logs = try #require(source.range(of: ".action(\"Logs and Diagnostics…\")"))
        let theme = try #require(source.range(of: ".action(\"Theme…\")"))
        #expect(plugin.lowerBound < logs.lowerBound && logs.lowerBound < theme.lowerBound)
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

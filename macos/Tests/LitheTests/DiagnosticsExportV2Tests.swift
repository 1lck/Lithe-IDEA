import Combine
import Foundation
import Testing
import LitheModuleAPI
@testable import Lithe

@Suite("Diagnostic export v2", .serialized)
@MainActor
struct DiagnosticsExportV2Tests {
    @Test func selectionsMapToCoreRequestsWithWindowFilter() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let service = DiagnosticsExportService(logDirectoryProviding: ExportV2Directory(),
            fileStorage: UnavailableFileStorage(), systemDiagnostics: ExportV2Environment(),
            archiver: ExportV2Archive(), core: RustCoreBridge())
        let feature = DiagnosticsFeatureModel(service: service, now: { date })
        #expect(feature.exportQuery.session == "current")
        feature.range = .recent
        #expect(feature.exportQuery.session == "all" && feature.exportQuery.recentSessions == 3)
        feature.range = .day
        #expect(feature.exportQuery.since == ISO8601DateFormatter().string(from: date.addingTimeInterval(-86400)))

    }

    @Test func freezeUsesCorePlanAndIncludesOnlyConfirmedFilteredEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Date(timeIntervalSince1970: 1_793_664_000)
        let writer = MacLogStore(defaultDirectory: root.appendingPathComponent("logs"), now: { clock })
        writer.emit(AppSessionStarted())
        writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "confirmed"))
        let archiver = ExportV2InspectArchive()
        let service = DiagnosticsExportService(logDirectoryProviding: ExportV2Directory(), fileStorage: ExportV2Storage(root: root),
            systemDiagnostics: ExportV2Environment(), archiver: archiver, core: RustCoreBridge(), applicationLogging: writer, now: { clock })
        let feature = DiagnosticsFeatureModel(service: service, now: { clock })
        let ready = TestGate()
        let observation = feature.$state.sink { if case .awaitingConfirmation = $0 { ready.open() } }
        defer { observation.cancel(); feature.dismiss() }
        var filter = LogWindowQuery(); filter.channelPrefixes = ["app"]; filter.levels = ["WARN"]; filter.expression = "operation:fixture"
        feature.presentExport(filter: filter)
        feature.currentFilterOnly = true
        feature.includeEnvironment = false
        try #require(await ready.waitUntilOpen())
        #expect(feature.exportQuery.channelPrefixes == ["app"])
        #expect(feature.exportQuery.levels == ["WARN"])
        #expect(feature.exportQuery.expression == "operation:fixture")
        guard case .awaitingConfirmation(let manifest) = service.state else { Issue.record("No frozen manifest"); return }
        #expect(manifest.redaction == "core-v2")
        #expect(!manifest.files.contains { $0.relativePath == "environment.json" })
        #expect(service.estimatedBytes > 0)
        writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "later"))
        await service.export(to: root.appendingPathComponent("result.zip"))
        let snapshot = archiver.snapshot
        #expect(snapshot.contains("confirmed") && !snapshot.contains("later"))
        #expect(!snapshot.contains("Application session started"))
        #expect(snapshot.contains("core-v2"))
        await writer.finishSession()
    }

    @Test func replacingOptionsCancelsTheInFlightCollector() async throws {
        let collector = ExportV2CancellationCollector()
        let service = DiagnosticsExportService(logDirectoryProviding: ExportV2Directory(), fileStorage: UnavailableFileStorage(),
            systemDiagnostics: ExportV2Environment(), archiver: ExportV2Archive(), core: RustCoreBridge(), applicationLogging: collector)
        let feature = DiagnosticsFeatureModel(service: service)
        feature.presentExport(filter: .init())
        defer { feature.dismiss(); collector.release.open() }
        try #require(await collector.entered.waitUntilOpen())
        feature.range = .recent
        collector.release.open()
        try #require(await collector.cancelled.waitUntilOpen())
        #expect(feature.exportQuery.recentSessions == 3)
    }

    @Test func logWindowOwnsMaintenanceAndExportPresentation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/Lithe/" + path), encoding: .utf8)
        }
        let window = try source("Views/Diagnostics/LogWindowView.swift")
        let settings = try source("Views/App/SettingsView.swift")
        let main = try source("Views/App/RootView.swift")
        let app = try source("LitheApp.swift")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Lithe/Views/Diagnostics/ApplicationLogSettingsView.swift").path))
        #expect(!settings.contains("diagnosticsSettings") && !settings.contains("logDirectoryControls"))
        #expect(!main.contains("DiagnosticsExportSheet"))
        #expect(app.contains("model.openLogs(.init(presentsExport: true))"))
        #expect(window.contains("DiagnosticsExportSheet(feature: exportFeature)"))
        for control in ["logs.enable-diagnostics", "logs.maintenance-menu", "NSOpenPanel()", "changeLogDirectory(to:", "clearLogs()", "Detailed diagnostics cover all channels and expire after 15 minutes."] {
            #expect(window.contains(control))
        }
        #expect(window.contains("if await exportFeature.changeLogDirectory(to: directory)"))
        #expect(window.contains("ByteCountFormatter.string(fromByteCount:"))
    }

    @Test func nativeCrashReportsAreBoundedRedactedAndFailuresAreNonfatal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for n in 0..<8 {
            let url = root.appendingPathComponent("Fixture_\(n).ips")
            let content = n == 0 ? String(repeating: "x", count: MacCrashReportCollector.maximumReportBytes + 10) : "token=synthetic-fixture-secret"
            try Data(content.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(Double(-n))], ofItemAtPath: url.path)
        }
        try Data("other-application".utf8).write(to: root.appendingPathComponent("Other_1.ips"))
        let old = root.appendingPathComponent("Fixture_old.ips")
        try Data("outside-range".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-1000)], ofItemAtPath: old.path)
        let logs = TypedLogRecorder()
        let collector = MacCrashReportCollector(directory: root, processName: "Fixture", bundleID: "dev.fixture", sink: logs)
        let result = try collector.collect(since: date.addingTimeInterval(-100), until: date)
        #expect(result.files.count == MacCrashReportCollector.maximumReports)
        #expect(result.files.allSatisfy { $0.data.count <= MacCrashReportCollector.maximumReportBytes })
        let contents = result.files.map { String(decoding: $0.data, as: UTF8.self) }.joined()
        #expect(!contents.contains("synthetic-fixture-secret") && !contents.contains("other-application") && !contents.contains("outside-range"))
        #expect(contents.contains("redacted"))
        #expect(result.status.contains { $0.contains("truncated") })
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let unavailable = try MacCrashReportCollector(directory: blocked, processName: "Fixture", bundleID: "dev.fixture", sink: logs)
            .collect(since: date.addingTimeInterval(-100), until: date)
        #expect(unavailable.files.isEmpty && !unavailable.status.isEmpty)
        #expect(logs.events.contains { $0 is AppDiagnosticsCrashSkipped })
    }
}

private struct ExportV2Directory: LogDirectoryProviding { let defaultLogDirectory = URL(fileURLWithPath: "/fixture/logs") }
private struct ExportV2Environment: SystemDiagnosticsProviding {
    func currentSnapshot(volumeURL: URL) -> SystemDiagnosticsSnapshot {
        .init(appVersion: "1.2.3", osName: "macOS", osVersion: "fixture", cpuCoreCount: 4, memoryRSSBytes: 0, diskFreeBytes: 0)
    }
}
private struct ExportV2Archive: DiagnosticsArchiving { func archive(directoryURL: URL, toZipURL: URL) throws {} }
private struct ExportV2Storage: FileStorage {
    let root: URL
    private let native = MacFileStorage()
    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root }
    func applicationSupportDirectory() -> URL { root }
    func temporaryDirectory() -> URL { root }
    func metadata(for url: URL) -> FileMetadata? { native.metadata(for: url) }
    func fileExists(at url: URL) -> Bool { native.fileExists(at: url) }
    func isExecutable(at url: URL) -> Bool { native.isExecutable(at: url) }
    func listDirectory(at url: URL) -> [URL] { native.listDirectory(at: url) }
    func readPrefix(from url: URL, byteCount: Int) throws -> Data { try native.readPrefix(from: url, byteCount: byteCount) }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data { try native.readData(from: url, options: options) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try native.writeData(data, to: url, options: options) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { try native.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories) }
    func removeItem(at url: URL) throws { try native.removeItem(at: url) }
    func moveItem(at source: URL, to target: URL) throws { try native.moveItem(at: source, to: target) }
    func copyItem(at source: URL, to target: URL) throws { try native.copyItem(at: source, to: target) }
}
private final class ExportV2InspectArchive: DiagnosticsArchiving, @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var snapshot: String { lock.withLock { value } }
    func archive(directoryURL: URL, toZipURL: URL) throws {
        let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey])!
        var text = ""
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                text += String(decoding: try Data(contentsOf: url), as: UTF8.self)
            }
        }
        lock.withLock { value = text }
    }
}
private final class ExportV2CancellationCollector: ApplicationLogging, @unchecked Sendable {
    let entered = TestGate(), release = TestGate(), cancelled = TestGate()
    func collect(query: ApplicationLogQuery) async throws -> ApplicationLogCollection {
        entered.open()
        guard await release.waitUntilOpen() else { if Task.isCancelled { cancelled.open() }; throw CancellationError() }
        if Task.isCancelled { cancelled.open(); throw CancellationError() }
        throw CocoaError(.userCancelled)
    }
    func configureDiagnostic(category: String?, enabled: Bool) async {}
    func clear() async throws {}
}

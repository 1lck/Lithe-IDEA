import LitheModuleAPI
import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Lithe

private struct WorkflowLogDirectory: LogDirectoryProviding {
    let defaultLogDirectory: URL
}

/// Real filesystem adapter with task-owned staging, never the user's cache.
private struct WorkflowDiskStorage: FileStorage {
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
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try native.moveItem(at: sourceURL, to: destinationURL) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { try native.copyItem(at: sourceURL, to: destinationURL) }
}

private struct WorkflowEnvironment: SystemDiagnosticsProviding {
    func currentSnapshot(volumeURL: URL) -> SystemDiagnosticsSnapshot {
        .init(appVersion: "1.2.3", osName: "macOS", osVersion: "Fixture", cpuCoreCount: 4, memoryRSSBytes: 1024, diskFreeBytes: 4096)
    }
}

private final class WorkflowClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance() { lock.withLock { value += 901 } }
}

@Suite("Logs and diagnostics workflow", .serialized)
@MainActor
struct DiagnosticsWorkflowTests {
    private func service(root: URL, logging: any ApplicationLogging) -> DiagnosticsExportService {
        .init(logDirectoryProviding: WorkflowLogDirectory(defaultLogDirectory: root),
            fileStorage: WorkflowDiskStorage(root: root), systemDiagnostics: WorkflowEnvironment(),
            archiver: MacDittoArchiver(processRunner: MacProcessRunner()), core: RustCoreBridge(),
            applicationLogging: logging)
    }

    @Test func nativeWorkflowFiltersExpiresSwitchesDirectoryAndExportsConfirmedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = WorkflowClock()
        let writer = MacLogStore(diagnosticNow: clock.now)
        try writer.redirect(to: root.appendingPathComponent("logs"))
        let workflow = service(root: root, logging: writer)
        let feature = DiagnosticsFeatureModel(service: workflow)
        defer { feature.dismiss() }
        writer.emit(EditorDocumentOpenFailed(error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "first evidence password=synthetic-secret"]), reason: "unavailable"))
        writer.emit(AppSessionStarted())
        await feature.refreshStatus()
        let collection = try await writer.collect(query: .init())
        #expect(collection.content.contains("first evidence"))
        #expect(!collection.content.contains("synthetic-secret"))
        await feature.setDiagnosticEnabled(true)
        #expect(feature.diagnosticEnabled && feature.diagnosticCategory == nil)
        clock.advance()
        await feature.refreshStatus()
        #expect(!feature.diagnosticEnabled)
        #expect(await feature.changeLogDirectory(to: root.appendingPathComponent("selected")))
        writer.emit(EditorDocumentOpenFailed(error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "confirmed evidence"]), reason: "unavailable"))
        await feature.refreshStatus()
        #expect(try await writer.collect(query: .init()).content.contains("confirmed evidence"))
        let ready = TestGate()
        let observation = workflow.$state.sink { if case .awaitingConfirmation = $0 { ready.open() } }
        defer { observation.cancel() }
        feature.presentExport()
        try #require(await ready.waitUntilOpen(), "Export state: \(String(describing: workflow.state))")
        writer.emit(EditorDocumentOpenFailed(error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "later evidence"]), reason: "unavailable"))
        #expect(feature.exportQuery.session == "current")
        let destination = root.appendingPathComponent("diagnostics.zip")
        await feature.export(to: destination)
        guard case .completed = feature.state else { Issue.record("Archive did not complete"); return }
        let unpack = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", destination.path, "*/logs/sessions/*/editor*.log"], currentDirectoryURL: root)
        #expect(unpack.terminationStatus == 0)
        let evidence = String(decoding: unpack.output, as: UTF8.self)
        #expect(evidence.contains("confirmed evidence") && !evidence.contains("later evidence"))
        await feature.clearLogs()
        #expect(feature.logsCleared)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocked)
        #expect(await feature.changeLogDirectory(to: blocked) == false)
        #expect(feature.logError != nil && !feature.isBusy)
        await feature.refreshStatus()
        #expect(feature.logError == nil, "A failed location change must leave the current writer usable")
        await writer.finishSession()
    }

    @Test(arguments: [ColorScheme.dark, .light], ["en", "zh-Hans"])
    func nativePageRendersItsActionsInBothLanguagesAndAppearances(scheme: ColorScheme, language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let instant = Date(timeIntervalSince1970: 1_793_664_000)
        let writer = MacLogStore(defaultDirectory: root.appendingPathComponent("logs"), now: { instant })
        await writer.configureDiagnostic(category: nil, enabled: true)
        let op = "fixture-operation"
        writer.emit(AppSessionStarted(operationID: op))
        writer.emit(EditorDocumentOpenFailed(error: LogFailure(domain: "fixture", code: "unavailable"), reason: "unavailable", operationID: op))
        writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "unavailable", operationID: op))
        writer.emit(LspSessionStageChanged(server: LogSegment("fixture-server")!, stage: "requested", operationID: op))
        for _ in 0..<4 { writer.emit(AppNotificationOperationRejected(operation: "fixture", reason: "repeated", operationID: op)) }
        writer.emit(AppDiagnosticsExportFailed(error: NSError(domain: "fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "token=synthetic-fixture-secret"]), stage: "planning", operationID: op))
        let logModel = LogWindowModel(logging: writer)
        let loaded = TestGate()
        let observation = logModel.$state.sink { if !$0.records.isEmpty { loaded.open() } }
        defer { observation.cancel(); logModel.stop() }
        logModel.refresh()
        try #require(await loaded.waitUntilOpen())
        let feature = DiagnosticsFeatureModel(service: service(root: root, logging: writer), now: { instant })
        let ready = TestGate()
        let confirmation = feature.$state.sink { if case .awaitingConfirmation = $0 { ready.open() } }
        defer { confirmation.cancel(); feature.dismiss() }
        feature.presentExport(filter: logModel.query)
        try #require(await ready.waitUntilOpen())
        logModel.select([LogWindowModel.recordID(logModel.state.records.last!)])
        let suite = "logging-probe-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            LogWindowView(model: logModel, coordinator: LogWindowCoordinator())
                .environmentObject(AppSettings(store: MacUserDefaultsStore(defaults: defaults)))
                .frame(width: 1000, height: 760)
            DiagnosticsExportSheet(feature: feature)
        }.background(LitheTheme.settingsSurface).environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1560, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { feature.dismiss(); window.contentView = nil; window.close() }
        if let directory = ProcessInfo.processInfo.environment["LITHE_LOGGING_SCREENSHOTS"] {
            try #require(Bundle.main.localizations.contains(language), "Localized screenshots require a host packaged with the product string tables")
            let title = AppLanguage(rawValue: language)?.localizedString("Logs and Diagnostics")
            #expect(title == (language == "zh-Hans" ? "日志与诊断" : "Logs and Diagnostics"))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("logging-\(scheme)-\(language).png"))
        }
        await writer.finishSession()
    }
}

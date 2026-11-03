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

private final class WorkflowCollector: ApplicationLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [ApplicationLogQuery] = []
    private var enabled = true
    private var empty = false
    let entered = TestGate()
    let release = TestGate()
    var receivedQueries: [ApplicationLogQuery] { lock.withLock { queries } }
    func collect(query: ApplicationLogQuery) async throws -> ApplicationLogCollection {
        lock.withLock { queries.append(query) }
        entered.open()
        guard await release.waitUntilOpen() else { throw CocoaError(.userCancelled) }
        return lock.withLock {
            .init(files: [], content: empty ? "" : "fresh evidence", truncated: true,
                effectiveDirectory: URL(fileURLWithPath: "/fixture/logs"), diagnosticEnabled: enabled,
                droppedEvents: 2, writeFailures: 1, diagnosticCategory: "language")
        }
    }
    func configureDiagnostic(category: String?, enabled: Bool) async { lock.withLock { self.enabled = enabled } }
    func clear() async throws { lock.withLock { empty = true } }
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

    @Test func changingFiltersDiscardsStaleEvidenceAndAlwaysReleasesLoading() async throws {
        let collector = WorkflowCollector()
        let feature = DiagnosticsFeatureModel(service: service(root: URL(fileURLWithPath: "/fixture/logs"), logging: collector))
        let refresh = Task { await feature.refreshLogs() }
        defer { collector.release.open(); refresh.cancel(); feature.dismiss() }
        try #require(await collector.entered.waitUntilOpen())
        feature.logSearch = "new filter"
        collector.release.open()
        await refresh.value
        #expect(!feature.isLoadingLogs)
        #expect(feature.logContent.isEmpty)
        await feature.refreshLogs()
        #expect(collector.receivedQueries.last?.search == "new filter")
        #expect(feature.logContent == "fresh evidence")
        #expect(feature.droppedEvents == 2 && feature.writeFailures == 1 && feature.logTruncated)
        feature.logCategory = "git"
        #expect(feature.diagnosticCategory == "language", "Changing a view filter must not mislabel the active diagnostic scope")
        await feature.clearLogs()
        #expect(feature.logContent.isEmpty && feature.logsCleared && !feature.isBusy)
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
        feature.logCategory = "language"
        await feature.refreshLogs()
        #expect(feature.logContent.contains("first evidence"))
        #expect(!feature.logContent.contains("synthetic-secret") && !feature.logContent.contains("other module"))
        await feature.setDiagnosticEnabled(true)
        #expect(feature.diagnosticEnabled && feature.diagnosticCategory == "language")
        clock.advance()
        await feature.refreshLogs()
        #expect(!feature.diagnosticEnabled)
        #expect(await feature.changeLogDirectory(to: root.appendingPathComponent("selected")))
        writer.emit(EditorDocumentOpenFailed(error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "confirmed evidence"]), reason: "unavailable"))
        await feature.refreshLogs()
        #expect(feature.logContent.contains("confirmed evidence") && !feature.logContent.contains("first evidence"))
        let ready = TestGate()
        let observation = workflow.$state.sink { if case .awaitingConfirmation = $0 { ready.open() } }
        defer { observation.cancel() }
        feature.presentExport()
        try #require(await ready.waitUntilOpen(), "Export state: \(String(describing: workflow.state))")
        writer.emit(EditorDocumentOpenFailed(error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "later evidence"]), reason: "unavailable"))
        feature.logCategory = "git"
        #expect(feature.exportQuery.category == "language")
        let destination = root.appendingPathComponent("diagnostics.zip")
        await feature.export(to: destination)
        guard case .completed = feature.state else { Issue.record("Archive did not complete"); return }
        let unpack = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", destination.path, "*/logs/sessions/*/editor*.log"], currentDirectoryURL: root)
        #expect(unpack.terminationStatus == 0)
        let evidence = String(decoding: unpack.output, as: UTF8.self)
        #expect(evidence.contains("confirmed evidence") && !evidence.contains("later evidence"))
        await feature.clearLogs()
        #expect(feature.logsCleared && feature.logContent.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocked)
        #expect(await feature.changeLogDirectory(to: blocked) == false)
        #expect(feature.logError != nil && !feature.isBusy)
        await feature.refreshLogs()
        #expect(feature.logError == nil, "A failed location change must leave the current writer usable")
    }

    @Test(arguments: [ColorScheme.dark, .light], ["en", "zh-Hans"])
    func nativePageRendersItsActionsInBothLanguagesAndAppearances(scheme: ColorScheme, language: String) async throws {
        let collector = WorkflowCollector()
        collector.release.open()
        let feature = DiagnosticsFeatureModel(service: service(root: URL(fileURLWithPath: "/fixture/logs"), logging: collector))
        await feature.refreshLogs()
        let host = NSHostingView(rootView: ApplicationLogDiagnosticsPage(feature: feature) {
            Text(verbatim: "fixture/logs")
        }.padding(20).frame(width: 620, height: 1000, alignment: .topLeading)
            .background(LitheTheme.settingsSurface).environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { feature.dismiss(); window.contentView = nil; window.close() }
        for identifier in ["logs.refresh", "logs.diagnostic-toggle", "logs.clear", "logs.export"] {
            _ = try await AgentNativeControlTestSupport.frame(of: identifier, in: host)
        }
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
    }
}

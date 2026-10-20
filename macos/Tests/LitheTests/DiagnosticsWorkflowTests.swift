import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Lithe

private struct WorkflowLogDirectory: LogDirectoryProviding {
    let defaultLogDirectory: URL
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
    func record(level: String, scope: String, message: String, fields: [String: String]) {}
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
            fileStorage: MacFileStorage(), systemDiagnostics: WorkflowEnvironment(),
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
        let writer = MacApplicationLogWriter(diagnosticNow: clock.now)
        try writer.redirect(to: root.appendingPathComponent("logs"))
        let workflow = service(root: root, logging: writer)
        let feature = DiagnosticsFeatureModel(service: workflow)
        defer { feature.dismiss() }
        writer.record(level: "error", scope: "language.java", message: "first evidence password=synthetic-secret")
        writer.record(level: "info", scope: "git.fetch", message: "other module")
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
        writer.record(level: "error", scope: "language.java", message: "confirmed evidence")
        await feature.refreshLogs()
        #expect(feature.logContent.contains("confirmed evidence") && !feature.logContent.contains("first evidence"))
        let ready = TestGate()
        let observation = workflow.$state.sink { if case .awaitingConfirmation = $0 { ready.open() } }
        defer { observation.cancel() }
        feature.presentExport()
        try #require(await ready.waitUntilOpen())
        writer.record(level: "error", scope: "language.java", message: "later evidence")
        feature.logCategory = "git"
        #expect(feature.exportQuery.category == "language")
        let destination = root.appendingPathComponent("diagnostics.zip")
        await feature.export(to: destination)
        guard case .completed = feature.state else { Issue.record("Archive did not complete"); return }
        let unpack = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", destination.path, "*/logs/language/*"], currentDirectoryURL: root)
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

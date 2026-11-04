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
        await writer.configureDiagnostic(category: nil, enabled: true)
        #expect(try await writer.status().diagnosticEnabled)
        clock.advance()
        await feature.refreshStatus()
        #expect(try await !writer.status().diagnosticEnabled)
        #expect(await feature.changeLogDirectory(to: root.appendingPathComponent("selected")))
        writer.emit(EditorDocumentOpenFailed(error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "confirmed evidence"]), reason: "unavailable"))
        await feature.refreshStatus()
        #expect(try await writer.collect(query: .init()).content.contains("confirmed evidence"))
        let ready = TestGate()
        let observation = workflow.$state.sink { if case .awaitingConfirmation = $0 { ready.open() } }
        defer { observation.cancel() }
        feature.presentExport(filter: .init())
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
        #expect(feature.logError == nil)
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
        let previousLanguage = InterfaceLanguage.locale.identifier
        defer { InterfaceLanguage.select(previousLanguage) }
        // L10n text outside SwiftUI views follows the interface language, not the locale environment.
        let settings = AppSettings(store: MacUserDefaultsStore(defaults: defaults))
        settings.language = try #require(AppLanguage(rawValue: language))
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            LogWindowView(model: logModel, coordinator: LogWindowCoordinator(), exportFeature: feature)
                .environmentObject(settings)
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
            let title = AppLanguage(rawValue: language)?.localizedString("Logs and Diagnostics…")
            #expect(title == (language == "zh-Hans" ? "日志与诊断…" : "Logs and Diagnostics…"))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("logging-\(scheme)-\(language).png"))
        }
        await writer.finishSession()
    }
    /// Integration evidence uses catalog events through the real writer and Core redaction.
    @Test(arguments: [ColorScheme.light, .dark], ["zh-Hans", "en"])
    func logWindowMatchesMockup(scheme: ColorScheme, language: String) async throws {
        if ProcessInfo.processInfo.environment["LITHE_LOGGING_SCREENSHOTS"] != nil {
            // The packaged probe ships the product fonts; the app registers them the same way at launch.
            MacBundledFontRegistry.registerFonts(bundle: .main)
            try #require(NSFont(name: "JetBrainsMono-Regular", size: 12) != nil, "Run the packaged probe for product typography")
        }
        let previousLanguage = InterfaceLanguage.locale.identifier
        defer { InterfaceLanguage.select(previousLanguage) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = WorkflowRenderClock()
        let writer = MacLogStore(defaultDirectory: root.appendingPathComponent("logs"), diagnosticNow: { 0 }, now: clock.now)
        do {
            await writer.configureDiagnostic(category: nil, enabled: true)
            // Core keeps DEBUG only while detailed diagnostics is active. No synthetic records or
            // new production event definitions are used to match the prototype's channel labels.
            for index in 0..<320 {
                let op = "render-operation-\(index / 16)"
                switch index % 10 {
                case 0: writer.emit(AppSessionStarted(operationID: op))
                case 1, 2: writer.emit(LspTraceReceived(diagnostic: "Received response", server: LogSegment("jdtls")!, operationID: op))
                case 3: writer.emit(LspTraceReceived(diagnostic: "Sending request", server: LogSegment("rust-analyzer")!, operationID: op))
                case 4: writer.emit(LspStderrReceived(diagnostic: "Building workspace", server: LogSegment("jdtls")!, truncated: false, operationID: op))
                case 5: writer.emit(LspSessionDegradationReceived(failureCode: "unavailable", server: LogSegment("invalid-3f9a0c2e")!, stage: "index", operationID: op))
                case 6: writer.emit(VcsGitCommandFinished(arguments: "fetch --prune origin", command: "fetch", duration: .milliseconds(487), exitCode: 0, source: "background", operationID: op))
                case 7: writer.emit(PluginsHostMessageLogged(diagnostic: "Using mirror central", plugin: LogSegment("maven")!, severity: "info", operationID: op))
                case 8: writer.emit(PluginsHostMessageLogged(diagnostic: "Process stopped", plugin: LogSegment("lldb")!, severity: "debug", operationID: op))
                default: writer.emit(AppDiagnosticsExportFailed(error: LogFailure(domain: "render", code: "unavailable"), stage: "planning", operationID: op))
                }
            }
            for offset in 0..<6 { writer.emit(VcsGitCommandFinished(arguments: "fetch --prune origin", command: "fetch", duration: .milliseconds(480 + offset), exitCode: 0, source: "background", operationID: "render-selected")) }
            writer.emit(AppDiagnosticsExportFailed(error: NSError(domain: "render", code: 1, userInfo: [NSLocalizedDescriptionKey: "token=synthetic-render-secret"]), stage: "planning", operationID: "render-selected"))
            writer.emit(LspMessageLogged(diagnostic: "Workspace initialized", server: LogSegment("jdtls")!, severity: "info", operationID: "render-selected"))
            let model = LogWindowModel(logging: writer)
            let loaded = TestGate(), traced = TestGate()
            let observation = model.$state.sink { state in
                if state.records.count >= 280 { loaded.open() }
                if state.trace != nil { traced.open() }
            }
            defer { observation.cancel(); model.stop() }
            model.refresh()
            try #require(await loaded.waitUntilOpen(timeout: .seconds(5)), "Catalog render fixture did not load")
            #expect(Set(model.state.records.map(\.channel)).isSuperset(of: ["app", "lsp/jdtls", "lsp/rust-analyzer", "lsp/invalid-3f9a0c2e", "vcs/git", "plugins/maven/host", "plugins/lldb/host"]))
            #expect(Set(model.state.records.map(\.level)) == ["DEBUG", "INFO", "WARN", "ERROR"])
            #expect(model.displayRows.contains { $0.isRun && $0.count >= 3 })
            #expect(model.state.records.contains { $0.fields.values.contains { $0.contains("<redacted>") || $0.contains("‹redacted›") } })
            let record = try #require(model.state.records.last { $0.op == "render-selected" && $0.level == "INFO" })
            model.select([LogWindowModel.recordID(record)])
            try #require(await traced.waitUntilOpen(), "Selected operation did not load its chain")
            let formatted = try #require(await model.formatted(records: [record], format: "json", includeEnvironment: false))
            #expect(formatted.contains("\"op\": \"render-selected\"") && !formatted.contains("\"environment\""))
            #expect(!formatted.contains("synthetic-render-secret"))
            #expect(!LogJSONHighlight.attributed(formatted, fields: record.fields).runs.isEmpty)
            let feature = DiagnosticsFeatureModel(service: service(root: root, logging: writer), now: clock.now)
            let ready = TestGate()
            let confirmation = feature.$state.sink { if case .awaitingConfirmation = $0 { ready.open() } }
            defer { confirmation.cancel(); feature.dismiss() }
            feature.presentExport(filter: model.query)
            try #require(await ready.waitUntilOpen(timeout: .seconds(5)), "Export manifest did not load")
            feature.dismiss()
            let suite = "log-fidelity-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(store: MacUserDefaultsStore(defaults: defaults))
            settings.language = try #require(AppLanguage(rawValue: language))
            let coordinator = LogWindowCoordinator()
            let application = NSApplication.shared
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let oldAccessibility = application.accessibilityAttributeValue(enhanced)
            application.accessibilitySetValue(true, forAttribute: enhanced)
            defer { application.accessibilitySetValue(oldAccessibility, forAttribute: enhanced) }
            let mounted = TestGate()
            let host = NSHostingView(rootView: LogWindowView(model: model, coordinator: coordinator, exportFeature: feature)
                .environmentObject(settings).environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: language))
                .task { mounted.open() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 786), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            try #require(await mounted.waitUntilOpen(), "Log view did not mount")
            host.layoutSubtreeIfNeeded()
            let table = try #require(renderDescendants(host).compactMap { $0 as? LogTableView }.first)
            #expect(table.rowHeight == 22 && !table.usesAlternatingRowBackgroundColors)
            #expect(table.headerView?.frame.height == 26)
            #expect(table.numberOfRows > 100)
            #expect(host.bounds.size == NSSize(width: 1340, height: 786))
            try await verifyLogWindowInteractions(host: host, window: window, table: table, model: model, record: record)
            if let directory = ProcessInfo.processInfo.environment["LITHE_LOGGING_SCREENSHOTS"] {
                try #require(Bundle.main.localizations.contains(language), "Run the packaged probe for localized screenshots")
                // Native accessibility is the observable boundary for the asynchronous JSON view.
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !renderAccessibilityText(host).contains("\"Workspace initialized\""), ContinuousClock.now < deadline {
                    await Task.yield()
                    host.layoutSubtreeIfNeeded()
                }
                // JSON field values become accessible links only after Core formatting reaches the detail pane.
                try #require(renderAccessibilityText(host).contains("\"Workspace initialized\""), "Core JSON did not reach the detail text")
                try renderPNG(host, directory: directory, name: "logwindow-\(scheme)-\(language).png")
                if scheme == .light && language == "zh-Hans" {
                    let button = try #require(renderAccessibilityElements(host).first { $0.accessibilityIdentifier?() == "logs.trace-tab" })
                    try #require(button.accessibilityPerformPress?() == true, "Call chain tab did not activate")
                    host.layoutSubtreeIfNeeded()
                    try renderPNG(host, directory: directory, name: "logwindow-trace-light-zh-Hans.png")
                }
                let exportHost = NSHostingView(rootView: DiagnosticsExportSheet(feature: feature)
                    .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: language)))
                feature.presentExport(filter: model.query)
                try #require(await ready.waitUntilOpen(timeout: .seconds(5)), "Export did not reopen")
                window.contentView = exportHost
                exportHost.frame = NSRect(origin: .zero, size: exportHost.fittingSize)
                exportHost.layoutSubtreeIfNeeded()
                try renderPNG(exportHost, directory: directory, name: "export-\(scheme)-\(language).png")
            }
            window.contentView = nil
            model.stop(); feature.dismiss()
        } catch {
            await writer.finishSession()
            throw error
        }
        await writer.finishSession()
    }

    private func verifyLogWindowInteractions(host: NSView, window: NSWindow, table: LogTableView,
                                            model: LogWindowModel, record: RustCoreBridge.LogQueryRecord) async throws {
        let initialCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        model.userScrolledUp()
        host.layoutSubtreeIfNeeded()
        #expect(table.view(atColumn: 0, row: 0, makeIfNecessary: true) === initialCell,
            "Pausing follow must preserve existing native cells")
        window.makeFirstResponder(table)
        let find = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        NSApp.sendEvent(find)
        let focusDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(window.firstResponder is NSTextView), ContinuousClock.now < focusDeadline {
            await Task.yield(); host.layoutSubtreeIfNeeded()
        }
        #expect(window.firstResponder is NSTextView, "Command-F must focus the log filter from the table")
        func clickChannel(_ channel: String, flags: NSEvent.ModifierFlags = []) async throws {
            let channels = try #require(renderDescendants(host).compactMap { $0 as? NSTableView }.first { !($0 is LogTableView) })
            let row = try #require((0..<channels.numberOfRows).first { index in
                channels.view(atColumn: 0, row: index, makeIfNecessary: true)?.accessibilityIdentifier() == "logs.channel." + channel
            })
            channels.scrollRowToVisible(row)
            let rect = channels.rect(ofRow: row)
            let point = channels.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            window.sendEvent(down)
            window.sendEvent(up)
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        try await clickChannel("app")
        try await clickChannel("vcs/git", flags: .command)
        #expect(Set(model.query.channelPrefixes) == ["app", "vcs/git"], "Command-click must preserve both channels")
        try await clickChannel("")
        #expect(model.query.channelPrefixes.isEmpty)
        let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.state.records.count < 280, ContinuousClock.now < restoreDeadline { await Task.yield() }
        model.select([LogWindowModel.recordID(record)])
        try await verifyTimeRangePicker(host: host, window: window)
        window.setContentSize(NSSize(width: 1900, height: 1000))
        host.layoutSubtreeIfNeeded()
        let usedWidth = table.tableColumns.filter { !$0.isHidden }.reduce(0) { $0 + $1.width + table.intercellSpacing.width }
        #expect(abs(usedWidth - (table.enclosingScrollView?.contentSize.width ?? 0)) <= 2)
    }

    private func verifyTimeRangePicker(host: NSView, window: NSWindow) async throws {
        let range = try #require(renderAccessibilityElements(host).first { $0.accessibilityIdentifier?() == "logs.time-range" })
        try #require(range.accessibilityPerformPress?() == true)
        host.layoutSubtreeIfNeeded()
        let panelDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var panel: NSWindow?
        while panel == nil, ContinuousClock.now < panelDeadline {
            await Task.yield()
            panel = window.childWindows?.first { child in
                child.contentView.map { renderDescendants($0).contains { $0 is NSDatePicker } } == true
            }
        }
        let pickerPanel = try #require(panel)
        let panelContent = try #require(pickerPanel.contentView)
        let pickers = renderDescendants(panelContent).compactMap { $0 as? NSDatePicker }
        #expect(pickers.count == 4)
        #expect(pickers.filter { $0.datePickerElements.contains(.hourMinuteSecond) }.count == 2)
        if let directory = ProcessInfo.processInfo.environment["LITHE_LOGGING_SCREENSHOTS"] {
            try renderPNG(panelContent, directory: directory, name: "logwindow-time-range-\(window.effectiveAppearance.name.rawValue)-\(InterfaceLanguage.locale.identifier).png")
        }
        LitheContextMenuPresenter.shared.dismiss()
    }

    private func renderDescendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(renderDescendants)
    }
    private func renderAccessibilityElements(_ element: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 20 else { return [] }
        let children = element.accessibilityChildren?() ?? []
        let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
        return [element] + descendants.flatMap { renderAccessibilityElements($0 as AnyObject, depth: depth + 1) }
    }
    private func renderAccessibilityText(_ element: AnyObject) -> String {
        renderAccessibilityElements(element).map {
            ($0.accessibilityAttributeValue?(NSAccessibility.Attribute.value) as? String ?? "") + ($0.accessibilityLabel?() ?? "")
        }.joined()
    }
    private func renderPNG(_ view: NSView, directory: String, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

}

/// The writer captures one deterministic timestamp per emitted event; diagnostic time is frozen.
private final class WorkflowRenderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: TimeInterval = 0
    func now() -> Date {
        lock.withLock {
            defer { ticks += 0.137 }
            return Date(timeIntervalSince1970: 1_793_664_000 + ticks)
        }
    }
}

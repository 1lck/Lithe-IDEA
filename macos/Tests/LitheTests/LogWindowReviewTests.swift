import AppKit
import Combine
import SwiftUI
import Testing
import LitheModuleAPI
@testable import Lithe

@Suite("Log window review", .serialized)
@MainActor
struct LogWindowReviewTests {
    @Test func serverSelectionUsesCoreChannelsAndKeepsOtherEvidenceOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writer = MacLogStore(defaultDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        writer.emit(LspMessageLogged(diagnostic: "Java initialization", server: LogSegment("java")!, severity: "info"))
        writer.emit(LspMessageLogged(diagnostic: "Go initialization", server: LogSegment("go")!, severity: "info"))
        writer.emit(AppSessionStarted())
        let feature = LanguageServerLogsModel(logging: writer)
        let loaded = TestGate()
        let observation = feature.logs.$state.sink { if !$0.records.isEmpty { loaded.open() } }
        defer { observation.cancel(); feature.stop() }
        feature.apply(.init(providerID: "java", servers: []))
        feature.start()
        try #require(await loaded.waitUntilOpen())
        #expect(feature.logs.state.records.allSatisfy { $0.channel == "lsp/java" })
        let allLoaded = TestGate()
        let all = feature.logs.$state.sink { state in
            if Set(state.records.map(\.channel)) == ["lsp/java", "lsp/go"] { allLoaded.open() }
        }
        defer { all.cancel() }
        feature.select("")
        try #require(await allLoaded.waitUntilOpen())
        await writer.finishSession()
    }

    /// Optional local review: read a task-owned copy of real user evidence, never fabricate records.
    @Test func renderFinalReviewFromExistingSession() async throws {
        guard let source = ProcessInfo.processInfo.environment["LITHE_REVIEW_LOG_SESSION"],
              let output = ProcessInfo.processInfo.environment["LITHE_LOGGING_SCREENSHOTS"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(fileURLWithPath: source)
        let sessions = root.appendingPathComponent("logs/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: sessions.appendingPathComponent(sourceURL.lastPathComponent))
        let writer = MacLogStore(defaultDirectory: root.appendingPathComponent("logs"))
        do {
            try await renderReview(writer: writer, output: output)
        } catch {
            await writer.finishSession()
            throw error
        }
        await writer.finishSession()
    }

    private func renderReview(writer: MacLogStore, output: String) async throws {
        MacBundledFontRegistry.registerFonts(bundle: .main)
        let suite = "log-review-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let previousLanguage = InterfaceLanguage.locale.identifier
        settings.language = .simplifiedChinese
        defer { InterfaceLanguage.select(previousLanguage) }
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode, applicationLogging: writer)
        let app = AppModel(settings: settings, services: container.services)
        defer { container.moduleLifecycleCoordinator.stop() }
        let menu = WorkbenchSettingsMenu.items(model: app)
        #expect(menu.filter { $0.title == "Plugins…" || $0.title == "Logs and Diagnostics…" }.allSatisfy { $0.icon != nil })
        let export = DiagnosticsFeatureModel(service: app.services.diagnosticsExportService)
        var preferences = LogWindowPreferences(); preferences.query.session = "all"
        let logs = LogWindowModel(logging: writer, preferences: preferences)
        let coordinator = LogWindowCoordinator()
        let loaded = TestGate()
        let observation = logs.$state.sink { if !$0.records.isEmpty { loaded.open() } }
        defer { observation.cancel(); logs.stop(); export.dismiss() }
        logs.refresh()
        try #require(await loaded.waitUntilOpen())
        if let selected = logs.state.records.last(where: { $0.op != nil }) {
            logs.select([LogWindowModel.recordID(selected)])
        }
        for dark in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1600, height: 1000),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: LogWindowView(model: logs, coordinator: coordinator, exportFeature: export)
                .environmentObject(settings).environment(\.locale, settings.language.locale)
                .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            try screenshot(host, output: output, name: dark ? "final-logs-dark.png" : "final-logs-light.png")
            let presenter = LitheContextMenuPresenter()
            presenter.show(items: menu, at: NSPoint(x: window.frame.maxX - 280, y: window.frame.maxY - 80),
                appearance: window.appearance, locale: settings.language.locale, parentWindow: window)
            defer { presenter.dismiss() }
            let panel = try #require(window.childWindows?.first { $0.isVisible })
            try screenshot(try #require(panel.contentView), output: output, name: dark ? "final-settings-menu-dark.png" : "final-settings-menu-light.png")
            presenter.dismiss()
        }
        let serverCoordinator = LanguageServerLogsCoordinator()
        serverCoordinator.open(providerID: "java", servers: [.init(id: "java", displayName: "jdtls", status: .stopped, version: nil)])
        let serverFeature = LanguageServerLogsModel(logging: writer)
        serverFeature.logs.changeQuery { $0.session = "all" }
        let serverLoaded = TestGate()
        let serverObservation = serverFeature.logs.$state.sink { if !$0.records.isEmpty { serverLoaded.open() } }
        defer { serverObservation.cancel(); serverFeature.stop() }
        let host = NSHostingView(rootView: LanguageServerLogsView(feature: serverFeature, coordinator: serverCoordinator)
            .environment(\.locale, settings.language.locale).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1400, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try #require(await serverLoaded.waitUntilOpen())
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        try screenshot(host, output: output, name: "final-jdtls-logs.png")
        await app.shutdownProjectSession()
    }

    private func screenshot(_ view: NSView, output: String, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}

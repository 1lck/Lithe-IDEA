import AppKit
import Combine
import SwiftUI
import Testing
import LitheModuleAPI
@testable import Lithe

@Suite("Log window review", .serialized)
@MainActor
struct LogWindowReviewTests {
    @Test func serverTabShowsOneServerAndClearsOnlyThatServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writer = MacLogStore(defaultDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        writer.emit(LspMessageLogged(diagnostic: "Example initialization", server: LogSegment("example")!, severity: "info"))
        writer.emit(LspMessageLogged(diagnostic: "Go initialization", server: LogSegment("go")!, severity: "info"))
        writer.emit(AppSessionStarted())
        let feature = LanguageServerLogsModel(logging: writer)
        defer { feature.stop() }
        // Levels start at Info and there is no "all servers" choice.
        #expect(LanguageServerLogsModel.MinimumLevel.allCases == [.info, .warning, .error])
        #expect(feature.logs.query.levels == ["INFO", "WARN", "ERROR"])

        let example = try await showServer("example", channel: "lsp/example", in: feature)
        #expect(feature.logs.query.channelPrefixes == ["lsp/example"])
        feature.clear()
        #expect(feature.logs.state.records.isEmpty && feature.logs.state.cleared)

        // Clearing Example leaves Go untouched.
        _ = try await showServer("go", channel: "lsp/go", in: feature)
        #expect(feature.logs.query.channelPrefixes == ["lsp/go"])
        #expect(!feature.logs.state.cleared)

        // Back on Example the clear point still applies: only the newer row returns.
        let returned = TestGate()
        let observation = feature.logs.$state.sink { state in
            if !state.records.isEmpty, state.records.allSatisfy({ $0.channel == "lsp/example" }) { returned.open() }
        }
        defer { observation.cancel() }
        feature.select("example")
        writer.emit(LspMessageLogged(diagnostic: "Example ready", server: LogSegment("example")!, severity: "info"))
        try #require(await returned.waitUntilOpen(timeout: .logStoreQuery))
        #expect(feature.logs.query.channelPrefixes == ["lsp/example"])
        #expect(Set(feature.logs.state.records.map(LogWindowModel.recordID)).isDisjoint(with: example))
        await writer.finishSession()
    }

    /// Selects `id` and waits until the tab shows only `channel`; returns the shown record IDs.
    private func showServer(_ id: String, channel: String, in feature: LanguageServerLogsModel) async throws -> Set<String> {
        let loaded = TestGate()
        let observation = feature.logs.$state.sink { state in
            if !state.records.isEmpty, state.records.allSatisfy({ $0.channel == channel }) { loaded.open() }
        }
        defer { observation.cancel() }
        if feature.providerID.isEmpty { feature.open(providerID: id) } else { feature.select(id) }
        try #require(await loaded.waitUntilOpen(timeout: .logStoreQuery))
        #expect(feature.providerID == id)
        return Set(feature.logs.state.records.map(LogWindowModel.recordID))
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
        try #require(await loaded.waitUntilOpen(timeout: .logStoreQuery))
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
        // The reviewed session decides which language server channel is rendered.
        let serverID = ProcessInfo.processInfo.environment["LITHE_REVIEW_LOG_SERVER"] ?? "example"
        let serverFeature = LanguageServerLogsModel(logging: writer)
        serverFeature.logs.changeQuery { $0.session = "all" }
        let serverLoaded = TestGate()
        let serverObservation = serverFeature.logs.$state.sink { state in
            if !state.records.isEmpty, state.records.allSatisfy({ $0.channel == "lsp/\(serverID)" }) { serverLoaded.open() }
        }
        defer { serverObservation.cancel(); serverFeature.stop() }
        serverFeature.open(providerID: serverID)
        let host = NSHostingView(rootView: LanguageServerLogsView(feature: serverFeature).environmentObject(app)
            .environmentObject(settings).environment(\.locale, settings.language.locale).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1400, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try #require(await serverLoaded.waitUntilOpen(timeout: .logStoreQuery))
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        try screenshot(host, output: output, name: "final-server-logs.png")
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

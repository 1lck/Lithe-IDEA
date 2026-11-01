import Combine
import AppKit
import Foundation
import LitheCoreContracts
import LitheModuleAPI
import SwiftUI
import Testing
@testable import Lithe

/// The settings window observes `AppModel.settingsChanges` instead of the whole
/// model, so busy workbench features must not rebuild it.
@MainActor
struct AppModelSettingsChangesTests {
    @Test
    func workbenchOnlyRelayDoesNotReachSettings() async {
        let probe = SettingsChangesProbe()
        defer { probe.cancel() }
        await probe.drainPendingRelays()

        probe.model.scheduleObjectWillChangeRelay(affectsSettings: false)
        let relayed = await probe.awaitModelChange()

        #expect(relayed)
        #expect(probe.settingsChangeCount == 0)
    }

    @Test
    func settingsRelevantChangesReachSettings() async {
        let probe = SettingsChangesProbe()
        defer { probe.cancel() }
        await probe.drainPendingRelays()

        // Plugin and module actions notify the model directly.
        probe.model.objectWillChange.send()
        #expect(probe.settingsChangeCount == 1)

        probe.model.scheduleObjectWillChangeRelay()
        let relayed = await probe.awaitModelChange()

        #expect(relayed)
        #expect(probe.settingsChangeCount == 2)
    }

    @Test
    func coalescedRelayReachesSettingsWhenAnyChangeAffectsIt() async {
        let probe = SettingsChangesProbe()
        defer { probe.cancel() }
        await probe.drainPendingRelays()

        probe.model.scheduleObjectWillChangeRelay(affectsSettings: false)
        probe.model.scheduleObjectWillChangeRelay()
        probe.model.scheduleObjectWillChangeRelay(affectsSettings: false)
        let relayed = await probe.awaitModelChange()

        #expect(relayed)
        #expect(probe.modelChangeCount == 1)
        #expect(probe.settingsChangeCount == 1)
    }

    @Test(arguments: [AppLanguage.english, .simplifiedChinese])
    func mountedLSPPageRefreshesSnapshotsWithoutNotifyingTheSettingsRoot(language: AppLanguage) async throws {
        let root = URL(fileURLWithPath: "/fixture/lsp-snapshot-updates")
        let operations = UsageSnapshotOperations(inventories: [
            ["README"], ["README", "go.mod"], ["README", "Main.java"], ["README"]
        ])
        let probe = SettingsChangesProbe(workspaceOperations: operations, language: language)
        let model = probe.model
        // AppModel starts this required module asynchronously, even in safe
        // mode. Await its activation before establishing the notification baseline.
        _ = try await model.services.moduleRuntime.activateCapability(.workspaceFoundation)
        // Establish both session and feature identities without consuming the
        // controlled inventories through an automatic background rebuild.
        model.workspaceSessionCoordinator.beginWorkspace(at: root)
        model.workspaceFeature.beginWorkspace(at: root, visibilityRules: .default)
        let usage = model.languageToolingFeature.projectUsage
        let context = SettingsModelContext(model: model)
        let viewState = SettingsViewState(initialCategory: .lsp)
        let updater = UpdateChecker()
        let host = NSHostingView(rootView: SettingsView(settings: probe.settings, viewState: viewState, initialCategory: .lsp)
            .environmentObject(context).environmentObject(updater)
            .environmentObject(model).environmentObject(probe.settings)
            .environment(\.locale, language == .english ? Locale(identifier: "zh-Hans") : Locale(identifier: "en")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 668),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            usage.reset()
            model.workspaceFeature.reset()
            model.workspaceSessionCoordinator.clearSession()
            probe.cancel()
        }
        host.layoutSubtreeIfNeeded()
        try captureUsageSettings(host, name: "\(language.rawValue)-initial-loading")
        await probe.drainPendingRelays()
        var identities: Set<UUID> = []
        // Keep the same native host mounted while the production workspace
        // feature publishes create, rename and delete inventories.
        for expectedPlugin in [nil, OfficialPluginCatalog.goPluginID.rawValue,
                               OfficialPluginCatalog.javaPluginID.rawValue, nil] as [String?] {
            let result = await model.workspaceFeature.rebuild(at: root, rules: .default, isCurrent: { true })
            guard case .loaded(let snapshot) = result else { Issue.record("Snapshot was not applied"); return }
            identities.insert(snapshot.id)
            let input = model.languageToolingFeature.projectUsageInput(workspaceURL: model.workspaceURL, snapshot: snapshot)
            let ready = await usagePageRendered(host) { usage.summary(for: input.request) != nil }
            try #require(ready, "Mounted LSP page did not reload snapshot \(snapshot.id)")
            let summary = try #require(usage.summary(for: input.request))
            #expect(summary.pluginIDs == expectedPlugin.map { Set([$0]) } ?? [])
            #expect(model.workspaceSnapshotID == snapshot.id)
            try captureUsageSettings(host, name: "\(language.rawValue)-snapshot-\(identities.count)")
        }
        #expect(identities.count == 4)
        #expect(probe.settingsChangeCount == 0)
        window.setContentSize(NSSize(width: 1200, height: 800))
        try captureUsageSettings(host, name: "\(language.rawValue)-expanded")
        window.setContentSize(NSSize(width: 900, height: 668))
        try captureUsageSettings(host, name: "\(language.rawValue)-restored")
    }

    @Test(arguments: [AppLanguage.english, .simplifiedChinese])
    func loadingLabelFollowsAppLanguageWithOppositeParentLocale(language: AppLanguage) async throws {
        // Match the existing native AX fixtures: SwiftUI only publishes its
        // accessibility tree when an assistive client has requested it.
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        let probe = SettingsChangesProbe(language: language)
        let entered = TestGate()
        let release = TestGate()
        let usage = LSPProjectUsageModel(scanner: { _, _ in
            entered.open()
            #expect(await release.waitUntilOpen(timeout: .seconds(5)))
            return LSPProjectUsageSummary()
        })
        let input = probe.model.languageToolingFeature.projectUsageInput(workspaceURL: nil, snapshot: nil)
        // SwiftPM does not package app tables. Inject the actual shared native
        // resources so a missing translation cannot pass as the semantic key.
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let bundle = try #require(Bundle(url: resources))
        let host = NSHostingView(rootView: LSPControlCenterContent(usageModel: usage, input: input, localizationBundle: bundle)
            .environmentObject(probe.model).environmentObject(probe.settings)
            .environment(\.locale, language == .english ? Locale(identifier: "zh-Hans") : Locale(identifier: "en")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            release.open()
            usage.reset()
            window.contentView = nil
            window.close()
            probe.cancel()
        }
        try #require(await entered.waitUntilOpen())
        let label = language == .english ? "Loading…" : "正在加载…"
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        // SwiftUI does not publish AX-tree availability through Combine.
        // Poll only this native boundary, with a local monotonic deadline.
        while !accessibilityLabels(in: host).contains(label), clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        #expect(accessibilityLabels(in: host).contains(label))
        try captureUsageSettings(host, name: "\(language.rawValue)-loading-label")
        release.open()
        #expect(await awaitChange(on: usage) { usage.state == .ready })
    }
}

@MainActor
private func usagePageRendered(_ host: NSView, until condition: () -> Bool) async -> Bool {
    // The CLI runner has no persistent AppKit event loop. Drive native render
    // turns so SwiftUI can start its .task; model observation alone cannot do so.
    func renderFrame() { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true) }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    repeat {
        host.layoutSubtreeIfNeeded()
        renderFrame()
        if condition() { return true }
        await Task.yield()
    } while clock.now < deadline
    return condition()
}

@MainActor
private func accessibilityLabels(in element: Any, depth: Int = 0) -> [String] {
    guard depth < 32 else { return [] }
    // SwiftUI's AX nodes expose selectors without adopting the full protocol.
    let accessible = element as AnyObject
    return [accessible.accessibilityLabel?(), accessible.accessibilityTitle?()].compactMap { $0 }
        + (accessible.accessibilityChildren?() ?? []).flatMap { accessibilityLabels(in: $0, depth: depth + 1) }
}

@MainActor
private func captureUsageSettings(_ host: NSView, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["LITHE_LSP_REVIEW_SCREENSHOT_DIR"] else { return }
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(Bundle.main.bundleURL.path.utf8).write(to: root.appendingPathComponent("bundle-main-path.txt"))
    try data.write(to: root.appendingPathComponent(name + ".png"))
}

@MainActor
private final class SettingsChangesProbe {
    let model: AppModel
    let settings: AppSettings
    private(set) var modelChangeCount = 0
    private(set) var settingsChangeCount = 0
    private var observations: [AnyCancellable] = []

    init(workspaceOperations: (any WorkspaceOperations)? = nil, language: AppLanguage = .english) {
        let store = SettingsChangesTestStore()
        settings = AppSettings(store: store)
        settings.language = language
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode,
            workspaceOperations: workspaceOperations
        ).services
        model = AppModel(settings: settings, services: services)
        observations = [
            model.objectWillChange.sink { [weak self] _ in self?.modelChangeCount += 1 },
            model.settingsChanges.sink { [weak self] _ in self?.settingsChangeCount += 1 }
        ]
    }

    /// Flushes relays scheduled while the model was composed, then starts the
    /// counts from zero.
    func drainPendingRelays() async {
        model.scheduleObjectWillChangeRelay()
        _ = await awaitModelChange()
        modelChangeCount = 0
        settingsChangeCount = 0
    }

    /// Waits, with a deadline, for the next model publication.
    func awaitModelChange() async -> Bool {
        let target = modelChangeCount + 1
        return await awaitChange(on: model) { [weak self] in
            (self?.modelChangeCount ?? target) >= target
        }
    }

    func cancel() {
        observations.removeAll()
    }
}

private final class UsageSnapshotOperations: WorkspaceOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var inventories: [[String]]

    init(inventories: [[String]]) { self.inventories = inventories }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !inventories.isEmpty else { return nil }
        let files = inventories.removeFirst().map { rootURL.appendingPathComponent($0) }
        return WorkspaceSnapshot(root: FileNode(url: rootURL, isDirectory: true, children: []), files: files)
    }

    func warmSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {}
    func updateSearchIndex(at rootURL: URL, changedPaths: [String], visibilityRules: FileVisibilityRules) {}
    func invalidateSearchIndex(at rootURL: URL, visibilityRules: FileVisibilityRules) {}
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private final class SettingsChangesTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

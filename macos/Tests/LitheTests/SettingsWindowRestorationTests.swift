import AppKit
import Combine
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite(.serialized)
struct SettingsWindowRestorationTests {
    @Test
    func restoredSettingsBindOnceAndAcquireANewBindingAfterClosing() async throws {
        let fixture = SettingsRestorationFixture()
        try await WorkbenchTestScope.withCleanup({ await fixture.manager.stopAllSessions() }) { _ in
            let manager = fixture.manager
            let model = manager.activeModel
            let initialBinding = manager.settingsBindingID
            #expect(manager.settingsModel == nil)
            #expect(!model.isSettingsPresented)

            manager.prepareSettingsForPresentation()
            let binding = manager.settingsBindingID
            #expect(manager.settingsModel === model)
            #expect(binding != initialBinding)
            #expect(model.isSettingsPresented)
            manager.prepareSettingsForPresentation()
            #expect(manager.settingsBindingID == binding)

            manager.releaseSettings(for: model.id, bindingID: binding)
            #expect(manager.settingsModel == nil)
            #expect(!model.isSettingsPresented)
            manager.prepareSettingsForPresentation()
            #expect(manager.settingsModel === model)
            #expect(manager.settingsBindingID != binding)
        }
    }

    @Test
    func oldCallbacksCannotCloseOrReleaseANewerBindingOfTheSameSession() async throws {
        let fixture = SettingsRestorationFixture()
        try await WorkbenchTestScope.withCleanup({ await fixture.manager.stopAllSessions() }) { _ in
            let manager = fixture.manager
            manager.prepareSettingsForPresentation()
            let model = try #require(manager.settingsModel)
            let oldBinding = manager.settingsBindingID
            manager.bindSettings(to: model.id)
            let currentBinding = manager.settingsBindingID
            var closed = false

            manager.closeSettingsIfCurrent(for: model.id, bindingID: oldBinding) { closed = true }
            manager.releaseSettings(for: model.id, bindingID: oldBinding)
            #expect(!closed)
            #expect(manager.settingsModel === model)
            #expect(model.isSettingsPresented)
            #expect(manager.settingsBindingID == currentBinding)

            manager.closeSettingsIfCurrent(for: model.id, bindingID: currentBinding) { closed = true }
            #expect(closed)
            manager.releaseSettings(for: model.id, bindingID: currentBinding)
            #expect(manager.settingsModel == nil)
            #expect(!model.isSettingsPresented)
        }
    }

    @Test
    func restorationReplacesABindingWhoseSessionHasClosed() async throws {
        let fixture = SettingsRestorationFixture()
        try await WorkbenchTestScope.withCleanup({ await fixture.manager.stopAllSessions() }) { scope in
            let manager = fixture.manager
            manager.prepareSettingsForPresentation()
            let oldModel = try #require(manager.settingsModel)
            let oldBinding = manager.settingsBindingID
            try await scope.run("close settings owner's session") { await manager.resetPrimaryWindowSessions() }
            let replacement = manager.activeModel
            #expect(replacement !== oldModel)

            manager.prepareSettingsForPresentation()
            #expect(manager.settingsModel === replacement)
            #expect(manager.settingsBindingID != oldBinding)
            manager.releaseSettings(for: oldModel.id, bindingID: oldBinding)
            #expect(manager.settingsModel === replacement)
            #expect(replacement.isSettingsPresented)
        }
    }

    @Test(arguments: [AppThemePreference.light, .dark])
    func nativeHostRestoresRealSettingsContentAndReopensAfterDetachment(theme: AppThemePreference) async throws {
        let fixture = SettingsRestorationFixture()
        fixture.settings.themePreference = theme
        try await WorkbenchTestScope.withCleanup({ await fixture.manager.stopAllSessions() }) { _ in
            let manager = fixture.manager
            #expect(manager.settingsModel == nil)
            let host = NSHostingView(rootView: SettingsWindowHost(projectSessions: manager, settings: fixture.settings)
                .environmentObject(UpdateChecker())
                .environmentObject(fixture.settings)
                .environment(\.locale, AppLanguage.english.locale))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 668),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let previousOwner = SettingsWindowChrome.ownerWindow
            let previousSettings = SettingsWindowChrome.settingsWindow
            let application = NSApplication.shared
            let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
            application.accessibilitySetValue(true, forAttribute: attribute)
            defer {
                window.contentView = nil
                window.close()
                SettingsWindowChrome.ownerWindow = previousOwner
                SettingsWindowChrome.settingsWindow = previousSettings
                application.accessibilitySetValue(previousAccessibility, forAttribute: attribute)
            }
            window.contentView = host
            window.orderFront(nil)
            try await requireVisibleSearchField(in: host)
            #expect(manager.settingsModel === manager.activeModel)
            let binding = manager.settingsBindingID

            let released = TestGate()
            let observation = manager.$settingsModel.sink { if $0 == nil { released.open() } }
            defer { observation.cancel() }
            window.contentView = nil
            try #require(await released.waitUntilOpen(), "Detaching settings did not release its current binding")
            window.contentView = host
            try await requireVisibleSearchField(in: host)
            #expect(manager.settingsModel === manager.activeModel)
            #expect(manager.settingsBindingID != binding)
        }
    }

    private func requireVisibleSearchField(in host: NSView) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        // SwiftUI publishes its native accessibility tree after mounting; it has
        // no callback for this boundary. Wait on the actual product control.
        repeat {
            host.layoutSubtreeIfNeeded()
            if containsVisibleSearchField(host, host: host) { return }
            await Task.yield()
        } while clock.now < deadline
        Issue.record("Restored settings did not mount a visible search field within two seconds")
        throw MissingSettingsContent()
    }

    private func containsVisibleSearchField(_ element: Any, host: NSView, depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        let accessible = element as AnyObject
        if accessible.accessibilityLabel?() == "Search settings",
           let frame = accessible.accessibilityFrame?(), !frame.isEmpty,
           let window = host.window,
           host.bounds.intersects(host.convert(window.convertFromScreen(frame), from: nil)) { return true }
        let children = accessible.accessibilityChildren?() ?? []
        let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
        return descendants.contains { containsVisibleSearchField($0, host: host, depth: depth + 1) }
    }

    private struct MissingSettingsContent: Error {}
}

@MainActor
private final class SettingsRestorationFixture {
    let settings: AppSettings
    let manager: ProjectSessionManager

    init() {
        let store = SettingsRestorationStore()
        let settings = AppSettings(store: store)
        self.settings = settings
        manager = ProjectSessionManager(settings: settings) {
            AppModel(settings: settings, services: MacServiceContainer(
                store: store, settings: settings, moduleLaunchMode: .safeMode,
                javaMavenOperations: NoProjectJavaOperations(), aiConfigurationSources: []
            ).services)
        }
    }
}

private final class SettingsRestorationStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

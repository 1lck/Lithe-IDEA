import Combine
import Foundation
import Testing
@testable import Lithe

/// The settings window observes `AppModel.settingsChanges` instead of the whole
/// model, so busy workbench features must not rebuild it.
@MainActor
struct AppModelSettingsChangesTests {
    @Test
    func disablingDefinitionNavigationClosesResultsAndInvalidatesPendingOperation() {
        let probe = SettingsChangesProbe()
        defer { probe.cancel() }
        probe.model.settings.classMethodNavigationEnabled = true
        let operation = probe.model.languageNavigationCoordinator.begin(providerID: "test", kind: .definitions)
        probe.model.isImplementationChooserVisible = true
        probe.model.settings.classMethodNavigationEnabled = false
        #expect(!probe.model.isImplementationChooserVisible)
        #expect(!probe.model.languageNavigationCoordinator.owns(operation))
        #expect(!probe.model.canPerformShortcutCommand(id: "go-to-definition"))
    }

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
}

@MainActor
private final class SettingsChangesProbe {
    let model: AppModel
    private(set) var modelChangeCount = 0
    private(set) var settingsChangeCount = 0
    private var observations: [AnyCancellable] = []

    init() {
        let store = SettingsChangesTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
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

private final class SettingsChangesTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

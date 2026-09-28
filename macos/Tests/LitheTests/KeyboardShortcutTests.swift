import Foundation
import Testing
@testable import Lithe

@Suite("Keyboard shortcuts")
@MainActor
struct KeyboardShortcutTests {
    @Test
    func catalogHasStableUniqueCommandsAndConflictFreeDefaults() {
        let commands = LitheCommandCatalog.commands
        #expect(commands.count == 39)
        #expect(Set(commands.map(\.id)).count == commands.count)

        let owners = commands.flatMap { command in
            command.defaultBindings.map { (binding: $0, commandID: command.id) }
        }
        for (index, owner) in owners.enumerated() {
            #expect(!owners.dropFirst(index + 1).contains {
                $0.binding == owner.binding && $0.commandID != owner.commandID
            })
        }
    }

    @Test
    func presetsContainAssignableConflictFreeBindings() {
        for preset in KeyboardShortcutPreset.allCases {
            var owners: [KeyboardShortcutBinding: String] = [:]
            for command in LitheCommandCatalog.commands {
                for binding in preset.bindings(for: command) {
                    #expect(binding.isAssignable, "Invalid \(preset.title) binding for \(command.id)")
                    #expect(owners[binding] == nil, "\(preset.title): \(command.id) conflicts with \(owners[binding] ?? "")")
                    owners[binding] = command.id
                }
            }
        }
    }

    @Test
    func eclipseResolvesJetBrainsInheritanceAndExplicitlyClearedActions() throws {
        func bindings(_ id: String) throws -> [KeyboardShortcutBinding] {
            KeyboardShortcutPreset.eclipse.bindings(for: try #require(LitheCommandCatalog.command(id: id)))
        }

        #expect(try bindings("save") == [.keyPress(key: "s", modifiers: [.control])]) // $default
        #expect(try bindings("settings") == [.keyPress(key: ",", modifiers: [.command])]) // Mac parent
        #expect(try bindings("toggle-run") == [.keyPress(key: "4", modifiers: [.command])])
        #expect(try bindings("debug-resume") == [.keyPress(key: "f8", modifiers: [])]) // Eclipse override
        for id in ["find-in-file", "replace-in-file", "go-to-implementation", "replace-in-project"] {
            #expect(try bindings(id).isEmpty, "Eclipse explicitly clears \(id)")
        }
        #expect(try bindings("open-project") == [.keyPress(key: "o", modifiers: [.command])]) // Lithe-only

        let feature = KeyboardShortcutFeatureModel(settings: AppSettings(store: KeyboardShortcutTestStore()))
        feature.selectPreset(.eclipse)
        #expect(feature.displayText(for: "find-in-file") == nil)
        #expect(feature.registrations.first { $0.commandID == "find-in-file" }?.bindings == [])
    }

    @Test
    func ideaClassicStopUsesControlF2() throws {
        let stop = try #require(LitheCommandCatalog.command(id: "stop-run"))
        #expect(KeyboardShortcutPreset.ideaClassic.bindings(for: stop)
            == [.keyPress(key: "f2", modifiers: [.control])])
    }

    @Test
    func toggleBreakpointUsesTheIDEADefaultShortcut() throws {
        let command = try #require(LitheCommandCatalog.command(id: "toggle-breakpoint"))

        #expect(command.defaultBindings == [
            .keyPress(key: "f8", modifiers: [.command])
        ])
    }

    @Test
    func viewBreakpointsUsesTheIDEADefaultShortcut() throws {
        let command = try #require(LitheCommandCatalog.command(id: "view-breakpoints"))

        #expect(command.defaultBindings == [
            .keyPress(key: "f8", modifiers: [.shift, .command])
        ])
    }

    @Test
    @MainActor
    func actionRegistryCoversEveryCatalogCommand() {
        let store = KeyboardShortcutTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        let actions = LitheActionRegistry.actions(for: model)
        let actionIDs = Set(actions.map(\.id))
        let commandIDs = Set(LitheCommandCatalog.commands.map(\.id))

        #expect(actions.count == LitheCommandCatalog.commands.count)
        #expect(actionIDs.count == actions.count)
        #expect(actionIDs == commandIDs)
        #expect(actionIDs.contains("save"))
        #expect(actionIDs.contains("search-everywhere"))
        #expect(actionIDs.contains("find-next"))
        #expect(actionIDs.contains("find-previous"))
        #expect(actionIDs.contains("navigate-back"))
        #expect(actionIDs.contains("navigate-forward"))
        #expect(actionIDs.contains("go-to-definition"))
        #expect(actionIDs.contains("go-to-implementation"))
        #expect(actionIDs.contains("rebuild-java-index"))
        #expect(actionIDs.contains("spring-endpoints"))
        #expect(actionIDs.contains("toggle-breakpoint"))
        #expect(actionIDs.contains("view-breakpoints"))
    }

    @Test
    func bindingsUseCanonicalDisplayOrderAndRoundTripThroughJSON() throws {
        let binding = KeyboardShortcutBinding.keyPress(
            key: "u",
            modifiers: [.control, .option, .shift, .command]
        )
        #expect(binding.displayText == "⌃⌥⇧⌘U")
        let data = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(KeyboardShortcutBinding.self, from: data) == binding)
        #expect(KeyboardShortcutBinding.doubleTap(.shift).displayText == "⇧ ⇧")
    }

    @Test
    func plainTextKeysRequireANonShiftModifier() {
        #expect(!KeyboardShortcutBinding.keyPress(key: "a", modifiers: []).isAssignable)
        #expect(!KeyboardShortcutBinding.keyPress(key: "a", modifiers: [.shift]).isAssignable)
        #expect(KeyboardShortcutBinding.keyPress(key: "a", modifiers: [.command]).isAssignable)
        #expect(KeyboardShortcutBinding.keyPress(key: "f5", modifiers: []).isAssignable)
    }

    @Test
    func overridesPersistDisableAndResetWithoutChangingOtherSettings() throws {
        let store = KeyboardShortcutTestStore()
        let settings = AppSettings(store: store)
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let replacement = KeyboardShortcutBinding.keyPress(
            key: "k",
            modifiers: [.command, .option]
        )

        try feature.replaceBindings(for: "run", with: [replacement])
        #expect(feature.effectiveBindings(for: "run") == [replacement])
        #expect(AppSettings(store: store).keyboardShortcutOverrides["run"] == [replacement])

        try feature.replaceBindings(for: "run", with: [])
        #expect(feature.effectiveBindings(for: "run").isEmpty)

        feature.resetCommand("run")
        #expect(
            feature.effectiveBindings(for: "run")
                == LitheCommandCatalog.command(id: "run")?.defaultBindings
        )

        settings.editorFontSize = 17
        try feature.replaceBindings(for: "debug", with: [replacement])
        feature.resetAll()
        #expect(settings.editorFontSize == 17)
        #expect(settings.keyboardShortcutOverrides.isEmpty)
    }

    @Test
    func switchingPresetsKeepsOverridesSeparateAndPersistsSelection() throws {
        let store = KeyboardShortcutTestStore()
        let settings = AppSettings(store: store)
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let macBinding = KeyboardShortcutBinding.keyPress(key: "k", modifiers: [.command, .option])
        let classicBinding = KeyboardShortcutBinding.keyPress(key: "p", modifiers: [.control, .option])

        try feature.replaceBindings(for: "run", with: [macBinding])
        feature.selectPreset(.ideaClassic)
        #expect(feature.effectiveBindings(for: "run") == [.keyPress(key: "f10", modifiers: [.shift])])
        try feature.replaceBindings(for: "run", with: [classicBinding])
        feature.selectPreset(.macOS)
        #expect(feature.effectiveBindings(for: "run") == [macBinding])
        feature.selectPreset(.eclipse)
        #expect(feature.effectiveBindings(for: "run") == [.keyPress(key: "f11", modifiers: [.command, .shift])])

        let reloaded = KeyboardShortcutFeatureModel(settings: AppSettings(store: store))
        #expect(reloaded.selectedPreset == .eclipse)
        reloaded.selectPreset(.ideaClassic)
        #expect(reloaded.effectiveBindings(for: "run") == [classicBinding])
        reloaded.selectPreset(.macOS)
        #expect(reloaded.effectiveBindings(for: "run") == [macBinding])
    }

    @Test
    func legacyOverridesMigrateToTheMacOSPreset() throws {
        struct LegacyPayload: Encodable {
            let version = 1
            let commands: [String: [KeyboardShortcutBinding]]
        }
        let store = KeyboardShortcutTestStore()
        let binding = KeyboardShortcutBinding.keyPress(key: "k", modifiers: [.command, .option])
        store.set(
            try JSONEncoder().encode(LegacyPayload(commands: ["run": [binding]])),
            forKey: "settings.keyboardShortcutOverrides"
        )

        let feature = KeyboardShortcutFeatureModel(settings: AppSettings(store: store))
        #expect(feature.selectedPreset == .macOS)
        #expect(feature.effectiveBindings(for: "run") == [binding])
        feature.selectPreset(.eclipse)
        #expect(feature.effectiveBindings(for: "run") != [binding])
        feature.selectPreset(.macOS)
        #expect(feature.effectiveBindings(for: "run") == [binding])
        try feature.replaceBindings(for: "run", with: [binding])
        #expect(store.data(forKey: "settings.keyboardShortcutOverrides") == nil)
    }

    @Test
    func conflictReportsTheOwningCommandAndDoesNotPersist() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let findShortcut = try #require(feature.effectiveBindings(for: "find-in-file").first)

        #expect(throws: KeyboardShortcutUpdateError.conflict(commandID: "find-in-file")) {
            try feature.replaceBindings(for: "run", with: [findShortcut])
        }
        #expect(settings.keyboardShortcutOverrides["run"] == nil)
    }

    @Test
    func corruptPersistenceFallsBackToDefaults() {
        let store = KeyboardShortcutTestStore()
        store.set(Data("not-json".utf8), forKey: "settings.keyboardShortcutOverrides")

        let settings = AppSettings(store: store)
        let feature = KeyboardShortcutFeatureModel(settings: settings)

        #expect(settings.keyboardShortcutOverrides.isEmpty)
        #expect(
            feature.effectiveBindings(for: "run")
                == LitheCommandCatalog.command(id: "run")?.defaultBindings
        )
    }

    @Test
    func featureProjectsCurrentDisplayPrimaryKeyPressAndRegistrations() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let replacement = KeyboardShortcutBinding.keyPress(
            key: "p",
            modifiers: [.command, .option]
        )
        try feature.replaceBindings(for: "find-in-file", with: [replacement])

        #expect(feature.displayText(for: "find-in-file") == "⌥⌘P")
        #expect(feature.primaryKeyPress(for: "find-in-file") == replacement)
        #expect(
            feature.registrations.first { $0.commandID == "find-in-file" }?.bindings
                == [replacement]
        )
        #expect(
            feature.primaryKeyPress(for: "search-everywhere")
                == .keyPress(key: "o", modifiers: [.shift, .command])
        )
    }

    @Test
    func filteringMatchesTitleIDGroupAndShortcutText() {
        let feature = KeyboardShortcutFeatureModel(
            settings: AppSettings(store: KeyboardShortcutTestStore())
        )

        #expect(feature.filteredCommands(query: "find usages").map(\.id) == ["find-usages"])
        #expect(feature.filteredCommands(query: "window").allSatisfy { $0.group == .window })
        #expect(feature.filteredCommands(query: "⌃R").map(\.id).contains("run"))
        #expect(
            feature.filteredCommands(query: "全局搜索") { command in
                command.id == "search-everywhere" ? "全局搜索 查找文件和操作" : ""
            }.map(\.id) == ["search-everywhere"]
        )
        #expect(feature.groupedCommands(query: "history").allSatisfy { !$0.commands.isEmpty })
    }

    @Test
    func applicationRestoreDefaultsAlsoClearsShortcutOverrides() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let replacement = KeyboardShortcutBinding.keyPress(
            key: "k",
            modifiers: [.command, .option]
        )
        settings.editorFontSize = 18
        try feature.replaceBindings(for: "run", with: [replacement])

        settings.restoreDefaults()

        #expect(settings.editorFontSize == 13)
        #expect(settings.keyboardShortcutOverrides.isEmpty)
        #expect(
            feature.effectiveBindings(for: "run")
                == LitheCommandCatalog.command(id: "run")?.defaultBindings
        )
    }

    @Test
    func applicationRestoreDefaultsClearsEveryPreset() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let binding = KeyboardShortcutBinding.keyPress(key: "k", modifiers: [.command, .option])
        try feature.replaceBindings(for: "run", with: [binding])
        feature.selectPreset(.ideaClassic)
        try feature.replaceBindings(for: "run", with: [binding])

        settings.restoreDefaults()

        #expect(feature.selectedPreset == .macOS)
        #expect(settings.keyboardShortcutOverrides.isEmpty)
        feature.selectPreset(.ideaClassic)
        #expect(feature.effectiveBindings(for: "run") == [.keyPress(key: "f10", modifiers: [.shift])])
    }
}

@Suite("Shortcut session coordination")
@MainActor
struct ShortcutSessionCoordinatorTests {
    @Test
    func settingsAndRecordingUpdateTheDetectorSynchronously() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let factory = RecordingShortcutDetectorFactory()
        var publications = 0
        let coordinator = ShortcutSessionCoordinator(
            settings: settings, feature: feature, factory: factory,
            onRegistrationsChanged: { publications += 1 }, onCommand: { _ in }
        )
        defer { coordinator.shutdown() }
        #expect(factory.detector.registrations == feature.registrations)
        #expect(publications == 1)
        let replacement = KeyboardShortcutBinding.keyPress(key: "k", modifiers: [.command, .option])

        try feature.replaceBindings(for: "run", with: [replacement])

        #expect(factory.detector.registrations.first { $0.commandID == "run" }?.bindings == [replacement])
        #expect(publications == 2)
        feature.beginRecording(commandID: "run")
        #expect(factory.detector.isSuspended)
        feature.endRecording()
        #expect(!factory.detector.isSuspended)
    }

    @Test
    func presetSwitchUpdatesTheActiveDetectorImmediately() {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let factory = RecordingShortcutDetectorFactory()
        var publications = 0
        let coordinator = ShortcutSessionCoordinator(
            settings: settings, feature: feature, factory: factory,
            onRegistrationsChanged: { publications += 1 }, onCommand: { _ in }
        )
        defer { coordinator.shutdown() }

        feature.selectPreset(.ideaClassic)

        #expect(feature.selectedPreset == .ideaClassic)
        #expect(factory.detector.registrations.first { $0.commandID == "run" }?.bindings
                == [.keyPress(key: "f10", modifiers: [.shift])])
        #expect(publications == 2)
    }

    @Test
    func inactiveRecordingAndShutdownSessionsRejectQueuedCommands() {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let factory = RecordingShortcutDetectorFactory()
        var commands: [String] = []
        let coordinator = ShortcutSessionCoordinator(
            settings: settings, feature: feature, factory: factory,
            onRegistrationsChanged: {}, onCommand: { commands.append($0) }
        )
        defer { coordinator.shutdown() }
        factory.deliverQueuedCommand("inactive")
        coordinator.setActive(true)
        coordinator.setActive(true)
        factory.deliverQueuedCommand("active")
        feature.beginRecording(commandID: "run")
        factory.deliverQueuedCommand("recording")
        feature.endRecording()
        coordinator.setActive(false)
        coordinator.setActive(false)
        factory.deliverQueuedCommand("deactivated")
        coordinator.setActive(true)
        factory.deliverQueuedCommand("reactivated")
        coordinator.shutdown()
        coordinator.shutdown()
        coordinator.setActive(true)
        factory.deliverQueuedCommand("shutdown")

        #expect(commands == ["active", "reactivated"])
        #expect(factory.detector.lifecycle == ["start", "stop", "start", "stop"])
        let updates = factory.detector.updateCount
        settings.setKeyboardShortcutOverrides(["run": []])
        feature.beginRecording(commandID: "run")
        #expect(factory.detector.updateCount == updates)
        #expect(!factory.detector.isSuspended)
    }

    @Test
    func releasingActiveCoordinatorStopsMonitoringAndDisconnectsCallbacks() {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let factory = RecordingShortcutDetectorFactory()
        var commands: [String] = []
        var coordinator: ShortcutSessionCoordinator? = ShortcutSessionCoordinator(
            settings: settings, feature: feature, factory: factory,
            onRegistrationsChanged: {}, onCommand: { commands.append($0) }
        )
        coordinator?.setActive(true)
        coordinator = nil
        #expect(factory.detector.lifecycle == ["start", "stop"])
        let updates = factory.detector.updateCount
        settings.setKeyboardShortcutOverrides(["run": []])
        feature.beginRecording(commandID: "run")
        factory.deliverQueuedCommand("released")
        #expect(factory.detector.updateCount == updates)
        #expect(!factory.detector.isSuspended)
        #expect(commands.isEmpty)
    }
}

@MainActor
private final class RecordingShortcutDetectorFactory: ShortcutDetectorFactory {
    let detector = RecordingShortcutDetector()
    private var onCommand: (@MainActor @Sendable (String) -> Void)?

    func make(onCommand: @escaping @MainActor @Sendable (String) -> Void) -> any ShortcutDetector {
        self.onCommand = onCommand
        return detector
    }

    // Native events already queued on the main actor can arrive after stop().
    func deliverQueuedCommand(_ commandID: String) {
        onCommand?(commandID)
    }
}

private final class RecordingShortcutDetector: ShortcutDetector {
    var registrations: [KeyboardShortcutRegistration] = []
    var isSuspended = false
    var lifecycle: [String] = []
    var updateCount = 0

    func start() { lifecycle.append("start") }
    func stop() { lifecycle.append("stop") }
    func setSuspended(_ suspended: Bool) { isSuspended = suspended }
    func update(registrations: [KeyboardShortcutRegistration]) {
        self.registrations = registrations
        updateCount += 1
    }
}

private final class KeyboardShortcutTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

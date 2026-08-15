import Foundation
import Testing
@testable import Lithe

@Suite("Keyboard shortcuts")
@MainActor
struct KeyboardShortcutTests {
    @Test
    func catalogHasStableUniqueCommandsAndConflictFreeDefaults() {
        let commands = LitheCommandCatalog.commands
        #expect(commands.count == 27)
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
        #expect(actionIDs.contains("go-to-implementation"))
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
}

private final class KeyboardShortcutTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

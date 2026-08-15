import Combine
import Foundation

enum KeyboardShortcutUpdateError: Error, Equatable {
    case unknownCommand(String)
    case invalidBinding
    case duplicateBinding
    case conflict(commandID: String)
}

@MainActor
final class KeyboardShortcutFeatureModel: ObservableObject {
    @Published private(set) var recordingCommandID: String?

    private let settings: AppSettings
    private var settingsObservation: AnyCancellable?

    init(settings: AppSettings) {
        self.settings = settings
        settingsObservation = settings.$keyboardShortcutOverrides
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    var commands: [LitheCommandDefinition] {
        LitheCommandCatalog.commands
    }

    func effectiveBindings(for commandID: String) -> [KeyboardShortcutBinding] {
        if let override = settings.keyboardShortcutOverrides[commandID] {
            return override
        }
        return LitheCommandCatalog.command(id: commandID)?.defaultBindings ?? []
    }

    func replaceBindings(
        for commandID: String,
        with bindings: [KeyboardShortcutBinding]
    ) throws {
        guard LitheCommandCatalog.command(id: commandID) != nil else {
            throw KeyboardShortcutUpdateError.unknownCommand(commandID)
        }
        guard bindings.allSatisfy(\.isAssignable) else {
            throw KeyboardShortcutUpdateError.invalidBinding
        }
        guard Set(bindings).count == bindings.count else {
            throw KeyboardShortcutUpdateError.duplicateBinding
        }
        if let owner = conflictingCommand(for: bindings, excluding: commandID) {
            throw KeyboardShortcutUpdateError.conflict(commandID: owner.id)
        }

        var overrides = settings.keyboardShortcutOverrides
        overrides[commandID] = bindings
        settings.setKeyboardShortcutOverrides(overrides)
    }

    func resetCommand(_ commandID: String) {
        guard settings.keyboardShortcutOverrides[commandID] != nil else { return }
        var overrides = settings.keyboardShortcutOverrides
        overrides[commandID] = nil
        settings.setKeyboardShortcutOverrides(overrides)
    }

    func resetAll() {
        guard !settings.keyboardShortcutOverrides.isEmpty else { return }
        settings.setKeyboardShortcutOverrides([:])
    }

    func beginRecording(commandID: String) {
        recordingCommandID = commandID
    }

    func endRecording() {
        recordingCommandID = nil
    }

    func conflictingCommand(
        for bindings: [KeyboardShortcutBinding],
        excluding excludedCommandID: String
    ) -> LitheCommandDefinition? {
        let candidates = Set(bindings)
        guard !candidates.isEmpty else { return nil }
        return commands.first { command in
            command.id != excludedCommandID
                && !candidates.isDisjoint(with: effectiveBindings(for: command.id))
        }
    }
}

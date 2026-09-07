import Combine
import Foundation

enum KeyboardShortcutUpdateError: Error, Equatable {
    case unknownCommand(String)
    case invalidBinding
    case duplicateBinding
    case conflict(commandID: String)
}

struct KeyboardShortcutCommandSection: Identifiable, Equatable, Sendable {
    let group: LitheActionGroup
    let commands: [LitheCommandDefinition]

    var id: LitheActionGroup { group }
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

    var registrations: [KeyboardShortcutRegistration] {
        registrations(for: settings.keyboardShortcutOverrides)
    }

    // Use the emitted overrides when observing @Published, whose stored value
    // still contains the previous settings during the publication callback.
    func registrations(for overrides: [String: [KeyboardShortcutBinding]]) -> [KeyboardShortcutRegistration] {
        commands.map { command in
            KeyboardShortcutRegistration(
                commandID: command.id,
                bindings: overrides[command.id] ?? command.defaultBindings
            )
        }
    }

    func filteredCommands(
        query: String,
        additionalSearchText: (LitheCommandDefinition) -> String = { _ in "" }
    ) -> [LitheCommandDefinition] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return commands }
        return commands.filter { command in
            let searchText = [
                command.title,
                command.subtitle,
                command.id,
                command.group.rawValue,
                displayText(for: command.id) ?? "",
                additionalSearchText(command)
            ].joined(separator: " ").lowercased()
            return searchText.contains(normalizedQuery)
        }
    }

    func groupedCommands(
        query: String,
        additionalSearchText: (LitheCommandDefinition) -> String = { _ in "" }
    ) -> [KeyboardShortcutCommandSection] {
        let filtered = filteredCommands(query: query, additionalSearchText: additionalSearchText)
        return LitheActionGroup.allCases.compactMap { group in
            let groupCommands = filtered.filter { $0.group == group }
            guard !groupCommands.isEmpty else { return nil }
            return KeyboardShortcutCommandSection(group: group, commands: groupCommands)
        }
    }

    func effectiveBindings(for commandID: String) -> [KeyboardShortcutBinding] {
        if let override = settings.keyboardShortcutOverrides[commandID] {
            return override
        }
        return LitheCommandCatalog.command(id: commandID)?.defaultBindings ?? []
    }

    func displayText(for commandID: String) -> String? {
        let values = effectiveBindings(for: commandID).map(\.displayText)
        return values.isEmpty ? nil : values.joined(separator: "  ")
    }

    func primaryKeyPress(for commandID: String) -> KeyboardShortcutBinding? {
        effectiveBindings(for: commandID).first { binding in
            if case .keyPress = binding { return true }
            return false
        }
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

    func isCustomized(_ commandID: String) -> Bool {
        settings.keyboardShortcutOverrides[commandID] != nil
    }

    func beginRecording(commandID: String) {
        recordingCommandID = commandID
    }

    func endRecording(commandID: String? = nil) {
        guard commandID == nil || recordingCommandID == commandID else { return }
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

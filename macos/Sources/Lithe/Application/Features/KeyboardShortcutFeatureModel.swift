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

    var selectedPreset: KeyboardShortcutPreset {
        settings.keyboardShortcutPreset
    }

    func selectPreset(_ preset: KeyboardShortcutPreset) {
        settings.selectKeyboardShortcutPreset(preset)
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
                bindings: overrides[command.id] ?? settings.keyboardShortcutPreset.bindings(for: command)
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
        guard let command = LitheCommandCatalog.command(id: commandID) else { return [] }
        return settings.keyboardShortcutPreset.bindings(for: command)
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
        if let owner = try conflictingCommand(for: bindings, excluding: commandID) {
            throw KeyboardShortcutUpdateError.conflict(commandID: owner.id)
        }

        var overrides = settings.keyboardShortcutOverrides
        overrides[commandID] = bindings
        settings.setKeyboardShortcutOverrides(overrides)
    }

    /// Validate a batch against its final registrations, allowing swaps without transient conflicts.
    func validateOverrides(_ proposed: [String: [KeyboardShortcutBinding]]) throws {
        for (id, bindings) in proposed {
            guard LitheCommandCatalog.command(id: id) != nil else { throw KeyboardShortcutUpdateError.unknownCommand(id) }
            guard bindings.allSatisfy(\.isAssignable), Set(bindings).count == bindings.count else { throw KeyboardShortcutUpdateError.invalidBinding }
        }
        let conflicts = try finalConflicts(overrides: proposed)
        for id in proposed.keys.sorted() where proposed[id] != effectiveBindings(for: id) {
            if let owner = conflictOwner(of: id, in: conflicts) {
                throw KeyboardShortcutUpdateError.conflict(commandID: owner)
            }
        }
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

    /// The first command, in catalog order, that already owns one of `bindings`.
    func conflictingCommand(
        for bindings: [KeyboardShortcutBinding],
        excluding excludedCommandID: String
    ) throws -> LitheCommandDefinition? {
        guard !bindings.isEmpty else { return nil }
        var overrides = settings.keyboardShortcutOverrides
        overrides[excludedCommandID] = bindings
        let conflicts = try finalConflicts(overrides: overrides)
        return conflictOwner(of: excludedCommandID, in: conflicts).flatMap(LitheCommandCatalog.command(id:))
    }

    /// Core decides what is in conflict among the final preset-plus-override bindings.
    private func finalConflicts(
        overrides: [String: [KeyboardShortcutBinding]]
    ) throws -> [KeymapBindingConflict] {
        let base = commands.map {
            KeyboardShortcutRegistration(commandID: $0.id, bindings: settings.keyboardShortcutPreset.bindings(for: $0))
        }
        switch RustCoreBridge().analyzeKeymapConflicts(base: base, overrides: overrides) {
        case .success(let conflicts): return conflicts
        case .failure: throw KeyboardShortcutUpdateError.invalidBinding
        }
    }

    private func conflictOwner(of commandID: String, in conflicts: [KeymapBindingConflict]) -> String? {
        let others = Set(conflicts.filter { $0.commands.contains(commandID) }.flatMap(\.commands))
            .subtracting([commandID])
        return commands.first { others.contains($0.id) }?.id
    }
}

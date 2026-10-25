import SwiftUI

struct KeyboardShortcutSettingsView: View {
    @ObservedObject var feature: KeyboardShortcutFeatureModel
    let language: AppLanguage
    @State private var query = ""
    @State private var expandedGroups: Set<LitheActionGroup> = []
    @State private var selectedCommandID: String?
    @State private var editingTarget: EditingTarget?
    @State private var validationIssue: ValidationIssue?

    private struct EditingTarget: Equatable {
        let commandID: String
        let bindingIndex: Int?
    }

    private enum ValidationIssue: Equatable {
        case needsActionModifier
        case duplicateBinding
        case conflict(commandTitle: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            toolbar
            if sections.isEmpty {
                emptyState
                Spacer(minLength: 0)
            } else {
                LitheTreeList(
                    commandRows, selection: $selectedCommandID, hierarchy: { $0.hierarchy },
                    onExpansion: { row, expanded in
                        guard let group = row.group, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { return }
                        if expanded {
                            expandedGroups.insert(group)
                        } else {
                            expandedGroups.remove(group); cancelEditing()
                        }
                    }, multiline: true
                ) { row in
                    if let command = row.command {
                        commandRow(command)
                    } else if let group = row.group {
                        HStack(spacing: LitheTheme.Tree.iconTextGap) {
                            LitheIcon(kind: .folder, size: LitheTheme.Tree.iconSize)
                            Text(LocalizedStringKey(group.rawValue))
                        }
                    }
                    }
            }
        }
        .background(LitheTheme.settingsSurface)
    }

    private var sections: [KeyboardShortcutCommandSection] {
        feature.groupedCommands(query: query) { command in
            [
                localizedString(command.title),
                localizedString(command.subtitle),
                localizedString(command.group.rawValue)
            ].joined(separator: " ")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LitheSettingsSelect(
                selection: Binding(
                    get: { feature.selectedPreset },
                    set: { preset in
                        cancelEditing()
                        selectedCommandID = nil
                        feature.selectPreset(preset)
                    }
                ),
                options: KeyboardShortcutPreset.allCases,
                width: 200,
                accessibilityLabel: "Keymap",
                title: { $0.title }
            )
            LitheMenu {
                LitheContextMenuItem.action("Restore All Defaults") {
                    cancelEditing()
                    feature.resetAll()
                }
            } label: {
                LitheSystemIcon(systemImage: "gearshape", size: 16)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .buttonStyle(.litheNoPress)

            .tint(LitheTheme.secondaryText)
            .frame(width: 26)
            .accessibilityLabel("Restore All Defaults")
            .lithePointer()
            Spacer()
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                expandedGroups = Set(LitheActionGroup.allCases)
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/expandAll.svg", size: 16, fallbackSystemImage: "arrow.down.right.and.arrow.up.left", preservesOriginalColors: true)
            }
            .help("Expand All")
            .accessibilityLabel("Expand All")

            Button {
                expandedGroups = []
                cancelEditing()
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/collapseAll.svg", size: 16, fallbackSystemImage: "arrow.up.left.and.arrow.down.right", preservesOriginalColors: true)
            }
            .help("Collapse All")
            .accessibilityLabel("Collapse All")

            LitheMenu {
                if let selectedCommandID,
                    let command = LitheCommandCatalog.command(id: selectedCommandID)
                {
                    LitheContextMenuItem.action("Add Shortcut") {
                        expandedGroups.insert(command.group)
                        beginEditing(commandID: selectedCommandID, bindingIndex: nil)
                    }
                    for (index, binding) in Array(
                        feature.effectiveBindings(for: selectedCommandID).enumerated())
                    {
                        LitheContextMenuItem.action("Remove \(binding.displayText)") {
                            removeBinding(commandID: selectedCommandID, index: index)
                        }
                    }
                    if feature.isCustomized(selectedCommandID) {
                        LitheContextMenuItem.action("Restore Default") {
                            cancelEditing()
                            feature.resetCommand(selectedCommandID)
                        }
                    }
                }
            } label: {
                LitheIDEAIcon(
                    resourcePath: "expui/general/edit.svg", size: 16, fallbackSystemImage: "pencil",
                    preservesOriginalColors: true)
            }
            .buttonStyle(.litheNoPress)

            .tint(LitheTheme.secondaryText)
            .disabled(selectedCommandID == nil)
            .help("Edit Shortcuts")
            .accessibilityLabel("Edit Shortcuts")

            Spacer(minLength: 12)
            LitheSearchField("", text: $query, onTextChanged: { _ in
                cancelEditing()
                selectedCommandID = nil
            })
            .frame(width: 244)
            .accessibilityLabel("Search actions or shortcuts")
        }
        .font(LitheTheme.uiFont(size: 12))
        .buttonStyle(.litheNoPress)
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(alignment: .top) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
        .background(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
    }

    private struct CommandRow: Identifiable {
        let id: String
        var group: LitheActionGroup?
        var command: LitheCommandDefinition?
        var hierarchy: LitheTreeListHierarchy
    }

    private var commandRows: [CommandRow] {
        sections.flatMap { section in
            [
                CommandRow(
                    id: "group:" + section.group.rawValue, group: section.group,
                    hierarchy: .init(isBranch: true, isExpanded: isExpanded(section.group), isSelectable: false))
            ]
                + (isExpanded(section.group)
                    ? section.commands.map {
                        CommandRow(id: $0.id, command: $0, hierarchy: .init(depth: 1))
                    } : [])
        }
    }

    private func isExpanded(_ group: LitheActionGroup) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expandedGroups.contains(group)
    }

    private func commandRow(_ command: LitheCommandDefinition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selectedCommandID = command.id
                } label: {
                    HStack(spacing: 0) {
                        Text(LocalizedStringKey(command.title))
                            .font(LitheTheme.uiFont(size: 12.5))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)

                shortcutControls(for: command)
            }
            .foregroundStyle(selectedCommandID == command.id ? LitheTheme.settingsSelectionText : LitheTheme.primaryText)
            .frame(height: 24)
            .litheContextMenu {
                var items: [LitheContextMenuItem] = [
                    .action("Add Shortcut") {
                        beginEditing(commandID: command.id, bindingIndex: nil)
                    }
                ]
                if feature.isCustomized(command.id) {
                    items.append(.action("Restore Default") {
                        cancelEditing()
                        feature.resetCommand(command.id)
                    })
                }
                return items
            }

            if editingTarget?.commandID == command.id {
                KeyboardShortcutRecorderView(
                    feature: feature,
                    commandID: command.id,
                    onRecorded: { binding in save(binding, for: command) },
                    onInvalid: {
                        validationIssue = .needsActionModifier
                    },
                    onCancel: cancelEditing
                )
                .id("\(command.id)-\(editingTarget?.bindingIndex ?? -1)")
                .padding(.leading, 31)

                if let validationIssue {
                    Label {
                        validationMessage(for: validationIssue)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.warning)
                    .padding(.leading, 31)
                }
            }
        }
    }

    private func shortcutControls(for command: LitheCommandDefinition) -> some View {
        let bindings = feature.effectiveBindings(for: command.id)
        return HStack(spacing: 6) {
            if bindings.isEmpty {
                Button("Not Assigned") { beginEditing(commandID: command.id, bindingIndex: nil) }
                    .buttonStyle(.litheNoPress)
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .lithePointer()
            } else {
                ForEach(Array(bindings.enumerated()), id: \.offset) { index, binding in
                    bindingChip(binding, commandID: command.id, index: index)
                }
            }
        }
    }

    private func bindingChip(
        _ binding: KeyboardShortcutBinding,
        commandID: String,
        index: Int
    ) -> some View {
        Button {
            beginEditing(commandID: commandID, bindingIndex: index)
        } label: {
            HStack(spacing: 2) {
                ForEach(Array(keycapLabels(for: binding).enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(LitheTheme.uiFont(size: 11, weight: .medium, design: .rounded))
                        .frame(minWidth: 14, minHeight: 17)
                        .padding(.horizontal, 2)
                        .litheSettingsControlChrome(cornerRadius: 3)
                }
            }
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .help("Edit Shortcut")
        .accessibilityLabel(binding.displayText)
        .litheContextMenu {
            [LitheContextMenuItem.action("Remove Shortcut") {
                removeBinding(commandID: commandID, index: index)
            }]
        }
    }

    private func keycapLabels(for binding: KeyboardShortcutBinding) -> [String] {
        guard let (_, modifiers) = binding.keyPressValue else { return [binding.displayText] }
        let symbols = [
            modifiers.contains(.control) ? "⌃" : nil,
            modifiers.contains(.option) ? "⌥" : nil,
            modifiers.contains(.shift) ? "⇧" : nil,
            modifiers.contains(.command) ? "⌘" : nil
        ].compactMap { $0 }
        return symbols + [String(binding.displayText.dropFirst(symbols.count))]
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(LitheTheme.uiFont(size: 28))
            Text("No matching commands")
                .font(LitheTheme.uiFont(size: 13, weight: .medium))
        }
        .foregroundStyle(LitheTheme.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private func beginEditing(commandID: String, bindingIndex: Int?) {
        selectedCommandID = commandID
        validationIssue = nil
        editingTarget = EditingTarget(commandID: commandID, bindingIndex: bindingIndex)
    }

    private func cancelEditing() {
        feature.endRecording()
        editingTarget = nil
        validationIssue = nil
    }

    private func save(_ binding: KeyboardShortcutBinding, for command: LitheCommandDefinition) {
        guard let editingTarget, editingTarget.commandID == command.id else { return }
        var bindings = feature.effectiveBindings(for: command.id)
        if let index = editingTarget.bindingIndex, bindings.indices.contains(index) {
            bindings[index] = binding
        } else {
            bindings.append(binding)
        }

        do {
            try feature.replaceBindings(for: command.id, with: bindings)
            cancelEditing()
        } catch KeyboardShortcutUpdateError.conflict(let commandID) {
            let title = LitheCommandCatalog.command(id: commandID)?.title ?? commandID
            validationIssue = .conflict(commandTitle: title)
        } catch KeyboardShortcutUpdateError.duplicateBinding {
            validationIssue = .duplicateBinding
        } catch {
            validationIssue = .needsActionModifier
        }
    }

    @ViewBuilder
    private func validationMessage(for issue: ValidationIssue) -> some View {
        switch issue {
        case .needsActionModifier:
            Text("Shortcut needs Command, Control, or Option")
        case .duplicateBinding:
            Text("Shortcut is already assigned to this command")
        case .conflict(let commandTitle):
            Text("Conflicts with \(Text(LocalizedStringKey(commandTitle)))")
        }
    }

    private func removeBinding(commandID: String, index: Int) {
        cancelEditing()
        var bindings = feature.effectiveBindings(for: commandID)
        guard bindings.indices.contains(index) else { return }
        bindings.remove(at: index)
        try? feature.replaceBindings(for: commandID, with: bindings)
    }

    private func localizedString(_ key: String) -> String {
        guard let resourceURL = Bundle.main.resourceURL,
              let localizationBundle = Bundle(
                url: resourceURL.appendingPathComponent("\(language.rawValue).lproj", isDirectory: true)
              ) else { return key }
        return localizationBundle.localizedString(forKey: key, value: key, table: nil)
    }
}

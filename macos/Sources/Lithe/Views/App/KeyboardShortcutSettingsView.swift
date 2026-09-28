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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        emptyState
                    } else {
                        ForEach(sections) { section in
                            commandSection(section)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
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
            Text("macOS")
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 190, height: 28, alignment: .leading)
                .padding(.horizontal, 9)
                .litheSettingsControlChrome()
            Menu {
                Button("Restore All Defaults") {
                    cancelEditing()
                    feature.resetAll()
                }
            } label: {
                LitheSystemIcon(systemImage: "gearshape", size: 16)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
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

            Button {
                expandedGroups = []
                cancelEditing()
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/collapseAll.svg", size: 16, fallbackSystemImage: "arrow.up.left.and.arrow.down.right", preservesOriginalColors: true)
            }
            .help("Collapse All")

            Menu {
                if let selectedCommandID,
                   let command = LitheCommandCatalog.command(id: selectedCommandID) {
                    Button("Add Shortcut") {
                        expandedGroups.insert(command.group)
                        beginEditing(commandID: selectedCommandID, bindingIndex: nil)
                    }
                    ForEach(Array(feature.effectiveBindings(for: selectedCommandID).enumerated()), id: \.offset) { index, binding in
                        Button("Remove \(binding.displayText)") {
                            removeBinding(commandID: selectedCommandID, index: index)
                        }
                    }
                    if feature.isCustomized(selectedCommandID) {
                        Button("Restore Default") {
                            cancelEditing()
                            feature.resetCommand(selectedCommandID)
                        }
                    }
                }
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/edit.svg", size: 16, fallbackSystemImage: "pencil", preservesOriginalColors: true)
            }
            .menuStyle(.borderlessButton)
            .tint(LitheTheme.secondaryText)
            .disabled(selectedCommandID == nil)
            .help("Edit Shortcuts")

            Spacer(minLength: 12)
            LitheSettingsSearchField("", text: $query) { _ in
                cancelEditing()
                selectedCommandID = nil
            }
            .frame(width: 244)
            .accessibilityLabel("Search actions or shortcuts")
        }
        .font(.system(size: 12))
        .buttonStyle(.litheNoPress)
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(alignment: .top) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
        .background(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
    }

    private func commandSection(_ section: KeyboardShortcutCommandSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expandedGroups.contains(section.group) {
                    expandedGroups.remove(section.group)
                    cancelEditing()
                } else {
                    expandedGroups.insert(section.group)
                }
            } label: {
                HStack(spacing: 7) {
                    LitheIDEAIcon(resourcePath: "expui/general/chevronRight.svg", size: 16, fallbackSystemImage: "chevron.right", preservesOriginalColors: true)
                        .rotationEffect(.degrees(isExpanded(section.group) ? 90 : 0))
                    LitheIcon(kind: .folder, size: 16)
                    Text(LocalizedStringKey(section.group.rawValue))
                        .font(.system(size: 12.5))
                    Spacer()
                }
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .disabled(!query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if isExpanded(section.group) {
                ForEach(section.commands) { command in
                    commandRow(command)
                }
            }
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
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)

                shortcutControls(for: command)
            }
            .foregroundStyle(selectedCommandID == command.id ? LitheTheme.settingsSelectionText : LitheTheme.primaryText)
            .padding(.leading, 36)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background(selectedCommandID == command.id ? LitheTheme.settingsSelection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contextMenu {
                Button("Add Shortcut") {
                    beginEditing(commandID: command.id, bindingIndex: nil)
                }
                if feature.isCustomized(command.id) {
                    Button("Restore Default") {
                        cancelEditing()
                        feature.resetCommand(command.id)
                    }
                }
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
                    .font(.system(size: 11))
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
                    .font(.system(size: 12))
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
                        .font(.system(size: 11, weight: .medium, design: .rounded))
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
        .contextMenu {
            Button("Remove Shortcut") {
                removeBinding(commandID: commandID, index: index)
            }
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
                .font(.system(size: 28))
            Text("No matching commands")
                .font(.system(size: 13, weight: .medium))
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

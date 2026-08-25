import SwiftUI

struct KeyboardShortcutSettingsView: View {
    @ObservedObject var feature: KeyboardShortcutFeatureModel
    let language: AppLanguage
    @State private var query = ""
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    let sections = feature.groupedCommands(query: query) { command in
                        [
                            localizedString(command.title),
                            localizedString(command.subtitle),
                            localizedString(command.group.rawValue)
                        ].joined(separator: " ")
                    }
                    if sections.isEmpty {
                        emptyState
                    } else {
                        ForEach(sections) { section in
                            commandSection(section)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
        }
        .background(LitheTheme.settingsSurface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keymap")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Customize shortcuts for Lithe actions. Changes apply immediately.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
                Button("Restore All Defaults") {
                    editingTarget = nil
                    validationIssue = nil
                    feature.resetAll()
                }
                .buttonStyle(.bordered)
                .lithePointer()
            }

            LitheSettingsSearchField("Search actions or shortcuts", text: $query) { _ in
                    editingTarget = nil
                    validationIssue = nil
            }
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(24)
    }

    private func commandSection(_ section: KeyboardShortcutCommandSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(section.group.rawValue))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(Array(section.commands.enumerated()), id: \.element.id) { index, command in
                    commandRow(command)
                    if index < section.commands.count - 1 {
                        Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    }
                }
            }
            .background(LitheTheme.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(LitheTheme.divider, lineWidth: 1)
            }
        }
    }

    private func commandRow(_ command: LitheCommandDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(command.title))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(command.id)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

                shortcutControls(for: command)

                if feature.isCustomized(command.id) {
                    Button("Reset") {
                        cancelEditing()
                        feature.resetCommand(command.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                    .lithePointer()
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

                if let validationIssue {
                    Label {
                        validationMessage(for: validationIssue)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.warning)
                }
            }
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func shortcutControls(for command: LitheCommandDefinition) -> some View {
        let bindings = feature.effectiveBindings(for: command.id)
        return HStack(spacing: 6) {
            if bindings.isEmpty {
                Button("Not Assigned") { beginEditing(commandID: command.id, bindingIndex: nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .lithePointer()
            } else {
                ForEach(Array(bindings.enumerated()), id: \.offset) { index, binding in
                    bindingChip(binding, commandID: command.id, index: index)
                }
            }

            Button {
                beginEditing(commandID: command.id, bindingIndex: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Add Shortcut")
            .lithePointer()
        }
    }

    private func bindingChip(
        _ binding: KeyboardShortcutBinding,
        commandID: String,
        index: Int
    ) -> some View {
        HStack(spacing: 3) {
            Button(binding.displayText) {
                beginEditing(commandID: commandID, bindingIndex: index)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .lithePointer()

            Button {
                removeBinding(commandID: commandID, index: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .lithePointer()
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(LitheTheme.settingsControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(LitheTheme.inputBorder, lineWidth: 1)
        }
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

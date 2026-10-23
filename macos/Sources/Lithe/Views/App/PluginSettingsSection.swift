import LitheCoreContracts
import SwiftUI

// Note: 插件设置注册面与生效方式见 .agents/notes/implemented/architecture/2026-10-21-plugin-settings-surfaces.md

/// What a plugin settings surface asks the host to do. The views never know
/// which plugin or tool they show; every control and button is drawn from
/// the plugin's declaration and handed back through these closures.
struct PluginSettingsHandlers {
    let setValue: (_ settingID: String, _ value: ToolingJSONValue?, _ layer: PluginSettingLayer) -> PluginSettingApplication?
    let restartLanguageServers: () -> Void
    let runAction: (DeclarativePluginSettingAction) async -> Void
    let choosePath: (_ directory: Bool) -> URL?
}

/// The options and buttons one plugin registered for a surface, grouped by
/// the sections the plugin named. Every control writes as soon as its value
/// is valid; the setting's declared effect then decides whether the change
/// is already live or the section offers a restart, so editing a number
/// never restarts a server mid-keystroke.
struct PluginSettingsSection: View {
    let settings: [PluginSettingState]
    var actions: [DeclarativePluginSettingAction] = []
    /// A project is open, so project-scoped settings can be overridden.
    let hasProject: Bool
    let handlers: PluginSettingsHandlers
    /// Heading for the options the plugin did not put in a named section.
    var title: String?
    /// The layer the page edits. A page that hosts several plugins owns the
    /// switch; without one this section shows its own.
    var layer: Binding<PluginSettingLayer>?
    @State private var ownLayer = PluginSettingLayer.project
    @State private var pendingRestart = false

    private struct Group: Identifiable {
        let title: String?
        var settings: [PluginSettingState] = []
        var actions: [DeclarativePluginSettingAction] = []
        var id: String { title ?? "" }
    }

    /// Sections in the order the plugin first uses them; unnamed first.
    private var groups: [Group] {
        var groups = [Group(title: nil)]
        func index(_ title: String?) -> Int {
            if let found = groups.firstIndex(where: { $0.title == title }) { return found }
            groups.append(Group(title: title))
            return groups.count - 1
        }
        for setting in settings { groups[index(setting.declaration.section)].settings.append(setting) }
        for action in actions { groups[index(action.section)].actions.append(action) }
        return groups.filter { !$0.settings.isEmpty || !$0.actions.isEmpty }
    }

    private var hasProjectSettings: Bool {
        hasProject && settings.contains { $0.declaration.scope == .project }
    }

    private var editedLayer: Binding<PluginSettingLayer> { layer ?? $ownLayer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if layer == nil, hasProjectSettings {
                LitheSettingsBanner {
                    Text(LocalizedStringKey("Changes are written to"))
                    PluginSettingLayerPicker(layer: $ownLayer)
                    Spacer(minLength: 0)
                }
            }
            if pendingRestart {
                LitheSettingsNotice(LocalizedStringKey("Applies the next time the language server starts.")) {
                    Button(LocalizedStringKey("Restart Language Servers")) {
                        handlers.restartLanguageServers()
                        pendingRestart = false
                    }
                    .buttonStyle(LitheActionButtonStyle())
                }
            }
            ForEach(groups) { group in
                LitheSettingsSection(title: group.title ?? title ?? "", accessory: { EmptyView() }) {
                    ForEach(group.settings) { setting in
                        PluginSettingRow(
                            setting: setting,
                            pageLayer: editedLayer.wrappedValue,
                            hasProject: hasProject,
                            choosePath: handlers.choosePath
                        ) { value, layer in
                            record(handlers.setValue(setting.id, value, layer))
                        }
                    }
                    if !group.actions.isEmpty {
                        PluginSettingActionBar(actions: group.actions, run: handlers.runAction)
                    }
                }
            }
            if !settings.isEmpty {
                HStack(spacing: 6) {
                    Spacer()
                    LitheInfoTip(LocalizedStringKey("Valid values are saved as you type."))
                    Button(LocalizedStringKey("Restore Defaults"), action: restoreDefaults)
                        .buttonStyle(LitheActionButtonStyle())
                        .disabled(!settings.contains { hasStoredValue($0, in: editedLayer(of: $0)) })
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
    }

    /// The layer a row edits: the page's layer for a project-scoped
    /// setting in an open project, otherwise the global one.
    private func editedLayer(of setting: PluginSettingState) -> PluginSettingLayer {
        setting.declaration.scope == .project && hasProject ? editedLayer.wrappedValue : .global
    }

    private func hasStoredValue(_ setting: PluginSettingState, in layer: PluginSettingLayer) -> Bool {
        switch layer {
        case .project: setting.projectValue != nil
        case .global: setting.globalValue != nil
        }
    }

    /// Clears only the layer each row edits, so restoring this project's
    /// overrides never discards the values chosen for every project.
    private func restoreDefaults() {
        for setting in settings {
            let layer = editedLayer(of: setting)
            if hasStoredValue(setting, in: layer) { record(handlers.setValue(setting.id, nil, layer)) }
        }
    }

    private func record(_ application: PluginSettingApplication?) {
        if application == .restartRequired { pendingRestart = true }
    }
}

/// Where edits on a settings page go: this project, or every project.
struct PluginSettingLayerPicker: View {
    @Binding var layer: PluginSettingLayer

    var body: some View {
        LitheSettingsSegmentedControl(
            selection: $layer,
            options: [PluginSettingLayer.project, .global],
            width: 200,
            title: { $0 == .project ? "This project" : "All projects" }
        )
        .accessibilityLabel(Text(LocalizedStringKey("Changes are written to")))
    }
}

// MARK: - Row

private struct PluginSettingRow: View {
    let setting: PluginSettingState
    let pageLayer: PluginSettingLayer
    let hasProject: Bool
    let choosePath: (Bool) -> URL?
    let onChange: (ToolingJSONValue?, PluginSettingLayer) -> Void

    private var declaration: DeclarativePluginSetting { setting.declaration }
    private var canOverrideInProject: Bool { declaration.scope == .project && hasProject }

    /// Settings that only exist globally ignore the page's project switch.
    private var layer: PluginSettingLayer { canOverrideInProject ? pageLayer : .global }

    /// What the edited layer holds; a layer with nothing stored shows the
    /// value it would fall back to.
    private var shownValue: ToolingJSONValue {
        switch layer {
        case .project: setting.projectValue ?? setting.value
        case .global: setting.globalValue ?? declaration.defaultValue
        }
    }

    private var layerHasValue: Bool {
        switch layer {
        case .project: setting.projectValue != nil
        case .global: setting.globalValue != nil
        }
    }

    var body: some View {
        LitheSettingsRow(
            LocalizedStringKey(declaration.title),
            info: declaration.summary.map { LocalizedStringKey($0) },
            isModified: layerHasValue
        ) {
            control
        } badges: {
            scopePill
            PluginSettingEffectPill(effect: declaration.effect)
            Button { onChange(nil, layer) } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(LitheTheme.uiFont(size: 11, weight: .medium))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .help(Text(LocalizedStringKey("Reset to Default")))
            .accessibilityLabel(Text(LocalizedStringKey("Reset to Default")))
            .opacity(layerHasValue ? 1 : 0)
            .disabled(!layerHasValue)
        }
    }

    @ViewBuilder private var scopePill: some View {
        if setting.source == .project {
            LitheSettingsPill(LocalizedStringKey("This project"), kind: .project)
        } else if canOverrideInProject {
            LitheSettingsPill(LocalizedStringKey("All projects · project can override"))
        } else {
            LitheSettingsPill(LocalizedStringKey("All projects"))
        }
    }

    private func write(_ value: ToolingJSONValue) { onChange(value, layer) }

    /// A value that only marks a restart or the next run can be saved on
    /// every keystroke; one that reloads a build model or reaches a running
    /// server waits for Return or for the field to lose focus, so typing
    /// "1024" does not apply 1, 10, and 102 first.
    private var savesWhileTyping: Bool {
        switch declaration.effect {
        case .restart, .nextRun: true
        case .immediate, .reload: false
        }
    }

    @ViewBuilder private var control: some View {
        switch declaration.kind {
        case .integer(let minimum, let maximum, let unit):
            PluginIntegerSettingField(
                value: shownValue,
                range: minimum...maximum,
                unit: unit,
                accessibilityLabel: declaration.title,
                savesWhileTyping: savesWhileTyping,
                onChange: write
            )
        case .choice(let options):
            LitheSettingsSelect(
                selection: Binding(
                    get: { selectedOption(in: options) },
                    set: { write(.string($0)) }
                ),
                options: options.map(\.value),
                width: 180,
                accessibilityLabel: declaration.title,
                title: { value in options.first { $0.value == value }?.title ?? value }
            )
        case .toggle:
            Toggle("", isOn: Binding(
                get: { shownValue == .bool(true) },
                set: { write(.bool($0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(Text(LocalizedStringKey(declaration.title)))
        case .multiSelect(let options):
            PluginMultiSelectField(
                options: options,
                selected: selectedValues,
                accessibilityLabel: declaration.title
            ) { write(.array($0.map(ToolingJSONValue.string))) }
        case .text(_, _, let placeholder):
            PluginTextSettingField(
                value: shownString,
                placeholder: placeholder,
                width: 200,
                accessibilityLabel: declaration.title,
                savesWhileTyping: savesWhileTyping,
                accepts: { declaration.accepts(.string($0)) },
                onChange: { write(.string($0)) }
            )
        case .path(let directory, let placeholder):
            HStack(spacing: 6) {
                PluginTextSettingField(
                    value: shownString,
                    placeholder: placeholder,
                    width: 220,
                    isFlexible: true,
                    accessibilityLabel: declaration.title,
                    savesWhileTyping: savesWhileTyping,
                    accepts: { declaration.accepts(.string($0)) },
                    onChange: { write(.string($0)) }
                )
                Button(LocalizedStringKey("Choose…")) {
                    if let url = choosePath(directory) { write(.string(url.path)) }
                }
                .buttonStyle(LitheActionButtonStyle())
                .fixedSize()
            }
        }
    }

    private var shownString: String {
        if case .string(let value) = shownValue { value } else { "" }
    }

    private var selectedValues: [String] {
        guard case .array(let values) = shownValue else { return [] }
        return values.compactMap { if case .string(let value) = $0 { value } else { nil } }
    }

    private func selectedOption(in options: [DeclarativePluginSetting.Option]) -> String {
        if case .string(let value) = shownValue { return value }
        return options.first?.value ?? ""
    }
}

// MARK: - Pills

/// When a change takes effect, as the plugin declared it.
private struct PluginSettingEffectPill: View {
    let effect: DeclarativePluginSetting.Effect

    var body: some View {
        switch effect {
        case .immediate: LitheSettingsPill(LocalizedStringKey("Applies immediately"))
        case .restart: LitheSettingsPill(LocalizedStringKey("Needs restart"), kind: .effect)
        case .reload: LitheSettingsPill(LocalizedStringKey("Reloads project"), kind: .effect)
        case .nextRun: LitheSettingsPill(LocalizedStringKey("Next run"))
        }
    }
}

// MARK: - Actions

/// Buttons a plugin placed on the page. Each one runs a function of the
/// plugin's own process; a button the plugin marked as needing confirmation
/// asks first.
private struct PluginSettingActionBar: View {
    let actions: [DeclarativePluginSettingAction]
    let run: (DeclarativePluginSettingAction) async -> Void
    @State private var running: Set<String> = []
    @State private var confirming: DeclarativePluginSettingAction?

    var body: some View {
        HStack(spacing: LitheTheme.ActionButton.spacing) {
            ForEach(actions) { action in
                Button {
                    if action.requiresConfirmation { confirming = action } else { start(action) }
                } label: {
                    HStack(spacing: 6) {
                        if running.contains(action.id) {
                            ProgressView().controlSize(.mini)
                        }
                        Text(LocalizedStringKey(action.title))
                    }
                }
                .buttonStyle(LitheActionButtonStyle())
                .disabled(running.contains(action.id))
                .help(action.summary.map { Text(LocalizedStringKey($0)) } ?? Text(verbatim: ""))
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog(
            Text(LocalizedStringKey(confirming?.title ?? "")),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { action in
            Button(LocalizedStringKey("Run")) { start(action) }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
        } message: { action in
            if let summary = action.summary { Text(LocalizedStringKey(summary)) }
        }
    }

    private func start(_ action: DeclarativePluginSettingAction) {
        guard running.insert(action.id).inserted else { return }
        Task { @MainActor in
            await run(action)
            running.remove(action.id)
        }
    }
}

// MARK: - Fields

/// A menu of checkboxes; the value is the checked options in declared order.
private struct PluginMultiSelectField: View {
    let options: [DeclarativePluginSetting.Option]
    let selected: [String]
    let accessibilityLabel: String
    let onChange: ([String]) -> Void

    private var summary: String {
        let titles = options.filter { selected.contains($0.value) }.map(\.title)
        if titles.isEmpty { return String(localized: "None") }
        return titles.joined(separator: ", ")
    }

    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                Text(verbatim: summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(width: 200, height: SettingsSelectMetrics.controlHeight, alignment: .leading)
            .litheSettingsControlChrome(
                background: LitheTheme.settingsSelectBackground,
                border: isPresented ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder,
                lineWidth: isPresented ? 2 : 1
            )
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .litheDropdown(isPresented: $isPresented) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options, id: \.value) { option in
                        Button { toggle(option.value) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected.contains(option.value) ? "checkmark" : "")
                                    .frame(width: 16)
                                Text(verbatim: option.title)
                                Spacer(minLength: 12)
                            }
                        }
                        .buttonStyle(LitheDropdownRowStyle(isSelected: false))
                    }
                }
            }
            .frame(width: 200)
            .frame(maxHeight: SettingsSelectMetrics.maximumPopupHeight)
        }
    }

    private func toggle(_ value: String) {
        var next = Set(selected)
        if next.contains(value) { next.remove(value) } else { next.insert(value) }
        onChange(options.map(\.value).filter(next.contains))
    }
}

/// A one-line field saved whenever the text is acceptable. Rust Core's rules
/// (whole-match pattern, length, absolute paths) are mirrored by `accepts`,
/// and Core checks again before any value reaches a process.
private struct PluginTextSettingField: View {
    let value: String
    let placeholder: String?
    let width: CGFloat
    var isFlexible = false
    let accessibilityLabel: String
    let savesWhileTyping: Bool
    let accepts: (String) -> Bool
    let onChange: (String) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder ?? "", text: $text)
                .litheSettingsTextField()
                .frame(minWidth: isFlexible ? 0 : width, idealWidth: width, maxWidth: width)
                .focused($isFocused)
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .onSubmit(commit)
                .onChange(of: text) { _ in
                    if savesWhileTyping, isFocused, accepts(text), text != value { onChange(text) }
                }
                .onChange(of: isFocused) { focused in
                    guard !focused else { return }
                    if savesWhileTyping { text = value } else { commit() }
                }
            if !accepts(text) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LitheTheme.warning)
                    .help(Text(LocalizedStringKey("This value is not allowed.")))
            }
        }
        .onAppear { text = value }
        .onChange(of: value) { _ in
            if !isFocused { text = value }
        }
    }

    private func commit() {
        if accepts(text) {
            if text != value { onChange(text) }
        } else {
            text = value
        }
    }
}

/// A whole-number field with its unit. A value outside the allowed range is
/// never stored; the field says so and keeps the last stored value.
private struct PluginIntegerSettingField: View {
    let value: ToolingJSONValue
    let range: ClosedRange<Int>
    let unit: String?
    let accessibilityLabel: String
    let savesWhileTyping: Bool
    let onChange: (ToolingJSONValue) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var storedNumber: Int? {
        if case .integer(let number) = value { number } else { nil }
    }

    private var isAcceptable: Bool {
        Int(text.trimmingCharacters(in: .whitespaces)).map(range.contains) ?? false
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .litheSettingsTextField()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 90)
                .focused($isFocused)
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .onSubmit(commit)
                .onChange(of: text) { _ in commitWhileTyping() }
                .onChange(of: isFocused) { focused in
                    // Leaving the field with a value that was never accepted
                    // shows the stored one again.
                    guard !focused else { return }
                    if savesWhileTyping { text = storedNumber.map(String.init) ?? text } else { commit() }
                }
            if let unit {
                Text(verbatim: unit)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            if !isAcceptable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LitheTheme.warning)
                    .help(Text(verbatim: String(format: NSLocalizedString(
                        "Enter a whole number from %d to %d.",
                        comment: "Plugin integer setting range hint"
                    ), range.lowerBound, range.upperBound)))
            }
        }
        .onAppear { text = storedNumber.map(String.init) ?? "" }
        // A reset or another change of the stored value refreshes the field
        // unless the user is typing in it.
        .onChange(of: value) { _ in
            if !isFocused { text = storedNumber.map(String.init) ?? text }
        }
    }

    private func commitWhileTyping() {
        guard savesWhileTyping, isFocused, isAcceptable, let number = Int(text.trimmingCharacters(in: .whitespaces)),
              number != storedNumber else { return }
        onChange(.integer(number))
    }

    private func commit() {
        if isAcceptable, let number = Int(text.trimmingCharacters(in: .whitespaces)) {
            if number != storedNumber { onChange(.integer(number)) }
        } else {
            text = storedNumber.map(String.init) ?? text
        }
    }
}

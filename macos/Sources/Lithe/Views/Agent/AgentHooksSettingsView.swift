import SwiftUI
import LitheCoreContracts

struct AgentHooksSettingsView: View {
    @Environment(\.locale) private var locale
    var localizationBundle: Bundle = .main
    @ObservedObject var feature: AgentHooksFeatureModel
    @State private var operation: Task<Void, Never>?
    @State private var removal: AgentHookEntry?
    @State private var showsEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(key("Hooks")).font(LitheTheme.uiFont(size: 16, weight: .semibold))
                LitheInfoTip(key("Hooks run shell commands at Agent lifecycle events. The Agent supplies event JSON on standard input and runs the command in the session folder. Changes apply to new sessions; existing sessions keep their own loaded configuration."))
                Spacer()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LitheTheme.ActionButton.spacing) { search; toolbar }
                VStack(alignment: .leading, spacing: LitheTheme.ActionButton.spacing) {
                    search
                    HStack(spacing: LitheTheme.ActionButton.spacing) { toolbar }
                }
            }.disabled(feature.isBusy)
            if feature.isBusy { ProgressView().controlSize(.small) }
            if case .failed(let message) = feature.phase { AgentSettingsIssue(localized(String.LocalizationValue(message))) }
            if let library = feature.library {
                ForEach(library.targets, id: \.agentId) { target in
                    if let issue = target.issue {
                        HStack(alignment: .top) {
                            Text(verbatim: agentTitle(target.agentId)).font(LitheTheme.settingsFont)
                            AgentSettingsIssue(localized(String.LocalizationValue(issue)))
                        }
                    }
                    if target.disabled {
                        Text(key("Claude Code has disabled all Hooks in its settings."))
                            .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.warning)
                    }
                }
                if library.hooks.contains(where: \.needsSync) || library.hooks.contains(where: { $0.hook.pendingRemoval }) {
                    Button(key("Retry Hook synchronization")) { run { await feature.sync() } }
                        .buttonStyle(LitheActionButtonStyle()).disabled(feature.isBusy)
                }
                if feature.entries.isEmpty {
                    VStack(spacing: 10) {
                        Text(feature.query.isEmpty ? key("No Hooks yet.") : key("No matching Hooks."))
                            .foregroundStyle(LitheTheme.secondaryText)
                        if feature.query.isEmpty {
                            Button(key("Add Hook")) { feature.draft = AgentHook(); showsEditor = true }
                                .buttonStyle(LitheActionButtonStyle()).disabled(feature.isBusy)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 35)
                }
                ForEach(feature.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(verbatim: entry.hook.name).font(LitheTheme.uiFont(size: 13, weight: .semibold))
                            if !entry.hook.description.isEmpty { LitheInfoTip(LocalizedStringKey(entry.hook.description)) }
                            Spacer()
                            if entry.hook.pendingRemoval { Text(key("Removal pending")).foregroundStyle(LitheTheme.warning) }
                            else if entry.needsSync { Text(key("Sync needed")).foregroundStyle(LitheTheme.warning) }
                            Toggle(key("Enable Hook"), isOn: Binding(get: { entry.hook.enabled }, set: { enabled in
                                run { await feature.setEnabled(enabled, entry: entry) }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .disabled(feature.isBusy || entry.hook.pendingRemoval)
                                .accessibilityLabel(Text(verbatim: entry.hook.name + ": " + localized("Enable Hook")))
                            Button(key("Edit")) { feature.draft = entry.hook; showsEditor = true }
                                .buttonStyle(LitheActionButtonStyle()).disabled(feature.isBusy || entry.hook.pendingRemoval)
                            Button(key("Delete")) { removal = entry }.buttonStyle(LitheActionButtonStyle()).disabled(feature.isBusy)
                        }
                        HStack(spacing: 10) {
                            Text(key(String.LocalizationValue(entry.hook.event.title)))
                            if entry.hook.event.supportsMatcher { Text(key(String.LocalizationValue(entry.hook.matcher.title))) }
                            Text(verbatim: entry.hook.agents.map(agentTitle).joined(separator: " · "))
                        }.font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                        Text(verbatim: entry.hook.command).font(LitheTheme.codeFont).lineLimit(3).textSelection(.enabled)
                    }.padding(12).background(LitheTheme.settingsSurface)
                }
                HStack {
                    Text(key("Codex Hook approval"))
                    LitheInfoTip(key("Codex requires Hooks to be enabled and commands to be trusted in its native /hooks screen. Lithe saves configuration without granting trust. Editing a command requires approval again. A configured Hook is not proof it ran."))
                }.font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            }
        }.font(LitheTheme.settingsFont).frame(maxWidth: 760, alignment: .leading)
            .task { await feature.load() }
            .onAppear { showsEditor = feature.draft != nil }
            .onDisappear { operation?.cancel() }
            .sheet(isPresented: $showsEditor) {
                AgentHookEditor(localizationBundle: localizationBundle, feature: feature, onSave: { run { await feature.save(); if feature.draft == nil { showsEditor = false } } })
            }
            .alert(localized("Delete Hook?"), isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
                Button(key("Cancel"), role: .cancel) { removal = nil }
                Button(key("Delete"), role: .destructive) {
                    if let entry = removal { run { await feature.remove(entry) } }
                    removal = nil
                }
            } message: { Text(key("This removes only the native entries written by Lithe. Other Hooks are kept.")) }
    }
    private var search: some View {
        LitheSearchTextField(LocalizedStringKey(localized("Search Hooks")), text: $feature.query).litheSearchField()
    }
    @ViewBuilder private var toolbar: some View {
        Button(key("Reload from disk")) { run { await feature.load() } }.buttonStyle(LitheActionButtonStyle())
        Button(key("Add Hook")) { feature.draft = AgentHook(); showsEditor = true }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true)).disabled(feature.library == nil)
    }
    private func localized(_ value: String.LocalizationValue) -> String {
        AgentLocalization.string(value, locale: locale, bundle: localizationBundle)
    }
    private func key(_ value: String.LocalizationValue) -> LocalizedStringKey { LocalizedStringKey(localized(value)) }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard !feature.isBusy, operation == nil else { return }
        operation = Task {
            defer { operation = nil }
            await action()
        }
    }
    private func agentTitle(_ id: String) -> String { id == "codex-acp" ? "Codex" : "Claude Code" }
}

private struct AgentHookEditor: View {
    @Environment(\.locale) private var locale
    var localizationBundle: Bundle = .main
    @ObservedObject var feature: AgentHooksFeatureModel
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var timeout = ""

    private func field<Value>(_ keyPath: WritableKeyPath<AgentHook, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { feature.draft?[keyPath: keyPath] ?? fallback }, set: { feature.draft?[keyPath: keyPath] = $0 })
    }
    private func localized(_ value: String.LocalizationValue) -> String {
        AgentLocalization.string(value, locale: locale, bundle: localizationBundle)
    }
    private func key(_ value: String.LocalizationValue) -> LocalizedStringKey { LocalizedStringKey(localized(value)) }
    private var timeoutValid: Bool { timeout.isEmpty || (Int(timeout).map { (1...86400).contains($0) } ?? false) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(key("Hook")).font(LitheTheme.uiFont(size: 16, weight: .semibold))
            LitheSettingsRow(key("Name"), info: key("Use 1–80 letters, digits, hyphens or underscores. Names must be unique.")) {
                TextField("notify", text: field(\.name, fallback: "")).litheSettingsTextField()
            }
            LitheSettingsRow(key("Description"), info: key("Optional description, up to 200 characters. Only the Hook library stores it.")) {
                TextField(localized("Hook description"), text: field(\.description, fallback: "")).litheSettingsTextField()
            }
            LitheSettingsRow(key("When to run")) {
                LitheSettingsSelect(selection: field(\.event, fallback: .turnEnd), options: AgentHookEvent.allCases,
                    width: 240, accessibilityLabel: "When to run", title: { localized(String.LocalizationValue($0.title)) }, localizesTitles: false)
            }
            if feature.draft?.event.supportsMatcher == true {
                LitheSettingsRow(key("Tool filter")) {
                    LitheSettingsSelect(selection: field(\.matcher, fallback: .all), options: AgentHookMatcher.allCases,
                        width: 240, accessibilityLabel: "Tool filter", title: { localized(String.LocalizationValue($0.title)) }, localizesTitles: false)
                }
            }
            LitheSettingsLabel(key("Command"), info: key("The Agent executes this command using its own shell and passes event JSON on standard input. Commands run with your user permissions; add only commands you trust."))
            TextEditor(text: field(\.command, fallback: "")).font(LitheTheme.codeFont)
                .litheSettingsTextEditor(height: 120).accessibilityLabel(Text(key("Hook command")))
            LitheSettingsRow(key("Timeout (seconds)"), info: key("Leave empty to use the Agent default, or enter an integer from 1 to 86400.")) {
                TextField(localized("Agent default"), text: $timeout).litheSettingsTextField()
                    .onChange(of: timeout) { value in feature.draft?.timeoutSeconds = value.isEmpty ? nil : Int(value) }
            }
            LitheSettingsRow(key("Agents")) {
                HStack(spacing: 16) {
                    ForEach(AgentInstructionKind.allCases) { agent in
                        Toggle(agent.title, isOn: Binding(get: { feature.draft?.agents.contains(agent.rawValue) ?? false }, set: { value in
                            feature.draft?.agents.removeAll { $0 == agent.rawValue }
                            if value { feature.draft?.agents.append(agent.rawValue) }
                        })).toggleStyle(.checkbox)
                    }
                }
            }
            if case .failed(let message) = feature.phase { AgentSettingsIssue(localized(String.LocalizationValue(message))) }
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                if feature.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(key("Cancel")) { feature.draft = nil; dismiss() }.buttonStyle(LitheActionButtonStyle()).keyboardShortcut(.cancelAction)
                Button(key("Save Hook"), action: onSave).buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .disabled(!feature.canSave || !timeoutValid).keyboardShortcut(.defaultAction)
            }
        }.font(LitheTheme.settingsFont).padding(20).frame(width: 620).background(LitheTheme.settingsSurface)
            .disabled(feature.isBusy)
            .onAppear { timeout = feature.draft?.timeoutSeconds.map(String.init) ?? "" }
            .onChange(of: feature.draft?.event) { event in if event?.supportsMatcher != true { feature.draft?.matcher = .all } }
            .interactiveDismissDisabled(feature.isBusy)
    }
}

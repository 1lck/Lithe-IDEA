import SwiftUI
import LitheCoreContracts

/// A compact shared library followed by native Agent rows. Only explicit actions write.
struct AgentInstructionsSettingsView: View {
    @Environment(\.locale) private var locale
    var localizationBundle: Bundle = .main
    @ObservedObject var feature: AgentInstructionsFeatureModel
    @State private var operations: [UUID: Task<Void, Never>] = [:]
    @FocusState private var sharedEditorFocused: Bool
    @FocusState private var nativeEditorFocused: Bool
    @State private var expandsShared = false
    @State private var confirmsReload = false
    @State private var reloadsShared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                Text(key("Instructions")).font(LitheTheme.uiFont(size: 16, weight: .semibold))
                LitheInfoTip(key("Write shared instructions once, then enable them for each Agent. Lithe only changes its marked block; the rest of each native file stays yours. Start a new conversation to load changes. Project instructions still apply."))
                Spacer(minLength: 0)
                Button(localized("Refresh")) {
                    run { await feature.loadShared(); await feature.loadAll() }
                }.buttonStyle(LitheActionButtonStyle())
                    .disabled(feature.isSharedBusy || feature.phases.values.contains(.saving))
            }
            sharedCard
            LitheSettingsSection(title: localized("Instruction Agents"), accessory: {
                LitheInfoTip(key("The switch controls the Lithe shared block, not the Agent or its own instructions. Save shared changes before switching. Open a row to edit the complete native file."))
            }) {
                ForEach(AgentInstructionKind.allCases) { agent in
                    agentRow(agent)
                    if feature.isEditorExpanded && feature.selectedAgent == agent { nativeEditor }
                }
            }
        }
        .font(LitheTheme.settingsFont)
        .frame(maxWidth: 860, alignment: .leading)
        .task {
            await feature.loadShared()
            await feature.loadAll()
        }
        .onDisappear { operations.values.forEach { $0.cancel() }; operations.removeAll() }
        .alert(localized("Discard draft and reload?"), isPresented: $confirmsReload) {
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Reload from disk"), role: .destructive) { reload(shared: reloadsShared) }
        } message: { Text(key("Reloading replaces this draft with the current file contents.")) }
    }

    private var sharedCard: some View {
        LitheSettingsCard {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(LitheTheme.secondaryText)
                Text(key("Shared instructions")).font(LitheTheme.uiFont(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("Markdown").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.tertiaryText)
            }.padding(.vertical, 8)
            Button { expandsShared.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.plaintext").foregroundStyle(LitheTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key("Default instructions")).font(LitheTheme.uiFont(size: 13, weight: .medium))
                        Text(verbatim: feature.sharedDraft.split(whereSeparator: \.isNewline).first.map(String.init) ?? localized("Empty"))
                            .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if feature.isSharedDirty { badge("Unsaved changes", color: LitheTheme.warning) }
                    Image(systemName: expandsShared ? "chevron.down" : "chevron.right")
                        .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.tertiaryText)
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("shared-instructions-expand")
            if expandsShared {
                VStack(alignment: .leading, spacing: 10) {
                    LitheTextEditor(text: Binding(get: { feature.sharedDraft }, set: feature.editShared), height: 230, focus: $sharedEditorFocused)
                        .autocorrectionDisabled()
                        .disabled(feature.sharedLibrary == nil || feature.isSharedBusy)
                        .accessibilityLabel(Text(key("Shared instructions")))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: LitheTheme.ActionButton.spacing) { sharedActions }
                        VStack(alignment: .leading, spacing: LitheTheme.ActionButton.spacing) { sharedActions }
                    }
                }.padding(.vertical, 8)
            }
            if case .failed(let message) = feature.sharedPhase {
                HStack {
                    Text(key(String.LocalizationValue(message))).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error)
                    Spacer(minLength: 0)
                    Button(localized("Reload from disk")) { requestReload(shared: true) }
                        .buttonStyle(LitheActionButtonStyle()).disabled(feature.isSharedBusy)
                }
            }
        }
    }

    @ViewBuilder private var sharedActions: some View {
        Button(localized("Save shared instructions")) { run { await feature.saveShared() } }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .disabled(!feature.canSaveShared).opacity(feature.canSaveShared ? 1 : 0.5)
            .keyboardShortcut(sharedEditorFocused ? KeyboardShortcut("s", modifiers: .command) : nil)
        Button(localized("Reload from disk")) { requestReload(shared: true) }
            .buttonStyle(LitheActionButtonStyle()).disabled(feature.isSharedBusy)
        if feature.isSharedBusy { ProgressView().controlSize(.small) }
        else if feature.sharedSaved { Text(key("Shared instructions saved.")).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText) }
        if feature.sharedDraft.utf8.count > 1024 * 1024 {
            Text(key("Global instructions must be no larger than 1 MiB.")).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error)
        }
    }

    private func agentRow(_ agent: AgentInstructionKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { feature.toggleEditor(agent) } label: {
                    HStack(spacing: 12) {
                        AgentBrandIcon(name: agent.title, size: 24, style: .brand)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: agent.title).font(LitheTheme.uiFont(size: 13, weight: .medium))
                            if let file = feature.files[agent] {
                                Text(verbatim: file.path).font(LitheTheme.uiFont(size: 11, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText).lineLimit(1).truncationMode(.middle).help(file.path)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("instruction-agent-\(agent.rawValue)")
                if let state = feature.sharedState(agent) {
                    if state.needsSync { badge("Sync needed", color: LitheTheme.warning) }
                    else if state.ownLineCount > 0 {
                        Text(verbatim: String(format: localized("%d lines of its own"), state.ownLineCount))
                            .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                    }
                    if let enabled = state.enabled {
                        Toggle(localized("Use shared instructions"), isOn: Binding(get: { enabled }, set: { value in
                            run { await feature.setSharedEnabled(value, agent: agent) }
                        }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .accessibilityLabel(Text(verbatim: agent.title + ": " + localized("Use shared instructions")))
                        .disabled(!feature.canToggleShared(agent))
                    }
                }
                Button { feature.toggleEditor(agent) } label: {
                    Image(systemName: feature.isEditorExpanded && feature.selectedAgent == agent ? "chevron.down" : "chevron.right")
                        .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.tertiaryText)
                }.buttonStyle(.plain).accessibilityLabel(Text(verbatim: agent.title))
            }.padding(.vertical, 9)
            if let issue = feature.sharedSyncErrors[agent] ?? feature.sharedState(agent)?.issue {
                Text(key(String.LocalizationValue(issue))).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error)
            }
            if feature.sharedState(agent)?.needsSync == true {
                Button(localized("Sync again")) { run { await feature.setSharedEnabled(true, agent: agent) } }
                    .buttonStyle(LitheActionButtonStyle()).disabled(!feature.canToggleShared(agent))
            }
            if feature.files[agent] == nil, case .failed(let message) = feature.phases[agent] {
                Text(key(String.LocalizationValue(message))).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error)
            }
        }
    }

    private var nativeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(key("Native instruction file")).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                LitheInfoTip(key("This editor shows the complete native file, including any Lithe shared block. Editing shared text here can leave it out of sync; use the shared editor to update all enabled Agents."))
                Spacer(minLength: 0)
            }
            if let file = feature.file {
                if file.path.hasSuffix("AGENTS.override.md") {
                    Text(key("Codex is using AGENTS.override.md. Clearing it restores the base AGENTS.md instructions."))
                        .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.warning).fixedSize(horizontal: false, vertical: true)
                }
                if !file.exists {
                    Text(key("The file will be created when you save.")).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                }
                LitheTextEditor(text: Binding(get: { feature.draft }, set: feature.edit), height: 280, focus: $nativeEditorFocused)
                    .autocorrectionDisabled().disabled(feature.isBusy || feature.isSharedBusy)
                    .accessibilityLabel(Text(key("Global instructions")))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LitheTheme.ActionButton.spacing) { nativeActions }
                VStack(alignment: .leading, spacing: LitheTheme.ActionButton.spacing) { nativeActions }
            }
            if case .failed(let message) = feature.phase {
                Text(key(String.LocalizationValue(message))).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error).textSelection(.enabled)
            }
            if feature.draft.utf8.count > 1024 * 1024 {
                Text(key("Global instructions must be no larger than 1 MiB.")).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error)
            }
        }.padding(.vertical, 8)
    }

    @ViewBuilder private var nativeActions: some View {
        Button(localized("Save instructions")) { run { await feature.save() } }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .disabled(!feature.canSave).opacity(feature.canSave ? 1 : 0.5)
            .keyboardShortcut(nativeEditorFocused ? KeyboardShortcut("s", modifiers: .command) : nil)
        Button(localized("Reload from disk")) { requestReload(shared: false) }
            .buttonStyle(LitheActionButtonStyle()).disabled(feature.isBusy || feature.isSharedBusy)
        if feature.isBusy { ProgressView().controlSize(.small) }
        else if feature.isDirty { Text(key("Unsaved changes")).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.warning) }
        else if feature.saved.contains(feature.selectedAgent) { Text(key("Instructions saved.")).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText) }
    }

    private func badge(_ value: String.LocalizationValue, color: Color) -> some View {
        Text(key(value)).font(LitheTheme.smallFont).foregroundStyle(color)
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        let id = UUID()
        operations[id] = Task {
            await action()
            operations.removeValue(forKey: id)
        }
    }
    private func requestReload(shared: Bool) {
        reloadsShared = shared
        if shared ? feature.isSharedDirty : feature.isDirty { confirmsReload = true }
        else { reload(shared: shared) }
    }
    private func reload(shared: Bool) {
        run {
            if shared { await feature.loadShared(reload: true) }
            else { await feature.load(reload: true) }
        }
    }
    private func localized(_ value: String.LocalizationValue) -> String {
        AgentLocalization.string(value, locale: locale, bundle: localizationBundle)
    }
    private func key(_ value: String.LocalizationValue) -> LocalizedStringKey { LocalizedStringKey(localized(value)) }
}

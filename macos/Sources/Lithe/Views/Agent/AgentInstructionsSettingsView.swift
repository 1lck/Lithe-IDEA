import SwiftUI
import LitheCoreContracts

struct AgentInstructionsSettingsView: View {
    @Environment(\.locale) private var locale
    var localizationBundle: Bundle = .main
    @ObservedObject var feature: AgentInstructionsFeatureModel
    @State private var operation: Task<Void, Never>?
    @State private var confirmsReload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(key("Instructions")).font(LitheTheme.uiFont(size: 16, weight: .semibold))
            LitheSettingsSection(localized("Global instructions")) {
                HStack {
                    LitheSettingsLabel(key("Agent"), info: key("Global instructions apply to all projects using this Agent. Each Agent keeps its own native file."))
                    LitheSettingsSelect(selection: $feature.selectedAgent,
                                        options: AgentInstructionKind.allCases, width: 220,
                                        accessibilityLabel: localized("Instruction Agent"), title: { $0.title }, localizesTitles: false)
                        .disabled(feature.isBusy)
                }
                if let file = feature.file {
                    Text(verbatim: file.path)
                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                    if file.path.hasSuffix("AGENTS.override.md") {
                        Text(key("Codex is using AGENTS.override.md. Clearing it restores the base AGENTS.md instructions."))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !file.exists {
                        Text(key("The file will be created when you save."))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    TextEditor(text: Binding(get: { feature.draft }, set: { feature.edit($0) }))
                        .autocorrectionDisabled()
                        .litheSettingsTextEditor(height: 320)
                        .disabled(feature.isBusy)
                        .accessibilityLabel(Text(key("Global instructions")))
                }
                HStack(spacing: 8) {
                    Button(localized("Save instructions")) {
                        operation = Task { await feature.save() }
                    }
                    .buttonStyle(LithePrimaryButtonStyle(backgroundColor: LitheTheme.settingsPrimaryAction, restingOpacity: 1))
                    .disabled(!feature.canSave)
                    .opacity(feature.canSave ? 1 : 0.5)
                    Button(localized("Reload from disk")) {
                        if feature.isDirty { confirmsReload = true }
                        else { reload() }
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                    .disabled(feature.isBusy)
                    if feature.isBusy {
                        ProgressView().controlSize(.small)
                    } else if feature.saved.contains(feature.selectedAgent) {
                        Text(key("Instructions saved.")).foregroundStyle(LitheTheme.secondaryText)
                    } else if feature.isDirty {
                        Text(key("Unsaved changes")).foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                if case .failed(let message) = feature.phase {
                    Text(key(String.LocalizationValue(message))).foregroundStyle(LitheTheme.error)
                        .textSelection(.enabled)
                }
                if feature.draft.utf8.count > 1024 * 1024 {
                    Text(key("Global instructions must be no larger than 1 MiB.")).foregroundStyle(LitheTheme.error)
                }
                Text(key("Start a new conversation after saving to load the updated instructions. Project instructions still apply."))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task(id: feature.selectedAgent) { await feature.load() }
        .onDisappear { operation?.cancel(); operation = nil }
        .alert(localized("Discard draft and reload?"), isPresented: $confirmsReload) {
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Reload from disk"), role: .destructive) { reload() }
        } message: {
            Text(key("Reloading replaces this draft with the current file contents."))
        }
    }

    private func localized(_ value: String.LocalizationValue) -> String {
        AgentLocalization.string(value, locale: locale, bundle: localizationBundle)
    }

    private func key(_ value: String.LocalizationValue) -> LocalizedStringKey {
        LocalizedStringKey(localized(value))
    }

    private func reload() {
        operation = Task { await feature.load(reload: true) }
    }
}

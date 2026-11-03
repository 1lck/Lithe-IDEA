import LitheCoreContracts
import LitheModuleAPI
import SwiftUI

/// The feature owns drafts and saves. This view supplies an exact scope and
/// shows saved inputs separately from the page's probed installation facts.
struct ToolchainPreferenceEditorView: View {
    @ObservedObject var editor: ToolchainPreferencesFeatureModel
    let workspace: URL
    let tool: ToolchainSettingsSnapshot.Tool
    @State private var action: Task<Void, Never>?

    private var isOpen: Bool {
        editor.workspace == workspace && editor.address?.tool == tool.id && editor.address?.directory == tool.directoryID
    }
    private var modes: [ToolchainPreferencesFeatureModel.Mode] {
        var result: [ToolchainPreferencesFeatureModel.Mode] = [.inherited]
        if tool.directoryID != "." || editor.address?.consumer != nil { result.append(.workspace) }
        if tool.directoryID != ".", editor.address?.consumer != nil { result.append(.consumer) }
        return result + [.installation, .executable]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: LitheInfoTip.labelSpacing) {
                Text("Build tool defaults").font(LitheTheme.uiFont(size: 12, weight: .semibold))
                LitheInfoTip("These machine-local choices apply to Build providers and their Run configurations on the next operation. Saving does not probe or execute a tool. Inherited choices follow later default changes.")
                Spacer(minLength: 0)
                if !isOpen {
                    Button("Edit defaults") { open(consumer: nil) }.buttonStyle(LitheActionButtonStyle())
                        .accessibilityIdentifier("toolchain-preference-open:" + tool.id)
                }
            }
            if isOpen {
                ToolchainSettingsLine("Consumer") {
                    LitheSettingsSelect(selection: Binding(get: { editor.address?.consumer ?? "" }, set: { open(consumer: $0.isEmpty ? nil : $0) }),
                        options: [""] + tool.consumers.map(\.id), width: 240, accessibilityLabel: "Consumer",
                        title: { id in id.isEmpty ? L10n.string("All Build consumers") : tool.consumers.first { $0.id == id }.map { $0.title + " · " + $0.pluginName } ?? id })
                        .disabled(editor.isLoading || editor.isSaving)
                }
                if let draft = editor.draft {
                    ToolchainSettingsLine("Saved input", info: "A saved input is revalidated by the existing toolchain resolver when the consumer runs. It is not a verified current installation.") {
                        LitheSettingsSelect(selection: Binding(get: { editor.draft?.mode ?? .inherited }, set: { editor.edit(mode: $0) }),
                            options: modes, width: 240, accessibilityLabel: "Saved input", title: Self.title)
                            .disabled(editor.isLoading || editor.isSaving)
                    }
                    if draft.mode == .installation || draft.mode == .executable {
                        LitheTextField("Path", text: Binding(get: { editor.draft?.path ?? "" }, set: { editor.edit(path: $0) }))
                            .disabled(editor.isLoading || editor.isSaving)
                            .accessibilityIdentifier("toolchain-preference-path:" + tool.id)
                    }
                    ToolchainSettingsLine("Next Build input") {
                        Text(verbatim: effectiveInput).font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                            .lineLimit(2).textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Button("Save") { perform { await editor.save() } }
                            .disabled(!draft.isChanged || editor.isLoading || editor.isSaving)
                            .accessibilityIdentifier("toolchain-preference-save:" + tool.id)
                        Button("Cancel") { perform { await editor.cancel() } }
                            .disabled(editor.isLoading || editor.isSaving)
                            .accessibilityIdentifier("toolchain-preference-cancel:" + tool.id)
                        Button("Reset") { perform { await editor.save(reset: true) } }
                            .disabled(editor.isLoading || editor.isSaving || (editor.reading?.stored == nil && !draft.isChanged))
                            .accessibilityIdentifier("toolchain-preference-reset:" + tool.id)
                        if editor.isSaving { ProgressView().controlSize(.mini) }
                    }
                    .buttonStyle(LitheActionButtonStyle())
                } else if editor.isLoading { ProgressView().controlSize(.mini) }
                if let error = editor.error {
                    Text(verbatim: error.localizedDescription).font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(LitheTheme.error).textSelection(.enabled)
                    if editor.draft == nil {
                        Button("Refresh") { open(consumer: editor.address?.consumer) }
                            .buttonStyle(LitheActionButtonStyle())
                            .disabled(editor.isLoading || editor.isSaving)
                    }
                }
            }
        }
        .onDisappear {
            action?.cancel(); action = nil
            if isOpen, let address = editor.address { editor.hide(address) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolchain-preference-editor:" + tool.id)
    }

    private var effectiveInput: String {
        switch editor.reading?.fixed {
        case .installation(let home): home
        case .executable(let path): path
        case nil: L10n.string("Automatic selection")
        }
    }
    private static func title(_ mode: ToolchainPreferencesFeatureModel.Mode) -> String {
        switch mode {
        case .inherited: L10n.string("Use inherited choice")
        case .workspace: L10n.string("Use workspace default")
        case .consumer: L10n.string("Use consumer default")
        case .installation: L10n.string("Installation directory")
        case .executable: L10n.string("Executable file")
        }
    }
    private func open(consumer: String?) {
        let address = ToolchainPreferenceAddress(directory: tool.directoryID, consumer: consumer, tool: tool.id)
        perform { await editor.open(workspace: workspace, address: address) }
    }
    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        action?.cancel()
        action = Task { await operation() }
    }
}

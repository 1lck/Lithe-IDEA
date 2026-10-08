import SwiftUI
import LitheGitModule

struct GitPatchPresentation: ViewModifier {
    @Environment(\.locale) private var locale
    @ObservedObject var editor: GitPatchFeatureModel
    let surface: GitPatchFeatureModel.Surface

    func body(content: Content) -> some View {
        content.background(LitheCenteredPopup(isPresented: Binding(
            get: { editor.mode != nil && editor.surface == surface },
            set: { if !$0 && editor.surface == surface { editor.dismiss() } }
        ), allowsDismiss: !editor.isBusy,
           dialogTitle: String(localized: editor.mode == .export ? "Create Patch" : "Apply Patch", locale: locale)) {
            GitPatchDialog(editor: editor)
        }.frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

struct GitPatchToolbar: View {
    let feature: GitFeatureModel

    var body: some View {
        HStack(spacing: 2) {
            Button {
                guard let root = feature.gitRepositoryRoot else { return }
                feature.patchExchange.beginExport(at: root)
            } label: { Image(systemName: "doc.badge.arrow.up") }
                .litheToolbarIconButton(isEnabled: feature.gitRepositoryRoot != nil).help("Create Patch…")
                .accessibilityLabel("Create Patch")

        }
        .font(LitheTheme.uiFont(size: LitheTheme.Metrics.toolbarIconSize))
        .foregroundStyle(LitheTheme.secondaryText)
    }
}

private struct GitPatchDialog: View {
    @ObservedObject var editor: GitPatchFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if editor.mode == .export { exportControls } else { importControls }
            if !editor.files.isEmpty { fileList }
            if !editor.patchText.isEmpty { rawPreview }
            if let check = editor.applyPreview {
                Label(LocalizedStringKey(check.applicable ? "Patch can be applied to the selected destination." : "Patch cannot be applied."),
                      systemImage: check.applicable ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(check.applicable ? LitheTheme.accent : LitheTheme.warning)
                if !check.diagnostic.isEmpty {
                    Text(LocalizedStringKey(check.diagnostic)).font(LitheTheme.uiFont(size: 11)).textSelection(.enabled)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            if let message = editor.errorMessage {
                Text(LocalizedStringKey(message)).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.error).textSelection(.enabled)
            }
            if let notice = editor.notice {
                Text(LocalizedStringKey(notice)).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.accent).textSelection(.enabled)
            }
            footer
        }
        .font(LitheTheme.uiFont(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 700)
        .foregroundStyle(LitheTheme.primaryText)
        .buttonStyle(LitheCommitDialogButtonStyle())
        .background(LitheCommitDialogStyle.background)
        .environment(\.lithePointingHandCursorEnabled, false)
        .onExitCommand { if !editor.isBusy { editor.dismiss() } }
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if editor.source == .commits {
                HStack(spacing: 10) {
                    Text("Base \(editor.baseRevision.prefix(12)) → Target \(editor.targetRevision.prefix(12))")
                        .font(LitheTheme.uiFont(size: 12, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Swap Direction") { editor.swapRevisions() }.disabled(editor.isBusy)
                }
                Text("The patch changes the base commit's tree into the target commit's tree.")
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            } else {
                LabeledContent("Include") {
                    LitheSettingsSelect(selection: Binding(get: { editor.source }, set: { editor.setSource($0) }), options: [GitPatchSource.workingTree, .staged, .unstaged], width: 260, accessibilityLabel: "Include", title: { $0 == .workingTree ? "All uncommitted changes" : $0 == .staged ? "Staged changes" : "Unstaged changes" })
                }
                .disabled(editor.isBusy)
                Text(LocalizedStringKey(editor.source == .workingTree
                     ? "Exports the working tree's net changes against HEAD, including selected untracked files."
                     : editor.source == .staged ? "Exports the index against HEAD." : "Exports working files against the index, including selected untracked files."))
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            }
        }
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button("Open Patch…") { editor.chooseImportFile() }.disabled(editor.isBusy)
                Button("Paste Patch") { editor.pasteImport() }.disabled(editor.isBusy)
                if !editor.importedName.isEmpty {
                    Text(editor.importedName).font(LitheTheme.uiFont(size: 11)).lineLimit(1)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
            }
            LabeledContent("Apply to") {
                LitheSettingsSelect(selection: Binding(get: { editor.target }, set: { editor.setTarget($0) }), options: [GitPatchTarget.worktree, .indexAndWorktree], width: 260, accessibilityLabel: "Apply to", title: { $0 == .worktree ? "Working tree" : "Index and working tree" })
            }
            .disabled(editor.isBusy)
            Text("Review the files and diff before applying. The repository is checked again when you confirm.")
                .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(editor.files.count) files").font(LitheTheme.uiFont(size: 11, weight: .medium))
                Spacer()
                if editor.mode == .export {
                    Button("Select All") { editor.selectAllPaths(true) }
                    Button("Clear") { editor.selectAllPaths(false) }
                }
            }
            .font(LitheTheme.uiFont(size: 11)).disabled(editor.isBusy)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(editor.files) { file in
                        HStack(spacing: 8) {
                            if editor.mode == .export {
                                Toggle(isOn: Binding(
                                    get: { editor.selectedPaths.contains(file.path) },
                                    set: { editor.selectPath(file.path, included: $0) }
                                )) { Text(fileLabel(file)) }
                                .toggleStyle(.checkbox).disabled(editor.isBusy)
                            } else { Text(fileLabel(file)) }
                            Spacer(minLength: 0)
                            if let additions = file.additions, let deletions = file.deletions {
                                Text("+\(additions) −\(deletions)").foregroundStyle(LitheTheme.secondaryText)
                            }
                        }
                        .font(LitheTheme.uiFont(size: 11)).lineLimit(2)
                    }
                }
                .padding(9)
            }
            // The panel measures its ideal height before lazy rows are laid out.
            // Reserve visible space so discovery never collapses the file picker.
            .frame(height: 135)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var rawPreview: some View {
        let text = editor.patchText
        let maximumPreviewCharacters = 65_536
        let displayed = String(text.prefix(maximumPreviewCharacters))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Patch preview").font(LitheTheme.uiFont(size: 11, weight: .medium))
                Spacer()
                Text("\(text.utf8.count) bytes").font(LitheTheme.uiFont(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(displayed).font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 185)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            if displayed.utf8.count < text.utf8.count {
                Text("Preview shows the first 65,536 characters. The complete patch is used when saving or applying.")
                    .font(LitheTheme.uiFont(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if editor.mode == .export {
                Button("Refresh Files") { editor.refreshFiles() }
                    .disabled(editor.isBusy)
                Button("Generate Preview") { editor.generateExport() }
                    .disabled(!editor.canGenerateExport)
            } else {
                Button("Check Again") { editor.inspectImport() }
                    .disabled(editor.isBusy || editor.importedPatch.isEmpty)
            }
            if editor.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Close") { editor.dismiss() }.keyboardShortcut(.cancelAction)
                .disabled(editor.isBusy)
            if editor.mode == .export {
                Button("Save Patch…") { editor.saveExport() }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true)).disabled(!editor.canSave)
            } else {
                Button("Apply Patch") { Task { await editor.confirmApply() } }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true)).disabled(!editor.canApply)
            }
        }
    }

    private func fileLabel(_ file: GitPatchFile) -> String {
        if let original = file.originalPath { return "\(original) → \(file.path)" }
        return file.path
    }
}

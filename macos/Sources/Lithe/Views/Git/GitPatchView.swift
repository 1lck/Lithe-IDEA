import SwiftUI
import LitheGitModule

struct GitPatchPresentation: ViewModifier {
    @ObservedObject var editor: GitPatchFeatureModel
    let surface: GitPatchFeatureModel.Surface

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { editor.mode != nil && editor.surface == surface },
            set: { if !$0 && editor.surface == surface { editor.dismiss() } }
        )) {
            GitPatchDialog(editor: editor)
        }
    }
}

struct GitPatchToolbar: View {
    let feature: GitFeatureModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                guard let root = feature.gitRepositoryRoot else { return }
                feature.patchExchange.beginExport(at: root)
            } label: { Image(systemName: "doc.badge.arrow.up") }
                .buttonStyle(.plain).help("Create Patch…").lithePointer()
                .accessibilityLabel("Create Patch")
                .disabled(feature.gitRepositoryRoot == nil)
            Button {
                guard let root = feature.gitRepositoryRoot else { return }
                feature.patchExchange.beginImport(at: root, surface: .changes)
            } label: { Image(systemName: "doc.badge.arrow.down") }
                .buttonStyle(.plain).help("Apply Patch…").lithePointer()
                .accessibilityLabel("Apply Patch")
                .disabled(feature.gitRepositoryRoot == nil)
        }
        .font(.system(size: 13))
        .foregroundStyle(LitheTheme.secondaryText)
    }
}

private struct GitPatchDialog: View {
    @ObservedObject var editor: GitPatchFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(LocalizedStringKey(editor.mode == .export ? "Create Patch" : "Apply Patch"))
                .font(.system(size: 17, weight: .semibold))
            if editor.mode == .export { exportControls } else { importControls }
            if !editor.files.isEmpty { fileList }
            if !editor.patchText.isEmpty { rawPreview }
            if let check = editor.applyPreview {
                Label(LocalizedStringKey(check.applicable ? "Patch can be applied to the selected destination." : "Patch cannot be applied."),
                      systemImage: check.applicable ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(check.applicable ? LitheTheme.accent : LitheTheme.warning)
                if !check.diagnostic.isEmpty {
                    Text(LocalizedStringKey(check.diagnostic)).font(.system(size: 11)).textSelection(.enabled)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            if let message = editor.errorMessage {
                Text(LocalizedStringKey(message)).font(.system(size: 12)).foregroundStyle(LitheTheme.error).textSelection(.enabled)
            }
            if let notice = editor.notice {
                Text(LocalizedStringKey(notice)).font(.system(size: 12)).foregroundStyle(LitheTheme.accent).textSelection(.enabled)
            }
            footer
        }
        .padding(20)
        .frame(width: 700)
        .background(LitheTheme.raised)
        .interactiveDismissDisabled(editor.isBusy)
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if editor.source == .commits {
                HStack(spacing: 10) {
                    Text("Base \(editor.baseRevision.prefix(12)) → Target \(editor.targetRevision.prefix(12))")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Swap Direction") { editor.swapRevisions() }.disabled(editor.isBusy).lithePointer()
                }
                Text("The patch changes the base commit's tree into the target commit's tree.")
                    .font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            } else {
                Picker("Include", selection: Binding(get: { editor.source }, set: { editor.setSource($0) })) {
                    Text("All uncommitted changes").tag(GitPatchSource.workingTree)
                    Text("Staged changes").tag(GitPatchSource.staged)
                    Text("Unstaged changes").tag(GitPatchSource.unstaged)
                }
                .disabled(editor.isBusy)
                Text(LocalizedStringKey(editor.source == .workingTree
                     ? "Exports the working tree's net changes against HEAD, including selected untracked files."
                     : editor.source == .staged ? "Exports the index against HEAD." : "Exports working files against the index, including selected untracked files."))
                    .font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            }
        }
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button("Open Patch…") { editor.chooseImportFile() }.disabled(editor.isBusy).lithePointer()
                Button("Paste Patch") { editor.pasteImport() }.disabled(editor.isBusy).lithePointer()
                if !editor.importedName.isEmpty {
                    Text(editor.importedName).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
            }
            Picker("Apply to", selection: Binding(get: { editor.target }, set: { editor.setTarget($0) })) {
                Text("Working tree").tag(GitPatchTarget.worktree)
                Text("Index and working tree").tag(GitPatchTarget.indexAndWorktree)
            }
            .disabled(editor.isBusy)
            Text("Review the files and diff before applying. The repository is checked again when you confirm.")
                .font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(editor.files.count) files").font(.system(size: 11, weight: .medium))
                Spacer()
                if editor.mode == .export {
                    Button("Select All") { editor.selectAllPaths(true) }.lithePointer()
                    Button("Clear") { editor.selectAllPaths(false) }.lithePointer()
                }
            }
            .font(.system(size: 11)).disabled(editor.isBusy)
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
                        .font(.system(size: 11)).lineLimit(2)
                    }
                }
                .padding(9)
            }
            // A sheet measures its ideal height before lazy rows are laid out.
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
                Text("Patch preview").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(text.utf8.count) bytes").font(.system(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(displayed).font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 185)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            if displayed.utf8.count < text.utf8.count {
                Text("Preview shows the first 65,536 characters. The complete patch is used when saving or applying.")
                    .font(.system(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if editor.mode == .export {
                Button("Refresh Files") { editor.refreshFiles() }
                    .disabled(editor.isBusy).lithePointer()
                Button("Generate Preview") { editor.generateExport() }
                    .disabled(!editor.canGenerateExport).lithePointer()
            } else {
                Button("Check Again") { editor.inspectImport() }
                    .disabled(editor.isBusy || editor.importedPatch.isEmpty).lithePointer()
            }
            if editor.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Close") { editor.dismiss() }.keyboardShortcut(.cancelAction)
                .disabled(editor.isBusy).lithePointer()
            if editor.mode == .export {
                Button("Save Patch…") { editor.saveExport() }
                    .buttonStyle(.borderedProminent).disabled(!editor.canSave).lithePointer()
            } else {
                Button("Apply Patch") { Task { await editor.confirmApply() } }
                    .buttonStyle(.borderedProminent).disabled(!editor.canApply).lithePointer()
            }
        }
    }

    private func fileLabel(_ file: GitPatchFile) -> String {
        if let original = file.originalPath { return "\(original) → \(file.path)" }
        return file.path
    }
}

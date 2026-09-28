import SwiftUI
import LitheGitModule

struct GitIdentitySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var feature: GitFeatureModel?

    var body: some View {
        Group {
            if let feature {
                GitIdentitySettingsPane(feature: feature, editor: feature.identitySettings)
            } else {
                Text("Open a project to configure Git identity.").foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .task(id: model.workspaceURL) {
            feature = await model.activateGitModule()
        }
    }
}

private struct GitIdentitySettingsPane: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var editor: GitRepositorySetupFeatureModel
    @State private var scope = GitIdentityScope.local

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text("Commit identity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize()
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            Text("Git records this name and email in new commits. These settings do not change existing commits.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            LitheSettingsSegmentedControl(
                selection: $scope,
                options: GitIdentityScope.allCases,
                width: 360,
                title: { $0 == .local ? "Current repository" : "Global Git configuration" }
            )
            .disabled(editor.isBusy)
            Text(scope == .global
                 ? LocalizedStringKey("Global identity applies to other repositories unless they override it.")
                 : LocalizedStringKey("Repository identity overrides inherited global values. Clear an override to use inherited settings."))
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            if let root = feature.repositorySetupRoot {
                Text(root.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                if editor.state?.isRepository == false && scope == .local {
                    Text("Initialize this project from Git before saving repository-specific identity.")
                        .foregroundStyle(LitheTheme.warning).font(LitheTheme.smallFont)
                }
                identityField(.name, title: "Committer name", draft: $editor.name,
                              configured: editor.state?.configuredName, effective: editor.state?.effectiveName)
                identityField(.email, title: "Committer email", draft: $editor.email,
                              configured: editor.state?.configuredEmail, effective: editor.state?.effectiveEmail)
                Text("Save each field separately. Switching scope reloads the saved values.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                Button("Reload Git Configuration") { Task { await editor.load(at: root, scope: scope) } }
                    .disabled(editor.isBusy).lithePointer()
            } else {
                Text("Open a project to configure Git identity.").foregroundStyle(LitheTheme.secondaryText)
            }
            if editor.isBusy { ProgressView().controlSize(.small) }
            if let error = editor.errorMessage {
                Text(error).foregroundStyle(LitheTheme.error).font(LitheTheme.smallFont).textSelection(.enabled)
            }
        }
        .task(id: "\(feature.repositorySetupRoot?.path ?? "")|\(scope.rawValue)") {
            await editor.load(at: feature.repositorySetupRoot, scope: scope)
        }
    }

    private func identityField(_ field: GitIdentityField, title: LocalizedStringKey,
                               draft: Binding<String>, configured: String?, effective: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            HStack {
                TextField(title, text: draft).litheSettingsTextField()
                Button("Save") { save(field) }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.wrappedValue == configured)
                    .lithePointer()
                Button("Clear Override") { save(field, clear: true) }.disabled(configured == nil).lithePointer()
            }
            .disabled(editor.isBusy || editor.state == nil || (scope == .local && editor.state?.isRepository != true))
            if let effective, !effective.isEmpty {
                Text("Effective value: \(effective)").font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            } else {
                Text("No effective value configured").font(.system(size: 11)).foregroundStyle(LitheTheme.warning)
            }
            if editor.savedField == field {
                Text("Git configuration saved").font(.system(size: 11)).foregroundStyle(LitheTheme.accent)
            }
        }
    }

    private func save(_ field: GitIdentityField, clear: Bool = false) {
        Task {
            await feature.saveGitIdentity(field, clear: clear)
            if editor.errorMessage == nil { await feature.refreshGitHistory() }
        }
    }
}

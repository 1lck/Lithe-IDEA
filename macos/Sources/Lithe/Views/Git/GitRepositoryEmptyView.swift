import SwiftUI
import LitheGitModule

struct GitRepositoryEmptyView: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var setup: GitRepositorySetupFeatureModel
    let openSettings: () -> Void
    let openChanges: () -> Void
    @State private var confirmsInitialization = false

    var body: some View {
        VStack(spacing: 12) {
            LitheSystemIcon(systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 27, weight: .light))
            if setup.isBusy {
                ProgressView().controlSize(.small)
                Text("Checking Git repository…")
            } else if let state = setup.state {
                if !state.isRepository {
                    Text("This project is not a Git repository")
                    Text("Initialize Git to track changes and create your first commit.").font(LitheTheme.smallFont)
                    Button("Initialize Git Repository…") { confirmsInitialization = true }
                        .buttonStyle(.borderedProminent).lithePointer()
                } else if !state.hasCommits {
                    Text("This branch has no commits yet")
                    if let branch = state.branch { Text("Branch: \(branch)").font(LitheTheme.smallFont) }
                    Text("Stage your files in Changes, enter a commit message, and create the first commit.")
                        .font(LitheTheme.smallFont)
                    if state.needsIdentity {
                        Text("Set your Git name and email in Settings before committing.")
                            .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.warning)
                    }
                    Button("Open Changes") { openChanges() }.buttonStyle(.borderedProminent).lithePointer()
                } else {
                    Text("No commits match this view")
                }
                if !state.isRepository || !state.hasCommits {
                    Button("Open Git Settings") { openSettings() }.lithePointer()
                }
            } else if feature.repositorySetupRoot == nil {
                Text("Open a project to use Git")
            }
            if let error = setup.errorMessage {
                Text(LocalizedStringKey(error)).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error).textSelection(.enabled)
                Button("Retry") { Task { await setup.load(at: feature.repositorySetupRoot) } }.lithePointer()
            }
        }
        .font(LitheTheme.uiFont).foregroundStyle(LitheTheme.secondaryText)
        .multilineTextAlignment(.center).padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(feature.repositorySetupRoot?.path ?? "")|\(feature.gitCommitsVersion)") {
            await setup.load(at: feature.repositorySetupRoot)
        }
        .confirmationDialog("Initialize Git in this project folder?", isPresented: $confirmsInitialization, titleVisibility: .visible) {
            Button("Initialize Git Repository") {
                Task {
                    if await setup.initialize() { await feature.refreshGit() }
                }
            }
        } message: {
            Text("Files will stay unchanged. Nothing will be staged or committed automatically.")
        }
    }
}

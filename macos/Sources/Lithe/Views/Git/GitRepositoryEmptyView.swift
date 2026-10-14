import SwiftUI
import LitheGitModule

struct GitRepositoryEmptyView: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var setup: GitRepositorySetupFeatureModel
    let openSettings: () -> Void
    let openChanges: () -> Void
    var openConsole: (() -> Void)? = nil
    @State private var confirmsInitialization = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(feature.repositorySetupRoot?.path ?? "")|\(feature.gitCommitsVersion)") {
            await setup.load(at: feature.repositorySetupRoot)
        }
        .confirmationDialog("Initialize Git in this project folder?", isPresented: $confirmsInitialization, titleVisibility: .visible) {
            Button("Initialize Git Repository") {
                Task {
                    if await feature.initializeGitRepository() { await feature.refreshGit() }
                }
            }
        } message: {
            Text("Files will stay unchanged. Nothing will be staged or committed automatically.")
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            if setup.isBusy {
                ProgressView().controlSize(.small)
                Text("Checking Git repository…")
            } else if let state = setup.state {
                if !state.isRepository {
                    repositoryInstructions
                } else if !state.hasCommits {
                    Text("This branch has no commits yet")
                        .foregroundStyle(LitheTheme.primaryText)
                    if let branch = state.branch { Text("Branch: \(branch)").font(LitheTheme.smallFont) }
                    Text("Stage your files in Changes, enter a commit message, and create the first commit.")
                        .font(LitheTheme.smallFont)
                    Button("Open Changes") { openChanges() }
                } else {
                    Text("No commits match this view")
                }
                if let openConsole {
                    Button("Open Git Console", action: openConsole)
                }
            } else if feature.repositorySetupRoot == nil {
                Text("Open a project to use Git")
            }
            if let error = setup.errorMessage {
                Text(LocalizedStringKey(error)).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error).textSelection(.enabled)
                Button("Retry") { Task { await setup.load(at: feature.repositorySetupRoot) } }
            }
        }
        .font(LitheTheme.uiFont(size: LitheTheme.ToolWindowEmptyState.fontSize))
        .foregroundStyle(LitheTheme.ToolWindowEmptyState.text)
        .buttonStyle(LitheToolWindowEmptyLinkStyle())
        .tint(LitheTheme.ToolWindowEmptyState.link)
    }

    private var repositoryInstructions: some View {
        // Community VcsToolWindowEmptyState + StatusText: left-aligned lines, 2pt gaps.
        VStack(alignment: .leading, spacing: LitheTheme.ToolWindowEmptyState.lineSpacing) {
            Text("To track changes to code:")
                .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "—")
                Text("Share project on")
                Link("GitHub", destination: URL(string: "https://github.com")!)
                Text("or")
                Link("GitLab", destination: URL(string: "https://gitlab.com")!)
            }
            .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "—")
                Button("Initialize Git repository…") { confirmsInitialization = true }
            }
            .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "—")
                Button("Open Git Settings", action: openSettings)
            }
            .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
            Color.clear.frame(width: 0, height: LitheTheme.ToolWindowEmptyState.rowHeight).accessibilityHidden(true)
            Link(destination: URL(string: "https://git-scm.com/doc")!) {
                HStack(spacing: 2) {
                    LitheIDEAIcon(resourcePath: "general/contextHelp.svg", size: 16, preservesOriginalColors: true)
                        .accessibilityHidden(true)
                    Text("Version control integration")
                }
            }
            .foregroundStyle(LitheTheme.ToolWindowEmptyState.link)
            .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
        }
    }
}

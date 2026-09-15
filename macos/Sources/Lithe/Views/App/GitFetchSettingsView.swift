import SwiftUI
import LitheGitModule

struct GitFetchSettingsView: View {
    @Binding var options: GitFetchOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fetch defaults").font(.headline)
            Text("Used for ordinary Fetch in every project. One-time choices can override these defaults.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            GitFetchPolicyControls(options: $options)
            Text("Credentials use your existing Git helper and SSH configuration.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            Button("Reset Fetch defaults") { options = GitFetchOptions() }.lithePointer()
        }
    }
}

struct GitFetchPolicyControls: View {
    @Binding var options: GitFetchOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Prune stale remote-tracking references", isOn: $options.prune)
            Picker("Fetch submodules", selection: $options.submodules) {
                Text("Use Git configuration").tag(GitFetchSubmodules.inherit)
                Text("Do not fetch submodules").tag(GitFetchSubmodules.no)
                Text("Fetch submodules on demand").tag(GitFetchSubmodules.onDemand)
                Text("Fetch all submodules").tag(GitFetchSubmodules.yes)
            }
            Picker("Fetch tags", selection: $options.tags) {
                Text("Use Git configuration").tag(GitFetchTags.inherit)
                Text("Fetch all tags").tag(GitFetchTags.all)
                Text("Do not fetch tags").tag(GitFetchTags.none)
                Text("Synchronize tags and remove local tags missing from the remote").tag(GitFetchTags.prune)
            }
        }
        .onChange(of: options.tags) { tags in if tags == .prune { options.prune = true } }
        .onChange(of: options.prune) { prune in if !prune && options.tags == .prune { options.tags = .inherit } }
    }
}

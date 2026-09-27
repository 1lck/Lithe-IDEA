import SwiftUI
import LitheGitModule

struct GitFetchSettingsView: View {
    @Binding var options: GitFetchOptions
    var body: some View {
        GitSettingsCard {
            GitSettingsHeader(icon: "arrow.down.circle", title: "Fetch defaults", subtitle: "Set the defaults used by ordinary Fetch in every project.")
            GitFetchPolicyControls(options: $options, usesSettingsControls: true)
            Text("Credentials use your existing Git helper and SSH configuration.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            Button("Reset Fetch defaults") { options = GitFetchOptions() }.lithePointer()
        }
    }
}

struct GitFetchPolicyControls: View {
    @Binding var options: GitFetchOptions
    var usesSettingsControls = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GitSettingsRow("Prune") {
                Toggle("Prune stale remote-tracking references", isOn: $options.prune)
            }
            GitSettingsRow("Fetch submodules") {
                if usesSettingsControls {
                    LitheSettingsSelect(
                        selection: $options.submodules,
                        options: GitFetchSubmodules.allCases,
                        width: 260,
                        accessibilityLabel: "Fetch submodules",
                        title: { option in
                            switch option {
                            case .inherit: "Use Git configuration"
                            case .no: "Do not fetch submodules"
                            case .onDemand: "Fetch submodules on demand"
                            case .yes: "Fetch all submodules"
                            }
                        }
                    )
                } else {
                    Picker("Fetch submodules", selection: $options.submodules) {
                        Text("Use Git configuration").tag(GitFetchSubmodules.inherit)
                        Text("Do not fetch submodules").tag(GitFetchSubmodules.no)
                        Text("Fetch submodules on demand").tag(GitFetchSubmodules.onDemand)
                        Text("Fetch all submodules").tag(GitFetchSubmodules.yes)
                    }.labelsHidden()
                }
            }
            GitSettingsRow("Fetch tags") {
                if usesSettingsControls {
                    LitheSettingsSelect(
                        selection: $options.tags,
                        options: GitFetchTags.allCases,
                        width: 260,
                        accessibilityLabel: "Fetch tags",
                        title: { option in
                            switch option {
                            case .inherit: "Use Git configuration"
                            case .all: "Fetch all tags"
                            case .none: "Do not fetch tags"
                            case .prune: "Synchronize tags and remove local tags missing from the remote"
                            }
                        },
                        expandsToFitOptions: true
                    )
                } else {
                    Picker("Fetch tags", selection: $options.tags) {
                        Text("Use Git configuration").tag(GitFetchTags.inherit)
                        Text("Fetch all tags").tag(GitFetchTags.all)
                        Text("Do not fetch tags").tag(GitFetchTags.none)
                        Text("Synchronize tags and remove local tags missing from the remote").tag(GitFetchTags.prune)
                    }.labelsHidden()
                }
            }
        }
        .onChange(of: options.tags) { tags in if tags == .prune { options.prune = true } }
        .onChange(of: options.prune) { prune in if !prune && options.tags == .prune { options.tags = .inherit } }
    }
}

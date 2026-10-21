import SwiftUI
import LitheGitModule

struct GitFetchPolicyControls: View {
    @Binding var options: GitFetchOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GitSettingsRow("Prune") {
                Toggle("Prune stale remote-tracking references", isOn: $options.prune)
            }
            GitSettingsRow("Fetch submodules") {
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
            }
            GitSettingsRow("Fetch tags") {
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
            }
        }
        .onChange(of: options.tags) { tags in if tags == .prune { options.prune = true } }
        .onChange(of: options.prune) { prune in if !prune && options.tags == .prune { options.tags = .inherit } }
    }
}

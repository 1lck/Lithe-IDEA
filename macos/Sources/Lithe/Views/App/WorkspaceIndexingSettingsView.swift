import SwiftUI
import LitheWorkspaceModule

struct WorkspaceIndexingSettingsView: View {
    @ObservedObject var feature: WorkspaceFeatureModel

    var body: some View {
        Group {
            LitheSettingsRow("Automatically exclude Git-ignored directories", info: "indexing.description") {
                Toggle("Automatically exclude Git-ignored directories", isOn: Binding(
                    get: { feature.indexingSettings.gitIgnoreEnabled },
                    set: { enabled in Task { await feature.setGitIgnoreIndexing(enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(feature.rootNode == nil || !feature.indexingStatus.supportsExclusions)
            }
            if !feature.indexingStatus.supportsExclusions {
                Text("Directory indexing exclusions are not supported for remote projects.")
                    .foregroundStyle(LitheTheme.secondaryText)
            } else if feature.indexingStatus.gitIgnoreFailed {
                Text("Git ignore exclusions could not be fully resolved. Manual exclusions remain active.")
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            if let error = feature.indexingError { Text(error).foregroundStyle(.red) }
        }
    }
}

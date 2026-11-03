import SwiftUI
import LitheWorkspaceModule

struct WorkspaceIndexingSettingsView: View {
    @ObservedObject var feature: WorkspaceFeatureModel

    var body: some View {
        Group {
            LitheSettingsRow("Automatically exclude Git-ignored directories", info: "indexing.description") {
                if feature.indexingStatus.effectiveGitIgnoreEnabled != nil {
                Toggle("Automatically exclude Git-ignored directories", isOn: Binding(
                    get: { feature.indexingStatus.effectiveGitIgnoreEnabled == true },
                    set: { enabled in Task { await feature.setGitIgnoreIndexing(enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(feature.rootNode == nil || !feature.indexingStatus.supportsExclusions || !feature.canEditIndexingSettings)
                } else {
                    Text("Indexing preference not confirmed").foregroundStyle(LitheTheme.secondaryText)
                }
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

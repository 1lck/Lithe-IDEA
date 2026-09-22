import SwiftUI

struct RunConfigurationSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                Text("Open a project to configure its run configurations.")
            } else if let feature = model.runFeatureIfActive {
                RunConfigurationSettingsContent(feature: feature)
                    .id(model.workspaceURL)
            } else {
                Text("Run configurations are unavailable. Enable the execution module and try again.")
            }
        }
        .task(id: model.workspaceURL) {
            if model.workspaceURL != nil { _ = await model.activateExecutionModule() }
        }
    }
}

private struct RunConfigurationSettingsContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: RunFeatureModel
    @State private var confirmGeneration = false
    @State private var isGenerating = false

    var body: some View {
        if let configuration = feature.configurations.first(where: { $0.id == feature.editingConfigurationID }) {
            RunConfigurationEditorView(feature: feature, configuration: configuration) {
                feature.editingConfigurationID = nil
            }
            .id(configuration.id)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Run configurations").font(.title2)
                    Text("Select a service or task to configure its arguments, environment and project-environment overrides. Changes apply after Save.")
                        .foregroundStyle(LitheTheme.secondaryText)
                    if feature.isLoadingProject || isGenerating {
                        ProgressView("Identifying project…")
                    } else {
                        Button("Identify Again") { confirmGeneration = true }
                            .disabled(feature.recoveryAction == .upgradeApplication)
                    }
                    if let error = feature.configurationSaveError {
                        Text(error).foregroundStyle(LitheTheme.error)
                    }
                    if case .failed(let message) = feature.generationState {
                        Text(message).foregroundStyle(LitheTheme.error)
                    }
                    ForEach(feature.configurationDiagnostics) { diagnostic in
                        Text(diagnostic.message).foregroundStyle(LitheTheme.secondaryText)
                    }
                    ForEach(feature.configurations) { configuration in
                        Button {
                            feature.editingConfigurationID = configuration.id
                        } label: {
                            HStack {
                                Text(configuration.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding(10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(feature.configurationStatus != .ready || feature.isLoadingProject || isGenerating)
                    }
                }
                .padding(24)
            }
            .confirmationDialog("Identify Again", isPresented: $confirmGeneration) {
                Button("Rescan") {
                    isGenerating = true
                    Task { @MainActor in
                        defer { isGenerating = false }
                        await model.generateRunConfigurations()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Lithe will look for services again and refresh .lithe/run/generated.json. Project and local overrides will not be changed.")
            }
        }
    }
}

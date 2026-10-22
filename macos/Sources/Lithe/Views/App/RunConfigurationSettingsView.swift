import SwiftUI

struct RunConfigurationSettingsView: View {
    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    /// Held here because module feature changes do not refresh the settings
    /// window; an activation finishing after the first render must still show.
    @State private var activatedFeature: RunFeatureModel?

    var body: some View {
        Group {
            if model.workspaceURL == nil {
                Text("Open a project to configure its run configurations.")
            } else if let feature = activatedFeature ?? model.runFeatureIfActive {
                RunConfigurationSettingsContent(feature: feature)
                    .id(model.workspaceURL)
            } else {
                Text("Run configurations are unavailable. Enable the execution module and try again.")
            }
        }
        .task(id: model.workspaceURL) {
            guard model.workspaceURL != nil else { return }
            activatedFeature = await model.activateExecutionModule()?.runFeature
            // The editor shows the JDK an automatic or inherited value resolves to.
            await model.runtimeFeature.ensureRuntimesDiscovered()
        }
    }
}

private struct RunConfigurationSettingsContent: View {
    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        if feature.isLoadingProject || isGenerating {
                            ProgressView("Identifying project…")
                        } else {
                            Button("Identify Again") { confirmGeneration = true }
                                .disabled(feature.recoveryAction == .upgradeApplication)
                        }
                        LitheInfoTip("Select a service or task to configure its arguments, environment and project-environment overrides. Changes apply after Save.")
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
                        .buttonStyle(.litheNoPress)
                        .disabled(feature.configurationStatus != .ready || feature.isLoadingProject || isGenerating)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
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

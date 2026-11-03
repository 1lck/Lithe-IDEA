import SwiftUI

struct RunConfigurationSettingsView: View {
    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    @State private var selection = ModuleFeatureSelection<RunFeatureModel>()

    var body: some View {
        let current = model.runFeatureIfActive
        Group {
            if model.workspaceURL == nil {
                Text("Open a project to configure its run configurations.")
            } else if let feature = selection.feature(current: current) {
                RunConfigurationSettingsContent(feature: feature)
                    .id(ContentIdentity(workspaceURL: model.workspaceURL, feature: ObjectIdentifier(feature)))
            } else if selection.isActivating {
                ProgressView("Loading…")
            } else {
                Text("Run configurations are unavailable. Enable the execution module and try again.")
            }
        }
        // Re-keyed on the current capability: when the execution module sleeps
        // the page activates it again and shows the new instance.
        .task(id: ContentIdentity(workspaceURL: model.workspaceURL, feature: current.map(ObjectIdentifier.init))) {
            guard model.workspaceURL != nil else { return }
            selection.beginActivation(current: model.runFeatureIfActive)
            let activated = await model.activateExecutionModule()?.runFeature
            // A newer activation task owns the selection once this one is cancelled.
            guard !Task.isCancelled else { return }
            selection.finishActivation(activated)
            // The editor shows the JDK an automatic or inherited value resolves to.
            await model.runtimeFeature.ensureRuntimesDiscovered()
        }
    }

    private struct ContentIdentity: Hashable {
        let workspaceURL: URL?
        let feature: ObjectIdentifier?
    }
}

/// The feature instance an on-demand settings page shows.
///
/// Module feature changes do not refresh the settings window, and the
/// capability cache may fill only after an activation returns, so the page
/// keeps the instance its activation produced. That instance is dropped as
/// soon as it is no longer the module's current capability, so a page left
/// open across idle sleep never reads or edits a released feature.
struct ModuleFeatureSelection<Feature: AnyObject> {
    private(set) var activated: Feature?
    private(set) var isActivating = false

    func feature(current: Feature?) -> Feature? {
        if let current { return current }
        return isActivating ? nil : activated
    }

    mutating func beginActivation(current: Feature?) {
        if activated !== current { activated = nil }
        isActivating = true
    }

    mutating func finishActivation(_ feature: Feature?) {
        activated = feature
        isActivating = false
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
                                .buttonStyle(LitheActionButtonStyle())
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
                Text("Lithe will look for services again. Project and local overrides will not be changed.")
            }
        }
    }
}

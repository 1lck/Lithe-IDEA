import SwiftUI
import LitheCoreContracts

/// Both placements read the same session-owned snapshot; opening details starts no work.
struct ProjectPreparationStatusView: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        ProjectPreparationContent(feature: model.languageToolingFeature, compact: compact)
    }
}

private struct ProjectPreparationContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var feature: LanguageToolingFeatureModel
    var compact: Bool
    @State private var showingDetails = false

    private var snapshot: ProjectPreparationSnapshot? {
        feature.projectPreparation
    }

    var body: some View {
        if let snapshot, snapshot.phase != "stopped", !compact || snapshot.status != "ready" {
            Button { showingDetails.toggle() } label: {
                HStack(spacing: 6) {
                    if snapshot.status == "loading" {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: snapshot.status == "failed" ? "exclamationmark.triangle" : "checkmark.circle")
                    }
                    Text(snapshot.status == "failed"
                        ? (settings.language.localizedString("native.inline.javaProjectPreparationFailed"))
                        : phaseTitle(snapshot.phase))
                        .lineLimit(1)
                }
                .font(LitheTheme.uiFont(size: 11))
            }
            .buttonStyle(.litheNoPress)
            .help(settings.language.localizedString("native.inline.viewProjectPreparationDetails"))
            .litheDropdown(isPresented: $showingDetails, opensUpward: !compact) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(phaseTitle(snapshot.phase)).font(LitheTheme.uiFont(.headline))
                    ForEach(["starting", "importing", "configuring", "building"], id: \.self) { phase in
                        Text((snapshot.phase == phase ? "› " : "· ") + phaseTitle(phase))
                            .font(LitheTheme.uiFont(size: 12, weight: snapshot.phase == phase ? .semibold : .regular))
                    }
                    Text(settings.language.localizedString("native.inline.theJavaWorkspaceMustFinishPreparationBeforeLaunchBackgroundIndexingDoesNotB"))
                        .font(LitheTheme.uiFont(size: 12))
                    Button(settings.language.localizedString("native.inline.languageServiceSettingsAndRetry")) {
                        showingDetails = false
                        model.showSettings(category: .lsp)
                    }
                    Button(settings.language.localizedString("native.inline.viewLogs")) {
                        showingDetails = false
                        model.showSettings(category: .diagnostics)
                    }
                    if model.alwaysContinuesAfterJavaBuildFailures {
                        Divider()
                        Text(settings.language.localizedString("native.inline.javaLaunchesAlwaysContinueAfterBuildFailuresInThisWorkspace"))
                            .font(LitheTheme.uiFont(size: 12))
                            .foregroundStyle(LitheTheme.secondaryText)
                        Button(settings.language.localizedString("native.inline.askAgain")) {
                            model.askAgainForJavaBuildFailures()
                        }
                    }
                }
                .padding(16)
                .frame(width: 330)
            }
        }
    }

    private func phaseTitle(_ phase: String) -> String {
        switch phase {
        case "starting": settings.language.localizedString("native.inline.startingJavaService")
        case "importing": settings.language.localizedString("native.inline.importingJavaProjectAndDependencies")
        case "configuring": settings.language.localizedString("native.inline.synchronizingJavaProjectConfiguration")
        case "building": settings.language.localizedString("native.inline.buildingJavaProject")
        case "ready": settings.language.localizedString("native.inline.javaProjectModelReady")
        default: settings.language.localizedString("native.inline.javaProjectPreparationStopped")
        }
    }
}

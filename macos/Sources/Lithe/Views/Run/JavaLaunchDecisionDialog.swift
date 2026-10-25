import SwiftUI
import LitheCoreContracts

struct JavaLaunchDecisionDialog: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let request: PendingJavaLaunchDecision

    private var report: JavaBuildReport? { request.failure.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                settings.language.localizedString("native.inline.javaBuildDidNotSucceed"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(LitheTheme.uiFont(.headline))
            .foregroundStyle(LitheTheme.warning)

            Text(explanation)
                .font(LitheTheme.uiFont(size: 13))
            Text(request.failure.message)
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)

            if let report {
                VStack(alignment: .leading, spacing: 5) {
                    evidenceRow(
                        settings.language.localizedString("native.inline.markerScope"),
                        value: report.markerScope == .workspace
                            ? (settings.language.localizedString("native.inline.workspaceMayIncludeUnrelatedModules"))
                            : (settings.language.localizedString("native.inline.requestedLaunchTargetAndDependencies"))
                    )
                    evidenceRow(
                        settings.language.localizedString("native.inline.buildElapsed"),
                        value: "\(report.elapsedMilliseconds) ms"
                    )
                }
                .padding(10)
                .background(LitheTheme.sidebar.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text(settings.language.localizedString("native.inline.runAnywayContinuesThisLaunchWithTheResolvedOutputAndDoesNotBuildAgain"))
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: LitheTheme.ActionButton.spacing) { actionButtons }
                VStack(alignment: .leading, spacing: LitheTheme.ActionButton.spacing) { actionButtons }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(LitheActionButtonStyle())
        .padding(20)
        .frame(width: 590)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(settings.language.localizedString("native.inline.runAnyway")) {
            model.completeJavaLaunchDecision(.runOnce, requestID: request.id)
        }
        .buttonStyle(LitheActionButtonStyle(isPrimary: true))
        .accessibilityIdentifier("java-build-run-anyway")

        Button(settings.language.localizedString("native.inline.alwaysContinueInThisWorkspace")) {
            model.completeJavaLaunchDecision(.alwaysContinue, requestID: request.id)
        }
        .accessibilityIdentifier("java-build-always-continue")

        if report?.recovery == .rebuildJavaIndex {
            Button(settings.language.localizedString("native.inline.rebuildJavaIndex")) {
                model.completeJavaLaunchDecision(.rebuildIndex, requestID: request.id)
            }
            .accessibilityIdentifier("java-build-rebuild-index")
        }

        Button(settings.language.localizedString("native.inline.openLogs")) {
            model.completeJavaLaunchDecision(.cancel, requestID: request.id)
            model.showSettings(category: .diagnostics)
        }
        .accessibilityIdentifier("java-build-open-logs")
        Button(settings.language.localizedString("native.inline.cancel"), role: .cancel) {
            model.completeJavaLaunchDecision(.cancel, requestID: request.id)
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("java-build-cancel")
    }

    private var explanation: String {
        if request.failure.code == "javaBuildFailed"
            || report?.builderFailedEarlier == true {
            return settings.language.localizedString("native.inline.theJavaLanguageServiceBuilderFailedInThisSessionSoTheseErrorMarkersMayBeSta")
        }
        return settings.language.localizedString("native.inline.theJavaLanguageServiceReportedCompilationErrorsWhichMayComeFromDependencies")
    }

    private func evidenceRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label + ":")
                .foregroundStyle(LitheTheme.secondaryText)
            Text(value)
                .textSelection(.enabled)
        }
        .font(LitheTheme.uiFont(size: 12))
    }
}

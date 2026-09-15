import SwiftUI

/// Build output stays in the bottom tool area independently of Maven navigation.
struct MavenBuildOutputView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: MavenFeatureModel

    var body: some View {
        buildOutputPane
            .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var mavenSearchRoots: [URL] {
        guard let project = feature.project else { return [] }
        return [project.rootURL] + moduleURLs(project.modules)
    }

    private func moduleURLs(_ modules: [MavenModule]) -> [URL] {
        modules.flatMap { [$0.url] + moduleURLs($0.modules) }
    }

    private var buildOutputPane: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(
                title: "Maven Build",
                systemImage: "terminal",
                onMinimize: { model.workbenchFeature.setVisibility(.mavenOutput, isVisible: false) }
            ) {
                if let runningTitle = feature.runningTitle {
                    ProgressView()
                        .controlSize(.mini)
                    Text(runningTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                } else if feature.taskState == .cancelled {
                    Label("Cancelled", systemImage: "stop.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LitheTheme.warning)
                } else if let exitCode = feature.lastExitCode {
                    Label(
                        exitCode == 0 ? "Succeeded" : "Failed",
                        systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(exitCode == 0 ? LitheTheme.success : LitheTheme.error)
                }

                if feature.isRunning || model.runWorkflowCoordinator.isModuleOperationStarting {
                    Button(action: model.stopMaven) {
                        Image(systemName: "stop.fill")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.warning)
                    .help("Stop Maven task")
                }

                Button(action: feature.clearOutput) {
                    Image(systemName: "trash")
                }
                .litheIconButton()
                .help("Clear build output")
                if !feature.issues.isEmpty {
                    Label("\(feature.issues.count)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LitheTheme.warning)
                }
            }

            if !feature.issues.isEmpty {
                issueList
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            OutputTextView(
                output: feature.output,
                searchRoots: mavenSearchRoots,
                fileExists: { model.fileExists(at: $0) },
                emptyMessage: "Run a Maven lifecycle phase to see output."
            ) { url, line, column in
                model.openSourceLocation(url: url, line: line, column: column)
            }
        }
    }

    private var issueList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(feature.issues) { issue in
                    Button {
                        model.openMavenIssue(issue)
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: issue.severity.systemImage)
                                .foregroundStyle(issue.severity == .error ? .red : LitheTheme.warning)
                                .frame(width: 15)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.locationTitle)
                                    .font(.system(size: 11.5, weight: .medium))
                                Text(issue.message)
                                    .font(.system(size: 11))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(LitheTheme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                }
            }
            .padding(.vertical, 5)
        }
        .frame(maxHeight: 132)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }
}

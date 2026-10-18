import LitheCoreContracts
import LitheExecutionModule
import SwiftUI

/// Output, diagnostics, and test results of the last plugin build-system run.
struct BuildOutputView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: BuildSystemsFeatureModel

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(
                title: "Build Output",
                systemImage: "terminal",
                onMinimize: { model.workbenchFeature.setVisibility(.buildOutput, isVisible: false) }
            ) {
                stateLabel
                if feature.isRunning {
                    Button(action: feature.stopRun) {
                        Image(systemName: "stop.fill")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.warning)
                    .help("Stop build task")
                }
                Button(action: feature.clearOutput) {
                    Image(systemName: "trash")
                }
                .litheIconButton()
                .help("Clear build output")
            }
            if let results = feature.testResults {
                testSummary(results)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            if !feature.diagnostics.isEmpty || feature.testResults?.tests.contains(where: Self.isProblem) == true {
                problemList
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            OutputTextView(
                output: feature.output,
                searchRoots: feature.outputRoots,
                resolvesRelativePathsUniquely: true,
                fileExists: { model.fileExists(at: $0) },
                emptyMessage: "Run a build task to see output."
            ) { url, line, column in
                // Output text is untrusted like decoded diagnostics: a link
                // may not reach a file outside the workspace.
                guard let workspaceURL = feature.workspaceURL,
                      BuildOutputSourcePath.contains(url, in: workspaceURL)
                else { return }
                model.openSourceLocation(url: url, line: line, column: column)
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    @ViewBuilder
    private var stateLabel: some View {
        Group {
            switch feature.runState {
            case .running:
                ProgressView().controlSize(.mini)
                Text(feature.runningTitle ?? "")
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            case .succeeded:
                Label("Succeeded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(LitheTheme.success)
            case .failed(let message):
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(LitheTheme.error)
                    .help(message)
            case .cancelled:
                Label("Cancelled", systemImage: "stop.circle.fill")
                    .foregroundStyle(LitheTheme.warning)
            case .idle:
                EmptyView()
            }
        }
        .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
    }

    private func testSummary(_ results: BuildTestResults) -> some View {
        HStack(spacing: 12) {
            Label(
                results.success ? "Tests passed" : "Tests failed",
                systemImage: results.success ? "checkmark.seal.fill" : "xmark.seal.fill"
            )
            .foregroundStyle(results.success ? LitheTheme.success : LitheTheme.error)
            Text("\(results.summary.passed) passed")
            if results.summary.failed + results.summary.errors > 0 {
                Text("\(results.summary.failed + results.summary.errors) failed")
                    .foregroundStyle(LitheTheme.error)
            }
            if results.summary.skipped > 0 {
                Text("\(results.summary.skipped) skipped")
            }
            Spacer(minLength: 0)
        }
        .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var problemList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(feature.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    problemRow(
                        systemImage: diagnostic.severity == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                        color: diagnostic.severity == "error" ? LitheTheme.error : LitheTheme.warning,
                        title: "\(diagnostic.path):\(diagnostic.line)",
                        message: diagnostic.message,
                        path: diagnostic.path,
                        line: diagnostic.line,
                        column: diagnostic.column
                    )
                }
                ForEach(feature.testResults?.tests.filter(Self.isProblem) ?? []) { test in
                    problemRow(
                        systemImage: "xmark.seal.fill",
                        color: LitheTheme.error,
                        title: test.suite + " › " + test.name,
                        message: test.message ?? "",
                        path: test.path,
                        line: test.line ?? 1,
                        column: nil
                    )
                }
            }
            .padding(.vertical, 5)
        }
        .frame(maxHeight: 132)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private func problemRow(
        systemImage: String,
        color: Color,
        title: String,
        message: String,
        path: String?,
        line: Int,
        column: Int?
    ) -> some View {
        Button {
            guard let path,
                  let workspaceURL = feature.workspaceURL,
                  let url = BuildOutputSourcePath.url(for: path, in: workspaceURL)
            else { return }
            model.openSourceLocation(url: url, line: line, column: column)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                    if !message.isEmpty {
                        Text(message)
                            .font(LitheTheme.uiFont(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
    }

    private static func isProblem(_ test: BuildTestResults.TestCase) -> Bool {
        test.status == .failed || test.status == .error
    }
}

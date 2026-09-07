import SwiftUI

struct ProblemsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var diagnosticsStore: EditorDiagnosticsStore
    @State private var severityFilter = Set(DiagnosticSeverity.allCases)

    var body: some View {
        VStack(spacing: 0) {
            header

            if allDiagnostics.isEmpty {
                emptyState
            } else if diagnostics.isEmpty {
                filteredEmptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(diagnostics) { diagnostic in
                            diagnosticRow(diagnostic)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .litheWorkbenchSurface(LitheTheme.editor)
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var header: some View {
        LitheToolWindowHeader(
            title: "Problems",
            systemImage: "exclamationmark.triangle",
            ideaAssetPath: "toolwindows/toolWindowProblems.svg",
            subtitle: allDiagnostics.isEmpty ? nil : String(diagnostics.count),
            onMinimize: { model.workbenchFeature.setVisibility(.problems, isVisible: false) }
        ) {
            if errorCount > 0 {
                Label(String(errorCount), systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.error)
            }
            if warningCount > 0 {
                Label(String(warningCount), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.warning)
            }

            Menu {
                Button {
                    severityFilter = Set(DiagnosticSeverity.allCases)
                } label: {
                    Label("All severities", systemImage: severityFilter.count == DiagnosticSeverity.allCases.count ? "checkmark" : "circle")
                }

                Divider()

                ForEach(DiagnosticSeverity.allCases, id: \.self) { severity in
                    Button {
                        if severityFilter.contains(severity) {
                            severityFilter.remove(severity)
                        } else {
                            severityFilter.insert(severity)
                        }
                    } label: {
                        Label(
                            severity.title,
                            systemImage: severityFilter.contains(severity) ? "checkmark" : "circle"
                        )
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .litheIconButton()
            .help("Filter problems by severity")
        }
    }

    private var allDiagnostics: [EditorDiagnostic] {
        diagnosticsStore.diagnosticsByURL.values
            .flatMap { $0 }
            .sorted {
                let left = model.relativePath(for: $0.fileURL)
                let right = model.relativePath(for: $1.fileURL)
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
                if $0.line != $1.line { return $0.line < $1.line }
                return $0.utf16Column < $1.utf16Column
            }
    }

    private var diagnostics: [EditorDiagnostic] {
        allDiagnostics.filter { severityFilter.contains($0.severity) }
    }

    private var errorCount: Int {
        diagnostics.filter { $0.severity == .error }.count
    }

    private var warningCount: Int {
        diagnostics.filter { $0.severity == .warning }.count
    }

    private func diagnosticRow(_ diagnostic: EditorDiagnostic) -> some View {
        Button {
            model.openDiagnostic(diagnostic)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: diagnostic.severity.systemImage)
                    .foregroundStyle(color(for: diagnostic.severity))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(diagnostic.locationTitle)
                            .font(.system(size: 11.5, weight: .medium))
                        if let source = diagnostic.source, !source.isEmpty {
                            Text(source)
                                .font(.system(size: 10.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        if let reason = diagnostic.reasonSummary {
                            Text(reason)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(diagnostic.isUnnecessary ? LitheTheme.secondaryText : LitheTheme.accent)
                        }
                    }
                    Text(diagnostic.message)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(3)
                    if !diagnostic.relatedInformation.isEmpty {
                        Text(diagnostic.relatedInformation.map { "\($0.locationTitle): \($0.message)" }.joined(separator: " · "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.secondaryText.opacity(0.82))
                            .lineLimit(2)
                    }
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
        .help(diagnostic.detailText)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LitheTheme.success)
            Text("No problems")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Diagnostics from active language servers will appear here.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("No problems match the current filter")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Use the filter menu to show other severities.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .unknown: LitheTheme.secondaryText
        case .error: LitheTheme.error
        case .warning: LitheTheme.warning
        case .information: LitheTheme.accent
        case .hint: LitheTheme.secondaryText
        }
    }
}

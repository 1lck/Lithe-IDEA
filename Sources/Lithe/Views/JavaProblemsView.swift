import SwiftUI

struct JavaProblemsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if diagnostics.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(diagnostics) { diagnostic in
                            diagnosticRow(diagnostic)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .background(LitheTheme.editor)
            }
        }
        .background(LitheTheme.editor)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
            Text("Problems")
                .font(.system(size: 12.5, weight: .semibold))

            if !diagnostics.isEmpty {
                Text(String(diagnostics.count))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            Spacer()

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

            Button {
                model.isProblemsVisible = false
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .help("Hide Problems tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 42)
        .foregroundStyle(LitheTheme.primaryText)
        .background(LitheTheme.toolHeader)
    }

    private var diagnostics: [JavaDiagnostic] {
        model.javaDiagnostics.values
            .flatMap { $0 }
            .sorted {
                let left = model.relativePath(for: $0.fileURL)
                let right = model.relativePath(for: $1.fileURL)
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
                if $0.line != $1.line { return $0.line < $1.line }
                return $0.utf16Column < $1.utf16Column
            }
    }

    private var errorCount: Int {
        diagnostics.filter { $0.severity == .error }.count
    }

    private var warningCount: Int {
        diagnostics.filter { $0.severity == .warning }.count
    }

    private func diagnosticRow(_ diagnostic: JavaDiagnostic) -> some View {
        Button {
            model.openJavaDiagnostic(diagnostic)
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
                    }
                    Text(diagnostic.message)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LitheTheme.success)
            Text("No Java problems")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Diagnostics from JDT LS will appear here.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for severity: JavaDiagnosticSeverity) -> Color {
        switch severity {
        case .error: LitheTheme.error
        case .warning: LitheTheme.warning
        case .information: LitheTheme.accent
        case .hint: LitheTheme.secondaryText
        }
    }
}

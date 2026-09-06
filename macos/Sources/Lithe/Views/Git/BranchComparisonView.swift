import SwiftUI
import LitheGitModule

struct BranchComparisonView: View {
    @ObservedObject var feature: GitFeatureModel
    let comparison: GitBranchComparison
    let onRefresh: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            comparisonToolbar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            HStack(spacing: 0) {
                filePane
                    .frame(width: 250)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                reviewPane
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.accent)
            Text("Diff: \(comparison.reference.shortName) with \(comparison.targetTitle)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Spacer()
            Text(comparison.files.count == 1 ? "1 file" : "\(comparison.files.count) files")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Button("Close") {
                feature.closeBranchComparison()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .help("Close comparison")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 36)
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.accent).frame(height: 2)
        }
    }

    private var comparisonToolbar: some View {
        HStack(spacing: 7) {
            Button {
                refreshComparison()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .disabled(feature.isLoadingBranchComparison)

            Button {
                moveFileSelection(by: -1)
            } label: {
                Label("Previous File", systemImage: "chevron.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .disabled(previousFile == nil || feature.isLoadingBranchComparison)

            Button {
                moveFileSelection(by: 1)
            } label: {
                Label("Next File", systemImage: "chevron.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .disabled(nextFile == nil || feature.isLoadingBranchComparison)

            Spacer()

            if let selectedFileIndex {
                Text("File \(selectedFileIndex + 1) of \(comparison.files.count)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            } else {
                Text(comparison.files.isEmpty ? "No changed files" : "Select a file")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var filePane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changed Files")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                if feature.isLoadingBranchComparison {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .litheWorkbenchSurface(LitheTheme.toolHeader)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if comparison.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(LitheTheme.success)
                    Text("No differences")
                        .font(LitheTheme.uiFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(comparison.files) { file in
                            Button {
                                Task { await feature.selectBranchComparisonFile(file) }
                            } label: {
                                HStack(spacing: 7) {
                                    Text(file.status)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(statusColor(file.status))
                                        .frame(width: 20)
                                    LitheSystemIcon(systemImage: "doc.text")
                                        .font(.system(size: 11))
                                        .foregroundStyle(LitheTheme.accent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text((file.path as NSString).lastPathComponent)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(LitheTheme.primaryText)
                                            .lineLimit(1)
                                        let directory = (file.path as NSString).deletingLastPathComponent
                                        if !directory.isEmpty {
                                            Text(directory)
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(LitheTheme.secondaryText)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 6)
                                }
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 39)
                                .background(
                                    feature.selectedBranchComparisonFile?.id == file.id
                                        ? LitheTheme.subtleSelection
                                        : .clear
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .lithePointer()
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var reviewPane: some View {
        VStack(spacing: 0) {
            versionHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if feature.isLoadingBranchComparison {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading comparison…")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feature.selectedBranchComparisonFile == nil {
                Text(comparison.files.isEmpty ? "The selected versions match" : "Select a file")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feature.branchComparisonRows.isEmpty {
                Text("No textual diff available")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffPaneView(
                    rows: feature.branchComparisonRows,
                    fileExtension: selectedFileExtension
                )
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var versionHeader: some View {
        HStack(spacing: 0) {
            versionTitle(comparison.reference.shortName, icon: "lock")
            ZStack {
                LitheTheme.window
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
            }
            .frame(width: 34)
            versionTitle(
                comparison.targetTitle,
                icon: comparison.targetReference == nil ? "folder" : "lock"
            )
        }
        .frame(height: 34)
        .background(LitheTheme.window)
    }

    private func versionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            if let file = feature.selectedBranchComparisonFile {
                Text(file.path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private var selectedFileExtension: String {
        guard let file = feature.selectedBranchComparisonFile else { return "" }
        return URL(fileURLWithPath: file.path).pathExtension
    }

    private var selectedFileIndex: Int? {
        guard let selected = feature.selectedBranchComparisonFile else { return nil }
        return comparison.files.firstIndex(where: { $0.id == selected.id })
    }

    private var previousFile: GitBranchComparisonFile? {
        guard let selectedFileIndex, selectedFileIndex > comparison.files.startIndex else { return nil }
        return comparison.files[comparison.files.index(before: selectedFileIndex)]
    }

    private var nextFile: GitBranchComparisonFile? {
        guard let selectedFileIndex else { return comparison.files.first }
        let nextIndex = comparison.files.index(after: selectedFileIndex)
        guard nextIndex < comparison.files.endIndex else { return nil }
        return comparison.files[nextIndex]
    }

    private func refreshComparison() {
        Task { await onRefresh() }
    }

    private func moveFileSelection(by offset: Int) {
        let file = offset < 0 ? previousFile : nextFile
        guard let file else { return }
        Task { await feature.selectBranchComparisonFile(file) }
    }

    private func statusColor(_ status: String) -> Color {
        if status.hasPrefix("A") { return LitheTheme.success }
        if status.hasPrefix("D") { return .red.opacity(0.85) }
        if status.hasPrefix("R") { return LitheTheme.accent }
        return LitheTheme.warning
    }
}

import SwiftUI

struct BranchComparisonView: View {
    @EnvironmentObject private var model: AppModel
    let comparison: GitBranchComparison

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            HStack(spacing: 0) {
                filePane
                    .frame(width: 250)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                reviewPane
            }
        }
        .background(LitheTheme.editor)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.accent)
            Text("Diff: \(comparison.reference.shortName) with Working Tree")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Spacer()
            Text(comparison.files.count == 1 ? "1 file" : "\(comparison.files.count) files")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Button {
                model.closeBranchComparison()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .litheIconButton()
            .help("Close comparison")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(LitheTheme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.accent).frame(height: 2)
        }
    }

    private var filePane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changed Files")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                if model.isLoadingBranchComparison {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(LitheTheme.toolHeader)

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
                                Task { await model.selectBranchComparisonFile(file) }
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
                                    model.selectedBranchComparisonFile?.id == file.id
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
        .background(LitheTheme.sidebar)
    }

    private var reviewPane: some View {
        VStack(spacing: 0) {
            versionHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.isLoadingBranchComparison {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading comparison…")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedBranchComparisonFile == nil {
                Text(comparison.files.isEmpty ? "Working tree matches this reference" : "Select a file")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.branchComparisonRows.isEmpty {
                Text("No textual diff available")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let contentWidth = max(900, geometry.size.width)
                    let kinds = model.branchComparisonRows.map(\.kind)
                    let contentHeight = max(
                        DiffLayoutMetrics.contentHeight(rows: model.branchComparisonRows, kinds: kinds),
                        geometry.size.height
                    )

                    ScrollView([.vertical, .horizontal]) {
                        ZStack(alignment: .topLeading) {
                            DiffConnectorOverlay(
                                rows: model.branchComparisonRows,
                                kinds: kinds,
                                contentWidth: contentWidth
                            )

                            LazyVStack(spacing: 0) {
                                ForEach(model.branchComparisonRows) { row in
                                    DiffRowView(
                                        row: row,
                                        kind: row.kind,
                                        fileExtension: selectedFileExtension,
                                        highlightsWords: true,
                                        isSelectedDifference: false
                                    )
                                }
                            }
                            .textSelection(.enabled)
                        }
                        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                    }
                }
            }
        }
        .background(LitheTheme.editor)
    }

    private var versionHeader: some View {
        HStack(spacing: 0) {
            versionTitle(comparison.reference.shortName, icon: "lock")
            ZStack {
                LitheTheme.window
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
            }
            .frame(width: 34)
            versionTitle("Working Tree", icon: "folder")
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
            if let file = model.selectedBranchComparisonFile {
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
        guard let file = model.selectedBranchComparisonFile else { return "" }
        return URL(fileURLWithPath: file.path).pathExtension
    }

    private func statusColor(_ status: String) -> Color {
        if status.hasPrefix("A") { return LitheTheme.success }
        if status.hasPrefix("D") { return .red.opacity(0.85) }
        if status.hasPrefix("R") { return LitheTheme.accent }
        return LitheTheme.warning
    }
}

import SwiftUI
import LitheGitModule

/// Read-only commit diff opened from the changed-files pane of Git Log.
/// Working-tree diffs keep using DiffReviewView because they expose stage and
/// discard actions; historical commit diffs deliberately do not.
struct GitCommitDiffReviewView: View {
    @ObservedObject var feature: GitFeatureModel
    let context: GitCommitDiffContext

    @State private var highlightsWords = true
    @State private var selectedDifferenceIndex = 0

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                diffTab
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                toolbar(proxy: proxy)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                versionHeader
                Rectangle().fill(LitheTheme.divider).frame(height: 1)

                if feature.isLoadingDiff {
                    VStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Loading commit diff…")
                    }
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if feature.diffRows.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 30, weight: .light))
                        Text("No textual diff available")
                    }
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    diffContent(proxy: proxy)
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .onChange(of: feature.diffRows.count) { _ in
            selectedDifferenceIndex = 0
        }
    }

    private var diffTab: some View {
        HStack(spacing: 7) {
            LitheSystemIcon(systemImage: "doc.text", size: 14)
                .foregroundStyle(fileIconColor)
            Text((context.file.path as NSString).lastPathComponent)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)

            statusBadge

            Text("COMMIT DIFF")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(LitheTheme.accent)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(LitheTheme.accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Spacer()

            Button {
                feature.closeGitCommitDiff()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .litheIconButton()
            .help("Close diff")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 34)
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.accent).frame(height: 2)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: context.kind.symbol)
                .font(.system(size: 8, weight: .bold))
            Text(LocalizedStringKey(context.kind.title.uppercased()))
                .font(.system(size: 8.5, weight: .bold))
        }
        .foregroundStyle(changeKindColor)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(changeKindColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func toolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 4) {
            Button {
                navigateDifference(by: -1, proxy: proxy)
            } label: {
                Image(systemName: "arrow.up")
            }
            .litheIconButton()
            .disabled(differenceStarts.isEmpty)
            .help("Previous difference")

            Button {
                navigateDifference(by: 1, proxy: proxy)
            } label: {
                Image(systemName: "arrow.down")
            }
            .litheIconButton()
            .disabled(differenceStarts.isEmpty)
            .help("Next difference")

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(width: 1, height: 22)
                .padding(.horizontal, 4)

            Text(context.commit.shortHash)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(LitheTheme.accent)
            Text(context.commit.subject)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)

            Spacer()

            Button {
                highlightsWords.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: highlightsWords ? "checkmark.square.fill" : "square")
                    Text("Highlight words")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(LitheTheme.raised.opacity(0.58))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()

            Text("Read-only")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 7)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var versionHeader: some View {
        HStack(spacing: 0) {
            versionLabel("Parent version", path: context.path)
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(width: 1)
            versionLabel("Commit version", path: context.path)
        }
        .frame(height: 34)
        .background(LitheTheme.window)
    }

    private func versionLabel(_ title: String, path: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text(path)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private func diffContent(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geometry in
            let usesSinglePane = context.kind == .added || context.kind == .deleted
            let contentWidth = DiffLayoutMetrics.contentWidth(
                rows: feature.diffRows,
                viewportWidth: geometry.size.width,
                minimumWidth: usesSinglePane ? 680 : 980,
                paneCount: usesSinglePane ? 1 : 2
            )

            let kinds = feature.diffRows.map(\.kind)
            if usesSinglePane {
                ScrollView(.horizontal) {
                    ScrollView(.vertical) {
                        let contentHeight = max(
                            DiffLayoutMetrics.contentHeight(rows: feature.diffRows, kinds: kinds),
                            geometry.size.height
                        )
                        LazyVStack(spacing: 0) {
                            ForEach(feature.diffRows, id: \.id) { row in
                                diffRowView(for: row, contentWidth: contentWidth)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                    }
                    .frame(width: contentWidth, height: geometry.size.height, alignment: .topLeading)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(LitheTheme.editor)
            } else {
                let displayRows = feature.diffRows.enumerated().map {
                    DiffDisplayRow.row($0.element, index: $0.offset)
                }
                DiffSplitPaneView(
                    displayRows: displayRows,
                    kinds: kinds,
                    fileExtension: context.url.pathExtension,
                    contentWidth: contentWidth,
                    viewportWidth: geometry.size.width,
                    minimumHeight: geometry.size.height,
                    highlightsWords: highlightsWords,
                    selectedRowIDs: Set(differenceIndexByRow.compactMap { entry in
                        entry.value == selectedDifferenceIndex ? entry.key : nil
                    }),
                    onExpand: { _ in }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(LitheTheme.editor)
            }
        }
    }

    @ViewBuilder
    private func diffRowView(for row: DiffRow, contentWidth: CGFloat) -> some View {
        let differenceIndex = differenceIndexByRow[row.id]
        if context.kind == .added || context.kind == .deleted {
            SingleFileDiffRowView(
                row: row,
                changeKind: context.kind,
                fileExtension: context.url.pathExtension,
                isSelectedDifference: differenceIndex == selectedDifferenceIndex
            )
            .id(row.id)
        }
    }

    private var differenceStarts: [DiffRowID] {
        var result: [DiffRowID] = []
        var insideDifference = false
        for row in feature.diffRows {
            let isDifference = row.kind.isCommitDifference
            if isDifference && !insideDifference {
                result.append(row.id)
            }
            insideDifference = isDifference
        }
        return result
    }

    private var differenceIndexByRow: [DiffRowID: Int] {
        var result: [DiffRowID: Int] = [:]
        var currentIndex = -1
        var insideDifference = false
        for row in feature.diffRows {
            let isDifference = row.kind.isCommitDifference
            if isDifference && !insideDifference {
                currentIndex += 1
            }
            if isDifference {
                result[row.id] = currentIndex
            }
            insideDifference = isDifference
        }
        return result
    }

    private func navigateDifference(by offset: Int, proxy: ScrollViewProxy) {
        let starts = differenceStarts
        guard !starts.isEmpty else { return }
        let current = min(max(selectedDifferenceIndex, 0), starts.count - 1)
        let next = (current + offset + starts.count) % starts.count
        selectedDifferenceIndex = next
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(starts[next], anchor: .center)
        }
    }

    private var changeKindColor: Color {
        switch context.kind {
        case .added: LitheTheme.success
        case .modified: LitheTheme.warning
        case .deleted: .red.opacity(0.86)
        case .moved: LitheTheme.accent
        case .copied: Color(red: 0.46, green: 0.72, blue: 0.92)
        case .conflicted: .red
        }
    }

    private var fileIconColor: Color {
        switch context.url.pathExtension.lowercased() {
        case "swift": .orange
        case "java", "kt", "kts": Color(red: 0.42, green: 0.66, blue: 0.95)
        case "js", "jsx", "ts", "tsx": .yellow
        default: LitheTheme.accent
        }
    }
}

private extension DiffRowKind {
    var isCommitDifference: Bool {
        switch self {
        case .changed, .addition, .removal: true
        case .context, .information: false
        }
    }
}

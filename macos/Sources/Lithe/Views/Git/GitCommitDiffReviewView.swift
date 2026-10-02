import SwiftUI
import LitheGitModule

/// Read-only commit diff opened from the changed-files pane of Git Log.
/// Working-tree diffs keep using DiffReviewView because they expose stage and
/// discard actions; historical commit diffs deliberately do not.
struct GitCommitDiffReviewView: View {
    @ObservedObject var feature: GitFeatureModel
    let context: GitCommitDiffContext
    let onClose: () -> Void
    let onOpenFile: () -> Void
    let onOpenCommitDiff: (GitCommitFile) -> Void

    @State private var unified = false
    @State private var highlightsWords = true
    @State private var selectedDifferenceIndex = 0
    @State private var collapsesUnchangedRegions = false
    @State private var expandedRegionIDs: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                toolbar(proxy: proxy)
                if usesUnifiedPane || feature.isLoadingDiff || feature.diffRows.isEmpty {
                    versionHeader
                }

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
                            .font(LitheTheme.uiFont(size: 30, weight: .light))
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
        .litheWorkbenchSurface(LitheTheme.Diff.background)
        .onChange(of: context.id) { _ in
            selectedDifferenceIndex = 0
            expandedRegionIDs = []
        }
    }

    private var usesUnifiedPane: Bool { unified || context.kind == .added || context.kind == .deleted }

    private func toolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 4) {
            Button { navigateDifference(by: -1, proxy: proxy) } label: {
                LitheIDEAIcon(resourcePath: "expui/general/up", size: 16, preservesOriginalColors: true)
            }.litheToolbarIconButton(isEnabled: !differenceStarts.isEmpty).accessibilityLabel("Previous difference").workbenchHoverHelp(Text("Previous difference"))
            Button { navigateDifference(by: 1, proxy: proxy) } label: {
                LitheIDEAIcon(resourcePath: "expui/general/down", size: 16, preservesOriginalColors: true)
            }.litheToolbarIconButton(isEnabled: !differenceStarts.isEmpty).accessibilityLabel("Next difference").workbenchHoverHelp(Text("Next difference"))
            toolbarDivider
            Button {
                onOpenFile()
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/edit", size: 16, preservesOriginalColors: true)
            }.litheToolbarIconButton(isEnabled: context.kind != .deleted)
                .accessibilityLabel("Open in editor").workbenchHoverHelp(Text("Open in editor"))
            toolbarDivider
            Button { navigateFile(by: -1) } label: {
                LitheIDEAIcon(resourcePath: "expui/general/left", size: 16, preservesOriginalColors: true)
            }.litheToolbarIconButton(isEnabled: fileIndex.map { $0 > 0 } ?? false)
                .accessibilityLabel("Previous file").workbenchHoverHelp(Text("Previous file"))
            Text(files.count == 1 ? "1 file" : "\(files.count) files")
                .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.Diff.pathForeground)
            Button { navigateFile(by: 1) } label: {
                LitheIDEAIcon(resourcePath: "expui/general/right", size: 16, preservesOriginalColors: true)
            }.litheToolbarIconButton(isEnabled: fileIndex.map { $0 + 1 < files.count } ?? false)
                .accessibilityLabel("Next file").workbenchHoverHelp(Text("Next file"))
            toolbarDivider
            Button {
                collapsesUnchangedRegions.toggle()
                expandedRegionIDs = []
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/collapseAll", size: 16, preservesOriginalColors: true)
            }.litheToolbarIconButton(isEnabled: !feature.diffRows.isEmpty)
                .litheRowHover(isActive: collapsesUnchangedRegions, activeBackground: LitheTheme.hoverBackground)
                .accessibilityLabel("Collapse unchanged fragments")
                .accessibilityValue(collapsesUnchangedRegions ? "On" : "Off")
                .workbenchHoverHelp(Text("Collapse unchanged fragments"))
            Spacer()
            Text(differenceStarts.count == 1 ? "1 difference" : "\(differenceStarts.count) differences")
                .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.primaryText)
                .padding(.trailing, 8)
            HStack(spacing: 0) {
                viewerButton(unified: false)
                viewerButton(unified: true)
            }
            .padding(LitheTheme.Diff.viewerFocusInset + LitheTheme.Diff.viewerBorderWidth)
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Diff.viewerRadius)
                    .strokeBorder(LitheTheme.Diff.viewerBorder, lineWidth: LitheTheme.Diff.viewerBorderWidth)
                    .padding(LitheTheme.Diff.viewerFocusInset)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                // The parent paints only the selected segment, over the single shared outer border.
                RoundedRectangle(cornerRadius: LitheTheme.Diff.viewerRadius)
                    .strokeBorder(LitheTheme.Diff.viewerSelectedBorder, lineWidth: LitheTheme.Diff.viewerBorderWidth)
                    .frame(width: LitheTheme.Diff.viewerButtonWidth + 2 * LitheTheme.Diff.viewerBorderWidth,
                           height: LitheTheme.Diff.viewerButtonHeight + 2 * LitheTheme.Diff.viewerBorderWidth)
                    .offset(x: LitheTheme.Diff.viewerFocusInset + (usesUnifiedPane ? LitheTheme.Diff.viewerButtonWidth : 0))
                    .allowsHitTesting(false)
            }
            LitheMenu {
                LitheContextMenuItem.toggle("Highlight words", isOn: $highlightsWords)
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Close diff") { onClose() }
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/settings", size: 16, preservesOriginalColors: true)
            }.litheToolbarIconButton().accessibilityLabel("Diff settings").workbenchHoverHelp(Text("Diff settings"))
        }
        .padding(.horizontal, LitheTheme.Diff.toolbarHorizontalInset)
        .frame(height: LitheTheme.Diff.toolbarHeight)
        .background(RoundedRectangle(cornerRadius: LitheTheme.Diff.toolbarRadius).fill(LitheTheme.Diff.toolbarBackground))
        .overlay { RoundedRectangle(cornerRadius: LitheTheme.Diff.toolbarRadius).stroke(LitheTheme.Diff.toolbarBorder, lineWidth: 1) }
        .padding(.horizontal, LitheTheme.Diff.toolbarHorizontalInset)
        .padding(.top, LitheTheme.Diff.toolbarTopInset)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(LitheTheme.Diff.viewerBorder).frame(width: 1, height: 20).padding(.horizontal, 3)
    }

    private var files: [GitCommitFile] {
        guard feature.selectedGitCommit?.hash == context.commit.hash,
              feature.selectedGitCommitFiles.contains(where: { $0.id == context.file.id }) else { return [context.file] }
        return feature.selectedGitCommitFiles
    }

    private var fileIndex: Int? { files.firstIndex { $0.id == context.file.id } }

    private func navigateFile(by offset: Int) {
        guard let index = fileIndex, files.indices.contains(index + offset) else { return }
        onOpenCommitDiff(files[index + offset])
    }

    private func viewerButton(unified target: Bool) -> some View {
        Button { unified = target } label: {
            LitheIDEAIcon(resourcePath: target ? "expui/diff/unified" : "expui/diff/sideBySide",
                size: 16, preservesOriginalColors: true)
                .frame(width: LitheTheme.Diff.viewerButtonWidth, height: LitheTheme.Diff.viewerButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .litheRowHover(isActive: usesUnifiedPane == target, cornerRadius: LitheTheme.Diff.viewerRadius,
                       activeBackground: LitheTheme.Diff.viewerSelectedBackground)
        .accessibilityLabel(target ? "Unified view" : "Side-by-side view")
        .accessibilityValue(usesUnifiedPane == target ? "Selected" : "Not selected")
        .workbenchHoverHelp(Text(target ? "Unified view" : "Side-by-side view"))
    }

    private var versionHeader: some View {
        Group {
            if usesUnifiedPane {
                VStack(spacing: LitheTheme.Diff.titleGap) {
                    versionLabel(parentHash, path: context.path)
                    versionLabel(context.commit.shortHash, path: nil)
                }
            } else {
                HStack(spacing: 0) {
                    versionLabel(parentHash, path: context.path)
                    versionLabel(context.commit.shortHash, path: nil)
                }
            }
        }.padding(.vertical, LitheTheme.Diff.titleInset)
         .padding(.bottom, 1)
         .background(LitheTheme.Diff.background)
         .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.Diff.titleSeparator).frame(height: 1) }
    }

    private var parentHash: String { context.commit.parentHashes.first.map { String($0.prefix(8)) } ?? "Empty" }

    private func versionLabel(_ hash: String, path: String?) -> some View {
        HStack(spacing: 0) {
            LitheIDEAIcon(resourcePath: "expui/general/locked", size: LitheTheme.Diff.titleIconSize, preservesOriginalColors: true)
            Text(hash).font(LitheTheme.uiFont(size: 13, weight: .regular)).foregroundStyle(LitheTheme.Diff.titleForeground)
                .fixedSize()
            if let path {
                Text(path).font(LitheTheme.uiFont(size: 13, weight: .regular)).foregroundStyle(LitheTheme.Diff.pathForeground)
                    .lineLimit(1).truncationMode(.middle).padding(.leading, 8)
            }
            Spacer(minLength: 4)
        }.padding(.horizontal, LitheTheme.Diff.titleInset)
         .frame(maxWidth: .infinity).frame(minHeight: LitheTheme.Diff.titleIconSize)
    }

    private func diffContent(proxy: ScrollViewProxy) -> some View {
        // Patch hunk headers are metadata. Preserve source row IDs for existing navigation.
        let rows = feature.diffRows.filter { $0.kind != .information }
        let displayRows = collapsesUnchangedRegions
            ? DiffCollapse.plan(rows: rows, expandedRegionIDs: expandedRegionIDs)
            : rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        let kinds = displayRows.map { $0.layoutRow.kind }
        let layout = DiffSplitLayout.plan(displayRows: displayRows, kinds: kinds, gutterWidth: DiffLayoutMetrics.lineNumberGutterWidth(rows: rows))
        let unifiedLayout = DiffUnifiedLayout(rows: rows, displayRows: displayRows)
        let measuredWidth = DiffLayoutMetrics.contentWidth(rows: rows, viewportWidth: 0,
            minimumWidth: usesUnifiedPane ? 680 : 980, paneCount: usesUnifiedPane ? 1 : 2)
        let selectedIDs = Set(differenceIndexByRow.compactMap { $0.value == selectedDifferenceIndex ? $0.key : nil })
        return GeometryReader { geometry in
            if usesUnifiedPane {
                DiffUnifiedPaneView(layout: unifiedLayout, fileExtension: context.url.pathExtension,
                    contentWidth: measuredWidth, highlightsWords: highlightsWords, selectedRowIDs: selectedIDs,
                    onExpand: { expandedRegionIDs.insert($0.id) })
            } else {
                DiffSplitPaneView(displayRows: displayRows, kinds: kinds, layout: layout,
                    fileExtension: context.url.pathExtension, contentWidth: max(geometry.size.width, measuredWidth),
                    viewportWidth: geometry.size.width, highlightsWords: highlightsWords,
                    header: { position in AnyView(
                        HStack(spacing: 0) {
                            versionLabel(parentHash, path: context.path).frame(width: position).clipped()
                            versionLabel(context.commit.shortHash, path: nil)
                        }.padding(.vertical, LitheTheme.Diff.titleInset).padding(.bottom, 1)
                         .background(LitheTheme.Diff.background)
                         .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.Diff.titleSeparator).frame(height: 1) }
                    ) },
                    selectedRowIDs: selectedIDs, onExpand: { expandedRegionIDs.insert($0.id) })
            }
        }.background(LitheTheme.Diff.background)
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


}

private extension DiffRowKind {
    var isCommitDifference: Bool {
        switch self {
        case .changed, .addition, .removal: true
        case .context, .information: false
        }
    }
}

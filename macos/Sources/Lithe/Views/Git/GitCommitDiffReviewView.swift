import SwiftUI
import LitheGitModule

/// Read-only commit diff opened from the changed-files pane of Git Log.
/// Working-tree diffs keep using DiffReviewView because they expose stage and
/// discard actions; historical commit diffs deliberately do not.
struct GitCommitDiffReviewView: View {
    @ObservedObject var feature: GitFeatureModel
    let context: GitCommitDiffContext

    @State private var unified = false
    @State private var highlightsWords = true
    @State private var selectedDifferenceIndex = 0

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                toolbar(proxy: proxy)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                if usesUnifiedPane || feature.isLoadingDiff || feature.diffRows.isEmpty {
                    versionHeader
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
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
        .onChange(of: feature.diffRows.count) { _ in
            selectedDifferenceIndex = 0
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
            Spacer()
            Text("\(differenceStarts.count) differences")
                .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.primaryText)
                .padding(.trailing, 8)
            HStack(spacing: 0) {
                viewerButton(unified: false)
                viewerButton(unified: true)
            }
            LitheMenu {
                LitheContextMenuItem.toggle("Highlight words", isOn: $highlightsWords)
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Close diff") { feature.closeGitCommitDiff() }
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/settings", size: 16, preservesOriginalColors: true)
            }.litheToolbarIconButton().accessibilityLabel("Diff settings").workbenchHoverHelp(Text("Diff settings"))
        }
        .padding(.horizontal, 6).frame(height: 38)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func viewerButton(unified target: Bool) -> some View {
        Button { unified = target } label: {
            LitheIDEAIcon(resourcePath: target ? "expui/diff/unified" : "expui/diff/sideBySide",
                size: 16, preservesOriginalColors: true)
                .frame(width: 48, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .litheRowHover(isActive: usesUnifiedPane == target, cornerRadius: 3,
                       activeBackground: LitheTheme.hoverBackground)
        .overlay { RoundedRectangle(cornerRadius: 3).stroke(
            usesUnifiedPane == target ? LitheTheme.secondaryText.opacity(0.5) : LitheTheme.divider, lineWidth: 1) }
        .accessibilityLabel(target ? "Unified view" : "Side-by-side view")
        .accessibilityValue(usesUnifiedPane == target ? "Selected" : "Not selected")
        .workbenchHoverHelp(Text(target ? "Unified view" : "Side-by-side view"))
    }

    private var versionHeader: some View {
        Group {
            if usesUnifiedPane {
                VStack(spacing: 0) {
                    versionLabel(parentHash, path: context.path)
                    versionLabel(context.commit.shortHash, path: nil)
                }
            } else {
                HStack(spacing: 0) {
                    versionLabel(parentHash, path: context.path)
                    versionLabel(context.commit.shortHash, path: nil)
                }
            }
        }.background(LitheTheme.Diff.background)
    }

    private var parentHash: String { context.commit.parentHashes.first.map { String($0.prefix(8)) } ?? "Empty" }

    private func versionLabel(_ hash: String, path: String?) -> some View {
        HStack(spacing: 4) {
            LitheIDEAIcon(resourcePath: "expui/general/locked", size: 16, preservesOriginalColors: true)
            Text(hash).font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.primaryText)
            if let path {
                Text(path).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1).truncationMode(.middle).padding(.leading, 6)
            }
            Spacer(minLength: 4)
        }.padding(.horizontal, 4).frame(maxWidth: .infinity).frame(height: 22)
    }

    private func diffContent(proxy: ScrollViewProxy) -> some View {
        // Patch hunk headers are metadata. Preserve source row IDs for existing navigation.
        let rows = feature.diffRows.filter { $0.kind != .information }
        let displayRows = rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        let kinds = rows.map(\.kind)
        let layout = DiffSplitLayout.plan(displayRows: displayRows, kinds: kinds)
        let unifiedLayout = DiffUnifiedLayout(rows: rows)
        let measuredWidth = DiffLayoutMetrics.contentWidth(rows: rows, viewportWidth: 0,
            minimumWidth: usesUnifiedPane ? 680 : 980, paneCount: usesUnifiedPane ? 1 : 2)
        let selectedIDs = Set(differenceIndexByRow.compactMap { $0.value == selectedDifferenceIndex ? $0.key : nil })
        return GeometryReader { geometry in
            if usesUnifiedPane {
                DiffUnifiedPaneView(layout: unifiedLayout, fileExtension: context.url.pathExtension,
                    contentWidth: measuredWidth, highlightsWords: highlightsWords, selectedRowIDs: selectedIDs)
            } else {
                DiffSplitPaneView(displayRows: displayRows, kinds: kinds, layout: layout,
                    fileExtension: context.url.pathExtension, contentWidth: max(geometry.size.width, measuredWidth),
                    viewportWidth: geometry.size.width, highlightsWords: highlightsWords,
                    header: { position in AnyView(
                        HStack(spacing: 0) {
                            versionLabel(parentHash, path: context.path).frame(width: position).clipped()
                            versionLabel(context.commit.shortHash, path: nil)
                        }.background(LitheTheme.Diff.background)
                         .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.Diff.separator).frame(height: 1) }
                    ) },
                    selectedRowIDs: selectedIDs, onExpand: { _ in })
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

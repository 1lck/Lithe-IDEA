import SwiftUI
import LitheGitModule

/// Shared repository diff. Working changes retain mutation actions; saved/history inputs stay read-only.
struct RepositoryDiffView: View {
    @ObservedObject var feature: GitFeatureModel
    let context: GitCommitDiffContext?
    let change: GitChange?
    let onClose: () -> Void
    let onOpenFile: () -> Void
    let onOpenCommitDiff: (GitCommitFile) -> Void
    /// Family that renders and measures the commit diff. Defaults to the bundled
    /// monospaced family so existing call sites and tests keep their rendering.
    var fontFamily: String = EditorFontDefaults.monospacedFamily

    init(feature: GitFeatureModel, context: GitCommitDiffContext,
         onClose: @escaping () -> Void, onOpenFile: @escaping () -> Void,
         onOpenCommitDiff: @escaping (GitCommitFile) -> Void,
         fontFamily: String = EditorFontDefaults.monospacedFamily) {
        self.feature = feature; self.context = context; change = nil
        self.onClose = onClose; self.onOpenFile = onOpenFile
        self.onOpenCommitDiff = onOpenCommitDiff; self.fontFamily = fontFamily
    }

    init(feature: GitFeatureModel, change: GitChange,
         onClose: @escaping () -> Void, onOpenFile: @escaping () -> Void,
         fontFamily: String = EditorFontDefaults.monospacedFamily) {
        self.feature = feature; self.change = change; context = nil
        self.onClose = onClose; self.onOpenFile = onOpenFile
        onOpenCommitDiff = { _ in }; self.fontFamily = fontFamily
    }

    @State private var diffSearchQuery = ""
    @State private var selectedDiffSearchIndex = 0
    @FocusState private var diffSearchFocused: Bool
    @State private var showsSearch = false
    @State private var unified = false
    @State private var highlightsWords = true
    @State private var selectedDifferenceIndex = 0
    @State private var collapsesUnchangedRegions = false
    @State private var expandedRegionIDs: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                toolbar(proxy: proxy)
                if showsSearch { diffSearchControl(proxy: proxy).padding(.horizontal, 8) }
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
        .onChange(of: context?.id ?? change?.id ?? "") { _ in
            selectedDifferenceIndex = 0
            expandedRegionIDs = []
            selectedDiffSearchIndex = 0
        }
        .onChange(of: diffSearchQuery) { _ in selectedDiffSearchIndex = 0 }
    }

    private var usesUnifiedPane: Bool { unified || kind == .added || kind == .deleted }

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
            }.litheToolbarIconButton(isEnabled: kind != .deleted)
                .accessibilityLabel("Open in editor").workbenchHoverHelp(Text("Open in editor"))
            toolbarDivider
            if context != nil {
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
            }
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
            Button { showsSearch.toggle() } label: {
                LitheIDEAIcon(resourcePath: "expui/general/search", size: 16, preservesOriginalColors: true)
            }.litheToolbarIconButton().accessibilityLabel("Search diff")
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
                if let change {
                    for mode in GitDiffWhitespaceMode.allCases {
                        LitheContextMenuItem.action(mode.title, checked: feature.gitDiffWhitespaceMode == mode) {
                            Task { await feature.reloadSelectedChangeDiff(whitespace: mode) }
                        }
                    }
                    LitheContextMenuItem.separator
                    if change.isStaged && !change.hasWorkingTreeChange {
                        LitheContextMenuItem.action("Unstage") { Task { await feature.unstageSelectedChange() } }
                    } else {
                        LitheContextMenuItem.action("Stage File") { Task { await feature.stageSelectedChange() } }
                        LitheContextMenuItem.action("Discard") { feature.requestDiscardSelectedChange() }
                    }
                }
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
        guard let context else { return [] }
        if context.commit.hash.hasPrefix("saved:"), let snapshot = feature.savedDiffSnapshot {
            return snapshot.files.filter { $0.version == feature.savedDiffVersion }.map(\.file)
        }
        guard feature.selectedGitCommit?.hash == context.commit.hash,
              feature.selectedGitCommitFiles.contains(where: { $0.id == context.file.id }) else { return [context.file] }
        return feature.selectedGitCommitFiles
    }

    private var fileIndex: Int? { context.flatMap { value in files.firstIndex { $0.id == value.file.id } } }
    private var fileURL: URL { context?.url ?? change!.url }
    private var path: String { context?.path ?? change!.path }
    private var kind: GitChangeKind { context?.kind ?? change!.kind }

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
                    versionLabel(leftVersionTitle, path: change?.originalPath ?? path)
                    versionLabel(rightVersionTitle, path: change?.path)
                }
            } else {
                HStack(spacing: 0) {
                    versionLabel(leftVersionTitle, path: change?.originalPath ?? path)
                    versionLabel(rightVersionTitle, path: change?.path)
                }
            }
        }.padding(.vertical, LitheTheme.Diff.titleInset)
         .padding(.bottom, 1)
         .background(LitheTheme.Diff.background)
         .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.Diff.titleSeparator).frame(height: 1) }
    }

    private var leftVersionTitle: String {
        guard let change else { return context?.commit.parentHashes.first.map { String($0.prefix(8)) } ?? "Empty" }
        if change.kind == .added { return "Empty file" }
        if change.kind == .deleted { return "Deleted version" }
        if change.kind == .moved || change.kind == .copied { return "Original location" }
        if change.hasWorkingTreeChange { return "Index version" }
        return "Repository version"
    }

    private var rightVersionTitle: String {
        guard let change else { return context?.commit.shortHash ?? "" }
        if change.kind == .deleted { return "Empty file" }
        if change.kind == .added { return "Added version" }
        if change.kind == .moved { return "Moved version" }
        if change.kind == .copied { return "Copied version" }
        return change.isStaged && !change.hasWorkingTreeChange ? "Staged version" : "Current version"
    }


    private func versionLabel(_ hash: String, path: String?) -> some View {
        HStack(spacing: 0) {
            LitheIDEAIcon(resourcePath: "expui/general/locked", size: LitheTheme.Diff.titleIconSize, preservesOriginalColors: true)
            Text(change == nil ? hash : String(localized: String.LocalizationValue(hash))).font(LitheTheme.uiFont(size: 13, weight: .regular)).foregroundStyle(LitheTheme.Diff.titleForeground)
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
        var actionHunks: [DiffRowID: DiffHunk] = [:]
        if change != nil {
            let hunks = Dictionary(feature.diffHunks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            for row in rows where row.kind.isCommitDifference {
                if let id = row.hunkID, seen.insert(id).inserted, let hunk = hunks[id] { actionHunks[row.id] = hunk }
            }
        }
        let displayRows = collapsesUnchangedRegions
            ? DiffCollapse.plan(rows: rows, expandedRegionIDs: expandedRegionIDs, pinnedRowIDs: Set(diffSearchMatches))
            : rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        let kinds = displayRows.map { $0.layoutRow.kind }
        let layout = DiffSplitLayout.plan(displayRows: displayRows, kinds: kinds, gutterWidth: DiffLayoutMetrics.lineNumberGutterWidth(rows: rows, family: fontFamily))
        let unifiedLayout = DiffUnifiedLayout(rows: rows, displayRows: displayRows, fontFamily: fontFamily)
        let measuredWidth = DiffLayoutMetrics.contentWidth(rows: rows, viewportWidth: 0,
            minimumWidth: usesUnifiedPane ? 680 : 980, paneCount: usesUnifiedPane ? 1 : 2, family: fontFamily)
        let selectedIDs = Set(differenceIndexByRow.compactMap { $0.value == selectedDifferenceIndex ? $0.key : nil })
        return GeometryReader { geometry in
            if usesUnifiedPane {
                DiffUnifiedPaneView(layout: unifiedLayout, fileExtension: fileURL.pathExtension,
                    contentWidth: measuredWidth, highlightsWords: highlightsWords, selectedRowIDs: selectedIDs,
                    fontFamily: fontFamily, currentSearchMatchID: selectedDiffSearchRowID,
                    rowOverlay: { row in AnyView(hunkActions(actionHunks[row.id])) },
                    onExpand: { expandedRegionIDs.insert($0.id) })
            } else {
                DiffSplitPaneView(displayRows: displayRows, kinds: kinds, layout: layout,
                    fileExtension: fileURL.pathExtension, contentWidth: max(geometry.size.width, measuredWidth),
                    viewportWidth: geometry.size.width, highlightsWords: highlightsWords,
                    fontFamily: fontFamily,
                    header: { position in AnyView(
                        HStack(spacing: 0) {
                            versionLabel(leftVersionTitle, path: change?.originalPath ?? path).frame(width: position).clipped()
                            versionLabel(rightVersionTitle, path: change?.path)
                        }.padding(.vertical, LitheTheme.Diff.titleInset).padding(.bottom, 1)
                         .background(LitheTheme.Diff.background)
                         .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.Diff.titleSeparator).frame(height: 1) }
                    ) },
                    selectedRowIDs: selectedIDs, searchMatchIDs: Set(diffSearchMatches),
                    currentSearchMatchID: selectedDiffSearchRowID,
                    onExpand: { expandedRegionIDs.insert($0.id) }) { row, side in
                        if side == (row.kind == .removal ? .left : .right) { hunkActions(actionHunks[row.id]) }
                    }
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

    private func diffSearchControl(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 4) {
            LitheSystemIcon(systemImage: "magnifyingglass")
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)

            LitheSearchTextField("Search diff", text: $diffSearchQuery)
                .font(LitheTheme.uiFont(size: 11.5))
                .frame(width: 145)
                .focused($diffSearchFocused)
                .macReturnKeyHandler(isEnabled: diffSearchFocused) { isShiftPressed in
                    navigateDiffSearch(
                        by: isShiftPressed ? -1 : 1,
                        proxy: proxy
                    )
                }

            Text(diffSearchLabel)
                .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(minWidth: 34, alignment: .trailing)
                .monospacedDigit()

            Button {
                navigateDiffSearch(by: -1, proxy: proxy)
            } label: {
                Image(systemName: "chevron.up")
            }
            .litheIconButton()
            .disabled(diffSearchMatches.isEmpty)
            .help("Previous diff match")

            Button {
                navigateDiffSearch(by: 1, proxy: proxy)
            } label: {
                Image(systemName: "chevron.down")
            }
            .litheIconButton()
            .disabled(diffSearchMatches.isEmpty)
            .help("Next diff match")
        }
        .litheSearchField(isFocused: diffSearchFocused)
        .onAppear { diffSearchFocused = false }
    }

    private var diffSearchMatches: [DiffRowID] {
        let query = diffSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let foldedQuery = query.localizedLowercase
        return feature.diffRows.filter { $0.kind != .information }.compactMap { row in
            let texts = [row.left, row.rightText].compactMap { $0 }
            return texts.contains(where: { $0.localizedLowercase.contains(foldedQuery) }) ? row.id : nil
        }
    }

    private var selectedDiffSearchRowID: DiffRowID? {
        guard !diffSearchMatches.isEmpty else { return nil }
        let index = min(max(selectedDiffSearchIndex, 0), diffSearchMatches.count - 1)
        return diffSearchMatches[index]
    }

    private var diffSearchLabel: String {
        guard !diffSearchMatches.isEmpty else { return diffSearchQuery.isEmpty ? "" : "0/0" }
        let index = min(max(selectedDiffSearchIndex, 0), diffSearchMatches.count - 1)
        return "\(index + 1)/\(diffSearchMatches.count)"
    }

    private func navigateDiffSearch(by offset: Int, proxy: ScrollViewProxy) {
        let matches = diffSearchMatches
        guard !matches.isEmpty else { return }
        let current = min(max(selectedDiffSearchIndex, 0), matches.count - 1)
        let next = (current + offset + matches.count) % matches.count
        selectedDiffSearchIndex = next
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(matches[next], anchor: .center)
        }
    }

    @ViewBuilder
    private func hunkActions(_ hunk: DiffHunk?) -> some View {
        if let change, let hunk {
            DiffHunkActionsView(feature: feature, hunk: hunk, change: change,
                isMutationEnabled: feature.gitDiffWhitespaceMode == .doNotIgnore)
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

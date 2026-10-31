import LitheModuleAPI
import AppKit
import LitheSearchModule
import SwiftUI

enum SearchEverywhereQueryMode: Equatable {
    case workspace(String)
    case commands(String)

    init(query: String) {
        if query.hasPrefix("/") {
            self = .commands(String(query.dropFirst()))
        } else {
            self = .workspace(query)
        }
    }

    var workspaceQuery: String {
        switch self {
        case .workspace(let query): return query
        case .commands: return ""
        }
    }

    var workspaceSearchTaskID: String {
        switch self {
        case .workspace(let query): return "workspace:\(query)"
        case .commands: return "commands"
        }
    }

    var commandQuery: String? {
        switch self {
        case .workspace: return nil
        case .commands(let query): return query
        }
    }
}

enum SearchEverywhereResultSource: Equatable {
    case combinedWorkspaceNames
    case classes
    case files
    case symbols
    case actions(String)
    case commands(String)
    case text

    init(queryMode: SearchEverywhereQueryMode, scope: SearchEverywhereScope) {
        if let commandQuery = queryMode.commandQuery {
            self = .commands(commandQuery)
            return
        }

        switch scope {
        case .all: self = .combinedWorkspaceNames
        case .classes: self = .classes
        case .files: self = .files
        case .symbols: self = .symbols
        case .actions: self = .actions(queryMode.workspaceQuery)
        case .text: self = .text
        }
    }

    var emptyResultsMessage: String {
        switch self {
        case .commands:
            return "No matching commands"
        case .combinedWorkspaceNames:
            return "No matches in All"
        case .classes:
            return "No matches in Classes"
        case .files:
            return "No matches in Files"
        case .symbols:
            return "No matches in Symbols"
        case .actions:
            return "No matches in Actions"
        case .text:
            return "No matches in Text"
        }
    }
}

/// Owns the native window; interactive state lives in its hosting tree.
struct SearchEverywhereView: View {
    @ObservedObject var feature: SearchFeatureModel
    @ObservedObject var session: SearchSessionFeatureModel
    @ObservedObject var settings: AppSettings
    let actionMatches: (String) -> [LitheAction]
    let search: (String, ProjectSearchOptions) async -> Void
    let dismiss: () -> Void
    let openResult: (FileSearchResult) -> Void
    let performAction: (LitheAction) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL, Bool) -> Void
    let relativePath: (URL) -> String
    let moduleLabel: (URL) -> String
    var actionIcon: (LitheAction) -> AnyView? = { _ in nil }
    var loadPreviewDocument: (URL, UUID) async -> EditorDocument? = { _, _ in nil }
    var releasePreviewDocument: (URL, UUID) -> Void = { _, _ in }
    var makePreviewEditor: SourcePreviewEditorBuilder = SourcePreviewEditorContent.monaco
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    var body: some View {
        GeometryReader { geometry in
            LitheCenteredPopup(isPresented: Binding(
                get: { session.isSearchEverywhereVisible },
                set: { if !$0 { dismiss() } }
            ), topInset: 84, focusFirstTextField: true,
               contentUpdateKey: "\(geometry.size)|\(colorScheme)|\(locale.identifier)|\(LitheTheme.activeTheme.rawValue)") {
                SearchEverywhereContent(feature: feature, session: session, settings: settings,
                    actionMatches: actionMatches, search: search, dismiss: dismiss,
                    openResult: openResult, performAction: performAction, revealInFinder: revealInFinder,
                    copyPath: copyPath, relativePath: relativePath, moduleLabel: moduleLabel,
                    actionIcon: actionIcon, loadPreviewDocument: loadPreviewDocument, releasePreviewDocument: releasePreviewDocument,
                    makePreviewEditor: makePreviewEditor, availableSize: geometry.size)
            }
        }
    }
}

/// IDEA 风格的全局搜索：名称、来源过滤和预览共用面板内的状态与键盘导航。
private struct SearchEverywhereContent: View {
    @ObservedObject var feature: SearchFeatureModel
    @ObservedObject var session: SearchSessionFeatureModel
    @ObservedObject var settings: AppSettings
    let actionMatches: (String) -> [LitheAction]
    let search: (String, ProjectSearchOptions) async -> Void
    let dismiss: () -> Void
    let openResult: (FileSearchResult) -> Void
    let performAction: (LitheAction) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL, Bool) -> Void
    let relativePath: (URL) -> String
    let moduleLabel: (URL) -> String
    var actionIcon: (LitheAction) -> AnyView? = { _ in nil }
    var loadPreviewDocument: (URL, UUID) async -> EditorDocument? = { _, _ in nil }
    var releasePreviewDocument: (URL, UUID) -> Void = { _, _ in }
    var makePreviewEditor: SourcePreviewEditorBuilder = SourcePreviewEditorContent.monaco
    let availableSize: CGSize
    @Environment(\.locale) private var locale
    @State private var searchFocused = false
    @State private var inputFocusRequest = 0
    @State private var draftQuery: String?
    private var query: String {
        get { draftQuery ?? session.everywhereQuery }
        nonmutating set { draftQuery = newValue; session.everywhereQuery = newValue }
    }
    @State private var pageRequest = 0
    @State private var retryPage = false
    // nil follows the current first result until the user explicitly selects a row.
    @State private var selectedItemID: String?
    private var selectedIndex: Int {
        get { visibleItems.firstIndex { $0.id == selectedItemID } ?? 0 }
        nonmutating set {
            selectedItemID = visibleItems.indices.contains(newValue) ? visibleItems[newValue].id : nil
        }
    }
    // New searches and keyboard navigation reveal rows; mouse selection preserves the viewport.
    @State private var selectionRevealRevision = 0
    private var scope: SearchEverywhereScope {
        get { session.everywhereScope }
        nonmutating set { session.everywhereScope = newValue }
    }
    @State private var searchOptions = ProjectSearchOptions.default
    @State private var filterPresented = false
    @State private var editingExclusions = false
    private var enabledProviders: Set<SearchEverywhereProvider> {
        get { session.enabledEverywhereProviders }
        nonmutating set { session.enabledEverywhereProviders = newValue }
    }
    private var showsPreview: Bool {
        get { session.isEverywherePreviewVisible }
        nonmutating set { session.isEverywherePreviewVisible = newValue }
    }
    @State private var keyMonitor: Any?

    private enum SearchItem: Identifiable {
        case result(FileSearchResult)
        case action(LitheAction)

        var id: String {
            switch self {
            case .result(let result): "result:\(result.id)"
            case .action(let action): "action:\(action.id)"
            }
        }
    }

    private var visibleItems: [SearchItem] {
        switch resultSource {
        case .combinedWorkspaceNames:
            let values = feature.searchEverywhereResults
            let nameMatches = (enabledProviders.contains(.files) ? values.fileMatches : [])
                + (enabledProviders.contains(.classes) ? values.classMatches : [])
                + (enabledProviders.contains(.symbols) ? values.symbolMatches : [])
            let names = rankedResults(nameMatches)
            return names.filter { pageNumber($0) == 0 }
                + (enabledProviders.contains(.actions) ? actionMatches(query).map(SearchItem.action) : [])
                + names.filter { pageNumber($0) > 0 }
        case .classes:
            return results(in: feature.searchEverywhereResults.classMatches)
        case .files:
            return results(in: feature.searchEverywhereResults.fileMatches)
        case .symbols:
            return results(in: feature.searchEverywhereResults.symbolMatches)
        case .text:
            return results(in: feature.searchEverywhereResults.contentMatches)
        case .actions(let actionQuery), .commands(let actionQuery):
            return actionMatches(actionQuery).map(SearchItem.action)
        }
    }

    private var queryMode: SearchEverywhereQueryMode {
        SearchEverywhereQueryMode(query: query)
    }

    private var resultSource: SearchEverywhereResultSource {
        SearchEverywhereResultSource(queryMode: queryMode, scope: scope)
    }

    private struct RankedResult {
        let index: Int
        let score: Int
        let value: FileSearchResult
    }

    /// 按相关度降序。同分保持原顺序，避免逐字输入时行位置来回跳动。
    private func rankedResults(_ results: [FileSearchResult]) -> [SearchItem] {
        var ranked: [RankedResult] = []
        ranked.reserveCapacity(results.count)
        for (index, value) in results.enumerated() {
            ranked.append(
                RankedResult(index: index, score: SearchRelevance.score(value, query: query), value: value)
            )
        }
        ranked.sort { left, right in
            let leftPage = feature.searchEverywherePageByID[left.value.id] ?? 0
            let rightPage = feature.searchEverywherePageByID[right.value.id] ?? 0
            if leftPage != rightPage { return leftPage < rightPage }
            return left.score == right.score ? left.index < right.index : left.score > right.score
        }
        return ranked.map { SearchItem.result($0.value) }
    }

    private func pageNumber(_ item: SearchItem) -> Int {
        guard case .result(let result) = item else { return 0 }
        return feature.searchEverywherePageByID[result.id] ?? 0
    }

    private var searchTaskIdentity: String {
        "\(queryMode.workspaceSearchTaskID)|\(scope.rawValue)|\(session.everywhereResultKinds.map(\.rawValue).sorted())|\(searchOptions.cacheKey)|\(settings.searchExcludedPathPatterns)|\(settings.searchExclusionsEnabled)"
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            scopeTabs
            searchField
            if hasQuery {
                resultsWithPreview.frame(maxHeight: LitheTheme.SearchEverywhere.maxResultsHeight)
            }
        }
        .frame(width: min(LitheTheme.SearchEverywhere.preferredWidth, max(0, availableSize.width - 32)),
               height: min(hasQuery ? LitheTheme.SearchEverywhere.maxResultsHeight + 84 : 84,
                           max(0, availableSize.height - 100)), alignment: .top)
        .background(LitheTheme.SearchEverywhere.background)
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.popupCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.popupCornerRadius)
                .strokeBorder(LitheTheme.SearchEverywhere.border, lineWidth: 1)
        }
        .background(LitheCenteredPopup(isPresented: $editingExclusions,
            dialogTitle: L10n.string("Search exclusions", locale: locale), focusFirstTextField: true) {
            SearchEverywhereExclusionsEditor(settings: settings, dismiss: { editingExclusions = false })
        }.frame(width: 0, height: 0).allowsHitTesting(false))
        .onAppear {
            selectedItemID = nil
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        // beginSearchEverywhere publishes even when the popup is already visible.
        // Read the seeded query, then ask AppKit to focus the existing input again.
        .onReceive(session.$isSearchEverywhereVisible) { visible in
            guard visible else { return }
            draftQuery = session.everywhereQuery
            inputFocusRequest &+= 1
        }
        .onChange(of: query) { _ in
            selectedItemID = nil
            selectionRevealRevision &+= 1
        }
        .onChange(of: scope) { _ in
            selectedItemID = nil
            selectionRevealRevision &+= 1
        }
        .onChange(of: enabledProviders) { _ in
            selectedItemID = nil
            selectionRevealRevision &+= 1
        }
        .onChange(of: visibleItems.map(\.id)) { ids in
            if let selectedItemID, !ids.contains(selectedItemID) { self.selectedItemID = nil }
        }
        .onChange(of: searchTaskIdentity) { _ in
            feature.cancelSearchEverywhere()
            pageRequest = 0
        }
        .task(id: pageRequest) {
            guard pageRequest > 0 else { return }
            await feature.loadNextSearchPage(retry: retryPage)
        }
        .task(id: searchTaskIdentity) {
            if queryMode.commandQuery != nil || session.everywhereResultKinds.isEmpty {
                feature.clearSearchEverywhere()
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await search(queryMode.workspaceQuery, scope == .text ? searchOptions : .default)
        }
    }

    private var scopeTabs: some View {
        HStack(spacing: 8) {
            ForEach(SearchEverywhereScope.allCases) { item in
                Button {
                    scope = item
                } label: {
                    Text(LocalizedStringKey(item.rawValue))
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.searchFieldText)
                        .padding(.horizontal, 8)
                        .modifier(LitheToolWindowTabStyle(isSelected: scope == item, isActive: true))
                }
                .buttonStyle(.litheNoPress)
                .contentShape(Rectangle())
                .accessibilityAddTraits(scope == item ? .isSelected : [])
            }

            Spacer(minLength: 12)
                .frame(maxHeight: .infinity)
                .overlay { LithePopupDragArea() }
            Button { showsPreview.toggle() } label: {
                LitheIDEAIcon(resourcePath: "expui/general/previewVertically.svg", size: 16, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .background(showsPreview ? LitheTheme.hoverBackground : .clear)
            .accessibilityLabel("Show Preview")
            .accessibilityValue(showsPreview ? "On" : "Off")
            .help("Show Preview")
            if scope == .all || scope == .text { searchOptionsMenu }
            Button {
                dismiss()
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: 16, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .accessibilityLabel("Close (Esc)")
            .help("Close (Esc)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .padding(.top, 2)
        .frame(height: 42)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.SearchEverywhere.border).frame(height: 1)
        }
    }

    private var searchField: some View {
        LitheSearchField("", text: Binding(get: { query }, set: { query = $0 }),
                         background: LitheTheme.SearchEverywhere.background) {
            if feature.isSearchingEverywhere {
                ProgressView().controlSize(.mini)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Search Everywhere")
            }
            Text("Type / to see commands")
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.searchFieldPlaceholder)
                .allowsHitTesting(false)
        }
        .background(SearchEverywhereInputFocus(request: inputFocusRequest))
        .accessibilityLabel("Search Everywhere")
        .background(LitheToolWindowActivityTracker(isActive: $searchFocused))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
    }

    private func editExclusions() {
        filterPresented = false
        editingExclusions = true
    }

    private var searchOptionsMenu: some View {
        Button { filterPresented.toggle() } label: {
            // Changing the rendering branch would recreate the button's popup anchor.
            LitheIDEAIcon(resourcePath: "expui/general/filter.svg", size: 16,
                          preservesOriginalColors: false)
                .foregroundStyle(enabledProviders.count == SearchEverywhereProvider.allCases.count
                    && (!settings.searchExclusionsEnabled || settings.searchExcludedPathPatterns.isEmpty)
                    ? LitheTheme.toolWindowText : LitheTheme.accent)
        }
        .litheDropdown(isPresented: $filterPresented) {
            VStack(spacing: 0) {
                if scope == .all {
                    SearchEverywhereProviderFilter(selection: Binding(get: { enabledProviders }, set: { enabledProviders = $0 }),
                        settings: settings, editExclusions: editExclusions)
                } else {
                    VStack(alignment: .leading) {
                        SearchEverywhereProviderFilter(selection: .constant([]), settings: settings,
                            editExclusions: editExclusions, showsProviders: false)
                        Toggle("Match Case", isOn: $searchOptions.caseSensitive)
                        Toggle("Whole Words", isOn: $searchOptions.wholeWords)
                        Toggle("Regular Expression", isOn: $searchOptions.regularExpression)
                    }
                    .padding(8)
                    .frame(minWidth: 220)
                }
            }
        }
        .litheToolbarIconButton()
        .accessibilityIdentifier("search-everywhere-filter")
        .accessibilityLabel(scope == .text ? "Search options" : "Filter results")
        .help(scope == .text ? "Search options" : "Filter results")
    }

    @ViewBuilder
    private var resultsWithPreview: some View {
        if showsPreview {
            GeometryReader { geometry in
                LitheSplitPaneView(axis: .vertical, placement: .leading,
                    defaultSize: geometry.size.height * 0.45, minimum: 72,
                    maximum: max(72, geometry.size.height - 100), flexibleMinimum: 100) {
                    resultsList
                } flexible: {
                    if visibleItems.indices.contains(selectedIndex), case .result(let result) = visibleItems[selectedIndex] {
                        SearchEverywhereSourcePreview(result: result, query: query,
                            options: scope == .text ? searchOptions : .default, loadDocument: loadPreviewDocument, releaseDocument: releasePreviewDocument, makeEditor: makePreviewEditor)
                    } else {
                        placeholder("Select a file to preview")
                    }
                }
            }
        } else { resultsList }
    }

    @ViewBuilder
    private var resultsList: some View {
        let items = visibleItems
        let selectedID = items.first(where: { $0.id == selectedItemID })?.id ?? items.first?.id
        if items.isEmpty {
            if !feature.isSearchingEverywhere {
                placeholder(resultSource.emptyResultsMessage)
            }
        } else {
            LitheTreeList(
                Array(items.enumerated()), id: \.element.id,
                selection: Binding(get: { selectedID }, set: { selectedItemID = $0 }),
                retainsSearchFocus: true
            ) { index, item in
                itemRow(item, index: index, selected: item.id == selectedID)
                    .background {
                        // A lazy list may not instantiate its last row until it is visible.
                        if index == max(0, items.count - Int(LitheScrollLoadTrigger.prefetchDistance / LitheTheme.Tree.rowHeight)) {
                            LitheScrollLoadTrigger(continuationID: feature.searchEverywhereResults.nextCursor,
                                isEnabled: !feature.isSearchingEverywhere && !feature.searchEverywhereFailed) {
                                    retryPage = false
                                    pageRequest += 1
                                }
                        }
                    }
            }
        }
        if feature.searchEverywhereFailed {
            Button("Retry") {
                retryPage = true
                pageRequest += 1
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: SearchItem, index: Int, selected: Bool) -> some View {
        switch item {
        case .result(let result):
            resultRow(result, index: index, selected: selected, showsLine: result.kind != .file)
        case .action(let action):
            actionRow(action, selected: selected)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 34)
    }

    private func resultRow(_ result: FileSearchResult, index: Int, selected: Bool, showsLine: Bool) -> some View {
        // 文件夹按钮与整行点击是两个独立目标，所以并排放而不是嵌套，
        // 否则嵌套的 Button 收不到点击。
        HStack(spacing: 8) {
            Button {
                let event = NSApp.currentEvent
                if showsPreview && event?.type != .keyDown && event?.clickCount != 2 { selectedItemID = SearchItem.result(result).id }
                else { openResult(result) }
            } label: {
                HStack(spacing: 8) {
                    LitheIcon(kind: iconKind(for: result), size: 16)
                        .frame(width: 16)

                    // 对齐 IDEA：名字和路径左侧连排，而不是把路径推到右端。
                    Text(SearchEverywhereNameText.highlighted(result, selected: selected,
                        foreground: session.everywhereGitStatus.change(relativePath: result.url.standardizedFileURL.path)?.fileNameColor
                            ?? LitheTheme.primaryText))
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if showsLine, let line = result.line {
                        Text(":\(line)")
                            .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(containerPath(for: result.url))
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if result.kind == .content {
                        Text(result.preview)
                            .font(LitheTheme.uiFont(size: 10.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Text(moduleLabel(for: result.url))
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .accessibilityIdentifier("search-everywhere-result-\(index)")
            .accessibilityAction(.default) { openResult(result) }
            .accessibilityAction(named: Text("Open")) { openResult(result) }

            Button {
                revealInFinder(result.url)
            } label: {
                LitheIcon(kind: .folder, size: 13)
            }
            .buttonStyle(.litheNoPress)
            .help("Show in Finder")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .litheContextMenu {
            [
                .action("Open", systemImage: "doc.text", action: {
                    openResult(result)
                }),
                .action("Show in Finder", systemImage: "folder", action: {
                    revealInFinder(result.url)
                }),
                .submenu("Copy Path / Reference", items: [
                    .action("Copy Path", action: {
                        copyPath(result.url, false)
                    }),
                    .action("Copy Relative Path", action: {
                        copyPath(result.url, true)
                    })
                ])
            ]
        }
    }

    /// 结果所在目录（不含文件名本身），文件直接位于工作区根下时为空。
    private func containerPath(for url: URL) -> String {
        let relative = relativePath(url)
        let parent = (relative as NSString).deletingLastPathComponent
        return parent
    }

    /// 结果归属的 Maven 模块 artifactID；非 Maven 项目或匹配不到时回退到顶层目录名。
    private func moduleLabel(for url: URL) -> String {
        moduleLabel(url)
    }

    private func actionRow(_ action: LitheAction, selected: Bool) -> some View {
        Button {
            // Native pointer dispatch can still reach the closure of a disabled
            // row; use the same execution gate as the keyboard path.
            if action.isEnabled { performAction(action) }
        } label: {
            HStack(spacing: 8) {
                if let icon = actionIcon(action) {
                    icon.foregroundStyle(selected ? LitheTheme.toolWindowSelectedText : LitheTheme.secondaryText)
                } else {
                    Color.clear.frame(width: WorkbenchContributionIcon.Role.action.size)
                }
                Group {
                    if action.localizesTitle { Text(LocalizedStringKey(action.title)) }
                    else { Text(verbatim: action.title) }
                }
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(LocalizedStringKey(action.subtitle))
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(action.group.rawValue))
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                    if let keyEquivalent = action.keyEquivalent {
                        Text(keyEquivalent)
                            .font(LitheTheme.uiFont(size: 10, design: .monospaced))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.45)
    }

    private func iconKind(for result: FileSearchResult) -> LitheIconKind {
        switch result.kind {
        case .file, .content:
            return LitheIcons.kind(for: result.url, isDirectory: false)
        case .type:
            return .javaClass
        case .symbol:
            return .javaGeneric
        }
    }

    private func results(in results: [FileSearchResult]) -> [SearchItem] {
        results.map(SearchItem.result)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard session.isSearchEverywhereVisible else { return event }
            guard !filterPresented, !editingExclusions, !(event.window?.parent is NSPanel) else { return event }
            guard !showsPreview || searchFocused
                || (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true
                || event.keyCode == 53 else { return event }
            switch event.keyCode {
            case 125: // Arrow Down
                if !visibleItems.isEmpty { selectedIndex = min(selectedIndex + 1, visibleItems.count - 1) }
                selectionRevealRevision &+= 1
                return nil
            case 126: // Arrow Up
                if !visibleItems.isEmpty { selectedIndex = max(selectedIndex - 1, 0) }
                selectionRevealRevision &+= 1
                return nil
            case 123, 124: // Arrow Left / Right
                moveScope(by: event.keyCode == 124 ? 1 : -1)
                return nil
            case 48: // Tab / Shift-Tab
                let isShiftDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
                moveScope(by: isShiftDown ? -1 : 1)
                return nil
            case 36, 76: // Return / Enter
                performSelectedItem()
                return nil
            case 53: // Escape
                dismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func moveScope(by offset: Int) {
        let scopes = SearchEverywhereScope.allCases
        guard let currentIndex = scopes.firstIndex(of: scope) else { return }
        let nextIndex = (currentIndex + offset + scopes.count) % scopes.count
        scope = scopes[nextIndex]
    }

    private func performSelectedItem() {
        guard visibleItems.indices.contains(selectedIndex) else { return }
        switch visibleItems[selectedIndex] {
        case .result(let result): openResult(result)
        case .action(let action): if action.isEnabled { performAction(action) }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

struct SearchEverywhereExclusionsEditor: View {
    @ObservedObject var settings: AppSettings
    let dismiss: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One pattern per line: `*.log`, `**/.*/`, `.*`, `cache/`. Only affects this Search Everywhere window.")
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            LitheTextEditor(text: $draft, height: 140, focus: $focused)
                .accessibilityLabel("Search exclusions")
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Spacer()
                Button("Cancel", action: dismiss)
                    .buttonStyle(LitheActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("search-exclusions-cancel")
                Button("Apply") {
                    settings.searchExcludedPathPatterns = draft.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    dismiss()
                }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                .accessibilityIdentifier("search-exclusions-apply")
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .frame(width: 470)
        .background {
            LitheCommitDialogStyle.background
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
        }
        .environment(\.lithePointingHandCursorEnabled, false)
        .onAppear {
            draft = settings.searchExcludedPathPatterns.joined(separator: "\n")
            focused = true
        }
        .onExitCommand(perform: dismiss)
    }
}

struct SearchEverywhereProviderFilter: View {
    @Binding var selection: Set<SearchEverywhereProvider>
    var settings: AppSettings? = nil
    var editExclusions: () -> Void = {}
    var showsProviders = true
    @State private var selectedRow: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if let settings {
                        HStack(spacing: 0) {
                            Button {
                                selectedRow = "exclusions"
                                settings.searchExclusionsEnabled.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    LitheIDEAIcon(resourcePath: settings.searchExclusionsEnabled
                                        ? "commit/checkBoxSelected.svg" : "commit/checkBox.svg",
                                        size: 24, preservesOriginalColors: true)
                                    Text("Search exclusions").font(LitheTheme.uiFont(size: 13))
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: LitheDropdownMetrics.rowHeight, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityRepresentation {
                                Toggle("Search exclusions", isOn: Binding(get: { settings.searchExclusionsEnabled },
                                    set: { settings.searchExclusionsEnabled = $0 }))
                                    .accessibilityIdentifier("search-exclusions-toggle")
                            }
                            Button(action: editExclusions) {
                                LitheIDEAIcon(resourcePath: "expui/general/edit.svg", size: LitheTheme.Metrics.toolbarIconSize)
                            }
                            .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize,
                                cornerRadius: 4, hoverBackground: LitheTheme.toolbarHoverBackground,
                                pressedBackground: LitheTheme.toolbarPressedBackground))
                            .accessibilityLabel("Edit search exclusions")
                            .accessibilityIdentifier("search-exclusions-edit")
                            .help("Edit search exclusions")
                        }
                        .foregroundStyle(selectedRow == "exclusions" ? LitheTheme.settingsSelectionText : LitheTheme.primaryText)
                        .litheRowHover(isActive: selectedRow == "exclusions",
                            cornerRadius: LitheDropdownMetrics.rowCornerRadius,
                            activeBackground: LitheTheme.settingsSelection,
                            hoverBackground: LitheTheme.Tree.inactiveSelection)
                    }
                    if showsProviders {
                        ForEach(SearchEverywhereProvider.allCases.sorted { $0.rawValue < $1.rawValue }, id: \.self) { provider in
                            let checked = Binding(get: { selection.contains(provider) }, set: {
                                if $0 { selection.insert(provider) } else { selection.remove(provider) }
                            })
                            Button {
                                selectedRow = provider.rawValue
                                checked.wrappedValue.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    LitheIDEAIcon(resourcePath: checked.wrappedValue ? "commit/checkBoxSelected.svg" : "commit/checkBox.svg",
                                        size: 24, preservesOriginalColors: true)
                                    Text(LocalizedStringKey(provider.rawValue)).font(LitheTheme.uiFont(size: 13))
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(LitheDropdownRowStyle(isSelected: selectedRow == provider.rawValue, horizontalPadding: 0,
                                hoverBackground: LitheTheme.Tree.inactiveSelection))
                            .accessibilityRepresentation { Toggle(LocalizedStringKey(provider.rawValue), isOn: checked) }
                        }
                    }
                }
                .padding(LitheDropdownMetrics.popupPadding)
            }
            .litheScrollViewChrome()
            .overlay { Rectangle().strokeBorder(LitheTheme.SearchEverywhere.filterBorder, lineWidth: 1).allowsHitTesting(false) }
            if showsProviders {
                HStack(spacing: LitheTheme.ActionButton.spacing) {
                    Button("All") { selection = Set(SearchEverywhereProvider.allCases) }
                    Button("None") { selection = [] }
                    Button("Invert") { selection = Set(SearchEverywhereProvider.allCases).subtracting(selection) }
                }
                .buttonStyle(LitheActionButtonStyle())
                .padding(5)
            }
        }
        // Three welcome-standard buttons, with shared gaps and the existing outer insets.
        .frame(width: 3 * LitheTheme.ActionButton.minimumWidth + 2 * LitheTheme.ActionButton.spacing + 10, height: showsProviders ? 200 : 36)
        // ElementsChooser is a table/Panel surface, not Popup.background.
        .background(LitheTheme.settingsListSurface)
    }
}

enum SearchEverywhereNameText {
    static func highlighted(_ result: FileSearchResult, selected: Bool, foreground: Color = LitheTheme.primaryText) -> AttributedString {
        let name = result.symbolName ?? result.url.lastPathComponent
        let fileForeground = result.isIgnored == true ? LitheTheme.Commit.fileIgnored : foreground
        guard selected else {
            var text = AttributedString(name)
            text.foregroundColor = fileForeground
            return text
        }
        var text = AttributedString()
        var cursor = name.startIndex
        for fragment in result.nameMatchRanges {
            guard fragment.start >= 0, fragment.length > 0,
                  fragment.start <= name.utf16.count,
                  fragment.length <= name.utf16.count - fragment.start,
                  let range = Range(NSRange(location: fragment.start, length: fragment.length), in: name),
                  range.lowerBound >= cursor else { continue }
            text += AttributedString(name[cursor..<range.lowerBound])
            var match = AttributedString(name[range])
            match.backgroundColor = LitheTheme.SearchEverywhere.matchBackground
            match.foregroundColor = LitheTheme.SearchEverywhere.matchForeground
            text += match
            cursor = range.upperBound
        }
        text += AttributedString(name[cursor...])
        // Explicit match foreground wins over the file-status foreground.
        text.foregroundColor = fileForeground
        for run in Array(text.runs) where run.backgroundColor != nil {
            text[run.range].foregroundColor = LitheTheme.SearchEverywhere.matchForeground
        }
        return text
    }
}

struct SearchEverywhereSourcePreview: View {
    let result: FileSearchResult
    let query: String
    var options: ProjectSearchOptions = .default
    let loadDocument: (URL, UUID) async -> EditorDocument?
    var releaseDocument: (URL, UUID) -> Void = { _, _ in }
    var makeEditor: SourcePreviewEditorBuilder = SourcePreviewEditorContent.monaco
    @State private var document: EditorDocument?
    @State private var isLoading = true
    @State private var presentationID = UUID()
    @State private var previewRequest: (url: URL, id: UUID)?

    var body: some View {
        Group {
            if let document {
                makeEditor(document, MonacoPreviewConfiguration(line: result.line ?? 1, query: query,
                    matchCase: options.caseSensitive, wholeWord: options.wholeWords,
                    regex: options.regularExpression, presentationID: presentationID))
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Could not load file preview").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .clipped()
        .accessibilityLabel("Read-only file preview")
        .task(id: result.url) {
            releaseCurrentPreview()
            let url = result.url, requestID = UUID()
            previewRequest = (url, requestID)
            isLoading = true
            let loaded = await loadDocument(url, requestID)
            guard !Task.isCancelled, previewRequest?.id == requestID else {
                releaseDocument(url, requestID)
                return
            }
            document = loaded
            isLoading = false
        }
        .onDisappear { releaseCurrentPreview() }
    }

    private func releaseCurrentPreview() {
        document = nil
        guard let request = previewRequest else { return }
        previewRequest = nil
        releaseDocument(request.url, request.id)
    }
}

/// Focuses the Search Everywhere input each time the popup is shown or reseeded.
/// The popup panel selects restored text when it takes focus; for the seeded
/// command prefix the caret goes after "/" so typing filters commands.
private struct SearchEverywhereInputFocus: NSViewRepresentable {
    let request: Int

    func makeNSView(context: Context) -> SearchEverywhereInputFocusView { SearchEverywhereInputFocusView() }

    func updateNSView(_ view: SearchEverywhereInputFocusView, context: Context) {
        view.request(request)
    }
}

final class SearchEverywhereInputFocusView: NSView {
    private var pending = 0
    private var handled = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func request(_ value: Int) {
        pending = value
        schedule()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedule()
    }

    private func schedule() {
        guard pending != handled, window != nil else { return }
        // Run after the popup finishes presenting, so its own focus and selection come first.
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        guard pending != handled, let window,
              let field = Self.textField(in: window.contentView, within: convert(bounds, to: nil))
        else { return }
        handled = pending
        if field.currentEditor() == nil || window.firstResponder !== field.currentEditor() {
            window.makeFirstResponder(field)
        }
        if field.stringValue == "/", let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: 1, length: 0)
        }
    }

    /// The search row also holds an icon and trailing accessories, so match the
    /// editable field that lies inside this helper's frame rather than its center.
    private static func textField(in view: NSView?, within rect: NSRect) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable,
           rect.contains(field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)) {
            return field
        }
        return view.subviews.lazy.compactMap { textField(in: $0, within: rect) }.first
    }
}
